// Collegamento con VirtualJoyCon2 sul Mac: trova il Mac con Bonjour e parla UDP.
// Il formato dei pacchetti è descritto in Sorgenti/PhoneLink.swift (lato Mac).

import Foundation
import Network
import UIKit

/// Tasto del Joy-Con; rawValue = bit nel campo tasti (stesso ordine di PhoneLink.buttons sul Mac).
enum PhoneButton: Int, CaseIterable {
    case a, b, x, y, r, zr, slR, srR, plus, home, rStick
    case up, down, left, right, l, zl, slL, srL, minus, capture, lStick
    var bit: UInt32 { 1 << UInt32(rawValue) }
}

/// Un campione di movimento negli assi DSU (telefono disteso che punta allo schermo:
/// +X destra, +Y su, +Z verso il giocatore).
struct MotionSample {
    var dt: Float
    var gyro: SIMD3<Float>       // gradi/s
    var accel: SIMD3<Float>      // g, forza specifica (+1 g in su da fermo)
}

/// Stato che il Mac rimanda: vibrazione, uscita e, per la verifica, i tasti che riceve.
struct MacStatus: Equatable {
    var low: UInt8 = 0, high: UInt8 = 0
    var outputActive = false
    var player = 0
    var joyCon2 = false
    var received: UInt32 = 0     // tasti premuti come li vede il Mac
    var rate = 0                 // campioni di movimento al secondo arrivati al Mac
}

/// Costruisce e invia i pacchetti. Lo chiamano sia il main thread (tasti) sia la coda
/// del movimento (campioni a 100-200 Hz), quindi tutto è sotto lucchetto.
final class Sender: @unchecked Sendable {
    private static let magic: [UInt8] = Array("VJP2".utf8)
    private static let redundancy = 3           // campioni ripetuti in ogni pacchetto

    private let lock = NSLock()
    private var connection: NWConnection?
    private var buttons: UInt32 = 0
    private var sticks: [Int16] = [0, 0, 0, 0]      // sinistro x/y, destro x/y
    private var side: UInt8 = 1
    private var flags: UInt8 = 0                    // bit 0: Sports, si muovono tutti e due i Joy-Con
    private var _steering = false
    private var steer: Float = 0                    // −1…1, sterzo dal giroscopio sullo stick sinistro

    /// Mario Kart: lo sterzo del telefono (a volante) muove lo stick sinistro in orizzontale.
    var steering: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _steering }
        set { lock.lock(); _steering = newValue; if !newValue { steer = 0 }; lock.unlock() }
    }
    /// Angolo del volante per lo sterzo pieno, e zona morta al centro (gradi).
    static let fullLock: Float = 40, steerDeadzone: Float = 3

    /// `up`: gravità ("su") negli assi DSU del controller tenuto a volante. Chiamato dalla coda
    /// del movimento prima di `add`, così lo sterzo parte con lo stesso pacchetto.
    func setSteer(up: SIMD3<Float>) {
        let wheel = atan2(-up.x, -up.z) * 180 / .pi       // a destra positivo, 0 = in piedi davanti a te
        let mag = max(0, abs(wheel) - Self.steerDeadzone) / (Self.fullLock - Self.steerDeadzone)
        lock.lock(); steer = min(1, mag) * (wheel >= 0 ? 1 : -1); lock.unlock()
    }
    private var recent: [MotionSample] = []     // dal più recente
    private var seq: UInt32 = 0
    private var lastSend = 0.0

    func setConnection(_ c: NWConnection?) {
        lock.lock(); connection = c; recent = []; lock.unlock()
    }

    /// `mode`: 0 Joy-Con sinistro, 1 destro, 2 coppia.
    func setInput(buttons b: UInt32, left l: SIMD2<Float>, right r: SIMD2<Float>, mode: Int, bothMove: Bool = false) {
        lock.lock()
        buttons = b
        sticks = [l.x, l.y, r.x, r.y].map { Int16(max(-1, min(1, $0)) * 32767) }
        side = UInt8(mode)
        flags = bothMove ? 1 : 0
        lock.unlock()
        sendInput()
    }

    func add(_ s: MotionSample) {
        lock.lock()
        seq &+= 1
        recent.insert(s, at: 0)
        if recent.count > Self.redundancy { recent.removeLast() }
        lock.unlock()
        sendInput()
    }

    /// Senza movimento (es. simulatore) i tasti arrivano comunque, almeno 20 volte al secondo.
    func keepAlive() {
        lock.lock(); let idle = ProcessInfo.processInfo.systemUptime - lastSend > 0.05; lock.unlock()
        if idle { sendInput() }
    }

    /// `id`: identificativo stabile del telefono, per farsi riconoscere quando si torna.
    func sendHello(name: String, id: String) {
        lock.lock()
        let n = Array(name.utf8.prefix(60)), i = Array(id.utf8.prefix(60))
        let p = Self.magic + [2, side, flags, UInt8(n.count)] + n + [UInt8(i.count)] + i
        let c = connection
        lock.unlock()
        c?.send(content: Data(p), completion: .idempotent)
    }

    private func sendInput() {
        lock.lock()
        guard let c = connection else { lock.unlock(); return }
        var p = Self.magic + [1, side, flags, UInt8(recent.count)]
        p.reserveCapacity(20 + recent.count * 28)
        func u16(_ v: UInt16) { p += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) { for i in 0..<4 { p.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        func f32(_ v: Float) { u32(v.bitPattern) }
        u32(seq)
        u32(buttons)
        var out = sticks
        // Sterzo dal giroscopio, se il dito non muove lo stick sinistro in orizzontale (in verticale
        // può esserci la mira del lancio dell'oggetto, che non deve fermare lo sterzo).
        if _steering && out[0] == 0 { out[0] = Int16(steer * 32767) }
        for v in out { u16(UInt16(bitPattern: v)) }
        for s in recent {
            f32(s.dt)
            f32(s.gyro.x); f32(s.gyro.y); f32(s.gyro.z)
            f32(s.accel.x); f32(s.accel.y); f32(s.accel.z)
        }
        lastSend = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        c.send(content: Data(p), completion: .idempotent)
    }
}

/// Trova i Mac con VirtualJoyCon2 aperta e tiene il collegamento con quello scelto.
@MainActor
final class MacLink: ObservableObject {
    static let service = "_vjc2phone._udp"

    @Published private(set) var macs: [String] = []
    @Published private(set) var macName: String?
    @Published private(set) var status = MacStatus()
    /// Il Mac ha risposto negli ultimi 2 secondi.
    @Published private(set) var linked = false
    @Published private(set) var browseError: String?

    let sender = Sender()
    var onStatus: ((MacStatus) -> Void)?
    var helloName = UIDevice.current.name
    private let phoneID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var connection: NWConnection?
    private var lastReply = 0.0
    private var timer: Timer?
    private var ticks = 0

    /// Mac scelto a mano (se ce ne sono più di uno); altrimenti il primo trovato.
    private var preferred: String? {
        get { UserDefaults.standard.string(forKey: "preferredMac") }
        set { UserDefaults.standard.set(newValue, forKey: "preferredMac") }
    }

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: .udp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.found(results) }
        }
        b.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed(let e), .waiting(let e): self?.browseError = "Rete locale: \(e.localizedDescription)"
                case .ready: self?.browseError = nil
                default: break
                }
            }
        }
        b.start(queue: .main)
        browser = b
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func choose(_ name: String) {
        preferred = name
        connect(to: name)
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        endpoints = [:]
        for r in results {
            if case let .service(name, _, _, _) = r.endpoint { endpoints[name] = r.endpoint }
        }
        macs = endpoints.keys.sorted()
        if let current = macName, endpoints[current] != nil { return }
        if let p = preferred, endpoints[p] != nil { connect(to: p) } else if let first = macs.first { connect(to: first) }
    }

    private func connect(to name: String) {
        guard let endpoint = endpoints[name] else { return }
        connection?.cancel()
        let c = NWConnection(to: endpoint, using: .udp)
        c.stateUpdateHandler = { [weak self, weak c] state in
            MainActor.assumeIsolated {
                guard let self, let c, c === self.connection else { return }
                if case .ready = state { self.sender.sendHello(name: self.helloName, id: self.phoneID) }
                if case .failed = state { self.reconnect() }
            }
        }
        connection = c
        macName = name
        lastReply = ProcessInfo.processInfo.systemUptime
        sender.setConnection(c)
        c.start(queue: .main)
        receive(c)
    }

    private func reconnect() {
        guard let name = macName else { return }
        connect(to: name)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, let c, c === self.connection else { return }
                if let data { self.handle([UInt8](data)) }
                if error == nil { self.receive(c) }
            }
        }
    }

    private func handle(_ d: [UInt8]) {
        guard d.count >= 16, Array(d[0..<4]) == Array("VJM2".utf8), d[4] == 1 else { return }
        lastReply = ProcessInfo.processInfo.systemUptime
        let received = (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[10 + $1]) << (8 * UInt32($1)) }
        let s = MacStatus(low: d[5], high: d[6], outputActive: d[7] != 0, player: Int(d[8]), joyCon2: d[9] != 0,
                          received: received, rate: Int(d[14]) | Int(d[15]) << 8)
        if s != status { status = s }
        if !linked { linked = true }
        onStatus?(s)
    }

    private func tick() {
        ticks += 1
        sender.keepAlive()
        if ticks % 20 == 0 { sender.sendHello(name: helloName, id: phoneID) }        // ogni secondo
        let silent = ProcessInfo.processInfo.systemUptime - lastReply
        if linked && silent > 2 {
            linked = false
            status = MacStatus()
            onStatus?(status)
        }
        // Il Mac non risponde da un po' (riaperto, rete cambiata): si riparte da capo.
        if macName != nil && silent > 4 { lastReply = ProcessInfo.processInfo.systemUptime; reconnect() }
    }
}
