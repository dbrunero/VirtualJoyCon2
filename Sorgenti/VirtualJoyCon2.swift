// VirtualJoyCon2 — fa credere al Mac che Wii Remote Plus (fino a 4), DualSense e iPhone siano Joy-Con.
//
// Legge il Wii Remote (con MotionPlus integrato o adattatore esterno) e lo inoltra
// al driver DriverKit di JoyCon2Mac (local.joycon2mac.driver) in una di due forme:
//
//  • Joy-Con classico (L o R): "Joy-Con (L)" 057E:2006 / "Joy-Con (R)" 057E:2007
//    (tipo 2). L'app parla il protocollo Nintendo (subcomandi, flash SPI, report
//    0x30 con 3 campioni IMU), così SDL e gli emulatori lo trattano come un Joy-Con.
//  • Joy-Con 2: gamepad virtuale "Joy-Con 2 Gamepad (Virtual)" 057E:2066 (tipo 0),
//    con tasti, stick e movimento a 200 Hz.
//
// Il giroscopio del Wii arriva a ~90 Hz e perde campioni via Bluetooth: qui si
// ricostruisce con l'intervallo vero, si consegna senza mai inventare rotazione, si
// interpola a 200 Hz e si corregge la deriva d'inclinazione a telecomando fermo.
// Senza Sensor Bar (IR) né bussola, la direzione orizzontale resta al ricentramento
// del gioco.
//
// Ogni giocatore ha il proprio dispositivo virtuale (una connessione al driver a testa).
// Nata da JoyConFinto: driver, emulazione Joy-Con, DualSense e correzioni del Wii sono le stesse.

import SwiftUI
import AppKit
import simd
import IOKit
import IOKit.hid
import SystemExtensions

// MARK: - Costanti

// Parole-pulsante Joy-Con 2 (stesse maschere di JoyConDecoder.h)
enum JCLeft {
    static let down: UInt32 = 0x000001, up: UInt32 = 0x000002
    static let right: UInt32 = 0x000004, left: UInt32 = 0x000008
    static let l: UInt32 = 0x000040, zl: UInt32 = 0x000080
    static let minus: UInt32 = 0x000100, l3: UInt32 = 0x000800
    static let capture: UInt32 = 0x002000
}
enum JCRight {
    static let y: UInt32 = 0x000100, b: UInt32 = 0x000200
    static let x: UInt32 = 0x000400, a: UInt32 = 0x000800
    static let r: UInt32 = 0x004000, zr: UInt32 = 0x008000
    static let plus: UInt32 = 0x000002, r3: UInt32 = 0x000004
    static let home: UInt32 = 0x000010, chat: UInt32 = 0x000040
}

enum OutputMode: String, CaseIterable, Identifiable {
    case joyCon2, left, right, pair
    var id: String { rawValue }
    var title: String {
        switch self {
        case .joyCon2: return "Joy-Con 2"
        case .left: return "Joy-Con sinistro"
        case .right: return "Joy-Con destro"
        case .pair: return "Coppia sx + dx"
        }
    }
    var isSwitch: Bool { self != .joyCon2 }
    /// Joy-Con classici pubblicati: 0 = sinistro, 1 = destro.
    var sides: Set<Int> {
        switch self {
        case .joyCon2: return []
        case .left: return [0]
        case .right: return [1]
        case .pair: return [0, 1]
        }
    }
    var seenAs: String {
        switch self {
        case .joyCon2: return "Joy-Con 2 Gamepad (Virtual) · 057E:2066"
        case .left: return "Joy-Con (L) · 057E:2006"
        case .right: return "Joy-Con (R) · 057E:2007"
        case .pair: return "Joy-Con (L) + Joy-Con (R) · 057E:2006/2007"
        }
    }
}


/// Tasto del Joy-Con a cui mandare un tasto del Wii Remote.
enum JoyButton: String, CaseIterable, Identifiable {
    case none
    case a, b, x, y, r, zr, slR, srR, plus, home, rStick
    case up, down, left, right, l, zl, slL, srL, minus, capture, lStick
    case chat
    case stick   // solo croce del Wii Remote: muove lo stick
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "— nessuno —"
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .r: return "R"
        case .zr: return "ZR"
        case .slR: return "SL (destro)"
        case .srR: return "SR (destro)"
        case .plus: return "+"
        case .home: return "Home"
        case .rStick: return "Clic stick R"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .l: return "L"
        case .zl: return "ZL"
        case .slL: return "SL (sinistro)"
        case .srL: return "SR (sinistro)"
        case .minus: return "−"
        case .capture: return "Cattura"
        case .lStick: return "Clic stick L"
        case .chat: return "C (chat)"
        case .stick: return "Stick (direzione)"
        }
    }

    /// Preme il tasto nello stato Joy-Con (Switch 1) del suo lato.
    func press(left: inout SwitchPadState, right: inout SwitchPadState) {
        switch self {
        case .none, .chat, .stick: break
        case .a: right.right |= SW.a
        case .b: right.right |= SW.b
        case .x: right.right |= SW.x
        case .y: right.right |= SW.y
        case .r: right.right |= SW.r
        case .zr: right.right |= SW.zr
        case .slR: right.right |= SW.slR
        case .srR: right.right |= SW.srR
        case .plus: right.shared |= SW.plus
        case .home: right.shared |= SW.home
        case .rStick: right.shared |= SW.rStick
        case .up: left.left |= SW.up
        case .down: left.left |= SW.down
        case .left: left.left |= SW.left
        case .right: left.left |= SW.right
        case .l: left.left |= SW.l
        case .zl: left.left |= SW.zl
        case .slL: left.left |= SW.slL
        case .srL: left.left |= SW.srL
        case .minus: left.shared |= SW.minus
        case .capture: left.shared |= SW.capture
        case .lStick: left.shared |= SW.lStick
        }
    }

    /// Bit nelle parole-pulsante Joy-Con 2 (sinistra, destra).
    var joyCon2Bits: (UInt32, UInt32) {
        switch self {
        case .up: return (JCLeft.up, 0)
        case .down: return (JCLeft.down, 0)
        case .left: return (JCLeft.left, 0)
        case .right: return (JCLeft.right, 0)
        case .l: return (JCLeft.l, 0)
        case .zl: return (JCLeft.zl, 0)
        case .minus: return (JCLeft.minus, 0)
        case .lStick: return (JCLeft.l3, 0)
        case .capture: return (JCLeft.capture, 0)
        case .a: return (0, JCRight.a)
        case .b: return (0, JCRight.b)
        case .x: return (0, JCRight.x)
        case .y: return (0, JCRight.y)
        case .r: return (0, JCRight.r)
        case .zr: return (0, JCRight.zr)
        case .plus: return (0, JCRight.plus)
        case .rStick: return (0, JCRight.r3)
        case .home: return (0, JCRight.home)
        case .chat: return (0, JCRight.chat)
        case .none, .slR, .srR, .slL, .srL, .stick: return (0, 0)
        }
    }
}


/// Tasto fisico del Wii Remote (Plus) e del Nunchuk; rawValue = bit in JFWiiState.buttons.
enum WiiButton: Int, CaseIterable, Identifiable {
    case up, down, left, right, a, b, one, two, minus, plus, home, nunchukC, nunchukZ
    var id: Int { rawValue }
    var key: String { String(describing: self) }
    var title: String {
        switch self {
        case .up: return "Croce ↑"
        case .down: return "Croce ↓"
        case .left: return "Croce ←"
        case .right: return "Croce →"
        case .a: return "A"
        case .b: return "B (grilletto)"
        case .one: return "1"
        case .two: return "2"
        case .minus: return "−"
        case .plus: return "+"
        case .home: return "Home"
        case .nunchukC: return "Nunchuk C"
        case .nunchukZ: return "Nunchuk Z"
        }
    }
    var isDpad: Bool { rawValue <= WiiButton.right.rawValue }
    func isPressed(_ buttons: UInt32) -> Bool { buttons & (1 << UInt32(rawValue)) != 0 }
}

typealias WiiButtonMap = [WiiButton: JoyButton]

/// Chiave della mappatura Wii: una per lato e impugnatura.
func wiiMapKey(side: WiiSide, sideways: Bool) -> String {
    "\(side.rawValue).\(sideways ? "orizzontale" : "verticale")"
}

/// Tasti Joy-Con disponibili per un tasto del Wii Remote.
func wiiTargets(side: WiiSide, for b: WiiButton) -> [JoyButton] {
    let base = (side == .left ? OutputMode.left : OutputMode.right).targets
    return b.isDpad ? [.stick] + base : base
}

/// Mappatura di fabbrica. In verticale i due lati sono uno lo specchio dell'altro per
/// posizione: 1 = tasto alto, 2 = tasto basso, − = sinistro, + = destro, A = clic stick,
/// B = grilletto, Home = −/+. In orizzontale i tasti fisici del Joy-Con ruotano di 90°.
func wiiDefaultMap(side: WiiSide, sideways: Bool) -> WiiButtonMap {
    var m: WiiButtonMap = [.up: .stick, .down: .stick, .left: .stick, .right: .stick]
    switch (side, sideways) {
    case (.right, false):
        m[.one] = .x; m[.two] = .b; m[.minus] = .y; m[.plus] = .a; m[.a] = .rStick; m[.b] = .zr
        m[.nunchukC] = .slR; m[.nunchukZ] = .srR; m[.home] = .plus
    case (.right, true):
        m[.two] = .x; m[.one] = .a; m[.minus] = .b; m[.a] = .y; m[.b] = .srR
        m[.nunchukC] = .slR; m[.nunchukZ] = .srR; m[.plus] = .plus; m[.home] = .home
    case (.left, false):
        m[.one] = .up; m[.two] = .down; m[.minus] = .left; m[.plus] = .right; m[.a] = .lStick; m[.b] = .zl
        m[.nunchukC] = .slL; m[.nunchukZ] = .srL; m[.home] = .minus
    case (.left, true):
        m[.two] = .down; m[.one] = .left; m[.a] = .right; m[.minus] = .up; m[.b] = .srL
        m[.nunchukC] = .slL; m[.nunchukZ] = .srL; m[.plus] = .minus; m[.home] = .capture
    }
    return m
}


/// Copia di DriverKitClient.convertButtonsToHID: stessa disposizione dei bit
/// che il demone JoyCon2Mac manda per un Joy-Con 2 reale.
func convertButtonsToHID(left: UInt32, right: UInt32, up: Bool, down: Bool, leftDir: Bool, rightDir: Bool) -> UInt32 {
    var h: UInt32 = 0
    if right & JCRight.x != 0 { h |= 1 << 0 }
    if right & JCRight.a != 0 { h |= 1 << 1 }
    if right & JCRight.y != 0 { h |= 1 << 2 }
    if right & JCRight.b != 0 { h |= 1 << 3 }
    if left & JCLeft.l != 0 { h |= 1 << 4 }
    if right & JCRight.r != 0 { h |= 1 << 5 }
    if left & JCLeft.zl != 0 { h |= 1 << 6 }
    if right & JCRight.zr != 0 { h |= 1 << 7 }
    if left & JCLeft.minus != 0 { h |= 1 << 8 }
    if right & JCRight.plus != 0 { h |= 1 << 9 }
    if left & JCLeft.l3 != 0 { h |= 1 << 10 }
    if right & JCRight.r3 != 0 { h |= 1 << 11 }
    if up { h |= 1 << 12 }
    if down { h |= 1 << 13 }
    if leftDir { h |= 1 << 14 }
    if rightDir { h |= 1 << 15 }
    if right & JCRight.home != 0 { h |= 1 << 16 }
    if left & JCLeft.capture != 0 { h |= 1 << 17 }
    return h
}

func hidDpad(up: Bool, down: Bool, left: Bool, right: Bool) -> UInt8 {
    if up && right { return 1 }
    if up && left { return 7 }
    if down && right { return 3 }
    if down && left { return 5 }
    if up { return 0 }
    if down { return 4 }
    if left { return 6 }
    if right { return 2 }
    return 8
}


// MARK: - Client del driver

final class VirtualJoyConDriver {
    static let typeJoyCon2: UInt32 = 0
    static let typeSwitch: UInt32 = 2

    private var connection: io_connect_t = IO_OBJECT_NULL
    private var legacyReports = false
    var isConnected: Bool { connection != IO_OBJECT_NULL }

    /// Durante la sostituzione del driver nessuno deve tenerlo aperto, altrimenti macOS
    /// lascia la copia vecchia "terminating for upgrade" e la nuova non parte.
    private static let pauseLock = NSLock()
    nonisolated(unsafe) private static var _paused = false
    static var paused: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return _paused }
        set { pauseLock.lock(); _paused = newValue; pauseLock.unlock() }
    }
    /// Chiude la connessione se il driver è in sostituzione; true se si può usare.
    private func usable() -> Bool {
        if Self.paused { disconnect(); return false }
        return isConnected
    }

    /// Il driver è caricato e risponde (chiunque l'abbia installato).
    static var isLive: Bool {
        let s = findService()
        guard s != IO_OBJECT_NULL else { return false }
        IOObjectRelease(s)
        return true
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func findService() -> io_service_t {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUserService"), &iterator) == KERN_SUCCESS else {
            return IO_OBJECT_NULL
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            if stringProperty(service, "IOUserClass") == "VirtualJoyConDriver" &&
               stringProperty(service, "CFBundleIdentifier") == "local.joycon2mac.driver" {
                return service
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return IO_OBJECT_NULL
    }

    @discardableResult
    func connect(type: UInt32) -> Bool {
        if Self.paused { disconnect(); return false }
        if isConnected { return true }
        let service = Self.findService()
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, type, &conn) == KERN_SUCCESS else { return false }
        connection = conn
        legacyReports = false
        return true
    }

    func disconnect() {
        if connection != IO_OBJECT_NULL {
            IOServiceClose(connection)
            connection = IO_OBJECT_NULL
        }
    }

    private func dropIfGone(_ ret: kern_return_t) {
        if ret == kIOReturnNotOpen || ret == kIOReturnNoDevice
            || ret == kern_return_t(MACH_SEND_INVALID_DEST) {
            disconnect()   // driver aggiornato/riavviato: ci si riconnette al prossimo giro
        }
    }

    /// Layout identico a struct JoyConReportData (28 byte; i driver vecchi ne accettano 16).
    func post(buttons: UInt32, dpad: UInt8, lx: Int16, ly: Int16, rx: Int16, ry: Int16,
              triggerL: UInt8, triggerR: UInt8, motion: [Int16]) {
        guard usable() else { return }
        var bytes = [UInt8](repeating: 0, count: 28)
        func put16(_ v: Int16, _ at: Int) {
            let u = UInt16(bitPattern: v)
            bytes[at] = UInt8(u & 0xFF); bytes[at + 1] = UInt8(u >> 8)
        }
        bytes[0] = UInt8(buttons & 0xFF); bytes[1] = UInt8((buttons >> 8) & 0xFF)
        bytes[2] = UInt8((buttons >> 16) & 0xFF); bytes[3] = UInt8(buttons >> 24)
        bytes[4] = dpad
        put16(lx, 6); put16(ly, 8); put16(rx, 10); put16(ry, 12)
        bytes[14] = triggerL; bytes[15] = triggerR
        for (i, v) in motion.prefix(6).enumerated() { put16(v, 16 + i * 2) }

        var outSize = 0
        var ret = IOConnectCallStructMethod(connection, 0, bytes, legacyReports ? 16 : 28, nil, &outSize)
        if ret != KERN_SUCCESS && !legacyReports {
            ret = IOConnectCallStructMethod(connection, 0, bytes, 16, nil, &outSize)
            if ret == KERN_SUCCESS { legacyReports = true }
        }
        dropIfGone(ret)
    }

    /// Vibrazione richiesta dai giochi al Joy-Con 2 virtuale.
    func latestRumble() -> (low: UInt8, high: UInt8)? {
        guard usable() else { return nil }
        var out = [UInt8](repeating: 0, count: 8)
        var size = 8
        guard IOConnectCallStructMethod(connection, 3, nil, 0, &out, &size) == KERN_SUCCESS, size == 8 else { return nil }
        return out[2] != 0 ? (out[0], out[1]) : (0, 0)
    }

    // Modalità Joy-Con classico (tipo 2): struct SwitchJoyConSetData / SwitchJoyConRawReport.

    func setSwitchDevices(left: Bool, right: Bool) -> Bool {
        guard isConnected else { return false }
        let bytes: [UInt8] = [left ? 1 : 0, right ? 1 : 0, 0, 0]
        var outSize = 0
        let ret = IOConnectCallStructMethod(connection, 5, bytes, 4, nil, &outSize)
        dropIfGone(ret)
        return ret == KERN_SUCCESS
    }

    func postSwitch(side: Int, report: [UInt8]) {
        guard isConnected, report.count <= 64 else { return }
        var bytes = [UInt8](repeating: 0, count: 68)
        bytes[0] = UInt8(side); bytes[1] = UInt8(report.count)
        bytes.replaceSubrange(4..<(4 + report.count), with: report)
        var outSize = 0
        dropIfGone(IOConnectCallStructMethod(connection, 6, bytes, 68, nil, &outSize))
    }

    func copySwitchOutput() -> (side: Int, report: [UInt8])? {
        guard usable() else { return nil }
        var out = [UInt8](repeating: 0, count: 68)
        var size = 68
        let ret = IOConnectCallStructMethod(connection, 7, nil, 0, &out, &size)
        guard ret == KERN_SUCCESS else { dropIfGone(ret); return nil }
        let length = Int(out[1])
        guard size == 68, length > 0, length <= 64 else { return nil }
        return (Int(out[0]), Array(out[4..<(4 + length)]))
    }
}

// MARK: - Installazione del driver

/// Installa il driver DriverKit (local.joycon2mac.driver) incluso nell'app, come faceva
/// JoyCon2Mac: da qui in poi il driver "appartiene" a VirtualJoyCon2 e JoyCon2Mac non serve
/// più. Con firma locale funziona solo con SIP disattivato e `systemextensionsctl developer on`.
@MainActor
final class DriverInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let identifier = "local.joycon2mac.driver"

    @Published private(set) var live = VirtualJoyConDriver.isLive
    @Published private(set) var busy = false
    @Published private(set) var needsApproval = false
    @Published private(set) var message: String?

    private let defaults = UserDefaults.standard
    /// Il driver è già stato attivato da questa app almeno una volta.
    var owned: Bool { defaults.bool(forKey: "driver.owned") }
    var bundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(Self.identifier).dext").path)
    }

    func refresh() {
        let l = VirtualJoyConDriver.isLive
        if l != live { live = l }
    }

    func install() {
        guard !busy else { return }
        guard bundled else { message = "Il driver non è dentro l'app: ricompila con Compila.command"; return }
        busy = true
        needsApproval = false
        message = "Richiesta di attivazione inviata…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func finish(_ text: String, ok: Bool) {
        VirtualJoyConDriver.paused = false        // i controller virtuali si ricollegano da soli
        busy = false
        needsApproval = false
        message = text
        if ok { defaults.set(true, forKey: "driver.owned") }
        refresh()
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            if result == .willCompleteAfterReboot {
                finish("Driver accettato: diventa attivo dopo il riavvio del Mac", ok: true)
            } else {
                finish("Driver installato e attivo", ok: true)
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            // "Estensione non trovata"/"richiesta annullata" arrivano anche quando il driver è già
            // al suo posto (versione in sostituzione, richieste sovrapposte): se risponde, va bene.
            let e = error as NSError
            let benign = e.domain == OSSystemExtensionErrorDomain
                && (e.code == OSSystemExtensionError.extensionNotFound.rawValue
                    || e.code == OSSystemExtensionError.requestCanceled.rawValue)
            if benign && VirtualJoyConDriver.isLive {
                finish("Driver attivo", ok: true)
            } else {
                finish("Attivazione non riuscita: \(error.localizedDescription)", ok: false)
            }
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            needsApproval = true
            message = "Da approvare: Impostazioni di Sistema → Generali → Elementi login ed estensioni → Estensioni driver"
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Si sostituisce sempre (anche a parità di versione): così il driver passa a questa app.
        VirtualJoyConDriver.paused = true
        DispatchQueue.main.async { self.message = "Sostituisco il driver installato con quello di VirtualJoyCon2…" }
        return .replace
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Emulazione del protocollo Joy-Con (Switch 1)

/// Stato di un Joy-Con nel formato dei report Nintendo.
struct SwitchPadState: Equatable {
    var right: UInt8 = 0, shared: UInt8 = 0, left: UInt8 = 0     // byte 3, 4, 5
    var stickX: UInt16 = 2048, stickY: UInt16 = 2048
    var accel: (Int16, Int16, Int16) = (0, 0, 0)
    var gyro: (Int16, Int16, Int16) = (0, 0, 0)

    static func == (a: SwitchPadState, b: SwitchPadState) -> Bool {
        a.right == b.right && a.shared == b.shared && a.left == b.left &&
        a.stickX == b.stickX && a.stickY == b.stickY && a.accel == b.accel && a.gyro == b.gyro
    }
}

private enum SW {
    // byte 3 (Joy-Con destro)
    static let y: UInt8 = 0x01, x: UInt8 = 0x02, b: UInt8 = 0x04, a: UInt8 = 0x08
    static let srR: UInt8 = 0x10, slR: UInt8 = 0x20, r: UInt8 = 0x40, zr: UInt8 = 0x80
    // byte 4 (condiviso)
    static let minus: UInt8 = 0x01, plus: UInt8 = 0x02, rStick: UInt8 = 0x04, lStick: UInt8 = 0x08
    static let home: UInt8 = 0x10, capture: UInt8 = 0x20
    // byte 5 (Joy-Con sinistro)
    static let down: UInt8 = 0x01, up: UInt8 = 0x02, right: UInt8 = 0x04, left: UInt8 = 0x08
    static let srL: UInt8 = 0x10, slL: UInt8 = 0x20, l: UInt8 = 0x40, zl: UInt8 = 0x80
}

/// Giroscopio: con la sensibilità dichiarata in flash (13371) host e giochi leggono
/// 936/13371 = 0,07 gradi/s per unità (come un Joy-Con vero, LSM6DS3 a ±2000 gradi/s).
let kJoyConGyroPerDps = 13371.0 / 936.0
/// Ogni report 0x30 porta 3 campioni da 5 ms: l'host integra 15 ms per report.
let kReportInterval = 0.015

/// Calibrazione stick dichiarata in flash: centro 2048, ±1500.
let kStickCenter = 2048.0
let kStickRange = 1500.0

final class SwitchJoyConEmulator {
    let side: Int                       // 0 = sinistro, 1 = destro
    private var inputMode: UInt8 = 0x3F
    private var lastGyro: (Int16, Int16, Int16) = (0, 0, 0)
    private var timer: UInt8 = 0
    private var spi = [UInt8](repeating: 0xFF, count: 0x10000)
    private(set) var rumbleLow: UInt8 = 0, rumbleHigh: UInt8 = 0
    var streaming: Bool { inputMode == 0x30 || inputMode == 0x31 }

    init(side: Int) {
        self.side = side
        buildFlash()
    }

    private func pack12(_ x: Int, _ y: Int) -> [UInt8] {
        [UInt8(x & 0xFF), UInt8(((x >> 8) & 0x0F) | ((y & 0x0F) << 4)), UInt8((y >> 4) & 0xFF)]
    }

    private func write(_ address: Int, _ bytes: [UInt8]) {
        spi.replaceSubrange(address..<(address + bytes.count), with: bytes)
    }

    private func buildFlash() {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        // Calibrazione IMU di fabbrica: origine 0, sensibilità standard.
        write(0x6020, le16(0) + le16(0) + le16(0) + le16(16384) + le16(16384) + le16(16384)
                    + le16(0) + le16(0) + le16(0) + le16(13371) + le16(13371) + le16(13371))
        let c = Int(kStickCenter), r = Int(kStickRange)
        // Stick sinistro: max sopra il centro, centro, min sotto il centro.
        write(0x603D, pack12(r, r) + pack12(c, c) + pack12(r, r))
        // Stick destro: centro, min sotto, max sopra.
        write(0x6046, pack12(c, c) + pack12(r, r) + pack12(r, r))
        // Colori: corpo, tasti, grip sx, grip dx (blu neon / rosso neon).
        let body: [UInt8] = side == 0 ? [0x0A, 0xB9, 0xE6] : [0xFF, 0x3C, 0x28]
        let buttons: [UInt8] = side == 0 ? [0x00, 0x1E, 0x1E] : [0x1E, 0x0A, 0x0A]
        write(0x6050, body + buttons + body + body)
        write(0x6080, [0x50, 0xFD, 0x00, 0x00, 0xC6, 0x0F])
        let stickParams: [UInt8] = [0x0F, 0x30, 0x61, 0x96, 0x30, 0xF3, 0xD4, 0x14, 0x54,
                                    0x41, 0x15, 0x54, 0xC7, 0x79, 0x9C, 0x33, 0x36, 0x63]
        write(0x6086, stickParams)
        write(0x6098, stickParams)
        // 0x8010…: calibrazioni utente assenti (0xFF), come un Joy-Con mai ricalibrato.
    }

    private func header(_ id: UInt8, _ s: SwitchPadState) -> [UInt8] {
        timer &+= 1
        var r = [UInt8](repeating: 0, count: 49)
        r[0] = id
        r[1] = timer
        r[2] = 0x8E                      // batteria piena, connessione "Joy-Con"
        r[3] = s.right; r[4] = s.shared; r[5] = s.left
        let stick = pack12(Int(s.stickX), Int(s.stickY))
        if side == 0 { r[6] = stick[0]; r[7] = stick[1]; r[8] = stick[2] }
        else { r[9] = stick[0]; r[10] = stick[1]; r[11] = stick[2] }
        r[12] = 0x80                     // vibratore pronto
        return r
    }

    /// Report periodico: 0x30 (completo con 3 campioni IMU) o 0x3F (semplice).
    func inputReport(_ s: SwitchPadState) -> [UInt8] {
        if !streaming { return simpleReport(s) }
        var r = header(0x30, s)
        func put(_ v: Int16, _ at: Int) {
            let u = UInt16(bitPattern: v)
            r[at] = UInt8(u & 0xFF); r[at + 1] = UInt8(u >> 8)
        }
        // Un sensore vero non è mai perfettamente fermo: un IMU che legge zeri
        // identici viene preso per spento e l'host lo riattiva in continuazione.
        func noisy(_ v: Int16, _ amount: Int) -> Int16 {
            Int16(max(-32767, min(32767, Int(v) + Int.random(in: -amount...amount))))
        }
        // I 3 campioni (5 ms l'uno, dal più vecchio) seguono una rampa che prosegue dal
        // report precedente: velocità continua a 200 Hz come su un Joy-Con vero invece di
        // gradini da 15 ms. La media dei 3 resta il valore del report, quindi l'angolo
        // integrato dall'host non cambia.
        func ramp(_ v: Int16, _ prev: Int16, _ frame: Int) -> Int16 {
            let d = Double(Int(v) - Int(prev))
            return Int16(max(-32767, min(32767, (Double(v) + d * Double(frame - 1) / 3).rounded())))
        }
        for frame in 0..<3 {
            let o = 13 + frame * 12
            put(noisy(s.accel.0, 2), o); put(noisy(s.accel.1, 2), o + 2); put(noisy(s.accel.2, 2), o + 4)
            put(noisy(ramp(s.gyro.0, lastGyro.0, frame), 1), o + 6)
            put(noisy(ramp(s.gyro.1, lastGyro.1, frame), 1), o + 8)
            put(noisy(ramp(s.gyro.2, lastGyro.2, frame), 1), o + 10)
        }
        lastGyro = s.gyro
        return r
    }

    private func simpleReport(_ s: SwitchPadState) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 12)
        r[0] = 0x3F
        r[3] = 0x08                      // hat neutro
        for i in stride(from: 4, to: 12, by: 2) { r[i] = 0x00; r[i + 1] = 0x80 }
        return r
    }

    /// Gestisce un output report dell'host; restituisce l'eventuale risposta 0x21.
    /// Alcuni host (es. giochi che usano hidapi) mettono l'ID del report anche nei dati
    /// e il driver lo antepone di nuovo: "01 01 cnt vibrazione×8 sub" invece di
    /// "01 cnt vibrazione×8 sub". Letto così, il sottocomando era un byte della
    /// vibrazione (0x40): ogni comando riceveva l'ACK sbagliato e l'host ritentava
    /// all'infinito. Il doppione si riconosce dai byte d'ampiezza bassa frequenza
    /// della vibrazione, sempre tra 0x40 e 0x72, che cadono un byte più avanti.
    private static func normalized(_ out: [UInt8]) -> [UInt8] {
        func lfAmplitude(_ b: UInt8) -> Bool { (0x40...0x72).contains(b) }
        guard out.count >= 11, out[0] == 0x01 || out[0] == 0x10, out[1] == out[0],
              out[2] <= 0x0F, lfAmplitude(out[6]), lfAmplitude(out[10]) else { return out }
        return Array(out.dropFirst())
    }

    func handleOutput(_ raw: [UInt8], state s: SwitchPadState) -> [UInt8]? {
        let out = Self.normalized(raw)
        guard let id = out.first else { return nil }
        if (id == 0x01 || id == 0x10) && out.count >= 10 {
            decodeRumble(Array(out[(side == 0 ? 2 : 6)..<(side == 0 ? 6 : 10)]))
        }
        guard id == 0x01, out.count >= 11 else { return nil }
        let sub = out[10]
        let args = Array(out[11...])
        var ack: UInt8 = 0x80
        var data: [UInt8] = []

        switch sub {
        case 0x01:                       // pairing Bluetooth manuale
            ack = 0x81; data = [0x03]
        case 0x02:                       // info dispositivo
            ack = 0x82
            data = [0x04, 0x33, side == 0 ? 0x01 : 0x02, 0x02,
                    0x98, 0xB6, 0xE9, 0x4A, 0x43, side == 0 ? 0x4C : 0x52,
                    0x01, 0x01]
        case 0x03:                       // modalità dei report
            if let mode = args.first { inputMode = mode }
        case 0x04:                       // tempo di pressione dei trigger
            ack = 0x83; data = [UInt8](repeating: 0, count: 14)
        case 0x10:                       // lettura flash SPI
            guard args.count >= 5 else { break }
            let address = Int(args[0]) | Int(args[1]) << 8 | Int(args[2]) << 16 | Int(args[3]) << 24
            let size = min(Int(args[4]), 0x1D)
            ack = 0x90
            data = Array(args[0..<5])
            for i in 0..<size {
                let a = address + i
                data.append(a >= 0 && a < spi.count ? spi[a] : 0xFF)
            }
        case 0x11:                       // scrittura flash SPI (ignorata)
            data = [0x00]
        case 0x21:                       // configurazione MCU NFC/IR
            ack = 0xA0
            data = [0x01, 0x00, 0xFF, 0x00, 0x08, 0x00, 0x1B, 0x01]
        case 0x50:                       // tensione batteria
            ack = 0xD0; data = [0x5A, 0x06]
        default:                         // luci, IMU, vibrazione, sleep, ecc.: semplice ACK
            break
        }

        var r = header(0x21, s)
        r[13] = ack
        r[14] = sub
        for (i, b) in data.prefix(34).enumerated() { r[15 + i] = b }
        return r
    }

    /// Ampiezze HD Rumble → intensità 0…255 (per il motore del Wii Remote).
    private func decodeRumble(_ b: [UInt8]) {
        guard b.count == 4 else { return }
        let hf = min(Int(b[1] >> 1), 100)                       // ampiezza alta frequenza
        let lf = min(max(Int(b[3] & 0x7F) - 0x40, 0), 0x32)     // ampiezza bassa frequenza
        rumbleHigh = UInt8(hf * 255 / 100)
        rumbleLow = UInt8(lf * 255 / 0x32)
    }
}

/// Collega i Joy-Con emulati al driver su una coda dedicata (polling a 2,5 ms,
/// report 0x30 ogni 15 ms esatti come un Joy-Con Bluetooth).
final class SwitchBridge {
    let sides: Set<Int>
    private let driver = VirtualJoyConDriver()
    private let queue = DispatchQueue(label: "joyconfinto.switch", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var emulators: [Int: SwitchJoyConEmulator] = [:]
    private var ticks = 0
    private let lock = NSLock()
    private var states: [Int: SwitchPadState] = [:]
    private var lastSent: [Int: SwitchPadState] = [:]
    private var _connected = false
    private var _rumble: [Int: (UInt8, UInt8)] = [:]
    private var gyro: [Int: GyroFeed] = [:]

    private struct GyroFeed {
        var pending: (Double, Double, Double) = (0, 0, 0)   // angolo vero non ancora consegnato
    }
    /// Quota dell'angolo in attesa consegnata a ogni report (0,6 ≈ 10 ms di ritardo in più).
    private var _gyroShare = 0.6

    var connected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    var gyroShare: Double {
        get { lock.lock(); defer { lock.unlock() }; return _gyroShare }
        set { lock.lock(); _gyroShare = newValue; lock.unlock() }
    }

    /// Vibrazione (bassa, alta) chiesta dall'host per i lati indicati.
    func rumble(for wanted: Set<Int>) -> (UInt8, UInt8) {
        lock.lock(); defer { lock.unlock() }
        let values = wanted.compactMap { _rumble[$0] }
        return (values.map(\.0).max() ?? 0, values.map(\.1).max() ?? 0)
    }

    init(sides: Set<Int>) {
        self.sides = sides
        for side in sides { emulators[side] = SwitchJoyConEmulator(side: side) }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .microseconds(2500), leeway: .microseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            if driver.isConnected {
                _ = driver.setSwitchDevices(left: false, right: false)
                driver.disconnect()
            }
        }
        lock.lock(); _connected = false; _rumble = [:]; lock.unlock()
    }

    /// `integrated`: lati il cui giroscopio arriva a campioni irregolari (addGyroSample)
    /// invece che come velocità nello stato.
    func update(_ newStates: [Int: SwitchPadState], integrated: Set<Int> = []) {
        lock.lock()
        states = newStates
        for side in integrated where gyro[side] == nil { gyro[side] = GyroFeed() }
        for side in gyro.keys where !integrated.contains(side) { gyro[side] = nil }
        lock.unlock()
    }

    /// Un campione di giroscopio da una sorgente irregolare (Wii Remote): velocità in unità
    /// Joy-Con e durata che rappresenta.
    ///
    /// Il Wii Remote arriva via Bluetooth a ~90 Hz e perde campioni (buchi fino a
    /// 80-100 ms già nel kernel), mentre l'host integra un report ogni 15 ms.
    /// Ogni report consegna il 60% dell'angolo arrivato e non ancora consegnato:
    /// abbastanza liscio da non dare velocità a strappi (1 o 2 campioni per report),
    /// e mai più rotazione di quella arrivata. Prolungare l'ultima velocità durante i
    /// buchi, come si faceva prima, inventava fino a 100° negli swing veloci e la
    /// correzione successiva li riportava indietro: il gioco vedeva un secondo swing.
    func addGyroSample(side: Int, rate: (Double, Double, Double), dt: Double) {
        lock.lock(); defer { lock.unlock() }
        guard var g = gyro[side] else { return }
        // Al massimo ~0,1 s di rotazione a fondo scala in attesa: oltre è un arretrato da scartare.
        func add(_ p: Double, _ r: Double) -> Double { max(-3200, min(3200, p + r * dt)) }
        g.pending = (add(g.pending.0, rate.0), add(g.pending.1, rate.1), add(g.pending.2, rate.2))
        gyro[side] = g
    }

    /// L'angolo accumulato mentre l'host non legge l'IMU non va consegnato dopo: uscirebbe
    /// tutto insieme come una rotazione enorme e falsa (a ogni avvio o riconnessione).
    private func discardGyro(_ side: Int) {
        lock.lock(); gyro[side]?.pending = (0, 0, 0); lock.unlock()
    }

    private func drainGyro(_ side: Int) -> (Int16, Int16, Int16)? {
        lock.lock(); defer { lock.unlock() }
        guard var g = gyro[side] else { return nil }
        func out(_ pending: inout Double) -> Int16 {
            let v = max(-32000, min(32000, (pending * _gyroShare / kReportInterval).rounded()))
            pending -= v * kReportInterval
            return Int16(v)
        }
        let r = (out(&g.pending.0), out(&g.pending.1), out(&g.pending.2))
        gyro[side] = g
        return r
    }

    private func tick() {
        if !driver.isConnected {
            // Riprova ogni ~0,5 s finché il driver non risponde.
            ticks += 1
            guard ticks % 200 == 1 else { return }
            if driver.connect(type: VirtualJoyConDriver.typeSwitch) {
                if !driver.setSwitchDevices(left: emulators[0] != nil, right: emulators[1] != nil) {
                    driver.disconnect()   // driver vecchio senza modalità Joy-Con classico
                }
            }
            lock.lock(); _connected = driver.isConnected; lock.unlock()
            return
        }

        lock.lock(); let current = states; lock.unlock()

        // 1) Risposte ai comandi dell'host.
        for _ in 0..<32 {
            guard let (side, report) = driver.copySwitchOutput() else { break }
            guard let emu = emulators[side] else { continue }
            if let reply = emu.handleOutput(report, state: current[side] ?? SwitchPadState()) {
                driver.postSwitch(side: side, report: reply)
            }
        }

        // 2) Report periodici (0x30 ogni 15 ms; 0x3F solo quando cambia qualcosa).
        ticks += 1
        let periodic = ticks % 6 == 0
        for (side, emu) in emulators {
            var s = current[side] ?? SwitchPadState()
            if !emu.streaming { discardGyro(side) }   // niente arretrato prima che l'host chieda l'IMU
            if periodic && emu.streaming, let g = drainGyro(side) { s.gyro = g }
            if emu.streaming ? periodic : (periodic && lastSent[side] != s) {
                driver.postSwitch(side: side, report: emu.inputReport(s))
                lastSent[side] = s
            }
        }

        let rumble = emulators.mapValues { ($0.rumbleLow, $0.rumbleHigh) }
        lock.lock(); _connected = driver.isConnected; _rumble = rumble; lock.unlock()
    }
}

/// Wii Remote (Plus) → stato di un Joy-Con singolo.
///
/// Verticale (come un telecomando, giochi di movimento):
///   croce = stick · A = tasto destro (A / freccia →) · 1 = tasto basso (B / ↓)
///   2 = tasto alto (X / ↑) · − = tasto sinistro (Y / ←) · B (grilletto) = ZR / ZL
///   + = + / − · Home = Home / Cattura · Nunchuk: stick, C = SL, Z = SR
/// Orizzontale (stile NES, croce a sinistra): stessi ruoli per posizione,
///   2 = conferma, 1 = indietro, A = tasto alto, − = tasto sinistro, B = SR.
private func wiiSwitchState(_ w: JFWiiState, side: Int, sideways: Bool, map: WiiButtonMap,
                            mount: simd_double3x3 = matrix_identity_double3x3) -> SwitchPadState {
    func held(_ b: WiiButton) -> Bool { b.isPressed(w.buttons) }
    func toStick(_ b: WiiButton) -> Bool { held(b) && map[b] == .stick }

    var s = SwitchPadState()

    // Stick: la croce (dove mappata su "Stick") dà spinte piene; il Nunchuk, se c'è e si muove, vince.
    var fx = 0.0, fy = 0.0   // fy positivo = su
    if sideways {
        if toStick(.right) { fy += 1 }; if toStick(.left) { fy -= 1 }; if toStick(.down) { fx += 1 }; if toStick(.up) { fx -= 1 }
    } else {
        if toStick(.up) { fy += 1 }; if toStick(.down) { fy -= 1 }; if toStick(.right) { fx += 1 }; if toStick(.left) { fx -= 1 }
    }
    let nx = Double(w.nunchukX) / 32767, ny = -Double(w.nunchukY) / 32767
    if hypot(nx, ny) > hypot(fx, fy) { fx = nx; fy = ny }
    s.stickX = UInt16(kStickCenter + max(-1, min(1, fx)) * kStickRange)
    s.stickY = UInt16(kStickCenter + max(-1, min(1, fy)) * kStickRange)

    // Tasti: il lato è già quello giusto, l'altro stato si scarta.
    var other = SwitchPadState()
    for b in WiiButton.allCases where held(b) {
        let t = map[b] ?? .none
        if side == 1 { t.press(left: &other, right: &s) } else { t.press(left: &s, right: &other) }
    }

    // Movimento. Il Wii Remote disteso che punta allo schermo corrisponde al
    // Joy-Con nel grip; in orizzontale il Joy-Con destro ha la punta dalla
    // parte opposta del Wii Remote, quindi lo ruotiamo di 180° attorno a Y.
    // `mount`: rotazione virtuale del sensore (posizione fissa al tasto), uguale per
    // accelerometro e giroscopio.
    let a = mount * wiiAccel(w, side: side, sideways: sideways)
    let g = mount * wiiGyro(w, side: side, sideways: sideways)
    func clamp(_ x: Double) -> Int16 { Int16(max(-32767, min(32767, x.rounded()))) }
    s.gyro = (clamp(g.x), clamp(g.y), clamp(g.z))
    s.accel = (clamp(a.x), clamp(a.y), clamp(a.z))
    return s
}

/// Assi DSU → assi del Joy-Con, come joyConAxes ma senza arrotondare.
/// In orizzontale il Joy-Con destro ha la punta dalla parte opposta del Wii Remote:
/// rotazione di 180° attorno a Y.
private func wiiToJoyCon(_ v: SIMD3<Double>, side: Int, sideways: Bool) -> SIMD3<Double> {
    let flip = sideways && side == 1 ? -1.0 : 1.0
    let u = SIMD3(v.x * flip, v.y, v.z * flip)
    return side == 0 ? SIMD3(-u.z, -u.x, u.y) : SIMD3(-u.z, u.x, -u.y)
}

/// Accelerazione del Wii Remote negli assi e nelle unità del Joy-Con (4096 = 1 g).
private func wiiAccel(_ w: JFWiiState, side: Int, sideways: Bool) -> SIMD3<Double> {
    wiiToJoyCon(SIMD3(Double(w.accelX), Double(w.accelY), Double(w.accelZ)) * 4096, side: side, sideways: sideways)
}

/// Velocità angolare del Wii Remote negli assi e nelle unità del Joy-Con.
private func wiiGyro(_ w: JFWiiState, side: Int, sideways: Bool) -> SIMD3<Double> {
    wiiToJoyCon(SIMD3(Double(w.gyroPitch), Double(w.gyroYaw), Double(w.gyroRoll)) * kJoyConGyroPerDps,
                side: side, sideways: sideways)
}

/// Correzione dell'orientamento del Wii Remote visto come Joy-Con: le quattro rotazioni
/// di 180° più i quarti di giro attorno alla punta (nessuna specchia i dati, quindi
/// giroscopio e accelerometro restano coerenti).
enum WiiAxisFix: String, CaseIterable, Identifiable {
    case standard, flipFace, flipTip, flipSide, quarterLeft, quarterRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Standard"
        case .flipFace: return "Ruota sulla punta"
        case .flipTip: return "Ruota sulla faccia"
        case .flipSide: return "Ruota di lato"
        case .quarterLeft: return "¼ sulla punta ↺"
        case .quarterRight: return "¼ sulla punta ↻"
        }
    }
    var help: String {
        switch self {
        case .standard: return "Nessuna correzione"
        case .flipFace: return "Inverte lo swing (avanti/indietro) lasciando giusta l'inclinazione della punta"
        case .flipTip: return "Inverte punta e lato: la punta in su diventa in giù"
        case .flipSide: return "Inverte punta e faccia"
        case .quarterLeft, .quarterRight:
            return "Il gioco vede la faccia dei tasti girata di 90° attorno alla punta: per quando il gioco si aspetta il Joy-Con impugnato di taglio"
        }
    }
    var matrix: simd_double3x3 {
        switch self {
        case .standard: return matrix_identity_double3x3
        case .flipFace: return simd_double3x3(diagonal: SIMD3(1, -1, -1))   // 180° attorno alla punta (X)
        case .flipTip: return simd_double3x3(diagonal: SIMD3(-1, -1, 1))    // 180° attorno alla faccia (Z)
        case .flipSide: return simd_double3x3(diagonal: SIMD3(-1, 1, -1))   // 180° attorno al lato (Y)
        case .quarterLeft: return simd_double3x3(simd_quatd(angle: .pi / 2, axis: SIMD3(1, 0, 0)))
        case .quarterRight: return simd_double3x3(simd_quatd(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))
        }
    }
}

/// Profilo di gioco del Wii Remote, cambiabile dal telecomando (Home+1 tenuti premuti).
/// Golf: orientamento a parte, niente rotazione fantasma da fermo (deriva del giroscopio
/// e correzioni dell'inclinazione caricavano il tiro) e swing consegnato con meno ritardo
/// (la potenza dipende dal picco di velocità).
enum WiiProfile: String, CaseIterable, Identifiable {
    case sport, golf
    var id: String { rawValue }
    var title: String { self == .sport ? "Sport" : "Golf" }
    /// Velocità sotto cui, da fermo, il giroscopio si considera zero (gradi/s).
    var stillDeadband: Double { self == .golf ? 2.0 : 0 }
    /// Massima velocità della correzione d'inclinazione (gradi/s) e campioni fermi richiesti.
    var tiltMaxRate: Double { self == .golf ? 6 : 60 }
    var tiltCalmSamples: Int { self == .golf ? 30 : 8 }
    /// Quota dell'angolo in attesa consegnata a ogni report (Joy-Con classico, Joy-Con 2).
    var gyroShare: Double { self == .golf ? 0.9 : 0.6 }
    var gyroShareJoyCon2: Double { self == .golf ? 0.5 : 0.25 }
}

/// Posizione fissa al tasto: angolo voluto tra la punta del telecomando e la verticale
/// verso il basso.
enum WiiAim: String, CaseIterable, Identifiable {
    case off, deg45, perpendicular
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Come lo tengo"
        case .deg45: return "45°"
        case .perpendicular: return "Perpendicolare"
        }
    }
    var angle: Double? {
        switch self {
        case .off: return nil
        case .deg45: return .pi / 4
        case .perpendicular: return 0
        }
    }
}


enum WiiSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var index: Int { self == .left ? 0 : 1 }
    var title: String { self == .left ? "Joy-Con sinistro" : "Joy-Con destro" }
}

/// Stima il fattore di scala del giroscopio. Tra due momenti in cui il telecomando è
/// fermo, la gravità vista dal sensore deve ruotare esattamente quanto dice il
/// giroscopio integrato: si cerca la scala che rende le due rotazioni uguali.
/// Campioni: accelerazione (g), velocità angolare (rad/s) negli stessi assi, durata (s).
/// Ritorna scala, errore medio residuo (gradi) e numero di coppie usate.
nonisolated func estimateGyroScale(_ samples: [(f: SIMD3<Double>, w: SIMD3<Double>, dt: Double)]) -> (scale: Double, error: Double, pairs: Int)? {
    guard let (error, pairs) = gyroConsistency(samples) else { return nil }
    return bestGyroScale { error(matrix_identity_double3x3, $0) }.map { ($0.scale, $0.error, pairs) }
}

private nonisolated func bestGyroScale(_ error: (Double) -> Double) -> (scale: Double, error: Double)? {
    var best = (scale: 1.0, error: Double.infinity)
    for k in stride(from: 0.70, through: 1.30, by: 0.01) {
        let e = error(k)
        if e < best.error { best = (k, e) }
    }
    for k in stride(from: best.scale - 0.01, through: best.scale + 0.01, by: 0.0025) {   // rifinitura
        let e = error(k)
        if e < best.error { best = (k, e) }
    }
    return best.error.isFinite ? best : nil
}

/// Assi del giroscopio rispetto all'accelerometro (già corretto): tra le 48 combinazioni
/// di assi e segni, quella per cui la gravità ruota come dice il giroscopio. Così il
/// giroscopio non può restare specchiato rispetto all'accelerometro.
nonisolated func estimateGyroAxes(_ samples: [(f: SIMD3<Double>, w: SIMD3<Double>, dt: Double)])
    -> (matrix: simd_double3x3, scale: Double, error: Double, pairs: Int)? {
    guard let (error, pairs) = gyroConsistency(samples) else { return nil }
    var candidates: [simd_double3x3] = []
    for p in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
        for signs in 0..<8 {
            var cols = [SIMD3<Double>](repeating: .zero, count: 3)
            for i in 0..<3 { cols[i][p[i]] = signs & (1 << i) != 0 ? -1 : 1 }
            candidates.append(simd_double3x3(columns: (cols[0], cols[1], cols[2])))
        }
    }
    // La scala vera è vicina a 1: si sceglie l'orientamento a scala 1, poi si rifinisce la scala.
    guard let m = candidates.min(by: { error($0, 1) < error($1, 1) }),
          let best = bestGyroScale({ error(m, $0) }) else { return nil }
    return (m, best.scale, best.error, pairs)
}

/// Errore medio (gradi) tra la gravità integrata col giroscopio (trasformato da `m`,
/// scala `k`) e quella misurata, su coppie di momenti fermi.
private nonisolated func gyroConsistency(_ samples: [(f: SIMD3<Double>, w: SIMD3<Double>, dt: Double)])
    -> (error: (simd_double3x3, Double) -> Double, pairs: Int)? {
    let n = samples.count
    guard n > 100 else { return nil }
    // Fermo: |a| ≈ 1 g e accelerometro stabile per ±3 campioni.
    var still: [Int] = []
    for i in 3..<(n - 3) where abs(simd_length(samples[i].f) - 1) < 0.06 {
        if (i - 3...i + 3).allSatisfy({ simd_length(samples[$0].f - samples[i].f) < 0.05 }) { still.append(i) }
    }
    // Coppie fermo → fermo entro ~4 s con almeno 45° di rotazione della gravità.
    var pairs: [(Int, Int)] = []
    for (a, i) in still.enumerated() {
        for j in still[(a + 1)...] {
            if j - i < 10 { continue }
            if j - i > 400 { break }
            let c = simd_dot(simd_normalize(samples[i].f), simd_normalize(samples[j].f))
            if acos(max(-1, min(1, c))) > .pi / 4 { pairs.append((i, j)) }
        }
    }
    guard pairs.count >= 30 else { return nil }
    let step = max(1, pairs.count / 250)
    let used = stride(from: 0, to: pairs.count, by: step).map { pairs[$0] }

    func error(_ m: simd_double3x3, _ k: Double) -> Double {
        var total = 0.0
        for (i, j) in used {
            var f = simd_normalize(samples[i].f)
            for t in i..<j {
                let w = m * samples[t].w * k
                let th = simd_length(w) * samples[t].dt
                guard th > 1e-9 else { continue }
                let u = -w / simd_length(w)                 // df/dt = -w × f
                f = f * cos(th) + simd_cross(u, f) * sin(th) + u * simd_dot(u, f) * (1 - cos(th))
            }
            total += acos(max(-1, min(1, simd_dot(f, simd_normalize(samples[j].f)))))
        }
        return total / Double(used.count) * 180 / .pi
    }
    return (error, used.count)
}

/// Correzione degli assi del Wii Remote misurata con la procedura guidata: due matrici
/// (permutazioni con segno, anche specchianti) che portano accelerometro e giroscopio
/// come arrivano dal lettore negli assi DSU veri (+X destra, +Y fuori dalla faccia,
/// +Z verso il giocatore, telecomando disteso che punta allo schermo). Senza misura
/// sono l'identità: si usa la conversione del lettore così com'è.
struct WiiAxisCalibration {
    var accel = matrix_identity_double3x3
    var gyro = matrix_identity_double3x3
    var measured = false

    static func load(_ d: UserDefaults) -> WiiAxisCalibration {
        func m(_ k: String) -> simd_double3x3? {
            guard let v = d.array(forKey: k) as? [Double], v.count == 9 else { return nil }
            return simd_double3x3(columns: (SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8])))
        }
        guard let a = m("axisCal.accel"), let g = m("axisCal.gyro") else { return WiiAxisCalibration() }
        return WiiAxisCalibration(accel: a, gyro: g, measured: true)
    }

    func save(_ d: UserDefaults) {
        guard measured else {
            d.removeObject(forKey: "axisCal.accel"); d.removeObject(forKey: "axisCal.gyro")
            return
        }
        func flat(_ m: simd_double3x3) -> [Double] {
            [m.columns.0, m.columns.1, m.columns.2].flatMap { [$0.x, $0.y, $0.z] }
        }
        d.set(flat(accel), forKey: "axisCal.accel")
        d.set(flat(gyro), forKey: "axisCal.gyro")
    }

    func apply(_ w: JFWiiState) -> JFWiiState {
        guard measured else { return w }
        var o = w
        let a = accel * SIMD3(Double(w.accelX), Double(w.accelY), Double(w.accelZ))
        let g = gyro * SIMD3(Double(w.gyroPitch), Double(w.gyroYaw), Double(w.gyroRoll))
        o.accelX = Float(a.x); o.accelY = Float(a.y); o.accelZ = Float(a.z)
        o.gyroPitch = Float(g.x); o.gyroYaw = Float(g.y); o.gyroRoll = Float(g.z)
        return o
    }
}

/// Le tre pose della procedura (gravità media in g, come arriva dal lettore) → matrice
/// dell'accelerometro. Ogni posa fissa il segno di un asse vero:
///   faccia in su → +Y in su · punta al soffitto → −Z in su · fianco destro in su → +X in su.
/// Ritorna nil se una posa è ambigua o due pose cadono sullo stesso asse.
nonisolated func solveAccelAxes(_ poses: [SIMD3<Double>]) -> simd_double3x3? {
    let truth: [(axis: Int, sign: Double)] = [(1, 1), (2, -1), (0, 1)]
    guard poses.count == 3 else { return nil }
    var cols = [SIMD3<Double>](repeating: .zero, count: 3)
    var used = Set<Int>()
    for (m, t) in zip(poses, truth) {
        let a = SIMD3(abs(m.x), abs(m.y), abs(m.z))
        let i = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2)
        guard a[i] / simd_length(m) > 0.8, used.insert(i).inserted else { return nil }
        cols[i][t.axis] = t.sign * (m[i] < 0 ? -1 : 1)
    }
    return simd_double3x3(columns: (cols[0], cols[1], cols[2]))
}

/// Ingressi mostrati nell'anteprima. Oggetto a parte: a ogni movimento si ridisegna
/// solo l'anteprima, non tutta la finestra né il menu nella barra (che osservano Engine).
extension OutputMode {
    /// Tasti Joy-Con disponibili in questa modalità.
    var targets: [JoyButton] {
        switch self {
        case .left: return [.none, .up, .down, .left, .right, .l, .zl, .slL, .srL, .minus, .capture, .lStick]
        case .right: return [.none, .a, .b, .x, .y, .r, .zr, .slR, .srR, .plus, .home, .rStick]
        case .pair: return JoyButton.allCases.filter { $0 != .chat && $0 != .stick }
        case .joyCon2: return JoyButton.allCases.filter { ![.slR, .srR, .slL, .srL, .stick].contains($0) }
        }
    }
}

// MARK: - Uscita

/// Come si presenta il Wii Remote al Mac.
enum WiiOutput: String, CaseIterable, Identifiable {
    case joyCon, joyCon2
    var id: String { rawValue }
    var title: String { self == .joyCon ? "Joy-Con classico" : "Joy-Con 2" }
    func seenAs(_ side: WiiSide) -> String {
        switch self {
        case .joyCon: return side == .left ? "Joy-Con (L) · 057E:2006" : "Joy-Con (R) · 057E:2007"
        case .joyCon2: return "Joy-Con 2 Gamepad (Virtual) · 057E:2066"
        }
    }
}

/// Tasti disponibili per un tasto del Wii Remote, secondo l'uscita.
func wiiTargets(output: WiiOutput, side: WiiSide, for b: WiiButton) -> [JoyButton] {
    guard output == .joyCon2 else { return wiiTargets(side: side, for: b) }
    return b.isDpad ? [.stick] + OutputMode.joyCon2.targets : OutputMode.joyCon2.targets
}

/// Mappatura di fabbrica per l'uscita. Il Joy-Con 2 virtuale è un gamepad intero senza
/// SL/SR: i tasti che sul Joy-Con classico vanno a SL/SR diventano dorsali e grilletti.
func wiiDefaultMap(output: WiiOutput, side: WiiSide, sideways: Bool) -> WiiButtonMap {
    var m = wiiDefaultMap(side: side, sideways: sideways)
    guard output == .joyCon2 else { return m }
    for (b, t) in m {
        switch t {
        case .slL: m[b] = .l
        case .srL: m[b] = .zl
        case .slR: m[b] = .r
        case .srR: m[b] = .zr
        default: break
        }
    }
    return m
}

/// Assi del Joy-Con (punta, lato, faccia) → assi del gamepad (riferimento SDL/DSU:
/// disteso, +X destra, +Y su, +Z verso il giocatore), inverso di wiiToJoyCon.
private func joyConToGamepad(_ j: SIMD3<Double>, side: Int) -> SIMD3<Double> {
    side == 0 ? SIMD3(-j.y, j.z, -j.x) : SIMD3(j.y, -j.z, -j.x)
}

/// Uscita "Joy-Con 2": gamepad virtuale 057E:2066 del driver JoyCon2Mac (tipo 0).
/// Il suo report porta tasti, croce, 2 stick, 2 grilletti e 6 valori di movimento:
/// bussola, sensore ottico e NFC del Joy-Con 2 non hanno un campo, quindi non si
/// possono inviare. Si invia a 200 Hz come l'IMU del Joy-Con 2; il giroscopio arriva a
/// campioni irregolari dal Wii e si consegna come nel ponte Joy-Con classico (mai più
/// rotazione di quella arrivata, consegnata gradualmente).
final class JoyCon2Output {
    struct Frame {
        var buttons: UInt32 = 0
        var dpad: UInt8 = 8
        var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0
        var triggerL: UInt8 = 0, triggerR: UInt8 = 0
        var accel = SIMD3<Double>.zero          // unità Joy-Con, assi del gamepad
    }

    private static let interval = 0.005
    /// Quota dell'angolo in attesa consegnata a ogni invio (0,25 ≈ 20 ms di recupero).
    private var _share = 0.25
    var share: Double {
        get { lock.lock(); defer { lock.unlock() }; return _share }
        set { lock.lock(); _share = newValue; lock.unlock() }
    }

    private let driver = VirtualJoyConDriver()
    private let queue = DispatchQueue(label: "virtualjoycon2.joycon2", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var frame = Frame()
    private var pending = SIMD3<Double>.zero
    private var ticks = 0
    private var _connected = false
    private var _rumble: (UInt8, UInt8) = (0, 0)

    var connected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    var rumble: (UInt8, UInt8) { lock.lock(); defer { lock.unlock() }; return _rumble }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .microseconds(5000), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { driver.disconnect() }
        lock.lock(); _connected = false; _rumble = (0, 0); lock.unlock()
    }

    func update(_ f: Frame) {
        lock.lock(); frame = f; lock.unlock()
    }

    /// Velocità in unità Joy-Con, assi del gamepad, e durata che rappresenta.
    func addGyroSample(rate: SIMD3<Double>, dt: Double) {
        lock.lock()
        // Senza driver collegato non si accumula; al massimo ~0,1 s a fondo scala in attesa.
        pending = _connected ? simd_clamp(pending + rate * dt, SIMD3(repeating: -3200), SIMD3(repeating: 3200)) : .zero
        lock.unlock()
    }

    private func tick() {
        if !driver.isConnected {
            ticks += 1
            guard ticks % 100 == 1 else { return }          // riprova ogni ~0,5 s
            _ = driver.connect(type: VirtualJoyConDriver.typeJoyCon2)
            lock.lock(); _connected = driver.isConnected; lock.unlock()
            return
        }
        lock.lock()
        let f = frame
        var g = pending * _share / Self.interval
        g = simd_clamp(g, SIMD3(repeating: -32000), SIMD3(repeating: 32000)).rounded(.toNearestOrEven)
        pending -= g * Self.interval
        lock.unlock()

        func i16(_ v: Double) -> Int16 { Int16(max(-32767, min(32767, v.rounded()))) }
        driver.post(buttons: f.buttons, dpad: f.dpad, lx: f.lx, ly: f.ly, rx: f.rx, ry: f.ry,
                    triggerL: f.triggerL, triggerR: f.triggerR,
                    motion: [i16(g.x), i16(g.y), i16(g.z), i16(f.accel.x), i16(f.accel.y), i16(f.accel.z)])
        ticks += 1
        let rumble = ticks % 10 == 0 ? driver.latestRumble() : nil    // ~20 volte al secondo
        lock.lock()
        _connected = driver.isConnected
        if let r = rumble { _rumble = r }
        lock.unlock()
    }
}

// MARK: - Motore

// MARK: - DualSense

private let kSonyVendorID = 0x054C
private let kDualSenseProductIDs = [0x0CE6, 0x0DF2]       // DualSense, DualSense Edge
private let kVirtualDualSenseLocation = 0x4A433202        // DualSense virtuale del driver: da ignorare
private let kVirtualDualSenseSerial = "66:55:44:33:22:11"


/// Tasto fisico del DualSense.
enum PadButton: String, CaseIterable, Identifiable {
    case cross, circle, square, triangle, up, down, left, right
    case l1, r1, l2, r2, l3, r3, create, options, ps, touchpad, mute
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cross: return "Croce"
        case .circle: return "Cerchio"
        case .square: return "Quadrato"
        case .triangle: return "Triangolo"
        case .up: return "Croce dir. ↑"
        case .down: return "Croce dir. ↓"
        case .left: return "Croce dir. ←"
        case .right: return "Croce dir. →"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .l3: return "L3 (clic stick)"
        case .r3: return "R3 (clic stick)"
        case .create: return "Create"
        case .options: return "Options"
        case .ps: return "PS"
        case .touchpad: return "Touchpad"
        case .mute: return "Microfono"
        }
    }
    func isPressed(_ s: PadState) -> Bool {
        switch self {
        case .cross: return s.cross
        case .circle: return s.circle
        case .square: return s.square
        case .triangle: return s.triangle
        case .up: return s.dpadUp
        case .down: return s.dpadDown
        case .left: return s.dpadLeft
        case .right: return s.dpadRight
        case .l1: return s.l1
        case .r1: return s.r1
        case .l2: return s.zl
        case .r2: return s.zr
        case .l3: return s.l3
        case .r3: return s.r3
        case .create: return s.create
        case .options: return s.options
        case .ps: return s.ps
        case .touchpad: return s.touchpad
        case .mute: return s.mute
        }
    }
}


typealias ButtonMap = [PadButton: JoyButton]

extension OutputMode {
    /// Mappatura di fabbrica: tasti per posizione fisica, come su un Joy-Con.
    var defaultMap: ButtonMap {
        switch self {
        case .pair, .joyCon2:
            return [.up: .up, .down: .down, .left: .left, .right: .right,
                    .l1: .l, .l2: .zl, .create: .minus, .l3: .lStick, .touchpad: .capture,
                    .square: .y, .triangle: .x, .cross: .b, .circle: .a,
                    .r1: .r, .r2: .zr, .options: .plus, .r3: .rStick, .ps: .home,
                    .mute: self == .joyCon2 ? .chat : .none]
        case .left:
            // Joy-Con sinistro da solo: frecce = croce direzionale o tasti azione.
            return [.down: .down, .cross: .down, .up: .up, .triangle: .up,
                    .right: .right, .circle: .right, .left: .left, .square: .left,
                    .l1: .l, .l2: .zl, .r1: .slL, .r2: .srL,
                    .create: .minus, .options: .minus, .l3: .lStick, .r3: .lStick,
                    .touchpad: .capture, .ps: .capture, .mute: .none]
        case .right:
            // Joy-Con destro da solo: A/B/X/Y = tasti azione o croce direzionale.
            return [.square: .y, .left: .y, .triangle: .x, .up: .x,
                    .cross: .b, .down: .b, .circle: .a, .right: .a,
                    .r1: .r, .r2: .zr, .l1: .slR, .l2: .srR,
                    .options: .plus, .create: .plus, .r3: .rStick, .l3: .rStick,
                    .ps: .home, .touchpad: .home, .mute: .none]
        }
    }
}


/// Parole-pulsante Joy-Con 2 secondo la mappatura.
private func joyCon2Words(_ s: PadState, map: ButtonMap) -> (left: UInt32, right: UInt32) {
    var l: UInt32 = 0, r: UInt32 = 0
    for b in PadButton.allCases where b.isPressed(s) {
        let bits = (map[b] ?? .none).joyCon2Bits
        l |= bits.0; r |= bits.1
    }
    return (l, r)
}


// MARK: - Stato del DualSense

struct PadState: Equatable {
    var lx: UInt8 = 128, ly: UInt8 = 128, rx: UInt8 = 128, ry: UInt8 = 128
    var l2: UInt8 = 0, r2: UInt8 = 0
    var hat: UInt8 = 8
    var square = false, cross = false, circle = false, triangle = false
    var l1 = false, r1 = false, l2Button = false, r2Button = false
    var create = false, options = false, l3 = false, r3 = false
    var ps = false, touchpad = false, mute = false
    var gyroX: Int16 = 0, gyroY: Int16 = 0, gyroZ: Int16 = 0
    var accelX: Int16 = 0, accelY: Int16 = 0, accelZ: Int16 = 0

    var dpadUp: Bool { hat == 7 || hat == 0 || hat == 1 }
    var dpadRight: Bool { hat == 1 || hat == 2 || hat == 3 }
    var dpadDown: Bool { hat == 3 || hat == 4 || hat == 5 }
    var dpadLeft: Bool { hat == 5 || hat == 6 || hat == 7 }
    var zl: Bool { l2Button || l2 > 40 }
    var zr: Bool { r2Button || r2 > 40 }
}


/// Byte 0…255 del DualSense → -1…1 (positivo = giù/destra), con deadzone.
private func unitAxis(_ v: UInt8, deadzone: Double) -> Double {
    let f = (Double(v) - 127.5) / 127.5
    if abs(f) < deadzone { return 0 }
    return max(-1, min(1, (abs(f) - deadzone) / (1 - deadzone) * (f < 0 ? -1 : 1)))
}

private func axis(_ v: UInt8, deadzone: Double) -> Int16 {
    Int16(unitAxis(v, deadzone: deadzone) * 32767)
}


/// Vettore nel riferimento DualSense/DSU (pad disteso, +X destra, +Y su, +Z verso
/// il giocatore), già in unità Joy-Con → assi del sensore del Joy-Con.
/// Sono le stesse corrispondenze fisiche che SDL usa tra DualSense e Joy-Con.
private func joyConAxes(_ side: Int, _ v: (Double, Double, Double)) -> (Int16, Int16, Int16) {
    func clamp(_ x: Double) -> Int16 { Int16(max(-32767, min(32767, x.rounded()))) }
    return side == 0 ? (clamp(-v.2), clamp(-v.0), clamp(v.1))
                     : (clamp(-v.2), clamp(v.0), clamp(-v.1))
}

/// DualSense → stato di ciascun Joy-Con, secondo la modalità.
private func switchStates(for s: PadState, mode: OutputMode, map: ButtonMap, deadzone: Double) -> [Int: SwitchPadState] {
    func stick(_ x: UInt8, _ y: UInt8) -> (UInt16, UInt16) {
        let fx = unitAxis(x, deadzone: deadzone), fy = -unitAxis(y, deadzone: deadzone)   // su = positivo
        return (UInt16(kStickCenter + fx * kStickRange), UInt16(kStickCenter + fy * kStickRange))
    }
    func stronger(_ a: (UInt8, UInt8), _ b: (UInt8, UInt8)) -> (UInt8, UInt8) {
        func mag(_ p: (UInt8, UInt8)) -> Double { hypot(Double(p.0) - 127.5, Double(p.1) - 127.5) }
        return mag(a) >= mag(b) ? a : b
    }
    // Giroscopio: unità DualSense ≈ Joy-Con; accelerometro: 8192/g → 4096/g.
    let dg = (Double(s.gyroX), Double(s.gyroY), Double(s.gyroZ))
    let da = (Double(s.accelX) / 2, Double(s.accelY) / 2, Double(s.accelZ) / 2)

    var left = SwitchPadState(), right = SwitchPadState()
    left.accel = joyConAxes(0, da); left.gyro = joyConAxes(0, dg)
    right.accel = joyConAxes(1, da); right.gyro = joyConAxes(1, dg)

    for b in PadButton.allCases where b.isPressed(s) {
        (map[b] ?? .none).press(left: &left, right: &right)
    }

    switch mode {
    case .pair, .joyCon2:
        (left.stickX, left.stickY) = stick(s.lx, s.ly)
        (right.stickX, right.stickY) = stick(s.rx, s.ry)
        return mode == .pair ? [0: left, 1: right] : [:]
    case .left:
        let p = stronger((s.lx, s.ly), (s.rx, s.ry))
        (left.stickX, left.stickY) = stick(p.0, p.1)
        return [0: left]
    case .right:
        let p = stronger((s.rx, s.ry), (s.lx, s.ly))
        (right.stickX, right.stickY) = stick(p.0, p.1)
        return [1: right]
    }
}


// MARK: - Lettura del DualSense

private let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}

private func crc32<S: Sequence>(_ data: S) -> UInt32 where S.Element == UInt8 {
    var c: UInt32 = 0xFFFFFFFF
    for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

final class DualSenseDevice {
    let device: IOHIDDevice
    let isBluetooth: Bool
    let name: String
    private(set) var isOpen = false
    private(set) var exclusive = false
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
    private var btSequence: UInt8 = 0
    var lightbar: (UInt8, UInt8, UInt8) = (0x00, 0xA0, 0xFF)
    var onState: ((PadState) -> Void)?

    init(device: IOHIDDevice) {
        self.device = device
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        isBluetooth = transport.lowercased().contains("bluetooth")
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "DualSense"
    }

    deinit {
        close()
        buffer.deallocate()
    }

    /// exclusive = true prova a "sequestrare" il DualSense, così gli altri programmi vedono solo il Joy-Con.
    func open(exclusive wantExclusive: Bool) -> Bool {
        close()
        var ok = false
        if wantExclusive {
            ok = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess
            exclusive = ok
        }
        if !ok {
            ok = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
            exclusive = false
        }
        guard ok else { return false }
        isOpen = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 128, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            Unmanaged<DualSenseDevice>.fromOpaque(ctx).takeUnretainedValue().handleReport(report, length: length)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        if isBluetooth {
            // Leggere il feature report 0x05 (calibrazione) porta il DualSense in modalità
            // Bluetooth estesa (report 0x31, con giroscopio).
            var calib = [UInt8](repeating: 0, count: 41)
            var len = calib.count
            calib[0] = 0x05
            _ = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x05, &calib, &len)
        }
        sendOutput(lowMotor: 0, highMotor: 0)
        return true
    }

    func close() {
        guard isOpen else { return }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 128, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = false
        exclusive = false
    }

    private func handleReport(_ bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let n = Int(length)
        guard n >= 10 else { return }
        let r = UnsafeBufferPointer(start: bytes, count: n)
        var s = PadState()

        let base: Int
        if r[0] == 0x31 && n >= 30 { base = 2 }           // Bluetooth esteso
        else if r[0] == 0x01 && n >= 30 { base = 1 }      // USB
        else if r[0] == 0x01 {                            // Bluetooth semplice (senza giroscopio)
            s.lx = r[1]; s.ly = r[2]; s.rx = r[3]; s.ry = r[4]
            decodeButtons(&s, r[5], r[6], r[7])
            s.l2 = r[8]; s.r2 = r[9]
            onState?(s)
            return
        } else { return }

        s.lx = r[base]; s.ly = r[base + 1]; s.rx = r[base + 2]; s.ry = r[base + 3]
        s.l2 = r[base + 4]; s.r2 = r[base + 5]
        decodeButtons(&s, r[base + 7], r[base + 8], r[base + 9])
        if n >= base + 27 {
            func i16(_ at: Int) -> Int16 { Int16(bitPattern: UInt16(r[base + at]) | UInt16(r[base + at + 1]) << 8) }
            // Il DualSense dà già ~1/16 °/s e 1/8192 g: le stesse unità che il driver si aspetta.
            s.gyroX = i16(15); s.gyroY = i16(17); s.gyroZ = i16(19)
            s.accelX = i16(21); s.accelY = i16(23); s.accelZ = i16(25)
        }
        onState?(s)
    }

    private func decodeButtons(_ s: inout PadState, _ b0: UInt8, _ b1: UInt8, _ b2: UInt8) {
        s.hat = b0 & 0x0F
        s.square = b0 & 0x10 != 0; s.cross = b0 & 0x20 != 0
        s.circle = b0 & 0x40 != 0; s.triangle = b0 & 0x80 != 0
        s.l1 = b1 & 0x01 != 0; s.r1 = b1 & 0x02 != 0
        s.l2Button = b1 & 0x04 != 0; s.r2Button = b1 & 0x08 != 0
        s.create = b1 & 0x10 != 0; s.options = b1 & 0x20 != 0
        s.l3 = b1 & 0x40 != 0; s.r3 = b1 & 0x80 != 0
        s.ps = b2 & 0x01 != 0; s.touchpad = b2 & 0x02 != 0; s.mute = b2 & 0x04 != 0
    }

    /// Vibrazione + colore della barra luminosa.
    func sendOutput(lowMotor: UInt8, highMotor: UInt8) {
        guard isOpen else { return }
        var common = [UInt8](repeating: 0, count: 47)
        common[0] = 0x01 | 0x02            // vibrazione compatibile + selezione haptics
        common[1] = 0x04 | 0x10            // controllo barra luminosa + LED giocatore
        common[2] = highMotor              // motore destro (leggero)
        common[3] = lowMotor               // motore sinistro (forte)
        common[43] = 0x04                  // LED giocatore centrale
        common[44] = lightbar.0; common[45] = lightbar.1; common[46] = lightbar.2

        if isBluetooth {
            var report = [UInt8](repeating: 0, count: 78)
            report[0] = 0x31
            report[1] = btSequence << 4
            btSequence = (btSequence + 1) & 0x0F
            report[2] = 0x10
            report.replaceSubrange(3..<(3 + common.count), with: common)
            let crc = crc32([0xA2] + report[0..<74])
            report[74] = UInt8(crc & 0xFF); report[75] = UInt8((crc >> 8) & 0xFF)
            report[76] = UInt8((crc >> 16) & 0xFF); report[77] = UInt8(crc >> 24)
            _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x31, report, report.count)
        } else {
            var report = [UInt8](repeating: 0, count: 63)
            report[0] = 0x02
            report.replaceSubrange(1..<(1 + common.count), with: common)
            _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x02, report, report.count)
        }
    }
}


// MARK: - Motore

/// Stato mostrato nelle anteprime. Oggetto a parte per ogni sorgente: a ogni pressione
/// si ridisegna solo la sua anteprima, non tutta la finestra né il menu nella barra.
@MainActor
final class LiveInput: ObservableObject {
    @Published var pad = PadState()
    @Published var wiiButtons: UInt32 = 0
}

/// Un posto giocatore per un Wii Remote (0…3, come il LED acceso sul telecomando).
/// Ogni giocatore ha il proprio dispositivo virtuale (una connessione al driver a testa):
/// due giocatori possono essere entrambi "Joy-Con (L)" o entrambi "Joy-Con 2".
@MainActor
final class WiiPlayer: ObservableObject, @MainActor Identifiable {
    let slot: Int
    var id: Int { slot }
    var number: Int { slot + 1 }
    let live = LiveInput()
    weak var app: AppEngine?

    @Published var enabled: Bool { didSet { save(enabled, "enabled"); apply() } }
    @Published var output: WiiOutput { didSet { save(output.rawValue, "output"); resetTilt(); apply() } }
    @Published var side: WiiSide { didSet { save(side.rawValue, "side"); resetTilt(); apply() } }
    @Published var sideways: Bool { didSet { save(sideways, "sideways"); resetTilt(); push() } }
    @Published var rumble: Bool { didSet { save(rumble, "rumble") } }
    @Published var aim: WiiAim {
        didSet {
            save(aim.rawValue, "aim")
            if aim == .off { mount = matrix_identity_double3x3; resetTilt(); push() }
        }
    }
    @Published var aimButton: WiiButton { didSet { save(aimButton.key, "aimButton") } }
    /// Orientamento del profilo Sport e del profilo Golf.
    @Published var axisFix: WiiAxisFix { didSet { save(axisFix.rawValue, "axisFix"); orientationChanged() } }
    @Published var golfAxisFix: WiiAxisFix { didSet { save(golfAxisFix.rawValue, "golfAxisFix"); orientationChanged() } }
    @Published var profile: WiiProfile { didSet { save(profile.rawValue, "profile"); orientationChanged(); applyProfileTuning() } }
    @Published private(set) var outputConnected = false
    /// Copia per la UI, aggiornata solo quando cambia qualcosa di visibile.
    @Published private(set) var wiiState = JFWiiState()
    @Published private(set) var gyroScale = 1.0
    @Published private(set) var gyroScaleCalibrating = false
    @Published private(set) var gyroScaleStatus: String?

    private let defaults = UserDefaults.standard
    private var bridge: SwitchBridge?
    private var joyCon2: JoyCon2Output?
    private var liveWii = JFWiiState()
    private var rumbleOn = false
    private var mount = matrix_identity_double3x3
    private var recentAccel: [SIMD3<Double>] = []
    private var lastButtons: UInt32 = 0
    private var arrivals: [Double] = []
    private var meanDt = 0.01
    private var lastSample = 0.0
    private var lastRate = SIMD3<Double>.zero
    private var tiltUp: SIMD3<Double>?        // gravità ("su") come la integra il gioco, assi Joy-Con
    private var tiltCalm = 0
    private var gyroScaleBuiltIn: Bool?
    private var scaleSamples: [(f: SIMD3<Double>, w: SIMD3<Double>, dt: Double)] = []
    private var scaleDeadline = 0.0
    private var comboSince: Double?           // Home+1 premuti insieme da…
    private var comboFired = false
    private var pulses: [ClosedRange<Double>] = []   // vibrazioni di conferma

    /// Correzione assi del profilo attivo.
    var activeAxisFix: WiiAxisFix { profile == .golf ? golfAxisFix : axisFix }
    /// Orientamento finale del Wii come Joy-Con: correzione assi, poi posizione al tasto.
    private var frame: simd_double3x3 { mount * activeAxisFix.matrix }
    private var sideIndex: Int { side.index }

    /// Impostazioni per giocatore: "p1.output", "p2.side"…
    private func key(_ k: String) -> String { "p\(number).\(k)" }
    private func save(_ v: Any, _ k: String) { defaults.set(v, forKey: key(k)) }

    init(slot: Int) {
        self.slot = slot
        let d = UserDefaults.standard
        func k(_ s: String) -> String { "p\(slot + 1).\(s)" }
        // Prima dei profili c'era una sola correzione, lasciata su "Ruota sulla punta" per il
        // golf: diventa quella del golf e lo Sport torna Standard (tennis e ping pong).
        // Va fatto prima di register: object(forKey:) vede anche i valori registrati.
        if d.object(forKey: k("golfAxisFix")) == nil, d.string(forKey: k("axisFix")) == WiiAxisFix.flipFace.rawValue {
            d.set(WiiAxisFix.standard.rawValue, forKey: k("axisFix"))
            d.set(WiiAxisFix.flipFace.rawValue, forKey: k("golfAxisFix"))
        }
        d.register(defaults: [k("enabled"): true, k("output"): WiiOutput.joyCon.rawValue,
                              // giocatori dispari Joy-Con (L), pari Joy-Con (R)
                              k("side"): (slot % 2 == 0 ? WiiSide.left : WiiSide.right).rawValue,
                              k("sideways"): false, k("rumble"): true,
                              k("aim"): WiiAim.off.rawValue, k("aimButton"): WiiButton.up.key,
                              k("axisFix"): WiiAxisFix.standard.rawValue,
                              k("golfAxisFix"): WiiAxisFix.flipFace.rawValue,
                              k("profile"): WiiProfile.sport.rawValue])
        enabled = d.bool(forKey: k("enabled"))
        output = WiiOutput(rawValue: d.string(forKey: k("output")) ?? "") ?? .joyCon
        side = WiiSide(rawValue: d.string(forKey: k("side")) ?? "") ?? .left
        sideways = d.bool(forKey: k("sideways"))
        rumble = d.bool(forKey: k("rumble"))
        aim = WiiAim(rawValue: d.string(forKey: k("aim")) ?? "") ?? .off
        axisFix = WiiAxisFix(rawValue: d.string(forKey: k("axisFix")) ?? "") ?? .standard
        golfAxisFix = WiiAxisFix(rawValue: d.string(forKey: k("golfAxisFix")) ?? "") ?? .flipFace
        profile = WiiProfile(rawValue: d.string(forKey: k("profile")) ?? "") ?? .sport
        let aimKey = d.string(forKey: k("aimButton"))
        aimButton = WiiButton.allCases.first { $0.key == aimKey } ?? .up
    }

    func handle(_ raw: JFWiiState) {
        if axisWizardActive { axisSample(raw) }
        var s = profileCombo(app?.axisCalibration.apply(raw) ?? raw)
        if axisWizardActive { s.buttons = 0 }   // durante la procedura i tasti non arrivano al gioco
        let wasConnected = liveWii.connected
        liveWii = s
        if s.connected != wasConnected || !s.motionPlus { resetTilt() }
        refreshGyroScale(s)
        updateAim(s)
        feedRotation(s)
        recordGyroScaleSample(s)
        if s.connected != wasConnected { wiiState = s; apply() } else { push() }
    }

    func recalibrate() { app?.hub.recalibrateSlot(Int32(slot)) }

    // MARK: Procedura guidata degli assi

    enum AxisStep: Equatable {
        case idle, faceUp, tipUp, rightUp, rotate, computing, verify, failed(String)
        var instruction: String {
            switch self {
            case .faceUp: return "1/4 · Telecomando disteso, punta verso lo schermo, tasti verso il soffitto. Fermo, premi A."
            case .tipUp: return "2/4 · Punta verso il soffitto (tasti verso di te). Fermo, premi A."
            case .rightUp: return "3/4 · Di nuovo disteso verso lo schermo, poi giralo sul fianco: fianco destro verso il soffitto (tasti verso sinistra). Fermo, premi A."
            case .rotate: return "4/4 · Per 20 secondi: rotazioni lente e ampie in tutte le direzioni (punta su/giù, giù di lato, girato), fermandoti un secondo tra una e l'altra."
            case .computing: return "Calcolo…"
            case .verify: return "Fatto. Controlla qui sotto che le scritte corrispondano a quello che fai."
            case .failed(let why): return why
            case .idle: return ""
            }
        }
    }
    @Published private(set) var axisStep: AxisStep = .idle
    @Published private(set) var axisHint: String?
    @Published private(set) var axisReadout = ""
    private var axisRecent: [SIMD3<Double>] = []
    private var axisPoses: [SIMD3<Double>] = []
    private var axisLastButtons: UInt32 = 0
    private var axisAccel = matrix_identity_double3x3
    private var axisSamples: [(f: SIMD3<Double>, w: SIMD3<Double>, dt: Double)] = []
    private var axisDeadline = 0.0

    var axisWizardActive: Bool { [.faceUp, .tipUp, .rightUp, .rotate].contains(axisStep) }

    func startAxisWizard() {
        guard liveWii.connected else { axisStep = .failed("Collega prima il Wii Remote"); return }
        axisPoses = []; axisRecent = []; axisSamples = []; axisHint = nil
        axisLastButtons = liveWii.buttons
        axisStep = .faceUp
    }

    func cancelAxisWizard() { axisStep = .idle; axisHint = nil; axisSamples = [] }

    private func axisSample(_ raw: JFWiiState) {
        let a = SIMD3(Double(raw.accelX), Double(raw.accelY), Double(raw.accelZ))
        axisRecent.append(a)
        if axisRecent.count > 45 { axisRecent.removeFirst() }
        let pressedA = WiiButton.a.isPressed(raw.buttons) && !WiiButton.a.isPressed(axisLastButtons)
        axisLastButtons = raw.buttons

        switch axisStep {
        case .faceUp, .tipUp, .rightUp:
            guard pressedA else { return }
            // Media dei ~0,3 s prima della pressione: gli ultimi campioni li muove il dito.
            let window = Array(axisRecent.dropLast(6).suffix(30))
            guard window.count >= 20 else { return }
            let mean = window.reduce(.zero, +) / Double(window.count)
            guard window.allSatisfy({ simd_length($0 - mean) < 0.1 }), abs(simd_length(mean) - 1) < 0.2 else {
                axisHint = "Si muoveva: tienilo immobile un attimo e premi di nuovo A"
                return
            }
            axisHint = nil
            axisPoses.append(mean)
            switch axisStep {
            case .faceUp: axisStep = .tipUp
            case .tipUp: axisStep = .rightUp
            default:
                guard let m = solveAccelAxes(axisPoses) else {
                    axisStep = .failed("Pose non chiare (due pose uguali o telecomando storto): riprova la procedura")
                    return
                }
                axisAccel = m
                if raw.motionPlus {
                    axisSamples = []
                    axisDeadline = ProcessInfo.processInfo.systemUptime + 20
                    axisStep = .rotate
                } else {
                    finishAxisWizard(gyro: m, scale: nil)   // senza MotionPlus: stessi assi dell'accelerometro
                }
            }
        case .rotate:
            guard raw.motionPlus else { axisStep = .failed("MotionPlus scollegato durante la misura"); return }
            axisSamples.append((f: axisAccel * a,
                                w: SIMD3(Double(raw.gyroPitch), Double(raw.gyroYaw), Double(raw.gyroRoll)) * .pi / 180,
                                dt: meanDt))
            guard ProcessInfo.processInfo.systemUptime >= axisDeadline else { return }
            axisStep = .computing
            let samples = axisSamples, builtIn = raw.motionPlusBuiltIn
            axisSamples = []
            Task.detached(priority: .userInitiated) {
                let r = estimateGyroAxes(samples)
                await MainActor.run {
                    // Una scala sul bordo della ricerca (0,70…1,30) non è una misura: è finita fuori scala.
                    guard let r, r.error < 8, r.scale > 0.71, r.scale < 1.29 else {
                        self.axisStep = .failed("Rotazioni non sufficienti: servono movimenti ampi (oltre 45°) con pause da fermo. Riprova.")
                        return
                    }
                    self.defaults.set(r.scale, forKey: self.gyroScaleKey(builtIn: builtIn))
                    self.app?.gyroScaleChanged(builtIn: builtIn, scale: r.scale)
                    self.gyroScaleStatus = String(format: "misurata %.3f (errore residuo %.1f°)", r.scale, r.error)
                    self.finishAxisWizard(gyro: r.matrix, scale: r.scale)
                }
            }
        default:
            break
        }
    }

    private func finishAxisWizard(gyro: simd_double3x3, scale: Double?) {
        app?.setAxisCalibration(WiiAxisCalibration(accel: axisAccel, gyro: gyro, measured: true))
        axisStep = .verify
    }

    /// Lettura per il controllo finale, negli assi veri (già corretti).
    private func updateAxisReadout() {
        guard axisStep == .verify, liveWii.connected else { return }
        let a = SIMD3(Double(liveWii.accelX), Double(liveWii.accelY), Double(liveWii.accelZ))
        let up = simd_length(a) > 0.5 ? simd_normalize(a) : SIMD3(0, 1, 0)
        let tip = asin(max(-1, min(1, -up.z))) * 180 / .pi          // punta = −Z
        let side = asin(max(-1, min(1, up.x))) * 180 / .pi          // fianco destro = +X
        let yaw = Double(liveWii.gyroYaw) * gyroScale                // +Y: la punta gira a sinistra
        var parts = [String(format: "Punta %@ %.0f°", tip >= 0 ? "in su" : "in giù", abs(tip)),
                     String(format: "fianco %@ in su %.0f°", side >= 0 ? "destro" : "sinistro", abs(side))]
        if abs(yaw) > 30 { parts.append(yaw > 0 ? "gira a SINISTRA" : "gira a DESTRA") }
        let text = parts.joined(separator: " · ")
        if text != axisReadout { axisReadout = text }
    }

    // MARK: Profilo Sport / Golf

    /// Home+1 tenuti premuti per ~0,6 s cambiano profilo: una vibrazione = Sport, due = Golf.
    /// Finché sono premuti insieme, Home e 1 non arrivano al gioco.
    private func profileCombo(_ s: JFWiiState) -> JFWiiState {
        let combo: UInt32 = 1 << UInt32(WiiButton.home.rawValue) | 1 << UInt32(WiiButton.one.rawValue)
        guard s.connected, s.buttons & combo == combo else { comboSince = nil; comboFired = false; return s }
        let now = ProcessInfo.processInfo.systemUptime
        if comboSince == nil { comboSince = now }
        if !comboFired, let since = comboSince, now - since >= 0.6 {
            comboFired = true
            profile = profile == .sport ? .golf : .sport
            let n = profile == .golf ? 2 : 1
            pulses = (0..<n).map { i in (now + Double(i) * 0.25)...(now + Double(i) * 0.25 + 0.12) }
        }
        var masked = s
        masked.buttons &= ~combo
        return masked
    }

    private func orientationChanged() {
        mount = matrix_identity_double3x3   // la posizione al tasto va ripresa col nuovo orientamento
        recentAccel = []
        resetTilt()
        push()
    }

    private func applyProfileTuning() {
        bridge?.gyroShare = profile.gyroShare
        joyCon2?.share = profile.gyroShareJoyCon2
    }

    // MARK: Uscite

    /// Crea o chiude il dispositivo virtuale: c'è solo con il Wii Remote collegato, così
    /// per il Mac il Joy-Con "si scollega" insieme al telecomando.
    func apply() {
        let active = enabled && liveWii.connected
        if active && output == .joyCon {
            if bridge?.sides != [sideIndex] {
                bridge?.stop()
                let b = SwitchBridge(sides: [sideIndex])
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
                j.start()
                joyCon2 = j
            }
        } else {
            joyCon2?.stop()
            joyCon2 = nil
        }
        applyProfileTuning()
        push()
        refreshConnected()
    }

    func shutdown() {
        bridge?.stop(); bridge = nil
        joyCon2?.stop(); joyCon2 = nil
    }

    private func refreshConnected() {
        let c = output == .joyCon ? (bridge?.connected ?? false) : (joyCon2?.connected ?? false)
        if c != outputConnected { outputConnected = c }
    }

    /// Stato attuale (tasti, stick, accelerometro) verso il dispositivo virtuale.
    func push() {
        guard liveWii.connected else { return }
        let s = wiiSwitchState(liveWii, side: sideIndex, sideways: sideways, map: currentMap, mount: frame)
        if let b = bridge {
            b.update([sideIndex: s], integrated: liveWii.motionPlus ? [sideIndex] : [])
        }
        if let j = joyCon2 {
            var f = JoyCon2Output.Frame()
            var l: UInt32 = 0, r: UInt32 = 0
            for b in WiiButton.allCases where b.isPressed(liveWii.buttons) {
                let bits = (currentMap[b] ?? .none).joyCon2Bits
                l |= bits.0; r |= bits.1
            }
            let up = l & JCLeft.up != 0, down = l & JCLeft.down != 0
            let left = l & JCLeft.left != 0, right = l & JCLeft.right != 0
            f.buttons = convertButtonsToHID(left: l, right: r, up: up, down: down, leftDir: left, rightDir: right)
            f.dpad = hidDpad(up: up, down: down, left: left, right: right)
            // Stick del Joy-Con (centro 2048 ±1500, su positivo) → asse HID (giù positivo).
            let sx = Int16(max(-32767, min(32767, (Double(s.stickX) - 2048) / 1500 * 32767)))
            let sy = Int16(max(-32767, min(32767, -(Double(s.stickY) - 2048) / 1500 * 32767)))
            if side == .left { f.lx = sx; f.ly = sy } else { f.rx = sx; f.ry = sy }
            f.triggerL = l & JCLeft.zl != 0 ? 255 : 0
            f.triggerR = r & JCRight.zr != 0 ? 255 : 0
            f.accel = joyConToGamepad(SIMD3(Double(s.accel.0), Double(s.accel.1), Double(s.accel.2)), side: sideIndex)
            j.update(f)
        }
    }

    /// Giroscopio verso il dispositivo virtuale. Intervallo vero dal campione precedente
    /// (i campioni persi nei buchi Bluetooth contano per il tempo che coprono), trapezio
    /// tra i due campioni, più la correzione della deriva a telecomando fermo.
    private func feedRotation(_ s: JFWiiState) {
        let now = ProcessInfo.processInfo.systemUptime
        arrivals.append(now)
        while let first = arrivals.first, now - first > 2 { arrivals.removeFirst() }
        guard s.connected, s.motionPlus, arrivals.count > 20, let first = arrivals.first, now > first else { return }
        meanDt = min(1.0 / 50, max(1.0 / 250, (now - first) / Double(arrivals.count - 1)))
        let dt = min(0.1, max(0, now - lastSample))
        lastSample = now
        var rate = frame * wiiGyro(s, side: sideIndex, sideways: sideways) * gyroScale
        // Golf: da fermo (all'indirizzo) la deriva residua del MotionPlus ruota piano il
        // bastone e il gioco la prende per un backswing. Sotto la soglia vale zero.
        if simd_length(rate) / kJoyConGyroPerDps < profile.stillDeadband { rate = .zero }
        let mean = (rate + lastRate) / 2
        lastRate = rate
        let g = mean + tiltCorrection(s, rate: rate)
        trackTilt(g, dt: dt)
        if let b = bridge { b.addGyroSample(side: sideIndex, rate: (g.x, g.y, g.z), dt: dt) }
        if let j = joyCon2 { j.addGyroSample(rate: joyConToGamepad(g, side: sideIndex), dt: dt) }
    }

    // MARK: Correzione della deriva (inclinazione)

    /// Il gioco integra il giroscopio: ogni campione perso negli swing veloci resta come
    /// errore e dopo qualche colpo la punta non è più dove dovrebbe. Si segue la gravità
    /// come la "vede" il gioco (integrando la stessa rotazione che gli si manda) e, a
    /// telecomando fermo, la si riporta su quella dell'accelerometro con una piccola
    /// rotazione in più. Durante gli swing non si interviene. Corregge inclinazione e
    /// rollio; la direzione orizzontale resta al ricentramento del gioco (senza IR né
    /// bussola non c'è un riferimento per l'orizzontale).
    private func trackTilt(_ g: SIMD3<Double>, dt: Double) {
        guard let up = tiltUp else { return }
        let w = g / kJoyConGyroPerDps * .pi / 180                    // rad/s, assi Joy-Con
        tiltUp = simd_normalize(up - simd_cross(w, up) * dt)         // vettore fisso nel mondo: dv/dt = -w × v
    }

    /// Velocità correttiva (unità Joy-Con) da aggiungere, solo a telecomando fermo.
    private func tiltCorrection(_ s: JFWiiState, rate: SIMD3<Double>) -> SIMD3<Double> {
        let a = frame * wiiAccel(s, side: sideIndex, sideways: sideways) / 4096   // in g, assi del gioco
        let calm = abs(simd_length(a) - 1) < 0.08 && simd_length(rate) / kJoyConGyroPerDps < 25
        tiltCalm = calm ? tiltCalm + 1 : 0
        let measured = simd_normalize(a)
        guard let up = tiltUp else {
            if tiltCalm >= 8 { tiltUp = measured }                   // primo riferimento
            return .zero
        }
        // Fermo da ~80 ms (Sport) o ~300 ms (Golf: la correzione è una rotazione che il
        // gioco vede, e all'indirizzo una rotazione rapida carica il tiro).
        guard tiltCalm >= profile.tiltCalmSamples else { return .zero }
        // Ruota la stima verso la misura: w = k (misurato × stimato), recupero in ~0,25 s.
        var w = simd_cross(measured, up) / 0.25                       // rad/s
        let maxRate = profile.tiltMaxRate * .pi / 180
        if simd_length(w) > maxRate { w = w / simd_length(w) * maxRate }
        return w * 180 / .pi * kJoyConGyroPerDps
    }

    private func resetTilt() { tiltUp = nil; tiltCalm = 0 }

    // MARK: Posizione fissa al tasto

    /// Alla pressione del tasto scelto misura l'inclinazione (media degli ultimi ~80 ms)
    /// e ruota virtualmente il sensore perché il gioco veda la punta all'angolo scelto
    /// rispetto alla verticale. Rollio e direzione orizzontale restano quelli veri.
    private func updateAim(_ s: JFWiiState) {
        guard s.connected else { recentAccel = []; return }
        recentAccel.append(activeAxisFix.matrix * wiiAccel(s, side: sideIndex, sideways: sideways))
        if recentAccel.count > 8 { recentAccel.removeFirst() }
        let pressed = aimButton.isPressed(s.buttons) && !aimButton.isPressed(lastButtons)
        lastButtons = s.buttons
        guard pressed, let target = aim.angle, recentAccel.count == 8 else { return }
        let down = -simd_normalize(recentAccel.reduce(.zero, +))       // l'accelerometro misura "su"
        let tip = SIMD3<Double>(1, 0, 0)                               // asse X del Joy-Con = punta
        let current = acos(max(-1, min(1, simd_dot(tip, down))))
        var axis = simd_cross(down, tip)                               // ruota "giù" verso la punta
        if simd_length(axis) < 1e-3 { axis = SIMD3(0, 1, 0) }
        mount = simd_double3x3(simd_quatd(angle: current - target, axis: simd_normalize(axis)))
        resetTilt()
        push()
    }

    // MARK: Sensibilità del giroscopio (per tipo di MotionPlus, condivisa tra giocatori)

    private func gyroScaleKey(builtIn: Bool) -> String { "gyroScale.\(builtIn ? "integrato" : "esterno")" }

    /// Carica la scala salvata quando cambia il tipo di MotionPlus collegato.
    private func refreshGyroScale(_ s: JFWiiState) {
        guard s.motionPlus, gyroScaleBuiltIn != s.motionPlusBuiltIn else { return }
        gyroScaleBuiltIn = s.motionPlusBuiltIn
        gyroScale = defaults.object(forKey: gyroScaleKey(builtIn: s.motionPlusBuiltIn)) as? Double ?? 1.0
        gyroScaleStatus = nil
    }

    func startGyroScale() {
        guard liveWii.motionPlus else { return }
        scaleSamples = []
        scaleDeadline = ProcessInfo.processInfo.systemUptime + 20
        gyroScaleStatus = nil
        gyroScaleCalibrating = true
    }

    func cancelGyroScale() {
        gyroScaleCalibrating = false
        scaleSamples = []
    }

    private func recordGyroScaleSample(_ s: JFWiiState) {
        guard gyroScaleCalibrating else { return }
        guard s.motionPlus else { cancelGyroScale(); gyroScaleStatus = "MotionPlus scollegato"; return }
        // Stessi assi per accelerometro e giroscopio (riferimento DSU), giroscopio grezzo
        // senza la scala attuale: la stima è assoluta.
        scaleSamples.append((f: SIMD3(Double(s.accelX), Double(s.accelY), Double(s.accelZ)),
                             w: SIMD3(Double(s.gyroPitch), Double(s.gyroYaw), Double(s.gyroRoll)) * .pi / 180,
                             dt: meanDt))
        guard ProcessInfo.processInfo.systemUptime >= scaleDeadline else { return }
        gyroScaleCalibrating = false
        gyroScaleStatus = "calcolo…"
        let samples = scaleSamples, builtIn = s.motionPlusBuiltIn
        scaleSamples = []
        Task.detached(priority: .userInitiated) {
            let result = estimateGyroScale(samples)
            await MainActor.run {
                guard let r = result, r.error < 8, r.scale > 0.71, r.scale < 1.29 else {
                    self.gyroScaleStatus = "misura non riuscita: servono più movimenti ampi con pause da fermo"
                    return
                }
                self.defaults.set(r.scale, forKey: self.gyroScaleKey(builtIn: builtIn))
                if self.gyroScaleBuiltIn == builtIn { self.gyroScale = r.scale }
                self.gyroScaleStatus = String(format: "misurata %.3f (errore residuo %.1f°)", r.scale, r.error)
                self.app?.gyroScaleChanged(builtIn: builtIn, scale: r.scale)
            }
        }
    }

    /// Un altro giocatore ha misurato la scala per lo stesso tipo di MotionPlus.
    func adoptGyroScale(builtIn: Bool, scale: Double) {
        if gyroScaleBuiltIn == builtIn { gyroScale = scale }
    }

    // MARK: Mappatura tasti (condivisa: per uscita, lato e impugnatura)

    var currentMap: WiiButtonMap { app?.wiiMap(output: output, side: side, sideways: sideways)
                                    ?? wiiDefaultMap(output: output, side: side, sideways: sideways) }
    func target(for b: WiiButton) -> JoyButton { currentMap[b] ?? .none }
    func targets(for b: WiiButton) -> [JoyButton] { wiiTargets(output: output, side: side, for: b) }
    func setTarget(_ t: JoyButton, for b: WiiButton) { app?.setWiiTarget(t, for: b, output: output, side: side, sideways: sideways) }
    func resetMapping() { app?.resetWiiMap(output: output, side: side, sideways: sideways) }

    var mappingSummary: String {
        WiiButton.allCases.compactMap { b in
            let t = target(for: b)
            return t == .none ? nil : "\(b.title) = \(t.title)"
        }.joined(separator: " · ") + " · Nunchuk: stick"
    }

    var seenAs: String { output.seenAs(side) }

    // MARK: Ciclo a 60 Hz

    func tick(uiFrame: Bool) {
        if uiFrame {
            updateAxisReadout()
            if liveWii.buttons != live.wiiButtons { live.wiiButtons = liveWii.buttons }
            if liveWii.connected != wiiState.connected || liveWii.motionPlus != wiiState.motionPlus
                || liveWii.battery != wiiState.battery || liveWii.calibration != wiiState.calibration
                || liveWii.motionPlusBuiltIn != wiiState.motionPlusBuiltIn { wiiState = liveWii }
        }
        // Vibrazione chiesta dal gioco → motore del Wii Remote (solo acceso/spento).
        if liveWii.connected {
            let (low, high) = bridge?.rumble(for: [sideIndex]) ?? joyCon2?.rumble ?? (0, 0)
            let now = ProcessInfo.processInfo.systemUptime
            pulses.removeAll { $0.upperBound < now }
            let on = pulses.contains { $0.contains(now) } || (rumble && max(low, high) > 40)
            if on != rumbleOn { rumbleOn = on; app?.hub.setRumble(on, slot: Int32(slot)) }
        }
        refreshConnected()
    }
}

/// Il DualSense (PS5) come Joy-Con: la stessa logica di JoyConFinto. Un solo DualSense,
/// con i propri dispositivi virtuali (indipendenti da quelli dei Wii Remote).
@MainActor
final class DualSensePlayer: ObservableObject {
    let live = LiveInput()

    @Published var enabled: Bool { didSet { save(enabled, "enabled"); apply() } }
    @Published var hideDualSense: Bool { didSet { save(hideDualSense, "hide"); apply(reopen: true) } }
    @Published var rumble: Bool { didSet { save(rumble, "rumble") } }
    @Published var deadzone: Double { didSet { save(deadzone, "deadzone"); lastSent = nil; push() } }
    @Published var mode: OutputMode { didSet { save(mode.rawValue, "mode"); driver.disconnect(); lastSent = nil; apply(reopen: true) } }
    /// Mappatura per modalità (UserDefaults "ds.mapping.<modalità>").
    @Published private(set) var mappings: [OutputMode: ButtonMap] = [:] {
        didSet {
            for (m, map) in mappings {
                defaults.set(Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value.rawValue) }),
                             forKey: "ds.mapping.\(m.rawValue)")
            }
            lastSent = nil
            push()
        }
    }
    @Published private(set) var padDescription: String?
    @Published private(set) var exclusive = false
    @Published private(set) var outputConnected = false

    private let defaults = UserDefaults.standard
    private let driver = VirtualJoyConDriver()        // solo per la modalità Joy-Con 2
    private var bridge: SwitchBridge?
    private var pad: DualSenseDevice?
    private var manager: IOHIDManager?
    private var liveState = PadState()
    private var lastSent: PadState?
    private var lastMotors: (UInt8, UInt8) = (0, 0)

    private func save(_ v: Any, _ k: String) { defaults.set(v, forKey: "ds.\(k)") }
    private var sides: Set<Int> { enabled && pad?.isOpen == true ? mode.sides : [] }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["ds.enabled": true, "ds.hide": true, "ds.rumble": true,
                              "ds.deadzone": 0.06, "ds.mode": OutputMode.right.rawValue])
        enabled = d.bool(forKey: "ds.enabled")
        hideDualSense = d.bool(forKey: "ds.hide")
        rumble = d.bool(forKey: "ds.rumble")
        deadzone = d.double(forKey: "ds.deadzone")
        mode = OutputMode(rawValue: d.string(forKey: "ds.mode") ?? "") ?? .right
        mappings = Dictionary(uniqueKeysWithValues: OutputMode.allCases.map { m in
            var map = m.defaultMap
            let saved = d.dictionary(forKey: "ds.mapping.\(m.rawValue)") as? [String: String] ?? [:]
            for (k, v) in saved {
                if let b = PadButton(rawValue: k), let t = JoyButton(rawValue: v), m.targets.contains(t) { map[b] = t }
            }
            return (m, map)
        })

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = kDualSenseProductIDs.map { [kIOHIDVendorIDKey: kSonyVendorID, kIOHIDProductIDKey: $0] as CFDictionary }
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            let me = Unmanaged<DualSensePlayer>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.deviceAppeared(device) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            let me = Unmanaged<DualSensePlayer>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.deviceRemoved(device) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        manager = m
    }

    private func isVirtual(_ device: IOHIDDevice) -> Bool {
        let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        return location == kVirtualDualSenseLocation || serial == kVirtualDualSenseSerial
    }

    private func deviceAppeared(_ device: IOHIDDevice) {
        guard pad == nil, !isVirtual(device) else { return }
        let p = DualSenseDevice(device: device)
        p.onState = { [weak self] s in
            MainActor.assumeIsolated { self?.handle(s) }
        }
        pad = p
        apply(reopen: true)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let p = pad, CFEqual(p.device, device) else { return }
        p.close()
        pad = nil
        liveState = PadState()
        live.pad = liveState
        apply()
    }

    private func lightbarColor() -> (UInt8, UInt8, UInt8) {
        if mode.sides == [1] { return (0xFF, 0x3C, 0x28) }   // rosso neon
        if mode.sides == [0, 1] { return (0xB4, 0x3C, 0xFF) } // viola
        return (0x00, 0xA0, 0xFF)                             // blu neon
    }

    /// Allinea DualSense e dispositivi virtuali allo stato voluto.
    private func apply(reopen: Bool = false) {
        if let p = pad {
            p.lightbar = lightbarColor()
            if enabled {
                if reopen || !p.isOpen {
                    _ = p.open(exclusive: hideDualSense)
                    lastMotors = (0, 0)
                }
                padDescription = p.isOpen ? "\(p.name) · \(p.isBluetooth ? "Bluetooth" : "USB")"
                                          : "\(p.name) · impossibile aprirlo"
            } else {
                p.close()
                padDescription = "\(p.name) · in pausa"
            }
            exclusive = p.exclusive
        } else {
            padDescription = nil
            exclusive = false
        }
        let s = sides
        if s.isEmpty {
            bridge?.stop(); bridge = nil
        } else if bridge?.sides != s {
            bridge?.stop()
            let b = SwitchBridge(sides: s)
            b.start()
            bridge = b
        }
        push()
        if enabled && pad?.isOpen == true && mode == .joyCon2 {
            if !driver.isConnected && driver.connect(type: VirtualJoyConDriver.typeJoyCon2) { lastSent = nil }
        } else {
            driver.disconnect()
        }
        refreshConnected()
    }

    func shutdown() {
        bridge?.stop(); bridge = nil
        driver.disconnect()
        pad?.close()
    }

    private func refreshConnected() {
        let c = mode == .joyCon2 ? driver.isConnected : (bridge?.connected ?? false) && !sides.isEmpty
        if c != outputConnected { outputConnected = c }
    }

    private func push() {
        guard let b = bridge else { return }
        let fromPad = switchStates(for: liveState, mode: mode == .joyCon2 ? .pair : mode,
                                   map: mappings[mode == .joyCon2 ? .pair : mode] ?? mode.defaultMap, deadzone: deadzone)
        var states: [Int: SwitchPadState] = [:]
        for side in sides { states[side] = fromPad[side] ?? SwitchPadState() }
        b.update(states)
    }

    private func handle(_ s: PadState) {
        liveState = s
        guard enabled else { return }
        if !sides.isEmpty { push(); return }
        guard mode == .joyCon2, driver.isConnected, s != lastSent else { return }
        let (lw, rw) = joyCon2Words(s, map: currentMap)
        let up = lw & JCLeft.up != 0, down = lw & JCLeft.down != 0
        let left = lw & JCLeft.left != 0, right = lw & JCLeft.right != 0
        let buttons = convertButtonsToHID(left: lw, right: rw, up: up, down: down, leftDir: left, rightDir: right)
        driver.post(buttons: buttons,
                    dpad: hidDpad(up: up, down: down, left: left, right: right),
                    lx: axis(s.lx, deadzone: deadzone), ly: axis(s.ly, deadzone: deadzone),
                    rx: axis(s.rx, deadzone: deadzone), ry: axis(s.ry, deadzone: deadzone),
                    triggerL: s.l2, triggerR: s.r2,
                    motion: [s.gyroX, s.gyroY, s.gyroZ, s.accelX, s.accelY, s.accelZ])
        lastSent = s
    }

    // MARK: Mappatura tasti

    var currentMap: ButtonMap { mappings[mode] ?? mode.defaultMap }
    func target(for b: PadButton) -> JoyButton { currentMap[b] ?? .none }
    func setTarget(_ t: JoyButton, for b: PadButton) {
        var map = currentMap
        map[b] = t
        mappings[mode] = map
    }
    func resetMapping() { mappings[mode] = mode.defaultMap }

    /// Mappature salvate da JoyConFinto ("mapping.<modalità>"); ritorna quante.
    func importMappings(from other: UserDefaults) -> Int {
        var maps = mappings, n = 0
        for m in OutputMode.allCases {
            guard let saved = other.dictionary(forKey: "mapping.\(m.rawValue)") as? [String: String] else { continue }
            var map = m.defaultMap
            for (k, v) in saved {
                if let b = PadButton(rawValue: k), let t = JoyButton(rawValue: v), m.targets.contains(t) { map[b] = t }
            }
            maps[m] = map
            n += 1
        }
        if n > 0 { mappings = maps }
        return n
    }

    var mappingSummary: String {
        PadButton.allCases.compactMap { b in
            let t = target(for: b)
            return t == .none ? nil : "\(b.title) = \(t.title)"
        }.joined(separator: " · ")
    }

    // MARK: Ciclo a 60 Hz

    func tick(uiFrame: Bool) {
        if uiFrame {
            var shown = liveState
            // L'anteprima non mostra i sensori, e il tremolio di ±1 degli stick non si vede.
            shown.gyroX = 0; shown.gyroY = 0; shown.gyroZ = 0
            shown.accelX = 0; shown.accelY = 0; shown.accelZ = 0
            shown.lx &= 0xFC; shown.ly &= 0xFC; shown.rx &= 0xFC; shown.ry &= 0xFC
            if shown != live.pad { live.pad = shown }
        }
        guard enabled, let p = pad, p.isOpen else { refreshConnected(); return }
        var motors: (UInt8, UInt8) = (0, 0)
        if mode == .joyCon2 {
            if !driver.isConnected, driver.connect(type: VirtualJoyConDriver.typeJoyCon2) { lastSent = nil }
            if rumble { motors = driver.latestRumble() ?? (0, 0) }
        } else if rumble, let b = bridge {
            motors = b.rumble(for: sides)
        }
        refreshConnected()
        if motors != lastMotors {
            lastMotors = motors
            p.sendOutput(lowMotor: motors.0, highMotor: motors.1)
        }
    }
}

/// Tutto insieme: 4 posti Wii Remote, il DualSense, l'accoppiamento e le mappature Wii
/// condivise.
@MainActor
final class AppEngine: ObservableObject {
    let hub = JFWiiHub()
    let players: [WiiPlayer]
    let dualSense = DualSensePlayer()
    let phones = PhoneHub()
    let driverInstaller = DriverInstaller()
    private let pairer = JFWiiPairer()
    /// JoyCon2Mac aperto: il suo demone usa lo stesso driver e cerca anche lui i Wii Remote.
    @Published private(set) var joyCon2MacRunning = false

    @Published private(set) var pairingStatus: String?
    @Published private(set) var pairing = false
    @Published private(set) var joyConFintoRunning = false
    /// Mappature Wii per uscita, lato e impugnatura (UserDefaults "mapping.<chiave>").
    @Published private(set) var wiiMappings: [String: WiiButtonMap] = [:] {
        didSet {
            for (k, map) in wiiMappings {
                defaults.set(Dictionary(uniqueKeysWithValues: map.map { ($0.key.key, $0.value.rawValue) }),
                             forKey: "mapping.\(k)")
            }
            for p in players { p.push() }
        }
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var ticks = 0
    /// Assi veri del Wii Remote (procedura guidata), uguali per tutti i telecomandi.
    @Published private(set) var axisCalibration = WiiAxisCalibration.load(.standard)

    /// Nuova misura degli assi: vale per tutti; le correzioni a rotazioni tornano Standard.
    func setAxisCalibration(_ c: WiiAxisCalibration) {
        axisCalibration = c
        c.save(defaults)
        for p in players { p.axisFix = .standard; p.golfAxisFix = .standard }
    }

    init() {
        players = (0..<4).map { WiiPlayer(slot: $0) }
        // Versione 2: nuova mappatura verticale (giocatore 1 come riferimento, lato destro
        // specchiato). Le mappature verticali salvate prima si sostituiscono una volta.
        let resetVertical = defaults.integer(forKey: "mappingVersion") < 2
        defaults.set(2, forKey: "mappingVersion")
        var maps: [String: WiiButtonMap] = [:]
        for out in WiiOutput.allCases {
            for s in WiiSide.allCases {
                for sw in [false, true] {
                    let k = Self.mapKey(output: out, side: s, sideways: sw)
                    var map = wiiDefaultMap(output: out, side: s, sideways: sw)
                    let saved = resetVertical && !sw ? [:]
                        : defaults.dictionary(forKey: "mapping.\(k)") as? [String: String] ?? [:]
                    for b in WiiButton.allCases {
                        if let v = saved[b.key], let t = JoyButton(rawValue: v),
                           wiiTargets(output: out, side: s, for: b).contains(t) { map[b] = t }
                    }
                    maps[k] = map
                }
            }
        }
        wiiMappings = maps
        for p in players { p.app = self }

        hub.onState = { [weak self] slot, s in
            MainActor.assumeIsolated {
                guard let self, slot >= 0, slot < 4 else { return }
                self.players[Int(slot)].handle(s)
            }
        }
        hub.start()
        pairer.onUpdate = { [weak self] state, message in
            MainActor.assumeIsolated { self?.pairingUpdate(state ?? "", message ?? "") }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hub.stop()
                self?.players.forEach { $0.shutdown() }
                self?.dualSense.shutdown()
                self?.phones.shutdown()
            }
        }
    }

    // MARK: Accoppiamento

    func startPairing() {
        pairing = true
        pairingStatus = "Premi il tasto rosso SYNC sotto il coperchio delle pile del Wii Remote…"
        pairer.start(withTimeout: 30)
    }

    func cancelPairing() { pairer.cancel() }

    private func pairingUpdate(_ state: String, _ message: String) {
        switch state {
        case "searching": pairingStatus = "Cerco… premi il tasto rosso SYNC sotto il coperchio delle pile"
        case "pairing": pairingStatus = "Trovato, accoppio…"
        case "paired": pairing = false; pairingStatus = "Accoppiato! Da ora basta premere 1+2 per collegarlo."
        case "timeout": pairing = false; pairingStatus = "Nessun Wii Remote trovato: riprova tenendo premuto SYNC."
        case "cancelled": pairing = false; pairingStatus = nil
        default: pairing = false; pairingStatus = "Accoppiamento non riuscito" + (message.isEmpty ? "" : ": \(message)")
        }
    }

    // MARK: Mappature Wii condivise

    static func mapKey(output: WiiOutput, side: WiiSide, sideways: Bool) -> String {
        "\(output == .joyCon ? "classico" : "joycon2").\(wiiMapKey(side: side, sideways: sideways))"
    }

    func wiiMap(output: WiiOutput, side: WiiSide, sideways: Bool) -> WiiButtonMap {
        wiiMappings[Self.mapKey(output: output, side: side, sideways: sideways)]
            ?? wiiDefaultMap(output: output, side: side, sideways: sideways)
    }

    func setWiiTarget(_ t: JoyButton, for b: WiiButton, output: WiiOutput, side: WiiSide, sideways: Bool) {
        var map = wiiMap(output: output, side: side, sideways: sideways)
        map[b] = t
        wiiMappings[Self.mapKey(output: output, side: side, sideways: sideways)] = map
    }

    func resetWiiMap(output: WiiOutput, side: WiiSide, sideways: Bool) {
        wiiMappings[Self.mapKey(output: output, side: side, sideways: sideways)] = wiiDefaultMap(output: output, side: side, sideways: sideways)
    }

    // MARK: Importa da JoyConFinto

    @Published private(set) var importStatus: String?

    /// Copia da JoyConFinto le mappature Wii (uscita Joy-Con classico), quelle del
    /// DualSense e la sensibilità del giroscopio per tipo di MotionPlus.
    func importFromJoyConFinto() {
        guard let other = UserDefaults(suiteName: "local.joyconfinto.app") else {
            importStatus = "Impostazioni di JoyConFinto non trovate"
            return
        }
        var maps = wiiMappings, wii = 0
        for s in WiiSide.allCases {
            for sw in [false, true] {
                let k = wiiMapKey(side: s, sideways: sw)
                guard let saved = other.dictionary(forKey: "wiiMapping.\(k)") as? [String: String] else { continue }
                var map = wiiDefaultMap(output: .joyCon, side: s, sideways: sw)
                for b in WiiButton.allCases {
                    if let v = saved[b.key], let t = JoyButton(rawValue: v),
                       wiiTargets(output: .joyCon, side: s, for: b).contains(t) { map[b] = t }
                }
                maps[Self.mapKey(output: .joyCon, side: s, sideways: sw)] = map
                wii += 1
            }
        }
        if wii > 0 { wiiMappings = maps }
        let ds = dualSense.importMappings(from: other)
        var scales: [String] = []
        for builtIn in [true, false] {
            let name = builtIn ? "integrato" : "esterno"
            guard let v = other.object(forKey: "wiiGyroScale.\(name)") as? Double else { continue }
            defaults.set(v, forKey: "gyroScale.\(name)")
            gyroScaleChanged(builtIn: builtIn, scale: v)
            scales.append(String(format: "%@ %.3f", name, v))
        }
        importStatus = wii + ds + scales.count == 0
            ? "In JoyConFinto non c'è niente da importare"
            : "Importato: \(wii) mappature Wii, \(ds) DualSense" + (scales.isEmpty ? "" : ", sensibilità " + scales.joined(separator: ", "))
    }

    func gyroScaleChanged(builtIn: Bool, scale: Double) {
        for p in players { p.adoptGyroScale(builtIn: builtIn, scale: scale) }
    }

    var activeCount: Int {
        players.filter { $0.outputConnected }.count + (dualSense.outputConnected ? 1 : 0)
            + phones.phones.filter { $0.outputConnected }.count
    }

    // MARK: Ciclo a 60 Hz

    private func tick() {
        ticks += 1
        let uiFrame = ticks % 2 == 0                 // UI a 30 Hz
        for p in players { p.tick(uiFrame: uiFrame) }
        dualSense.tick(uiFrame: uiFrame)
        phones.tick(uiFrame: uiFrame)
        if ticks % 60 == 0 {
            // JoyConFinto e JoyCon2Mac usano lo stesso driver e gli stessi controller: insieme si disturbano.
            let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            let running = ids.contains("local.joyconfinto.app")
            if running != joyConFintoRunning { joyConFintoRunning = running }
            let j2m = ids.contains { $0.hasPrefix("local.joycon2mac.") }
            if j2m != joyCon2MacRunning { joyCon2MacRunning = j2m }
            driverInstaller.refresh()
            autoInstallDriver()
        }
    }

    private var driverAutoTried = false

    /// Alla prima apertura (e se il driver manca) lo installa da sé: dopo, il driver è di
    /// questa app. Non con JoyCon2Mac aperto, che tiene il driver occupato.
    private func autoInstallDriver() {
        let d = driverInstaller
        guard !driverAutoTried, !d.busy, d.bundled, !joyCon2MacRunning, !d.owned || !d.live else { return }
        driverAutoTried = true
        d.install()
    }
}
struct StickView: View {
    let x: UInt8, y: UInt8, label: String
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.4), lineWidth: 2)
                Circle().fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                    .offset(x: (CGFloat(x) - 127.5) / 127.5 * 28, y: (CGFloat(y) - 127.5) / 127.5 * 28)
            }
            .frame(width: 70, height: 70)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Anteprima di stick e tasti: osserva solo LiveInput, così si ridisegna da sola.
struct PadPreview: View {
    @ObservedObject var live: LiveInput

    var body: some View {
        let s = live.pad
        HStack(spacing: 24) {
            StickView(x: s.lx, y: s.ly, label: "Stick L")
            StickView(x: s.rx, y: s.ry, label: "Stick R")
            VStack(alignment: .leading, spacing: 6) {
                HStack { ButtonChip(label: "A", on: s.circle); ButtonChip(label: "B", on: s.cross)
                         ButtonChip(label: "X", on: s.triangle); ButtonChip(label: "Y", on: s.square) }
                HStack { ButtonChip(label: "L", on: s.l1); ButtonChip(label: "ZL", on: s.zl)
                         ButtonChip(label: "R", on: s.r1); ButtonChip(label: "ZR", on: s.zr) }
                HStack { ButtonChip(label: "−", on: s.create); ButtonChip(label: "+", on: s.options)
                         ButtonChip(label: "Home", on: s.ps); ButtonChip(label: "Cattura", on: s.touchpad)
                         ButtonChip(label: "C", on: s.mute) }
                HStack { ButtonChip(label: "↑", on: s.dpadUp); ButtonChip(label: "↓", on: s.dpadDown)
                         ButtonChip(label: "←", on: s.dpadLeft); ButtonChip(label: "→", on: s.dpadRight)
                         ButtonChip(label: "L3", on: s.l3); ButtonChip(label: "R3", on: s.r3) }
            }
        }
    }
}

struct ButtonChip: View {
    let label: String, on: Bool
    var body: some View {
        Text(label)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(on ? Color.white : Color.secondary)
    }
}


struct WiiButtonsPreview: View {
    @ObservedObject var live: LiveInput
    private let names = ["↑", "↓", "←", "→", "A", "B", "1", "2", "−", "+", "⌂", "C", "Z"]

    var body: some View {
        ForEach(Array(names.enumerated()), id: \.offset) { i, name in
            ButtonChip(label: name, on: live.wiiButtons & (1 << UInt32(i)) != 0)
        }
    }
}

/// Una riga della finestra di mappatura: un tasto fisico della sorgente.
struct MappingRow: Identifiable {
    let id: String
    let title: String
    let pressed: Bool
    let targets: [JoyButton]
    let target: JoyButton
    let set: (JoyButton) -> Void
}

/// Finestra per assegnare i tasti fisici (Wii Remote o DualSense) ai tasti Joy-Con.
/// Le righe arrivano da una closure valutata nel body, così il pallino "premuto"
/// segue LiveInput e i menu seguono il modello osservato.
struct MappingSheet<Model: ObservableObject>: View {
    @ObservedObject var model: Model
    @ObservedObject var live: LiveInput
    let title: String
    let subtitle: String
    let rows: () -> [MappingRow]
    let reset: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(rows()) { row in
                    GridRow {
                        Circle()
                            .fill(row.pressed ? Color.accentColor : Color.secondary.opacity(0.2))
                            .frame(width: 10, height: 10)
                        Text(row.title)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { row.target }, set: row.set)) {
                            ForEach(row.targets) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
            }

            HStack {
                Button("Ripristina predefiniti", action: reset)
                Spacer()
                Button("Fine") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}


func statusRow(ok: Bool, text: String) -> some View {
    Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
        .foregroundStyle(ok ? Color.green : Color.orange)
}

/// I 4 LED del Wii Remote, acceso quello del giocatore.
struct PlayerLEDs: View {
    let slot: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i == slot ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

/// Riga di un posto giocatore nella sezione Connessione.
struct PlayerRow: View {
    @ObservedObject var player: WiiPlayer
    @State private var showDetails = false

    var body: some View {
        let w = player.wiiState
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Giocatore \(player.number)").font(.headline)
                    PlayerLEDs(slot: player.slot)
                }
                if w.connected {
                    Text((["Collegato",
                          w.battery >= 0 ? "batteria \(w.battery)%" : nil,
                          w.motionPlus ? "MotionPlus \(w.motionPlusBuiltIn ? "integrato" : "esterno")" : "senza MotionPlus",
                          player.outputConnected ? "→ \(player.seenAs)" : nil] as [String?]).compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(player.outputConnected ? Color.green : Color.secondary)
                } else {
                    Text("Libero: premi 1+2 su un Wii Remote accoppiato")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("", selection: $player.output) {
                ForEach(WiiOutput.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            Picker("", selection: $player.side) {
                Text("Sinistro").tag(WiiSide.left)
                Text("Destro").tag(WiiSide.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            .help(player.output == .joyCon ? "Joy-Con (L) o (R)" : "Joy-Con 2: stick e mappatura di quel lato")
            Toggle("", isOn: $player.enabled).toggleStyle(.switch).labelsHidden()
                .help("Attiva o spegne il controller virtuale di questo giocatore")
            Button("Dettagli…") { showDetails = true }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showDetails) { PlayerDetails(player: player) }
    }
}

/// Impostazioni di un singolo Wii Remote.
struct PlayerDetails: View {
    @ObservedObject var player: WiiPlayer
    @State private var showMapping = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let w = player.wiiState
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Giocatore \(player.number)").font(.title2.bold())
                PlayerLEDs(slot: player.slot)
                Spacer()
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    statusRow(ok: w.connected, text: w.connected ? "Wii Remote collegato" + (w.battery >= 0 ? " · batteria \(w.battery)%" : "")
                                                                 : "Nessun Wii Remote in questo posto")
                    if w.connected {
                        statusRow(ok: w.motionPlus, text: w.motionPlus ? "MotionPlus attivo (\(w.motionPlusBuiltIn ? "integrato" : "adattatore esterno"))"
                                                                       : "MotionPlus non attivo: solo accelerometro")
                        if w.motionPlus {
                            statusRow(ok: w.calibration == 0,
                                      text: w.calibration == 0 ? "Giroscopio calibrato"
                                          : w.calibration == 2 ? "Calibrazione in corso: non toccarlo…"
                                          : "Da calibrare: appoggialo a faccia in giù su un piano, fermo")
                        }
                        statusRow(ok: player.outputConnected,
                                  text: player.outputConnected ? "Il Mac vede: \(player.seenAs)" : "Controller virtuale non attivo")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("Impugnatura", selection: $player.sideways) {
                Text("Verticale").tag(false)
                Text("Orizzontale").tag(true)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 6) {
                WiiButtonsPreview(live: player.live)
                Spacer()
                Button("Ricalibra giroscopio") { player.recalibrate() }
                    .help("Premi, poi appoggia il Wii Remote a faccia in giù su un piano orizzontale e non toccarlo per un secondo, come sulla Wii")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(player.axisStep == .idle
                             ? (player.app?.axisCalibration.measured == true
                                ? "Assi del telecomando misurati: il movimento arriva al gioco non specchiato."
                                : "Assi del telecomando non misurati: se il gioco vede i movimenti al contrario o da destro quando sei mancino, misurali.")
                             : player.axisStep.instruction)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if player.axisWizardActive || player.axisStep == .computing {
                            Button("Annulla") { player.cancelAxisWizard() }
                        } else if player.axisStep == .verify {
                            Button("Fine") { player.cancelAxisWizard() }
                        } else {
                            Button("Misura assi…") { player.startAxisWizard() }
                        }
                    }
                    if let hint = player.axisHint {
                        Text(hint).font(.caption).foregroundStyle(.orange)
                    }
                    if player.axisStep == .verify {
                        Text(player.axisReadout).font(.system(.callout, design: .monospaced))
                        Text("Prova: punta al soffitto → \"Punta in su\"; fianco destro in alto → \"fianco destro\"; giralo verso sinistra → \"gira a SINISTRA\".")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if w.motionPlus {
                HStack(alignment: .top) {
                    Text(player.gyroScaleCalibrating
                         ? "Per 20 secondi: movimenti lenti e ampi (30-90°) in tutte le direzioni, fermandoti 1 secondo tra uno e l'altro…"
                         : String(format: "Sensibilità giroscopio: %.3f", player.gyroScale)
                            + (player.gyroScaleStatus.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(player.gyroScaleCalibrating ? "Annulla" : "Calibra sensibilità") {
                        player.gyroScaleCalibrating ? player.cancelGyroScale() : player.startGyroScale()
                    }
                    .help("Una volta per tipo di MotionPlus (integrato / adattatore): vale per tutti i giocatori")
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Posizione al tasto")
                        Picker("", selection: $player.aimButton) {
                            ForEach(WiiButton.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        Picker("", selection: $player.aim) {
                            ForEach(WiiAim.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .help("Quando premi questo tasto il gioco vede la punta esattamente all'angolo scelto rispetto alla verticale. Vale fino alla pressione successiva.")
                    HStack {
                        Text("Profilo")
                        Picker("", selection: $player.profile) {
                            ForEach(WiiProfile.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 160)
                        Text("Home+1 tenuti premuti sul telecomando: 1 vibrazione = Sport, 2 = Golf")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Correzione assi Sport")
                        Picker("", selection: $player.axisFix) {
                            ForEach(WiiAxisFix.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        Text("Golf")
                        Picker("", selection: $player.golfAxisFix) {
                            ForEach(WiiAxisFix.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    .help(player.activeAxisFix.help + ". Si può cambiare mentre giochi.")
                    Toggle("Vibrazione chiesta dal gioco su questo Wii Remote", isOn: $player.rumble)
                }
            }

            HStack(alignment: .top) {
                Text(player.mappingSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Mappa tasti…") { showMapping = true }
            }

            HStack {
                Spacer()
                Button("Fine") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .sheet(isPresented: $showMapping) {
            MappingSheet(model: player, live: player.live,
                         title: "Mappa tasti Wii Remote",
                         subtitle: "\(player.output.title), \(player.side.title.lowercased()), impugnatura \(player.sideways ? "orizzontale" : "verticale"). La mappatura vale per tutti i giocatori con la stessa combinazione. La croce può muovere lo stick o fare da tasto.",
                         rows: {
                             WiiButton.allCases.map { b in
                                 MappingRow(id: b.key, title: b.title, pressed: b.isPressed(player.live.wiiButtons),
                                            targets: player.targets(for: b), target: player.target(for: b),
                                            set: { player.setTarget($0, for: b) })
                             }
                         },
                         reset: player.resetMapping)
        }
    }
}

/// Sezione DualSense (come JoyConFinto).
struct DualSenseSection: View {
    @ObservedObject var ds: DualSensePlayer
    @State private var showMapping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "gamecontroller.fill").font(.title2)
                VStack(alignment: .leading) {
                    Text("DualSense").font(.title3.bold())
                    Text("PS5 → Joy-Con").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $ds.enabled).toggleStyle(.switch).labelsHidden()
            }
            Picker("Si presenta come", selection: $ds.mode) {
                ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 6) {
                statusRow(ok: ds.padDescription != nil,
                          text: ds.padDescription ?? "Nessun DualSense: collegalo via USB (consigliato) o Bluetooth")
                if ds.padDescription != nil && ds.enabled {
                    statusRow(ok: ds.outputConnected,
                              text: ds.outputConnected ? "Il Mac vede: \(ds.mode.seenAs)" : "Controller virtuale non attivo")
                    statusRow(ok: ds.exclusive,
                              text: ds.exclusive ? "DualSense nascosto agli altri programmi" : "DualSense ancora visibile agli altri programmi")
                }
            }
            PadPreview(live: ds.live)
            HStack {
                Toggle("Nascondi il DualSense", isOn: $ds.hideDualSense)
                Toggle("Vibrazione", isOn: $ds.rumble)
                Spacer()
                Text("Deadzone")
                Slider(value: $ds.deadzone, in: 0...0.25).frame(width: 110)
                Text(String(format: "%.0f%%", ds.deadzone * 100)).monospacedDigit().frame(width: 36)
            }
            HStack(alignment: .top) {
                Text(ds.mappingSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Mappa tasti…") { showMapping = true }
            }
        }
        .sheet(isPresented: $showMapping) {
            MappingSheet(model: ds, live: ds.live,
                         title: "Mappa tasti DualSense",
                         subtitle: "Modalità «\(ds.mode.title)». Ogni modalità ha la sua mappatura. Premi un tasto sul DualSense: il pallino si accende sulla sua riga.",
                         rows: {
                             PadButton.allCases.map { b in
                                 MappingRow(id: b.rawValue, title: b.title, pressed: b.isPressed(ds.live.pad),
                                            targets: ds.mode.targets, target: ds.target(for: b),
                                            set: { ds.setTarget($0, for: b) })
                             }
                         },
                         reset: ds.resetMapping)
        }
    }
}

/// Stato del driver e installazione.
struct DriverSection: View {
    @ObservedObject var driver: DriverInstaller

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(driver.live ? (driver.owned ? "Driver attivo (installato da VirtualJoyCon2)" : "Driver attivo (installato da JoyCon2Mac)")
                                      : "Driver non attivo: i controller virtuali non possono comparire",
                          systemImage: driver.live ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(driver.live ? .green : .red)
                    Spacer()
                    if driver.needsApproval {
                        Button("Apri Impostazioni") { driver.openSettings() }
                    }
                    Button(driver.busy ? "Installo…" : (driver.live ? "Reinstalla driver" : "Installa driver")) { driver.install() }
                        .disabled(driver.busy)
                        .help("Attiva il driver incluso nell'app. Serve SIP disattivato e la modalità sviluppatore delle estensioni (systemextensionsctl developer on).")
                }
                if let m = driver.message {
                    Text(m).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ContentView: View {
    @ObservedObject var engine: AppEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "wand.and.rays").font(.title)
                    VStack(alignment: .leading) {
                        Text("VirtualJoyCon2").font(.title2.bold())
                        Text("Wii Remote Plus, DualSense e iPhone → Joy-Con").foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("Guida") {
                            // docs/ sta accanto all'app, nella cartella del progetto
                            let guide = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("docs/README.md")
                            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: guide.path) ? guide : guide.deletingLastPathComponent())
                        }
                        .help("Apre la documentazione (cartella docs accanto all'app)")
                        Button("Importa da JoyConFinto") { engine.importFromJoyConFinto() }
                            .help("Copia mappature Wii (Joy-Con classico), mappature DualSense e sensibilità del giroscopio salvate in JoyConFinto")
                        if let status = engine.importStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if engine.joyConFintoRunning {
                    Label("JoyConFinto è aperto: usa lo stesso driver e gli stessi controller. Chiudilo prima di usare questa app.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if engine.joyCon2MacRunning {
                    Label("JoyCon2Mac è aperto: usa lo stesso driver e cerca anche lui i Wii Remote. Chiudilo: VirtualJoyCon2 fa già tutto da sola.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DriverSection(driver: engine.driverInstaller)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Connessione Wii Remote").font(.title3.bold())
                            Spacer()
                            Button(engine.pairing ? "Annulla" : "Accoppia nuovo Wii Remote") {
                                engine.pairing ? engine.cancelPairing() : engine.startPairing()
                            }
                            .help("Solo la prima volta per ogni telecomando: poi basta premere 1+2")
                        }
                        if let status = engine.pairingStatus {
                            Label(status, systemImage: engine.pairing ? "dot.radiowaves.left.and.right" : "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Fino a 4 Wii Remote: ognuno prende il primo posto libero e accende il LED del suo numero. Ogni giocatore ha il proprio controller virtuale.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        ForEach(engine.players) { p in
                            PlayerRow(player: p)
                            if p.slot < 3 { Divider() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    DualSenseSection(ds: engine.dualSense)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    PhoneSection(hub: engine.phones)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Con più controller in Bluetooth la radio si satura e il Wii perde campioni: collega via USB tutto quello che puoi (es. il DualSense).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(width: 760, height: 900)
    }
}

@main
struct VirtualJoyCon2App: App {
    @StateObject private var engine = AppEngine()

    var body: some Scene {
        Window("VirtualJoyCon2", id: "main") {
            ContentView(engine: engine)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("VirtualJoyCon2", systemImage: "wand.and.rays") {
            ForEach(engine.players) { p in
                Toggle("Giocatore \(p.number)", isOn: Binding(get: { p.enabled }, set: { p.enabled = $0 }))
            }
            Toggle("DualSense", isOn: Binding(get: { engine.dualSense.enabled }, set: { engine.dualSense.enabled = $0 }))
            Divider()
            Button("Esci") { NSApplication.shared.terminate(nil) }
        }
    }
}
