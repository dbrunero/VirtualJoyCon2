// Vibrazione chiesta dal gioco → motore aptico dell'iPhone (Core Haptics, continua).

import CoreHaptics
import UIKit

final class Rumble {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var playing = false
    private var intensity: Float = 0
    private let tap = UIImpactFeedbackGenerator(style: .light)

    init() { setUp() }

    private func setUp() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = false
            e.resetHandler = { [weak self] in
                self?.playing = false
                try? self?.engine?.start()
                self?.makePlayer()
            }
            e.stoppedHandler = { [weak self] _ in self?.playing = false }
            try e.start()
            engine = e
            makePlayer()
        } catch {
            engine = nil
        }
    }

    private func makePlayer() {
        guard let e = engine else { return }
        // Un evento continuo lungo, ripetuto: l'intensità si cambia al volo.
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
        ], relativeTime: 0, duration: 30)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let p = try? e.makeAdvancedPlayer(with: pattern) else { return }
        p.loopEnabled = true
        player = p
    }

    /// Motori del Joy-Con (0…255): basso = colpo sordo, alto = ronzio.
    func set(low: UInt8, high: UInt8) {
        let i = Float(max(low, high)) / 255
        guard abs(i - intensity) > 0.03 || (i == 0 && intensity != 0) else { return }
        intensity = i
        guard let p = player else { return }
        if i < 0.04 {
            if playing { try? p.stop(atTime: CHHapticTimeImmediate); playing = false }
            return
        }
        if !playing {
            try? engine?.start()
            try? p.start(atTime: CHHapticTimeImmediate)
            playing = true
        }
        let sharp: Float = high > low ? 0.8 : 0.25
        try? p.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: i, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharp - 0.4, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    /// Piccolo colpo alla pressione di un tasto.
    func click() { tap.impactOccurred(intensity: 0.6) }
}
