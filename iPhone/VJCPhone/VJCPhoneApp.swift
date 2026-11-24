// VJC Phone — l'iPhone come Joy-Con per VirtualJoyCon2 sul Mac.
//
// Si tiene come un Wii Remote: disteso, schermo in su, la parte alta che punta allo
// schermo. Tasti e stick sullo schermo, movimento da giroscopio e accelerometro,
// vibrazione dal gioco. Tutto via Wi-Fi verso il Mac (Bonjour + UDP).

import SwiftUI
import UIKit
import simd

enum VolumeKey: Hashable {
    case up, down
    var other: VolumeKey { self == .up ? .down : .up }
}

/// Orientamento consentito: verticale per un Joy-Con, orizzontale (parte alta a sinistra) per la coppia.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .portrait
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }
}

@main
struct VJCPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var pad = Pad()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ControllerView(pad: pad, link: pad.link)
                .onAppear { pad.start(); pad.applyOrientation() }
                .onChange(of: phase) { _, p in
                    UIApplication.shared.isIdleTimerDisabled = p != .background
                    // Inattiva (un avviso, il Centro di Controllo) non è background: il Joy-Con continua.
                    if p == .active { pad.resume() } else if p == .background { pad.pause() }
                }
        }
    }
}

/// Setup: come si presenta l'iPhone al Mac (stesso numero del campo "modo" nei pacchetti).
enum Setup: Int, CaseIterable, Identifiable {
    case single_left = 0, single_right = 1, kart = 2, sports = 3, sportsLefty = 4, kartGyro = 5
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .sports: return "Switch Sports · iPhone = Joy-Con R"
        case .sportsLefty: return "Switch Sports · iPhone = Joy-Con L"
        case .kart: return "Mario Kart · levetta"
        case .kartGyro: return "Mario Kart · giroscopio"
        case .single_left: return "Joy-Con sinistro da solo"
        case .single_right: return "Joy-Con destro da solo"
        }
    }
    var detail: String {
        switch self {
        case .sports: return "Coppia L+R: in mano il destro (l'iPhone), il sinistro resta fermo"
        case .sportsLefty: return "Coppia L+R: in mano il sinistro (l'iPhone), il destro resta fermo"
        case .kart: return "Coppia L+R a volante, si sterza con lo stick sinistro"
        case .kartGyro: return "Coppia L+R a volante, si sterza ruotando il telefono; pulsanti F1 al centro"
        case .single_left, .single_right: return "Per l'emulatore è un controller tenuto in orizzontale"
        }
    }
    /// Sullo schermo i tasti del Joy-Con sinistro (frecce) invece che del destro.
    var leftLayout: Bool { self == .single_left || self == .sportsLefty }
    var isSports: Bool { self == .sports || self == .sportsLefty }
    var isKart: Bool { self == .kart || self == .kartGyro }
    /// Il "modo" che arriva al Mac: i due volanti sono tutti e due la coppia L+R.
    var modeByte: Int { self == .kartGyro ? Setup.kart.rawValue : rawValue }
}

/// Stato del controller: setup, tasti premuti, stick. Ogni cambiamento parte subito verso il Mac.
@MainActor
final class Pad: ObservableObject {
    let link = MacLink()
    private let motion = MotionSource()
    private let rumble = Rumble()
    private let camera = CameraKeepAlive()
    private var active = false

    /// Il setup (rawValue di Setup); "side" per compatibilità con le versioni con solo L/R.
    @Published var side: Int {
        didSet {
            UserDefaults.standard.set(side, forKey: "side")
            // Un tasto tenuto durante il cambio non riceverebbe più il rilascio: si riparte da zero.
            held = 0; stickL = .zero; stickR = .zero; volumeHeld = [:]; touchR = false; itemAim = 0
            motion.landscape = pair
            applyGain()
            applySteering()
            loadCalibration()
            applyOrientation()
            send()
        }
    }
    var pair: Bool { setup.isKart }
    var setup: Setup {
        get { Setup(rawValue: side) ?? .sports }
        set { side = newValue.rawValue }
    }
    var leftLayout: Bool { setup.leftLayout }
    @Published var clicks: Bool { didSet { UserDefaults.standard.set(clicks, forKey: "clicks") } }
    /// Tasti volume come tasti del Joy-Con (con la fotocamera accesa, vedi VolumeKeys.swift).
    @Published var volumeKeys: Bool {
        didSet { UserDefaults.standard.set(volumeKeys, forKey: "volumeKeys"); updateCamera() }
    }
    /// Volume + e − scambiati, se sul telefono arrivano al contrario.
    @Published var swapVolume: Bool { didSet { UserDefaults.standard.set(swapVolume, forKey: "swapVolume") } }
    /// Potenza dello swing in Sports (1 = reale). Il putter del golf vuole di più: lo swing è lento e corto.
    @Published var swingGain: Double {
        didSet { UserDefaults.standard.set(swingGain, forKey: "swingGain"); applyGain() }
    }
    /// Profilo Golf in Sports (vedi MotionSource.golf).
    @Published var golf: Bool { didSet { UserDefaults.standard.set(golf, forKey: "golf"); applyGain() } }
    /// Ultima posizione al tasto in golf: angolo della punta verso terra e se è stata applicata.
    @Published private(set) var aim: (degrees: Float, applied: Bool)?
    /// Sports: anche il Joy-Con che non è in mano si muove con l'iPhone (se il gioco legge l'altro).
    @Published var sportsBothMove: Bool { didSet { UserDefaults.standard.set(sportsBothMove, forKey: "sportsBothMove"); send() } }
    @Published private(set) var cameraState = CameraKeepAlive.State.off
    /// Mario Kart, sperimentale: ZR anche con la pressione leggera sul Controllo fotocamera, e il
    /// clic senza pressione leggera (tasto Azione, Volume −) diventa ZL. Spenta di serie: nella
    /// prova iOS non ha segnalato la pressione leggera, e allora la fotocamera dava ZL.
    @Published var kartTouchR: Bool {
        didSet { UserDefaults.standard.set(kartTouchR, forKey: "kartTouchZR"); if !kartTouchR { controlsActive(false) } }
    }
    /// Controlli della fotocamera attivi = dito sul Controllo fotocamera (con pressione leggera).
    @Published private(set) var cameraControlActive = false
    /// Esito dell'ultima calibrazione (o di quella salvata) per il setup attuale.
    @Published private(set) var calibration: String?

    /// Calibrazioni separate: a volante (Kart) e da telecomando (Sports, Joy-Con da soli).
    private var calibrationKey: String { "calibration." + (pair ? "kart" : "remote") }

    /// La posizione di adesso diventa quella "giusta": disteso e puntato allo schermo (Sports),
    /// in piedi davanti a te come un volante dritto (Kart). Si salva per il gruppo di setup.
    func calibrate() {
        let (q, deg) = motion.calibrate(target: pair ? SIMD3(0, 0, -1) : SIMD3(0, 1, 0))
        UserDefaults.standard.set([q.vector.x, q.vector.y, q.vector.z, q.vector.w], forKey: calibrationKey)
        calibration = String(format: "Calibrato (corretti %.0f°)", deg)
        rumble.click()
    }

    func resetCalibration() {
        UserDefaults.standard.removeObject(forKey: calibrationKey)
        motion.setCalibration(nil)
        calibration = nil
    }

    private func loadCalibration() {
        if let v = UserDefaults.standard.array(forKey: calibrationKey) as? [Float], v.count == 4 {
            let q = simd_quatf(vector: SIMD4(v[0], v[1], v[2], v[3]))
            motion.setCalibration(q)
            calibration = String(format: "Calibrato (corretti %.0f°)", q.angle * 180 / .pi)
        } else {
            motion.setCalibration(nil)
            calibration = nil
        }
    }

    /// Ultimi eventi dei tasti fisici (verifica): cosa manda iOS e che tasto diventa.
    @Published private(set) var hardwareEvents: [String] = []
    private let started = Date()

    func logHardware(_ s: String) {
        let line = String(format: "%7.2f  %@", Date().timeIntervalSince(started), s)
        print("[tasti] " + line)
        hardwareEvents.insert(line, at: 0)
        if hardwareEvents.count > 12 { hardwareEvents.removeLast() }
    }
    /// Tasto Joy-Con tenuto premuto da Volume + e da Volume −.
    @Published private(set) var volumeHeld: [VolumeKey: PhoneButton] = [:]
    @Published private(set) var held: UInt32 = 0
    @Published private(set) var stickL = SIMD2<Float>.zero
    @Published private(set) var stickR = SIMD2<Float>.zero
    /// Ultimo campione di movimento (verifica).
    var latestMotion: MotionSample? { motion.latest }
    var motionAvailable: Bool { motion.available }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["side": Setup.sports.rawValue, "clicks": true, "volumeKeys": true, "swapVolume": false,
                              "sportsBothMove": false, "swingGain": 1.0, "golf": false, "kartTouchZR": false])
        side = d.integer(forKey: "side")
        clicks = d.bool(forKey: "clicks")
        volumeKeys = d.bool(forKey: "volumeKeys")
        swapVolume = d.bool(forKey: "swapVolume")
        sportsBothMove = d.bool(forKey: "sportsBothMove")
        swingGain = d.double(forKey: "swingGain")
        golf = d.bool(forKey: "golf")
        kartTouchR = d.bool(forKey: "kartTouchZR")
        motion.landscape = pair
        applyGain()
        applySteering()
        loadCalibration()
    }

    private func applySteering() {
        link.sender.steering = setup == .kartGyro
        send()
    }

    /// Potenza e profilo Golf valgono solo in Sports: Kart e i Joy-Con da soli restano reali.
    private func applyGain() {
        motion.gain = setup.isSports ? swingGain : 1
        motion.golf = setup.isSports && golf
        if !(setup.isSports && golf) { motion.clearAim(); aim = nil }
    }

    /// Tasto con cui il gioco ricalibra la mazza: X sul Joy-Con destro, freccia su sul sinistro.
    var calibrateButton: PhoneButton { leftLayout ? .up : .x }

    func applyOrientation() {
        let mask: UIInterfaceOrientationMask = pair ? .landscapeRight : .portrait
        AppDelegate.orientations = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    func start() {
        link.onStatus = { [weak self] s in self?.rumble.set(low: s.low, high: s.high) }
        camera.onControlsActive = { [weak self] on in self?.controlsActive(on) }
        camera.onSlide = { [weak self] v in self?.logHardware(String(format: "dito che scorre sul Controllo fotocamera (%.2f)", v)) }
        send()                               // il lato salvato, prima del primo saluto al Mac
        link.start()
        resume()
    }

    func resume() {
        active = true
        let sender = link.sender, source = motion
        motion.start { s in
            if sender.steering { sender.setSteer(up: source.up) }
            sender.add(s)
        }
        updateCamera()
    }

    /// In background niente movimento e tasti rilasciati: il Joy-Con resta fermo.
    func pause() {
        active = false
        motion.stop()
        updateCamera()
        volumeHeld = [:]
        held = 0
        stickL = .zero; stickR = .zero
        send()
        rumble.set(low: 0, high: 0)
    }

    func set(_ b: PhoneButton, _ down: Bool) {
        let new = down ? held | b.bit : held & ~b.bit
        guard new != held else { return }
        if down && clicks { rumble.click() }
        // Golf: la posizione al tasto si prende prima che la pressione parta, così il gioco
        // ricalibra già sul telefono "dritto in giù".
        if down && b == calibrateButton && setup.isSports && golf { aim = motion.aimDown() }
        held = new
        send()
    }

    /// `right`: lo stick destro (nel modo Joy-Con destro c'è solo quello).
    func setStick(_ v: SIMD2<Float>, right: Bool) {
        if right { stickR = v } else { stickL = v }
        send()
    }

    // MARK: Tasti volume

    var volumeReady: Bool { volumeKeys && cameraState == .running }

    /// Volume + = grilletto (ZR / ZL), Volume − = X / freccia su (es. calibrare il colpo nel golf).
    /// Mario Kart (tutti e due i volanti): evento primario (Controllo fotocamera e Volume −, per iOS
    /// lo stesso tasto) = R, la derapata; Volume + = L, il lancio dell'oggetto.
    func button(for key: VolumeKey) -> PhoneButton {
        if setup.isKart {
            // Prova sul telefono: iOS non segnala la pressione leggera né il dito che scorre, e il
            // tasto Azione non arriva; restano due tasti: primario (fotocamera, Volume −) e Volume +.
            return key == .down ? .r : .l
        }
        // Sports mancino (iPhone nella mano sinistra): le dita stanno sul bordo destro, dove c'è il
        // Controllo fotocamera (evento primario), e i tasti volume finiscono sotto il palmo:
        // il grilletto va sul primario, la calibrazione (freccia su) su Volume +.
        if setup == .sportsLefty { return key == .down ? .zl : .up }
        switch key {
        case .up: return leftLayout ? .zl : .zr
        case .down: return leftLayout ? .up : .x
        }
    }

    func volumeKey(_ key: VolumeKey, down: Bool) {
        let k = swapVolume ? key.other : key
        logHardware("\(key == .up ? "secondario (Vol +)" : "primario (Vol − / Azione / Fotocamera)") \(down ? "giù" : "su")"
                    + (down ? " → \(button(for: k).title)" : "") + (cameraControlActive ? " · controlli attivi" : ""))
        if down {
            guard volumeHeld[k] == nil else { return }
            let b = button(for: k)
            volumeHeld[k] = b
            set(b, true)
        } else if let b = volumeHeld.removeValue(forKey: k) {
            if b == .zr && touchR { return } // il dito è ancora sul Controllo fotocamera
            set(b, false)                    // quello premuto, anche se nel frattempo è cambiato il lato
        }
    }

    /// Pressione leggera sul Controllo fotocamera: in Mario Kart ZR resta premuto finché iOS
    /// tiene attivi i controlli. Il clic fino in fondo passa da volumeKey come sempre.
    private func controlsActive(_ on: Bool) {
        logHardware(on ? "controlli fotocamera ATTIVI (pressione leggera)" : "controlli fotocamera spenti")
        cameraControlActive = on
        let touch = false   // la pressione leggera non arriva (vedi button(for:)): solo registro
        guard touch != touchR else { return }
        touchR = touch
        if touch { set(.zr, true) } else if !volumeHeld.values.contains(.zr) { set(.zr, false) }
    }
    private var touchR = false

    private func updateCamera() {
        if volumeKeys && active {
            guard cameraState != .running && cameraState != .starting else { return }
            cameraState = .starting
            camera.start { [weak self] s in
                guard let self else { return }
                // Nel frattempo spenta o app in background: la si richiude.
                if !(self.volumeKeys && self.active) { self.camera.stop(); self.cameraState = .off } else { self.cameraState = s }
                self.logHardware(self.camera.info.isEmpty ? "fotocamera: \(s)" : self.camera.info)
            }
        } else {
            camera.stop()
            if cameraState != .denied { cameraState = .off }
            for k in Array(volumeHeld.keys) { volumeKey(swapVolume ? k.other : k, down: false) }
        }
    }

    // MARK: Pulsanti F1 (Mario Kart · giroscopio)

    /// Mira del lancio: lo stick sinistro va su (avanti) o giù (indietro) mentre si preme L.
    private var itemAim: Float = 0

    /// Lancio lontano (pulsante F1): stick su + L finché il pulsante è premuto.
    func throwFar(_ down: Bool) {
        itemAim = down ? 1 : 0
        if down { send() }                       // prima la mira, poi il tasto
        set(.l, down)
        if !down { send() }
    }

    private func send() {
        var left = stickL
        if itemAim != 0 && left == .zero { left.y = itemAim }
        link.sender.setInput(buttons: held, left: left, right: stickR, mode: setup.modeByte,
                             bothMove: setup.isSports && sportsBothMove)
    }
}
