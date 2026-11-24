// iPhone come Joy-Con: l'app "VJC Phone" manda tasti, stick e movimento via Wi-Fi.
//
// Rete: UDP sulla rete locale, servizio Bonjour "_vjc2phone._udp" pubblicato dal Mac
// (l'iPhone lo trova da solo). Ogni iPhone diventa un giocatore con il proprio
// dispositivo virtuale, come un Wii Remote: Joy-Con classico (L, R o la coppia) o Joy-Con 2.
//
// Pacchetti iPhone → Mac (little endian, "VJP2"):
//   tipo 1, ingresso: modo (0 Joy-Con sinistro, 1 destro, 2 coppia che si muove insieme (Kart),
//     3/4 coppia con solo il destro/sinistro in mano (Sports)), flag (bit 0: in Sports si muovono
//     tutti e due), n campioni,
//     seq (u32, ultimo campione), tasti (u32, bit = PhoneLink.buttons), stick sinistro x/y e
//     stick destro x/y (i16, su positivo), n × campione (dal più recente): dt (f32, s),
//     giroscopio x/y/z (f32, gradi/s), accelerazione x/y/z (f32, g, forza specifica: +1 g in su da fermo).
//     Assi DSU del controller (+X destra, +Y fuori dalla faccia, +Z verso il giocatore): per un
//     Joy-Con singolo il telefono disteso che punta allo schermo, per la coppia il telefono in
//     orizzontale come un gamepad. L'iPhone fa già la conversione dai suoi assi.
//   tipo 2, saluto: modo, flag, lunghezza nome (u8), nome UTF-8, lunghezza id (u8), id del telefono
//     (UTF-8, stabile: riconosce lo stesso telefono quando torna).
// Pacchetti Mac → iPhone ("VJM2"):
//   tipo 1, stato: vibrazione bassa/alta (u8), uscita attiva (u8), giocatore (u8),
//     uscita (u8: 0 classico, 1 Joy-Con 2), tasti ricevuti (u32: per controllare dal telefono
//     che ogni tasto arrivi), campioni di movimento al secondo (u16).
//
// Ogni pacchetto ripete gli ultimi campioni: se il Wi-Fi ne perde uno, arriva col
// successivo. Quelli persi del tutto non si inventano (come nei buchi del Wii Remote).

import SwiftUI
import Network
import simd

enum PhoneLink {
    static let service = "_vjc2phone._udp"
    static let inMagic: [UInt8] = Array("VJP2".utf8)
    static let outMagic: [UInt8] = Array("VJM2".utf8)
    /// Bit i del campo tasti = buttons[i].
    static let buttons: [JoyButton] = [.a, .b, .x, .y, .r, .zr, .slR, .srR, .plus, .home, .rStick,
                                       .up, .down, .left, .right, .l, .zl, .slL, .srL, .minus, .capture, .lStick]
    static let sampleSize = 28
}

/// Come si usa l'iPhone.
/// - Un Joy-Con da solo: per l'emulatore è un controller tenuto in orizzontale.
/// - Coppia (Kart): in orizzontale come un volante, il movimento va a tutti e due.
/// - Sports: la coppia, perché Switch Sports accetta solo Joy-Con in coppia (stili Handheld +
///   JoyDual), ma in mano c'è solo un Joy-Con verticale (l'iPhone); l'altro resta fermo, disteso.
enum PhoneMode: Equatable {
    case left, right, pair, sportsRight, sportsLeft
    init(_ byte: UInt8) {
        switch byte {
        case 0: self = .left
        case 2: self = .pair
        case 3: self = .sportsRight
        case 4: self = .sportsLeft
        default: self = .right
        }
    }
    /// Joy-Con pubblicati.
    var sides: Set<Int> { self == .left ? [0] : self == .right ? [1] : [0, 1] }
    /// Joy-Con che si muovono con l'iPhone.
    var moving: Set<Int> {
        switch self {
        case .left, .sportsLeft: return [0]
        case .right, .sportsRight: return [1]
        case .pair: return [0, 1]
        }
    }
    var title: String {
        switch self {
        case .left: return "Joy-Con sinistro da solo"
        case .right: return "Joy-Con destro da solo"
        case .pair: return "Kart: coppia a volante"
        case .sportsRight: return "Sports: in mano il destro"
        case .sportsLeft: return "Sports: in mano il sinistro"
        }
    }
    var outputMode: OutputMode { self == .left ? .left : self == .right ? .right : .pair }
    /// Switch Sports vuole Joy-Con classici in coppia. Per Mario Kart si sceglie sul Mac: con
    /// l'emulatore che prende i Joy-Con da GameController (es. Mario Kart World) la coppia
    /// classica diventa due giocatori, e va meglio il Joy-Con 2 (un solo controller).
    var wantsClassic: Bool { self == .sportsRight || self == .sportsLeft }
}

/// Lettore little endian di un pacchetto.
private struct PacketReader {
    let data: [UInt8]
    var at = 0
    var remaining: Int { data.count - at }
    mutating func u8() -> UInt8? { guard remaining >= 1 else { return nil }; defer { at += 1 }; return data[at] }
    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { at += 2 }
        return UInt16(data[at]) | UInt16(data[at + 1]) << 8
    }
    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { at += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at + $1]) << (8 * UInt32($1)) }
    }
    mutating func i16() -> Int16? { u16().map { Int16(bitPattern: $0) } }
    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
}

/// Un campione di movimento dall'iPhone, assi DSU.
struct PhoneSample {
    var dt: Double
    var gyro: SIMD3<Double>      // gradi/s
    var accel: SIMD3<Double>     // g
}

/// Un iPhone collegato: un giocatore con il proprio Joy-Con virtuale (o la coppia).
@MainActor
final class PhonePlayer: ObservableObject, @MainActor Identifiable {
    let id = UUID()
    private(set) var connection: NWConnection
    weak var hub: PhoneHub?
    /// Pacchetti arrivati di recente; senza, il Joy-Con resta acceso fermo per un po'.
    @Published private(set) var linked = true
    @Published private(set) var name = "iPhone"
    private(set) var phoneID = ""
    @Published private(set) var mode = PhoneMode.right
    /// Sports: anche il Joy-Con che non è in mano si muove (scelta sull'iPhone).
    @Published private(set) var bothMove = false
    private var moving: Set<Int> { bothMove && mode.sides.count == 2 ? mode.sides : mode.moving }
    @Published var number = 1
    @Published var enabled: Bool { didSet { save(enabled, "enabled"); apply() } }
    @Published var output: WiiOutput { didSet { save(output.rawValue, "output"); apply() } }
    @Published var rumble: Bool { didSet { save(rumble, "rumble") } }
    @Published private(set) var outputConnected = false
    @Published private(set) var rate = 0          // campioni al secondo
    @Published private(set) var pressed: [JoyButton] = []

    private let defaults = UserDefaults.standard
    private var bridge: SwitchBridge?
    private var joyCon2: JoyCon2Output?
    private var buttons: UInt32 = 0
    private var stickL = SIMD2<Double>.zero, stickR = SIMD2<Double>.zero
    private var accel = SIMD3<Double>(0, 1, 0)
    private var lastSeq: UInt32?
    private var samplesThisSecond = 0
    private(set) var named = false
    let created = ProcessInfo.processInfo.systemUptime
    var lastPacket = ProcessInfo.processInfo.systemUptime

    /// Impostazioni per nome del telefono: "phone.<nome>.output"…
    private func save(_ v: Any, _ k: String) { if named { defaults.set(v, forKey: "phone.\(name).\(k)") } }

    init(connection: NWConnection) {
        self.connection = connection
        enabled = true
        output = .joyCon
        rumble = true
    }

    /// Al primo saluto: carica le impostazioni salvate per questo telefono. Se lo stesso
    /// telefono era già collegato (app riaperta, Wi-Fi caduto) il suo Joy-Con prende questa
    /// connessione e questo giocatore sparisce: per il gioco il controller non si è mai scollegato.
    private func adopt(name newName: String, id: String) {
        guard !named else { return }
        if hub?.handOver(from: self, id: id) == true { return }
        name = newName
        phoneID = id
        let d = defaults
        d.register(defaults: ["phone.\(name).enabled": true, "phone.\(name).output": WiiOutput.joyCon.rawValue,
                              "phone.\(name).rumble": true])
        enabled = d.bool(forKey: "phone.\(name).enabled")
        output = WiiOutput(rawValue: d.string(forKey: "phone.\(name).output") ?? "") ?? .joyCon
        rumble = d.bool(forKey: "phone.\(name).rumble")
        named = true
        apply()
    }

    // MARK: Pacchetti

    /// Il telefono è tornato con una nuova connessione.
    func take(_ c: NWConnection) {
        connection.cancel()
        connection = c
        lastSeq = nil
        lastPacket = ProcessInfo.processInfo.systemUptime
    }

    func handle(_ data: [UInt8]) {
        guard data.count >= 8, Array(data[0..<4]) == PhoneLink.inMagic else { return }
        lastPacket = ProcessInfo.processInfo.systemUptime
        if !linked { linked = true }
        var r = PacketReader(data: data, at: 4)
        guard let type = r.u8(), let modeByte = r.u8(), let flags = r.u8() else { return }
        let both = flags & 1 != 0
        if both != bothMove { bothMove = both }
        let newMode = PhoneMode(modeByte)
        if newMode != mode {
            mode = newMode
            if mode.wantsClassic && output != .joyCon { output = .joyCon }   // didSet salva e applica
            apply()
        }
        switch type {
        case 2:
            guard let n = r.u8(), r.remaining >= Int(n) else { return }
            let s = String(decoding: data[r.at..<(r.at + Int(n))], as: UTF8.self)
            r.at += Int(n)
            var id = ""
            if let k = r.u8(), r.remaining >= Int(k) { id = String(decoding: data[r.at..<(r.at + Int(k))], as: UTF8.self) }
            adopt(name: s.isEmpty ? "iPhone" : s, id: id)
        case 1:
            guard let count = r.u8(), let seq = r.u32(), let b = r.u32(),
                  let lx = r.i16(), let ly = r.i16(), let rx = r.i16(), let ry = r.i16(),
                  r.remaining >= Int(count) * PhoneLink.sampleSize else { return }
            var samples: [PhoneSample] = []      // dal più recente
            for _ in 0..<count {
                guard let dt = r.f32(), let gx = r.f32(), let gy = r.f32(), let gz = r.f32(),
                      let ax = r.f32(), let ay = r.f32(), let az = r.f32() else { return }
                samples.append(PhoneSample(dt: Double(dt), gyro: SIMD3(Double(gx), Double(gy), Double(gz)),
                                           accel: SIMD3(Double(ax), Double(ay), Double(az))))
            }
            buttons = b
            stickL = SIMD2(Double(lx), Double(ly)) / 32767
            stickR = SIMD2(Double(rx), Double(ry)) / 32767
            // Nuovi = quelli dopo l'ultimo già usato. Un seq molto più basso = app riaperta.
            var fresh = samples.count
            if let last = lastSeq {
                let ahead = Int64(seq) - Int64(last)
                if ahead <= 0 && ahead > -400 { fresh = 0 } else if ahead > 0 { fresh = min(samples.count, Int(ahead)) }
            }
            if fresh > 0 || lastSeq == nil { lastSeq = seq }
            for s in samples.prefix(fresh).reversed() { feed(s) }
            push()
        default:
            break
        }
    }

    /// Un campione di movimento verso il dispositivo virtuale: nella coppia vanno a tutti e due
    /// i Joy-Con, che si muovono insieme (es. il volante in Mario Kart).
    private func feed(_ s: PhoneSample) {
        samplesThisSecond += 1
        accel = s.accel
        let dt = min(0.1, max(0, s.dt))
        let g = s.gyro * kJoyConGyroPerDps
        if let b = bridge {
            for side in moving {
                let j = dsuToJoyCon(g, side: side)
                b.addGyroSample(side: side, rate: (j.x, j.y, j.z), dt: dt)
            }
        }
        joyCon2?.addGyroSample(rate: g, dt: dt)
    }

    /// Assi DSU → assi del Joy-Con (punta, lato, faccia): le stesse corrispondenze del Wii
    /// Remote verticale e del DualSense (sono rotazioni, niente specchi).
    private func dsuToJoyCon(_ v: SIMD3<Double>, side: Int) -> SIMD3<Double> {
        side == 0 ? SIMD3(-v.z, -v.x, v.y) : SIMD3(-v.z, v.x, -v.y)
    }

    private var pressedButtons: [JoyButton] {
        PhoneLink.buttons.enumerated().compactMap { i, b in buttons & (1 << UInt32(i)) != 0 ? b : nil }
    }

    // MARK: Uscite

    /// Il dispositivo virtuale c'è solo con l'iPhone collegato e dopo il suo saluto.
    func apply() {
        let active = enabled && named
        if active && output == .joyCon {
            if bridge?.sides != mode.sides {
                bridge?.stop()
                let b = SwitchBridge(sides: mode.sides)
                b.gyroShare = 0.9            // campioni regolari: si consegna quasi tutto subito
                b.start()
                bridge = b
            }
        } else {
            bridge?.stop()
            bridge = nil
        }
        if active && output == .joyCon2 {
            if joyCon2 == nil {
                let j = JoyCon2Output()
                j.share = 0.5
                j.start()
                joyCon2 = j
            }
        } else {
            joyCon2?.stop()
            joyCon2 = nil
        }
        push()
        refreshConnected()
    }

    func shutdown(closing: Bool = true) {
        bridge?.stop(); bridge = nil
        joyCon2?.stop(); joyCon2 = nil
        if closing { connection.cancel() }
    }

    private func refreshConnected() {
        let c = output == .joyCon ? (bridge?.connected ?? false) : (joyCon2?.connected ?? false)
        if c != outputConnected { outputConnected = c }
    }

    private func push() {
        let held = pressedButtons
        if let b = bridge {
            var left = SwitchPadState(), right = SwitchPadState()
            for t in held { t.press(left: &left, right: &right) }
            func stick(_ v: SIMD2<Double>, _ s: inout SwitchPadState) {
                s.stickX = UInt16(kStickCenter + max(-1, min(1, v.x)) * kStickRange)
                s.stickY = UInt16(kStickCenter + max(-1, min(1, v.y)) * kStickRange)
            }
            stick(stickL, &left); stick(stickR, &right)
            func clamp(_ x: Double) -> Int16 { Int16(max(-32767, min(32767, x.rounded()))) }
            var states: [Int: SwitchPadState] = [:]
            for side in mode.sides {
                var s = side == 0 ? left : right
                // Il Joy-Con che non è in mano sta fermo, disteso a faccia in su (+1 g fuori dalla faccia).
                let a = dsuToJoyCon((moving.contains(side) ? accel : SIMD3(0, 1, 0)) * 4096, side: side)
                s.accel = (clamp(a.x), clamp(a.y), clamp(a.z))
                states[side] = s
            }
            b.update(states, integrated: moving)
        }
        if let j = joyCon2 {
            var f = JoyCon2Output.Frame()
            var l: UInt32 = 0, r: UInt32 = 0
            for t in held { let bits = t.joyCon2Bits; l |= bits.0; r |= bits.1 }
            let up = l & JCLeft.up != 0, down = l & JCLeft.down != 0
            let left = l & JCLeft.left != 0, right = l & JCLeft.right != 0
            f.buttons = convertButtonsToHID(left: l, right: r, up: up, down: down, leftDir: left, rightDir: right)
            f.dpad = hidDpad(up: up, down: down, left: left, right: right)
            func hid(_ v: Double) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
            f.lx = hid(stickL.x); f.ly = hid(-stickL.y)       // HID: giù positivo
            f.rx = hid(stickR.x); f.ry = hid(-stickR.y)
            f.triggerL = l & JCLeft.zl != 0 ? 255 : 0
            f.triggerR = r & JCRight.zr != 0 ? 255 : 0
            f.accel = accel * 4096
            j.update(f)
        }
    }

    // MARK: Ciclo a 60 Hz

    private var ticks = 0

    func tick(uiFrame: Bool) {
        ticks += 1
        refreshConnected()
        // Mezzo secondo senza pacchetti: tasti rilasciati e stick al centro, niente resta premuto.
        if linked, ProcessInfo.processInfo.systemUptime - lastPacket > 0.5 {
            linked = false
            buttons = 0
            stickL = .zero; stickR = .zero
            push()
        }
        if uiFrame {
            let p = pressedButtons
            if p != pressed { pressed = p }
        }
        if ticks % 60 == 0 { rate = samplesThisSecond; samplesThisSecond = 0 }
        if ticks % 3 == 0 { sendStatus() }           // ~20 volte al secondo
    }

    private func sendStatus() {
        var motors: (UInt8, UInt8) = (0, 0)
        if rumble && enabled {
            motors = output == .joyCon ? (bridge?.rumble(for: mode.sides) ?? (0, 0)) : (joyCon2?.rumble ?? (0, 0))
        }
        var packet = PhoneLink.outMagic + [1, motors.0, motors.1, outputConnected ? 1 : 0, UInt8(number),
                                           output == .joyCon ? 0 : 1]
        for i in 0..<4 { packet.append(UInt8((buttons >> (8 * UInt32(i))) & 0xFF)) }
        let r = UInt16(min(rate, 65535))
        packet += [UInt8(r & 0xFF), UInt8(r >> 8)]
        connection.send(content: Data(packet), completion: .idempotent)
    }

    var seenAs: String { output == .joyCon ? mode.outputMode.seenAs : OutputMode.joyCon2.seenAs }
}

/// Pubblica il servizio Bonjour e accoglie gli iPhone (fino a 4).
@MainActor
final class PhoneHub: ObservableObject {
    @Published private(set) var phones: [PhonePlayer] = []
    @Published private(set) var status = "Avvio…"
    private var listener: NWListener?
    private var lastRestart = 0.0

    init() { start() }

    func start() {
        lastRestart = ProcessInfo.processInfo.systemUptime
        do {
            let l = try NWListener(using: .udp)
            l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: PhoneLink.service)
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerState(state) }
            }
            l.newConnectionHandler = { [weak self] c in
                MainActor.assumeIsolated { self?.accept(c) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            status = "Impossibile aprire la rete: \(error.localizedDescription)"
        }
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready: status = "In ascolto (porta \(listener?.port?.rawValue ?? 0)): apri VJC Phone sull'iPhone, sulla stessa rete Wi-Fi"
        case .failed(let e): status = "Rete non disponibile: \(e.localizedDescription)"; listener?.cancel(); listener = nil
        case .waiting(let e): status = "In attesa della rete: \(e.localizedDescription)"
        default: break
        }
    }

    private func accept(_ c: NWConnection) {
        guard phones.count < 4 else { c.cancel(); return }
        let p = PhonePlayer(connection: c)
        p.hub = self
        phones.append(p)
        renumber()
        c.start(queue: .main)
        receive(p)
    }

    private func receive(_ p: PhonePlayer) {
        let c = p.connection
        c.receiveMessage { [weak self, weak p] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, let p, p.connection === c else { return }   // connessione passata a un altro giocatore
                if let data { p.handle([UInt8](data)) }
                if error == nil { self.receive(p) } else { self.drop(p) }
            }
        }
    }

    /// Un telefono già noto è tornato: il suo giocatore (con il Joy-Con ancora acceso) prende
    /// la nuova connessione, quello appena creato sparisce senza aver mai creato un dispositivo.
    func handOver(from fresh: PhonePlayer, id: String) -> Bool {
        guard !id.isEmpty, let old = phones.first(where: { $0 !== fresh && $0.phoneID == id && !$0.linked }) else { return false }
        old.take(fresh.connection)
        fresh.shutdown(closing: false)
        phones.removeAll { $0 === fresh }
        renumber()
        receive(old)
        return true
    }

    private func drop(_ p: PhonePlayer) {
        guard phones.contains(where: { $0 === p }) else { return }
        p.shutdown()
        phones.removeAll { $0 === p }
        renumber()
    }

    private func renumber() {
        for (i, p) in phones.enumerated() where p.number != i + 1 { p.number = i + 1 }
    }

    func shutdown() {
        phones.forEach { $0.shutdown() }
        phones = []
        listener?.cancel()
    }

    func tick(uiFrame: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        // Niente pacchetti da 30 s: app chiusa o telefono fuori rete. Prima di allora il Joy-Con
        // resta acceso e fermo (schermo bloccato, Wi-Fi che cade): il gioco non perde il giocatore.
        for p in phones where now - p.lastPacket > 30 { drop(p) }
        // Connessioni che non si presentano (app vecchia, pacchetti d'altro tipo): via subito, non occupano un posto.
        for p in phones where !p.named && now - p.created > 3 { drop(p) }
        for p in phones { p.tick(uiFrame: uiFrame) }
        if listener == nil, now - lastRestart > 5 { start() }
    }
}

// MARK: - Interfaccia

struct PhoneSection: View {
    @ObservedObject var hub: PhoneHub

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "iphone.gen3").font(.title2)
                VStack(alignment: .leading) {
                    Text("iPhone").font(.title3.bold())
                    Text("Senza Wii Remote: l'iPhone come Joy-Con, via Wi-Fi").foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(hub.status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hub.phones.isEmpty {
                Text("Nessun iPhone collegato. Mac e iPhone devono stare sulla stessa rete Wi-Fi; alla prima apertura l'iPhone chiede il permesso per la rete locale: rispondi Consenti.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(hub.phones) { p in
                Divider()
                PhoneRow(phone: p)
            }
        }
    }
}

struct PhoneRow: View {
    @ObservedObject var phone: PhonePlayer

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("iPhone \(phone.number) · \(phone.name)").font(.headline)
                Text([phone.mode.title + (phone.bothMove && phone.mode.sides.count == 2 ? " (si muovono tutti e due)" : ""),
                      phone.linked ? "\(phone.rate) campioni/s" : "in attesa dell'iPhone (resta collegato 30 s)",
                      phone.outputConnected ? "→ \(phone.seenAs)" : "controller virtuale non attivo"].joined(separator: " · "))
                    .font(.caption).foregroundStyle(phone.outputConnected ? Color.green : Color.secondary)
                Text(phone.pressed.isEmpty ? " " : phone.pressed.map(\.title).joined(separator: " "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $phone.output) {
                ForEach(WiiOutput.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            Toggle("Vibrazione", isOn: $phone.rumble)
            Toggle("", isOn: $phone.enabled).toggleStyle(.switch).labelsHidden()
                .help("Attiva o spegne il controller virtuale di questo iPhone. Il lato si sceglie sull'iPhone.")
        }
        .padding(.vertical, 4)
    }
}
