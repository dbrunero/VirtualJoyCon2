// Tasti volume come tasti del Joy-Con.
//
// iOS manda pressione e rilascio dei tasti fisici (volume, tasto Azione, Controllo
// fotocamera) solo alle app che stanno usando la fotocamera (AVCaptureEventInteraction /
// onCameraCaptureEvent). Quindi la si tiene accesa al minimo, senza mostrarla: in alto
// compare il pallino verde. In cambio i tasti non cambiano il volume e il rilascio è esatto.

import AVFoundation

final class CameraKeepAlive: NSObject, AVCaptureSessionControlsDelegate {
    enum State { case off, starting, running, denied, unavailable }

    /// Controllo fotocamera: la pressione leggera "attiva" i controlli della sessione, il dito che
    /// si toglie (dopo un po') li disattiva. iOS non dice altro sul dito appoggiato. Main thread.
    var onControlsActive: ((Bool) -> Void)?
    /// Il dito scorre sul Controllo fotocamera (valore del cursore). Main thread.
    var onSlide: ((Float) -> Void)?
    private let controlsQueue = DispatchQueue(label: "vjcphone.camera.controls")

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vjcphone.camera")
    private var configured = false
    /// Esito della configurazione, per il registro dei tasti (main thread dopo `start`).
    private(set) var info = ""

    /// `done` arriva sul main thread.
    func start(_ done: @escaping (State) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { DispatchQueue.main.async { done(.denied) }; return }
            self.queue.async {
                if !self.configured { self.configured = self.configure() }
                if self.configured && !self.session.isRunning { self.session.startRunning() }
                let state: State = self.session.isRunning ? .running : .unavailable
                DispatchQueue.main.async { done(state) }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        DispatchQueue.main.async { self.onControlsActive?(true) }
    }
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        DispatchQueue.main.async { self.onControlsActive?(false) }
    }

    /// Fotocamera posteriore (il Controllo fotocamera e la sua pressione leggera sono pensati per
    /// quella), qualità minima, 15 fotogrammi al secondo, fotogrammi scartati.
    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .low
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(output) { session.addOutput(output) }
        // Serve almeno un controllo perché la pressione leggera attivi i controlli; il cursore
        // non fa niente, interessa solo sapere quando il dito c'è.
        var added = false
        if session.supportsControls {
            let slider = AVCaptureSlider("Joy-Con", symbolName: "gamecontroller", in: 0...1)
            // Senza azione e coda iOS rifiuta il controllo (canAddControl = NO).
            slider.setActionQueue(controlsQueue) { [weak self] v in
                DispatchQueue.main.async { self?.onSlide?(v) }
            }
            if session.canAddControl(slider) {
                session.setControlsDelegate(self, queue: controlsQueue)
                session.addControl(slider)
                added = true
            }
        }
        info = "fotocamera \(device.position == .back ? "posteriore" : "frontale"), controlli supportati: "
            + (session.supportsControls ? "sì" : "no") + (added ? ", aggiunti" : ", non aggiunti")
        if (try? device.lockForConfiguration()) != nil {
            let slow = CMTime(value: 1, timescale: 15)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= slow && slow <= $0.maxFrameDuration }) {
                device.activeVideoMinFrameDuration = slow
                device.activeVideoMaxFrameDuration = slow
            }
            device.unlockForConfiguration()
        }
        return true
    }
}
