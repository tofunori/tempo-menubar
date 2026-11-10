import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    /// Simulateur : remplace les vrais chiffres dans les aperçus, pour voir les couleurs changer.
    @State private var simulate = false
    @State private var simulated = 50.0

    private var modelName: String { store.snapshot?.modelName ?? "Fable" }

    /// Le relevé que montrent les aperçus : le vrai, ou celui du simulateur.
    private var previewSnapshot: UsageSnapshot {
        let now = Date()
        if simulate {
            // Le modèle suit à 60 % de l'hebdo, pour que les deux valeurs bougent ensemble.
            return UsageSnapshot.sample(weekly: simulated, model: simulated * 0.6, elapsed: 0.67, now: now)
        }
        return store.snapshot ?? UsageSnapshot.sample(weekly: 56, model: 10, elapsed: 0.67, now: now)
    }

    var body: some View {
        Form {
            Section(tr("Style de l'icône", "Icon style")) {
                StyleGallery(settings: settings, snapshot: previewSnapshot, samples: simulate ? [] : store.samples)
            }

            colorSection

            Section(tr("Affichage", "Display")) {
                Picker(tr("Donnée", "Value"), selection: $settings.metric) {
                    Text(tr("Hebdo + \(modelName)", "Weekly + \(modelName)")).tag(Metric.both)
                    Text(tr("Hebdo", "Weekly")).tag(Metric.weekly)
                    Text(modelName).tag(Metric.model)
                }
                .pickerStyle(.segmented)
                .disabled(settings.iconStyle.isDual)

                Picker(tr("Texte", "Text"), selection: $settings.barText) {
                    ForEach(BarText.allCases) { Text($0.label).tag($0) }
                }

                Toggle(tr("Repère de rythme sur l'icône", "Pace marker on the icon"), isOn: $settings.showPace)
                Toggle(tr("Afficher le restant plutôt que l'utilisé", "Show what is left instead of what is used"), isOn: $settings.showRemaining)
            }

            Section(tr("Général", "General")) {
                Picker(tr("Langue", "Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }

                Picker(tr("Actualisation", "Refresh"), selection: $settings.refreshMinutes) {
                    Text(tr("Aux 5 minutes", "Every 5 minutes")).tag(5)
                    Text(tr("Aux 15 minutes", "Every 15 minutes")).tag(15)
                    Text(tr("Aux 30 minutes", "Every 30 minutes")).tag(30)
                }

                Toggle(tr("Ouvrir Tempo à la connexion", "Open Tempo at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 760)
    }

    // MARK: - Couleurs

    private var usesScale: Bool { settings.colorMode == .thresholds || settings.colorMode == .gradient }

    @ViewBuilder
    private var colorSection: some View {
        Section(tr("Couleurs", "Colors")) {
            Picker(tr("Couleur de l'hebdo", "Weekly color"), selection: $settings.colorMode) {
                ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(modeHelp).font(.caption).foregroundStyle(.secondary)

            if settings.colorMode != .mono || settings.modelColorMode == .usage {
                LabeledContent(tr("Palette", "Palette")) {
                    HStack(spacing: 14) {
                        swatch(settings.colorMode == .pace ? tr("Dans le rythme", "On pace") : tr("Début", "Start"), \.low)
                        swatch(settings.colorMode == .pace ? tr("Serré", "Tight") : tr("Milieu", "Middle"), \.mid)
                        swatch(settings.colorMode == .pace ? tr("Trop vite", "Too fast") : tr("Fin", "End"), \.high)
                        Menu(tr("Modèles", "Presets")) {
                            ForEach(Palette.presets) { preset in
                                Button(preset.name) { apply(preset) }
                            }
                        }
                        .fixedSize()
                    }
                }

                if usesScale || settings.modelColorMode == .usage {
                    ScaleStrip(palette: settings.palette, gradient: settings.colorMode == .gradient)
                    LabeledContent(tr("Milieu à partir de \(Fmt.pct(settings.palette.warnAt))", "Middle from \(Fmt.pct(settings.palette.warnAt))")) {
                        Slider(value: $settings.palette.warnAt, in: 5...90, step: 5)
                            .onChange(of: settings.palette.warnAt) { _, value in
                                if settings.palette.dangerAt <= value { settings.palette.dangerAt = value + 5 }
                            }
                    }
                    LabeledContent(tr("Fin à partir de \(Fmt.pct(settings.palette.dangerAt))", "End from \(Fmt.pct(settings.palette.dangerAt))")) {
                        Slider(value: $settings.palette.dangerAt, in: 10...100, step: 5)
                            .onChange(of: settings.palette.dangerAt) { _, value in
                                if settings.palette.warnAt >= value { settings.palette.warnAt = value - 5 }
                            }
                    }
                }
            }

            Picker(tr("Couleur de \(modelName)", "\(modelName) color"), selection: $settings.modelColorMode) {
                ForEach(ModelColorMode.allCases) { Text($0.label).tag($0) }
            }
            if settings.modelColorMode == .fixed {
                ColorPicker(tr("Teinte de \(modelName)", "\(modelName) tint"), selection: Binding(
                    get: { Color(nsColor: settings.modelFixed.nsColor) },
                    set: { settings.modelFixed = RGB(nsColor: NSColor($0)) }
                ), supportsOpacity: false)
            }

            Toggle(tr("Simuler un usage dans les aperçus", "Simulate usage in the previews"), isOn: $simulate)
            if simulate {
                LabeledContent(tr("Usage simulé : \(Fmt.pct(simulated))", "Simulated usage: \(Fmt.pct(simulated))")) {
                    Slider(value: $simulated, in: 0...100, step: 1)
                }
            }
        }
    }

    private var modeHelp: String {
        switch settings.colorMode {
        case .mono: return tr("L'icône prend la couleur du texte de la barre de menus.", "The icon uses the menu bar text color.")
        case .thresholds: return tr("La couleur change par paliers à mesure que le quota s'épuise.", "The color changes in steps as the quota drains.")
        case .gradient: return tr("La couleur glisse en continu d'une teinte à l'autre à mesure que le quota s'épuise.", "The color blends continuously from one tint to the next as the quota drains.")
        case .pace: return tr("La couleur suit la prévision : dans le rythme, serré, ou trop vite.", "The color follows the forecast: on pace, tight, or too fast.")
        }
    }

    private func swatch(_ label: String, _ keyPath: WritableKeyPath<Palette, RGB>) -> some View {
        VStack(spacing: 3) {
            ColorPicker(label, selection: Binding(
                get: { Color(nsColor: settings.palette[keyPath: keyPath].nsColor) },
                set: { settings.palette[keyPath: keyPath] = RGB(nsColor: NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func apply(_ preset: Palette.Preset) {
        guard let low = RGB(hex: preset.low), let mid = RGB(hex: preset.mid), let high = RGB(hex: preset.high) else { return }
        var palette = settings.palette
        palette.low = low
        palette.mid = mid
        palette.high = high
        settings.palette = palette
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = tr("Impossible de changer ce réglage : \(error.localizedDescription)", "Couldn't change this setting: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// La couleur obtenue pour chaque pourcentage, de 0 à 100.
private struct ScaleStrip: View {
    let palette: Palette
    let gradient: Bool

    var body: some View {
        VStack(spacing: 2) {
            Canvas { context, size in
                let step = size.width / 100
                for p in 0..<100 {
                    let c = palette.color(forUsage: Double(p) + 0.5, gradient: gradient)
                    let rect = CGRect(x: CGFloat(p) * step, y: 0, width: step + 0.5, height: size.height)
                    context.fill(Path(rect), with: .color(Color(.sRGB, red: c.r, green: c.g, blue: c.b)))
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack {
                Text(Fmt.pct(0))
                Spacer()
                Text("usage")
                Spacer()
                Text(Fmt.pct(100))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .accessibilityLabel(tr("Échelle des couleurs selon l'usage", "Color scale by usage"))
    }
}

/// Galerie des styles : chaque case montre l'icône telle qu'elle sortira avec les réglages courants.
private struct StyleGallery: View {
    @ObservedObject var settings: Settings
    let snapshot: UsageSnapshot
    let samples: [Sample]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 14) {
            ForEach(StyleGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(IconStyle.allCases.filter { $0.group == group }) { style in
                            cell(style, now)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func cell(_ style: IconStyle, _ now: Date) -> some View {
        let selected = settings.iconStyle == style
        var options = settings.options
        options.iconStyle = style
        options.barText = .none
        let preview = MenuBarContent.make(snapshot: snapshot, samples: samples, options: options, now: now, zoom: 1.6)

        return Button {
            settings.iconStyle = style
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let image = preview.image {
                        Image(nsImage: image)
                    } else {
                        Text(Fmt.pct(snapshot.weekly?.percent ?? 0))
                            .font(.system(size: 15, weight: .medium)).monospacedDigit()
                    }
                }
                .frame(height: 36)
                Text(style.label).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(style.label)
    }
}
