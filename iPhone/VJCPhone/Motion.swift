// Movimento dall'iPhone: giroscopio (già senza deriva) e accelerometro di CoreMotion.

import CoreMotion
import simd

final class MotionSource {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private var last: TimeInterval?
    private let lock = NSLock()
    private var _landscape = false
    private var _gain = 1.0
    private var _golf = false
    private var _neutral = matrix_identity_float3x3 // calibrazione: la posizione "giusta", assi DSU
    private var _mount = matrix_identity_float3x3   // posizione al tasto (golf), assi DSU
    private var _rawUp = SIMD3<Float>(0, 1, 0)      // gravità "su", assi DSU, senza calibrazione né golf
    private var _up = SIMD3<Float>(0, 1, 0)         // gravità "su" dopo calibrazione e golf, prima della posizione al tasto
    private var _latest: MotionSample?

    /// Coppia sx + dx: telefono in orizzontale come un gamepad, invece che disteso come un telecomando.
    var landscape: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _landscape }
        set { lock.lock(); _landscape = newValue; lock.unlock() }
    }
    /// Potenza dello swing: moltiplica la rotazione e l'accelerazione dei movimenti (non la gravità).
    var gain: Double {
        get { lock.lock(); defer { lock.unlock() }; return _gain }
        set { lock.lock(); _gain = newValue; lock.unlock() }
    }
    /// Profilo Golf (come il profilo Golf del Wii Remote): il telefono si impugna come una mazza,
    /// con la faccia girata dall'altra parte, quindi si ruota di 180° attorno alla punta; e da fermo
    /// sotto 2 gradi/s la rotazione vale zero, perché anche poca deriva carica il tiro.
    var golf: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _golf }
        set { lock.lock(); _golf = newValue; lock.unlock() }
    }
    /// Tolleranza della posizione al tasto: punta in giù tra 45° e 90°.
    static let aimRange: ClosedRange<Float> = 45...90

    /// Posizione al tasto (golf): con la punta in giù tra 45° e 90°, da ora il gioco vede il
    /// telefono con la punta dritta in giù (rotazione più piccola che porta la gravità misurata
    /// sull'asse della punta). Fuori tolleranza niente correzione. Ritorna l'angolo misurato.
    @discardableResult
    func aimDown() -> (degrees: Float, applied: Bool) {
        lock.lock(); defer { lock.unlock() }
        let up = _up
        let deg = asin(max(-1, min(1, up.z))) * 180 / .pi           // punta = −Z: in giù se "su" sta su +Z
        guard Self.aimRange.contains(deg) else { _mount = matrix_identity_float3x3; return (deg, false) }
        _mount = simd_float3x3(simd_quatf(from: up, to: SIMD3(0, 0, 1)))
        return (deg, true)
    }

    func clearAim() { lock.lock(); _mount = matrix_identity_float3x3; lock.unlock() }

    /// Calibrazione: la posizione di adesso diventa quella "giusta" (`target` = dove deve stare il
    /// "su" negli assi DSU: (0, 1, 0) disteso a schermo in su, (0, 0, −1) a volante). È la
    /// rotazione più piccola tra le due: corregge inclinazione e rollio, non la direzione
    /// orizzontale (che senza bussola non ha riferimento). Ritorna di quanti gradi corregge.
    func calibrate(target: SIMD3<Float>) -> (rotation: simd_quatf, degrees: Float) {
        lock.lock(); defer { lock.unlock() }
        let q = simd_quatf(from: _rawUp, to: simd_normalize(target))
        _neutral = simd_float3x3(q)
        return (q, q.angle * 180 / .pi)
    }

    /// Calibrazione salvata (o nessuna).
    func setCalibration(_ q: simd_quatf?) {
        lock.lock(); _neutral = q.map { simd_float3x3($0) } ?? matrix_identity_float3x3; lock.unlock()
    }

    /// Gravità "su" dell'ultimo campione (senza le accelerazioni dei movimenti), assi del campione.
    var up: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _up }
    /// Ultimo campione, per la schermata di verifica.
    var latest: MotionSample? { lock.lock(); defer { lock.unlock() }; return _latest }

    var available: Bool { manager.isDeviceMotionAvailable }

    /// `onSample` gira sulla coda del movimento, non sul main thread.
    func start(_ onSample: @escaping (MotionSample) -> Void) {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 200
        last = nil
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            let dt = self.last.map { m.timestamp - $0 } ?? self.manager.deviceMotionUpdateInterval
            self.last = m.timestamp
            var s = Self.sample(m, dt: dt, landscape: self.landscape, gain: self.gain, golf: self.golf)
            self.lock.lock()
            // Golf: 180° attorno alla punta (−Z in DSU), come "Ruota sulla punta" del Wii Remote.
            let golf = self._golf
            func flip(_ v: SIMD3<Float>) -> SIMD3<Float> { golf ? SIMD3(-v.x, -v.y, v.z) : v }
            // "Su" dalla sola gravità (senza le accelerazioni dello swing).
            let g = Self.sample(m, dt: dt, landscape: self._landscape, gain: 0, golf: false).accel
            if simd_length(g) > 0.5 { self._rawUp = simd_normalize(g) }
            self._up = flip(self._neutral * self._rawUp)
            // Assi del telefono → calibrazione → golf → posizione al tasto.
            s.gyro = self._mount * flip(self._neutral * s.gyro)
            s.accel = self._mount * flip(self._neutral * s.accel)
            self._latest = s
            self.lock.unlock()
            onSample(s)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    /// Assi dell'iPhone (+X destra, +Y verso l'alto dello schermo, +Z fuori dallo schermo)
    /// → assi DSU del controller (+X destra, +Y fuori dalla faccia, +Z verso il giocatore):
    /// - Joy-Con singolo, telefono disteso che punta allo schermo: DSU = (x, z, −y);
    /// - coppia, telefono in orizzontale con la parte alta a sinistra (come un gamepad, la
    ///   destra del gamepad è il fondo del telefono): DSU = (−y, z, −x).
    /// Sono rotazioni, non specchi.
    /// CoreMotion dà la gravità come accelerazione verso il basso: la forza specifica che
    /// leggerebbe un Joy-Con fermo è l'opposto (+1 g in su).
    /// `golf` qui toglie solo la deriva da fermo; la rotazione del golf si applica dopo la calibrazione.
    /// `gain` (potenza dello swing) moltiplica la velocità angolare e l'accelerazione del
    /// movimento; la gravità resta com'è, così l'inclinazione da fermo non cambia.
    private static func sample(_ m: CMDeviceMotion, dt: TimeInterval, landscape: Bool, gain: Double, golf: Bool) -> MotionSample {
        var toDeg = 180 / Double.pi * gain
        let r = m.rotationRate
        if golf && simd_length(SIMD3(r.x, r.y, r.z)) * 180 / .pi < 2 { toDeg = 0 }
        let u = m.userAcceleration
        let f = SIMD3(-(m.gravity.x + u.x * gain),
                      -(m.gravity.y + u.y * gain),
                      -(m.gravity.z + u.z * gain))
        func dsu(_ v: SIMD3<Double>) -> SIMD3<Float> {
            landscape ? SIMD3(Float(-v.y), Float(v.z), Float(-v.x)) : SIMD3(Float(v.x), Float(v.z), Float(-v.y))
        }
        return MotionSample(dt: Float(max(0, min(0.1, dt))),
                            gyro: dsu(SIMD3(r.x, r.y, r.z) * toDeg),
                            accel: dsu(f))
    }
}
