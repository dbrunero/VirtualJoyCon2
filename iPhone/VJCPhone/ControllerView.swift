// Interfaccia: un Joy-Con (sinistro o destro) in verticale, oppure la coppia sx + dx in
// orizzontale (come un gamepad o un volante), più la schermata di verifica.

import SwiftUI
import AVKit
import simd

private enum Palette {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let body = Color(red: 0.13, green: 0.13, blue: 0.16)
    static let key = Color(red: 0.20, green: 0.20, blue: 0.24)
    static let label = Color(white: 0.92)
    static let blue = Color(red: 0.04, green: 0.72, blue: 0.90)
    static let red = Color(red: 1.0, green: 0.30, blue: 0.24)
    @MainActor static func accent(_ pad: Pad) -> Color { pad.pair ? Color(red: 0.70, green: 0.40, blue: 1.0) : pad.leftLayout ? blue : red }
}

extension PhoneButton {
    var title: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .r: return "R"
        case .zr: return "ZR"
        case .slR, .slL: return "SL"
        case .srR, .srL: return "SR"
        case .plus: return "+"
        case .home: return "⌂"
        case .rStick: return "R3"
        case .up: return "▲"
        case .down: return "▼"
        case .left: return "◀"
        case .right: return "▶"
        case .l: return "L"
        case .zl: return "ZL"
        case .minus: return "−"
        case .capture: return "◉"
        case .lStick: return "L3"
        }
    }

    /// Tutti i tasti del Joy-Con (o della coppia) in ciascun setup: sono tutti sullo schermo
    /// e tutti nella verifica.
    static func onScreen(_ setup: Setup) -> [PhoneButton] {
        let left: [PhoneButton] = [.zl, .l, .slL, .srL, .up, .left, .right, .down, .minus, .capture, .lStick]
        let right: [PhoneButton] = [.zr, .r, .slR, .srR, .x, .y, .a, .b, .plus, .home, .rStick]
        switch setup {
        case .single_left, .sportsLefty: return left
        case .single_right, .sports: return right
        case .kart: return left.filter { $0 != .slL && $0 != .srL } + right.filter { $0 != .slR && $0 != .srR }
        case .kartGyro: return [.zl, .l, .up, .left, .right, .down, .minus, .capture,
                                .r, .zr, .x, .y, .a, .b, .home, .plus, .rStick]
        }
    }
}

struct ControllerView: View {
    @ObservedObject var pad: Pad
    @ObservedObject var link: MacLink
    @State private var verifying = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if pad.setup == .kartGyro { gyroLayout } else if pad.pair { pairLayout } else { singleLayout }
        }
        .background(Palette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        // Primario = Volume − (e tasto Azione / Controllo fotocamera), secondario = Volume +.
        .onCameraCaptureEvent(isEnabled: pad.volumeReady,
                              primaryAction: { e in pad.volumeKey(.down, down: e.phase == .began) },
                              secondaryAction: { e in pad.volumeKey(.up, down: e.phase == .began) })
        .sheet(isPresented: $verifying) { VerifyView(pad: pad, link: link) }
        .sheet(isPresented: $showSettings) { SettingsView(pad: pad, link: link) }
    }

    private var header: some View {
        VStack(spacing: 6) {
            TopBar(pad: pad, link: link, verify: { verifying = true }, openSettings: { showSettings = true })
            SettingsChips(pad: pad)
        }
    }

    // MARK: Un Joy-Con, in verticale

    /// Le misure vengono dall'altezza disponibile: su ogni iPhone entrano tutti i tasti.
    private var singleLayout: some View {
        VStack(spacing: 8) {
            header
            GeometryReader { geo in
                let h = geo.size.height
                let w = min(geo.size.width, 440)
                let left = pad.leftLayout
                let accent = Palette.accent(pad)
                let unit = min(h / 10.5, w / 4.6)            // un tasto azione è circa 1 unità
                VStack(spacing: 0) {
                    shoulders(left: left, width: w, height: unit * 0.95, accent: accent)
                    Spacer(minLength: 4)
                    HStack {
                        key(left ? .slL : .slR, .capsule, unit * 1.3, unit * 0.5, font: .subheadline.weight(.semibold))
                        Spacer()
                        key(left ? .srL : .srR, .capsule, unit * 1.3, unit * 0.5, font: .subheadline.weight(.semibold))
                    }
                    Spacer(minLength: 4)
                    stickBlock(right: !left, size: unit * 3.0, accent: accent)
                    Spacer(minLength: 4)
                    diamond(left: left, size: unit * 0.95, accent: accent)
                    Spacer(minLength: 4)
                    system(left: left, size: unit * 0.75)
                }
                .frame(width: w)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: Coppia, in orizzontale

    /// Come i due Joy-Con: a sinistra stick sopra le frecce, a destra A B X Y sopra lo stick.
    /// Il movimento va a tutti e due (in Mario Kart si sterza ruotando il telefono come un volante).
    private var pairLayout: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let col = min(geo.size.width * 0.34, h * 1.05)
            let unit = h / 8.0
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    shoulders(left: true, width: col, height: unit * 0.85, accent: Palette.blue)
                    Spacer(minLength: 2)
                    stickBlock(right: false, size: unit * 2.1, accent: Palette.blue)
                    Spacer(minLength: 2)
                    diamond(left: true, size: unit * 1.2, accent: Palette.blue)
                    Spacer(minLength: 2)
                    system(left: true, size: unit * 0.7)
                }
                .frame(width: col)
                VStack(spacing: 8) {
                    header
                    Spacer(minLength: 0)
                    Text("Tienilo come un volante. Sterzo con lo stick sinistro. Controllo fotocamera = derapata (R), Volume + = oggetto (L).")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 0) {
                    shoulders(left: false, width: col, height: unit * 0.85, accent: Palette.red)
                    Spacer(minLength: 2)
                    diamond(left: false, size: unit * 1.2, accent: Palette.red)
                    Spacer(minLength: 2)
                    stickBlock(right: true, size: unit * 2.1, accent: Palette.red)
                    Spacer(minLength: 2)
                    system(left: false, size: unit * 0.7)
                }
                .frame(width: col)
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 10)
    }

    // MARK: Mario Kart · giroscopio, in orizzontale

    /// Si sterza ruotando il telefono. Il pollice destro sta su A (accelera); il pollice sinistro,
    /// libero dallo sterzo, ha i tre pulsanti "da volante di F1" al centro, verso sinistra:
    /// Derapata (il più grande, R tenuto), Oggetto (L) e Lontano (su + L, es. banane in avanti).
    /// Impostazioni e stato sono dietro il pulsante ⓘ.
    private var gyroLayout: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let unit = h / 8.0
            let side = min(geo.size.width * 0.22, h * 0.75)
            let right = min(geo.size.width * 0.30, h * 1.0)
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    shoulders(left: true, width: side, height: unit * 0.8, accent: Palette.blue)
                    Spacer(minLength: 2)
                    diamond(left: true, size: unit * 0.85, accent: Palette.blue)
                    Spacer(minLength: 2)
                    system(left: true, size: unit * 0.65)
                }
                .frame(width: side)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        round("info.circle", action: { showSettings = true })
                        round("scope", action: pad.calibrate)
                        round("checklist", action: { verifying = true })
                        Circle().fill(link.linked && link.status.outputActive ? Color.green : link.linked ? .orange : Color(white: 0.4))
                            .frame(width: 10, height: 10)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    F1Buttons(pad: pad, unit: unit)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 0) {
                    shoulders(left: false, width: right, height: unit * 0.8, accent: Palette.red)
                    Spacer(minLength: 2)
                    diamond(left: false, size: unit * 1.25, accent: Palette.red)
                    Spacer(minLength: 2)
                    stickBlock(right: true, size: unit * 1.9, accent: Palette.red)
                    Spacer(minLength: 2)
                    system(left: false, size: unit * 0.65)
                }
                .frame(width: right)
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 10)
    }

    private func round(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(Palette.key, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    // MARK: Pezzi

    private func key(_ b: PhoneButton, _ shape: KeyShape, _ w: CGFloat, _ h: CGFloat,
                     tint: Color? = nil, font: Font = .title2.weight(.bold)) -> some View {
        Key(pad: pad, button: b, title: b.title, shape: shape, width: w, height: h, tint: tint, font: font)
    }

    /// Dorsali: il grilletto (ZR/ZL) è il più grande, è quello degli swing e dei tiri.
    private func shoulders(left: Bool, width w: CGFloat, height: CGFloat, accent: Color) -> some View {
        HStack(spacing: 10) {
            if left {
                key(.zl, .capsule, w * 0.55, height, tint: accent)
                key(.l, .capsule, w * 0.40, height)
            } else {
                key(.r, .capsule, w * 0.40, height)
                key(.zr, .capsule, w * 0.55, height, tint: accent)
            }
        }
    }

    /// Stick con il suo clic (L3 / R3) accanto.
    private func stickBlock(right: Bool, size: CGFloat, accent: Color) -> some View {
        ZStack(alignment: right ? .bottomTrailing : .bottomLeading) {
            Stick(pad: pad, right: right, size: size, accent: accent)
                .frame(maxWidth: .infinity)
            key(right ? .rStick : .lStick, .circle, size * 0.24, size * 0.24, font: .caption.weight(.bold))
        }
        .frame(height: size)
    }

    /// Frecce (sinistro) o tasti azione (destro), a rombo.
    private func diamond(left: Bool, size d: CGFloat, accent: Color) -> some View {
        let keys: [PhoneButton] = left ? [.up, .left, .right, .down] : [.x, .y, .a, .b]
        return VStack(spacing: d * 0.05) {
            key(keys[0], .circle, d, d)
            HStack(spacing: d * 0.9) {
                key(keys[1], .circle, d, d)
                key(keys[2], .circle, d, d, tint: left ? nil : accent)
            }
            key(keys[3], .circle, d, d)
        }
    }

    private func system(left: Bool, size s: CGFloat) -> some View {
        HStack {
            if left {
                key(.minus, .circle, s, s)
                Spacer()
                key(.capture, .roundedSquare, s, s)
            } else {
                key(.home, .circle, s, s)
                Spacer()
                key(.plus, .circle, s, s)
            }
        }
        .padding(.horizontal, s * 0.4)
    }
}

// MARK: - Barra in alto e impostazioni

/// Stato del collegamento, pulsanti per la verifica e per le impostazioni.
private struct TopBar: View {
    @ObservedObject var pad: Pad
    @ObservedObject var link: MacLink
    let verify: () -> Void
    let openSettings: () -> Void

    var body: some View {
        // Su una riga se c'è posto, altrimenti (in orizzontale) lo stato sopra e i pulsanti sotto.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                status.frame(minWidth: 170, alignment: .leading)
                Spacer(minLength: 4)
                settings
            }
            VStack(alignment: .leading, spacing: 8) {
                status
                settings
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.body, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var status: some View {
        HStack(spacing: 10) {
            Circle().fill(dot).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var settings: some View {
        HStack(spacing: 8) {
            round("scope", action: pad.calibrate)
            round("checklist", action: verify)
            round("slider.horizontal.3", action: openSettings)
        }
    }

    private func round(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(Palette.key, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private var dot: Color {
        if link.linked && link.status.outputActive { return .green }
        return link.linked ? .orange : Color(white: 0.4)
    }

    private var title: String {
        if link.linked { return link.status.player > 0 ? "iPhone \(link.status.player) · \(link.macName ?? "Mac")" : (link.macName ?? "Mac") }
        return link.macName.map { "Collego a \($0)…" } ?? "Cerco VirtualJoyCon2…"
    }

    private var subtitle: String {
        if let e = link.browseError { return e }
        if !pad.motionAvailable { return "Movimento non disponibile su questo dispositivo" }
        guard link.linked else { return "Apri VirtualJoyCon2 sul Mac, stessa rete Wi-Fi" }
        let kind = link.status.joyCon2 ? "Joy-Con 2" : pad.setup == .single_left ? "Joy-Con (L)"
            : pad.setup == .single_right ? "Joy-Con (R)" : "Joy-Con (L) + (R)"
        return link.status.outputActive ? "Il Mac vede: \(kind)" : "Controller virtuale non attivo sul Mac"
    }
}

/// Le impostazioni attive, come etichette sotto la barra (si cambiano dalla finestra Impostazioni).
/// Le etichette dei tasti volume si accendono mentre li premi; quella della tolleranza di X
/// diventa verde o arancione dopo la pressione.
private struct SettingsChips: View {
    @ObservedObject var pad: Pad

    var body: some View {
        FlowLayout(spacing: 6) {
            Group {
                chip(pad.setup.isSports ? "Sports · Joy-Con \(pad.leftLayout ? "L" : "R")" : pad.setup.title, color: Palette.accent(pad), filled: true)
                if pad.setup.isSports {
                    chip(pad.golf ? "Golf" : "Sport")
                    chip("Potenza \(gainText)", color: pad.swingGain > 1 ? .yellow : nil)
                    if pad.sportsBothMove { chip("Muovono tutti e due") }
                    if pad.golf { aimChip }
                }
                if pad.setup == .kartGyro { chip("Sterzo col giroscopio", color: .green) }
                chip(pad.calibration ?? "Non calibrato: ⌖ in alto", color: pad.calibration == nil ? .orange : .green)
                volumeChips
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gainText: String {
        pad.swingGain == 1.5 ? "1,5×" : String(format: "%.0f×", pad.swingGain)
    }

    @ViewBuilder private var aimChip: some View {
        let b = pad.calibrateButton == .x ? "X" : "▲"
        if let a = pad.aim {
            chip(String(format: "%@ %.0f° %@", b, a.degrees, a.applied ? "→ dritta in giù" : "fuori 45–90°"),
                 color: a.applied ? .green : .orange)
        } else {
            chip("\(b): punta in giù 45–90°")
        }
    }

    @ViewBuilder private var volumeChips: some View {
        if pad.volumeKeys {
            switch pad.cameraState {
            case .running:
                volume("Vol +", .up)
                volume(pad.setup.isKart || pad.setup == .sportsLefty ? "Fotocamera / Vol −" : "Vol −", .down)
            case .denied: chip("Tasti volume: consenti la fotocamera", color: .orange)
            case .unavailable: chip("Tasti volume: fotocamera occupata", color: .orange)
            case .off, .starting: chip("Tasti volume: avvio…")
            }
        } else {
            chip("Tasti volume spenti")
        }
    }

    private func volume(_ title: String, _ key: VolumeKey) -> some View {
        let held = pad.volumeHeld[pad.swapVolume ? key.other : key] != nil
        return chip("\(title) → \(pad.button(for: pad.swapVolume ? key.other : key).title)",
                    color: Palette.accent(pad), filled: held)
    }

    private func chip(_ text: String, color: Color? = nil, filled: Bool = false) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(filled ? Palette.background : (color ?? Palette.label))
            .background(filled ? (color ?? Palette.label) : Palette.key, in: Capsule())
    }
}

/// Etichette su più righe: vanno a capo quando non c'è più posto, così si leggono tutte.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (i, p) in rows.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, maxX, y + rowHeight)
    }
}

// MARK: - Pulsanti F1 (Mario Kart · giroscopio)

/// Tre pulsanti per il pollice sinistro, come sul volante di una F1: Derapata (il più grande,
/// il più vicino al pollice), poi Oggetto e Lontano uno sopra l'altro.
private struct F1Buttons: View {
    @ObservedObject var pad: Pad
    let unit: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: unit * 0.35) {
            Key(pad: pad, button: .r, title: "DERAPATA", shape: .circle, width: unit * 2.3, height: unit * 2.3,
                tint: Color(red: 1.0, green: 0.55, blue: 0.1), font: .headline.weight(.heavy))
            VStack(spacing: unit * 0.3) {
                Key(pad: pad, button: .l, title: "OGGETTO", shape: .circle, width: unit * 1.6, height: unit * 1.6,
                    tint: Color(red: 0.2, green: 0.75, blue: 0.35), font: .caption.weight(.heavy))
                FarThrowKey(pad: pad, size: unit * 1.6)
            }
        }
    }
}

/// Lancio lontano: stick su + L finché è premuto (avanti, es. le banane).
private struct FarThrowKey: View {
    @ObservedObject var pad: Pad
    let size: CGFloat
    @GestureState private var pressing = false

    var body: some View {
        ZStack {
            Circle().fill(pressing ? Palette.blue : Palette.blue.opacity(0.35))
            VStack(spacing: 0) {
                Image(systemName: "arrow.up").font(.headline.weight(.heavy))
                Text("LONTANO").font(.caption.weight(.heavy))
            }
            .foregroundStyle(pressing ? Palette.background : Palette.label)
        }
        .frame(width: size, height: size)
        .scaleEffect(pressing ? 0.94 : 1)
        .animation(.easeOut(duration: 0.08), value: pressing)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).updating($pressing) { _, state, _ in state = true })
        .onChange(of: pressing) { _, down in pad.throwFar(down) }
        .onDisappear { if pressing { pad.throwFar(false) } }
    }
}

// MARK: - Impostazioni

/// Tutte le impostazioni in una finestra (un modulo a sezioni). Ogni scelta vale subito;
/// cambiando setup lo schermo può girare (Mario Kart è in orizzontale).
private struct SettingsView: View {
    @ObservedObject var pad: Pad
    @ObservedObject var link: MacLink
    @Environment(\.dismiss) private var dismiss

    /// Dove stanno le dita su un iPhone 17 in ciascun setup, e cosa fanno i tasti.
    private var ergonomics: String {
        switch pad.setup {
        case .kart, .kartGyro:
            return "A volante (parte alta a sinistra) il Controllo fotocamera è sul bordo in alto a destra, sotto l'indice destro: R, la derapata, tenuto (clic fino in fondo). Volume + è sul bordo in basso a sinistra: L, il lancio dell'oggetto. Volume − fa R come la fotocamera. iOS non passa all'app il tasto Azione né il tasto laterale, né la pressione leggera della fotocamera."
        case .sports:
            return "Nella mano destra le dita avvolgono il bordo sinistro: l'indice cade su Volume + = ZR (il grilletto), il medio su Volume − = X (ricalibra). Il Controllo fotocamera resta sotto il palmo: fa X anche lui, serve un clic deciso."
        case .sportsLefty:
            return "Nella mano sinistra le dita avvolgono il bordo destro: l'indice cade sul Controllo fotocamera = ZL (il grilletto, clic fino in fondo). I tasti volume restano sotto il palmo: Volume + = ▲ (ricalibra) con un tocco deciso; Volume − fa ZL come la fotocamera."
        case .single_left, .single_right:
            return "Volume + = grilletto (ZR/ZL), Volume − = X o ▲."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(link.linked ? "Collegato a \(link.macName ?? "Mac")" + (link.status.player > 0 ? " · iPhone \(link.status.player)" : "")
                                     : "Non collegato: apri VirtualJoyCon2 sul Mac, stessa rete Wi-Fi")
                    SettingsChips(pad: pad)
                } header: { Text("Stato") }

                Section {
                    Picker("Setup", selection: $pad.setup) {
                        ForEach(Setup.allCases) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title)
                                Text(s.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: { Text("Setup") }

                if pad.setup.isSports {
                    Section {
                        Picker("Joy-Con in mano", selection: $pad.setup) {
                            Text("L").tag(Setup.sportsLefty)
                            Text("R").tag(Setup.sports)
                        }
                        .pickerStyle(.segmented)
                        Picker("Profilo", selection: $pad.golf) {
                            Text("Sport").tag(false)
                            Text("Golf").tag(true)
                        }
                        .pickerStyle(.segmented)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Potenza swing").font(.subheadline)
                            Picker("Potenza swing", selection: $pad.swingGain) {
                                Text("1×").tag(1.0)
                                Text("1,5×").tag(1.5)
                                Text("2×").tag(2.0)
                                Text("3×").tag(3.0)
                            }
                            .pickerStyle(.segmented)
                        }
                        Toggle("Muovi anche l'altro Joy-Con", isOn: $pad.sportsBothMove)
                    } header: { Text("Switch Sports") } footer: {
                        Text("Golf: movimento ruotato sulla punta; premendo X con la punta in giù tra 45° e 90° il gioco la vede dritta in giù. Potenza: 1× per gli sport veloci, 2–3× per il putter.")
                    }
                }

                if pad.setup.isKart {
                    Section {
                        Text(pad.setup == .kartGyro
                             ? "Sterzo ruotando il telefono come un volante (pieno a 40°): calibra (⌖) tenendolo dritto. Pulsanti al centro per il pollice sinistro: DERAPATA (R, tieni), OGGETTO (L), LONTANO (su + L, es. banane in avanti). Il pollice destro accelera con A. Nel gioco tieni spenta la guida con il movimento."
                             : "Sterzo con lo stick sinistro sullo schermo.")
                        Text("Tasti fisici: Controllo fotocamera (e Volume −) = derapata (R), Volume + = oggetto (L).")
                    } header: { Text(pad.setup.title) }
                }

                Section {
                    Button {
                        pad.calibrate()
                    } label: {
                        Label("Calibra adesso", systemImage: "scope")
                    }
                    if pad.calibration != nil {
                        Button("Azzera calibrazione", role: .destructive) { pad.resetCalibration() }
                    }
                    if let c = pad.calibration { Text(c).foregroundStyle(.secondary) }
                } header: { Text("Calibrazione") } footer: {
                    Text(pad.pair
                         ? "Tieni il telefono come un volante dritto, in piedi davanti a te, e premi Calibra (anche dal pulsante ⌖ in alto): quella diventa la posizione dritta per lo sterzo e per il gioco."
                         : "Tieni il telefono disteso, schermo in su, la parte alta verso lo schermo, e premi Calibra (anche dal pulsante ⌖ in alto): se lo tieni un po' inclinato, il gioco lo vede comunque dritto. Poi ricentra nel gioco. In Golf vale in più la tolleranza di X.")
                }

                Section {
                    Text(ergonomics).font(.callout)
                } header: { Text("Tasti fisici su iPhone 17") }

                Section {
                    Toggle("Tasti volume (usa la fotocamera)", isOn: $pad.volumeKeys)
                    Toggle("Inverti Volume + e −", isOn: $pad.swapVolume)
                    Toggle("Vibrazione ai tasti", isOn: $pad.clicks)
                } header: { Text("Tasti") }

                if link.macs.count > 1 {
                    Section {
                        Picker("Mac", selection: Binding(get: { link.macName ?? "" }, set: { link.choose($0) })) {
                            ForEach(link.macs, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: { Text("Mac") }
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fine") { dismiss() } }
        }
    }
}

// MARK: - Verifica

/// Ogni tasto ha due spie: «iPhone» quando il telefono sente il tocco, «Mac» quando il Mac lo
/// riceve (il Mac rimanda i tasti che ha). Sotto, cosa legge il movimento, negli assi che
/// arrivano al gioco: se girando il telefono le frasi non corrispondono, c'è un asse sbagliato.
private struct VerifyView: View {
    @ObservedObject var pad: Pad
    @ObservedObject var link: MacLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 8)], spacing: 8) {
                        ForEach(PhoneButton.onScreen(pad.setup), id: \.self) { b in
                            cell(b)
                        }
                    }
                    .padding(.vertical, 4)
                    sticks
                } header: {
                    Text("Tasti")
                } footer: {
                    Text(link.linked
                         ? "Premi ogni tasto sullo schermo e i tasti volume: devono accendersi tutte e due le spie. Se si accende solo «iPhone», il tasto non arriva al Mac."
                         : "Il Mac non risponde: la spia «Mac» non può accendersi.")
                }
                Section {
                    if pad.hardwareEvents.isEmpty {
                        Text("Premi i tasti fisici: qui compare cosa manda iOS").foregroundStyle(.secondary)
                    }
                    ForEach(pad.hardwareEvents, id: \.self) { Text($0).font(.caption.monospaced()) }
                } header: {
                    Text("Tasti fisici (ultimi eventi)")
                } footer: {
                    Text("Serve a capire quale tasto arriva come: Controllo fotocamera (leggero e clic), tasto Azione, Volume + e −.")
                }
                Section {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in motionRows }
                } header: {
                    Text("Movimento")
                } footer: {
                    Text(pad.pair
                         ? "Tieni il telefono come un volante, schermo verso di te. Gira a destra: «volante a destra». Inclina la parte alta verso di te: «inclinato verso di te»."
                         : "Tienilo disteso, schermo in su, la parte alta verso lo schermo. Alza la punta: «punta in su». Alza il fianco destro: «fianco destro in su». Ruotalo verso sinistra: «gira a sinistra».")
                }
            }
            .navigationTitle("Verifica")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fine") { dismiss() } }
        }
    }

    private func cell(_ b: PhoneButton) -> some View {
        let phone = pad.held & b.bit != 0
        let mac = link.status.received & b.bit != 0
        return VStack(spacing: 4) {
            Text(b.title).font(.headline)
            HStack(spacing: 4) {
                lamp("iPhone", on: phone, color: .orange)
                lamp("Mac", on: mac, color: .green)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Palette.body, in: RoundedRectangle(cornerRadius: 10))
    }

    private func lamp(_ s: String, on: Bool, color: Color) -> some View {
        Text(s).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 2)
            .foregroundStyle(on ? Color.black : Color.secondary)
            .background(on ? color : Palette.key, in: Capsule())
    }

    private var sticks: some View {
        let l = pad.stickL, r = pad.stickR
        return VStack(alignment: .leading, spacing: 2) {
            if pad.pair || pad.leftLayout { Text(String(format: "Stick sinistro  x %+.2f  y %+.2f", l.x, l.y)).monospacedDigit() }
            if pad.pair || !pad.leftLayout { Text(String(format: "Stick destro  x %+.2f  y %+.2f", r.x, r.y)).monospacedDigit() }
        }
        .font(.callout)
    }

    @ViewBuilder private var motionRows: some View {
        if let m = pad.latestMotion {
            let f = simd_length(m.accel) > 0.3 ? simd_normalize(m.accel) : SIMD3<Float>(0, 1, 0)
            let deg = Float(180 / Double.pi)
            let yaw = m.gyro.y                        // +Y = su: positivo = gira a sinistra
            if pad.pair {
                let wheel = atan2(-f.x, -f.z) * deg   // in piedi davanti a te: 0°, a destra positivo
                let lean = asin(max(-1, min(1, f.y))) * deg
                row("Volante", String(format: "%.0f° %@", abs(wheel), wheel >= 0 ? "a destra" : "a sinistra"))
                row("Inclinazione", String(format: "%.0f° %@", abs(lean), lean >= 0 ? "verso di te" : "in avanti"))
            } else {
                let tip = asin(max(-1, min(1, -f.z))) * deg      // punta = −Z
                let side = asin(max(-1, min(1, f.x))) * deg      // fianco destro = +X
                row("Punta", String(format: "%.0f° %@", abs(tip), tip >= 0 ? "in su" : "in giù"))
                row("Fianco", String(format: "%@ in su %.0f°", side >= 0 ? "destro" : "sinistro", abs(side)))
            }
            row("Rotazione", abs(yaw) > 30 ? (yaw > 0 ? "gira a SINISTRA" : "gira a DESTRA") : "ferma")
            row("Al Mac", link.linked ? "\(link.status.rate) campioni/s" : "non collegato")
        } else {
            Text("Nessun dato di movimento").foregroundStyle(.secondary)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary).monospacedDigit() }
    }
}

// MARK: - Tasto

private enum KeyShape { case circle, capsule, roundedSquare }

private struct Key: View {
    @ObservedObject var pad: Pad
    let button: PhoneButton
    let title: String
    let shape: KeyShape
    let width: CGFloat
    let height: CGFloat
    var tint: Color? = nil
    var font: Font = .title2.weight(.bold)

    @GestureState private var pressing = false

    var body: some View {
        let fill = pressing ? (tint ?? Palette.label).opacity(0.85) : (tint?.opacity(0.35) ?? Palette.key)
        ZStack {
            switch shape {
            case .circle: Circle().fill(fill)
            case .capsule: Capsule().fill(fill)
            case .roundedSquare: RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill)
            }
            Text(title)
                .font(font)
                .foregroundStyle(pressing ? Palette.background : Palette.label)
        }
        .frame(width: width, height: height)
        .scaleEffect(pressing ? 0.94 : 1)
        .animation(.easeOut(duration: 0.08), value: pressing)
        .contentShape(Rectangle())
        // Ogni tasto ha il suo tocco: si possono premere più tasti insieme (es. A + ZR).
        .gesture(DragGesture(minimumDistance: 0).updating($pressing) { _, state, _ in state = true })
        .onChange(of: pressing) { _, down in pad.set(button, down) }
        .onDisappear { if pressing { pad.set(button, false) } }
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Stick

private struct Stick: View {
    @ObservedObject var pad: Pad
    let right: Bool
    let size: CGFloat
    let accent: Color

    /// Spostamento del dito dal centro; nil = rilasciato (anche se il tocco viene annullato).
    @GestureState private var drag: CGSize? = nil

    var body: some View {
        let radius = size / 2
        let knob = size * 0.42
        let v = vector(radius: radius)
        ZStack {
            Circle().fill(Palette.body)
            Circle().stroke(Palette.key, lineWidth: 2).padding(6)
            Circle()
                .fill(drag == nil ? Palette.key : accent.opacity(0.8))
                .frame(width: knob, height: knob)
                .offset(x: CGFloat(v.x) * (radius - knob / 2), y: CGFloat(-v.y) * (radius - knob / 2))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).updating($drag) { value, state, _ in
            state = CGSize(width: value.location.x - radius, height: value.location.y - radius)
        })
        .onChange(of: drag) { _, _ in pad.setStick(vector(radius: radius), right: right) }
    }

    /// −1…1, su positivo, con una piccola zona morta.
    private func vector(radius: CGFloat) -> SIMD2<Float> {
        guard let d = drag else { return .zero }
        let reach = Float(radius * 0.75)
        var v = SIMD2(Float(d.width), Float(-d.height)) / reach
        let len = simd_length(v)
        if len < 0.08 { return .zero }
        if len > 1 { v /= len }
        return v
    }
}
