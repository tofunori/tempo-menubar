import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    /// L'icône qu'on est en train de régler.
    @State private var selected = 0
    /// Simulateur : remplace les vrais chiffres dans les aperçus, pour voir les couleurs changer.
    @State private var simulate = false
    @State private var simulated = 50.0

    private var modelName: String { store.data.modelName }

    /// Les données que montrent les aperçus : les vraies, ou celles du simulateur.
    private var previewData: UsageData {
        let now = Date()
        if simulate {
            // Les autres valeurs suivent à des fractions de la première, pour que tout bouge ensemble.
            return UsageData(
                claude: .sample(weekly: simulated, model: simulated * 0.6, elapsed: 0.67, now: now),
                chatgpt: .sampleChatGPT(session: simulated * 0.8, weekly: simulated * 0.5, elapsed: 0.67, now: now)
            )
        }
        // Sans relevé réel, un exemple tient lieu d'aperçu.
        var data = store.data
        if data.claude == nil { data.claude = .sample(weekly: 56, model: 10, elapsed: 0.67, now: now) }
        if data.chatgpt == nil { data.chatgpt = .sampleChatGPT(session: 35, weekly: 22, elapsed: 0.67, now: now) }
        return data
    }

    var body: some View {
        Form {
            iconSection
            colorSection

            Section(tr("Affichage", "Display")) {
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
        .frame(width: 540, height: 780)
    }

    // MARK: - Icônes

    @ViewBuilder
    private var iconSection: some View {
        Section(tr("Icônes de la barre de menus", "Menu bar icons")) {
            Picker(tr("Icône à régler", "Icon to set up"), selection: $selected) {
                ForEach(settings.items.indices, id: \.self) { index in
                    Text(tr("Icône \(index + 1)", "Icon \(index + 1)")).tag(index)
                }
            }
            .pickerStyle(.segmented)

            if selected > 0 {
                Toggle(tr("Afficher cette icône", "Show this icon"), isOn: $settings.items[selected].enabled)
            }

            Picker(tr("Première valeur", "First value"), selection: $settings.items[selected].primary) {
                ForEach(MetricKey.allCases) { key in
                    Text(key.label(modelName: modelName)).tag(key)
                }
            }

            Picker(tr("Deuxième valeur", "Second value"), selection: $settings.items[selected].secondary) {
                Text(tr("Aucune", "None")).tag(MetricKey?.none)
                ForEach(MetricKey.allCases) { key in
                    Text(key.label(modelName: modelName)).tag(MetricKey?.some(key))
                }
            }

            if let note = availabilityNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            Picker(tr("Texte", "Text"), selection: $settings.items[selected].barText) {
                ForEach(BarText.allCases) { Text($0.label).tag($0) }
            }

            LabeledContent(tr("Grosseur : \(Fmt.pct(settings.items[selected].scale * 100))", "Size: \(Fmt.pct(settings.items[selected].scale * 100))")) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
                    Slider(value: $settings.items[selected].scale, in: ItemConfig.scaleRange, step: 0.05)
                    Image(systemName: "circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(tr("Normale", "Reset")) { settings.items[selected].scale = 1 }
                        .controlSize(.small)
                        .disabled(settings.items[selected].scale == 1)
                }
            }

            StyleGallery(settings: settings, index: selected, data: previewData)
        }
    }

    /// Dit pourquoi une valeur choisie n'a pas de chiffre, s'il y a lieu.
    private var availabilityNote: String? {
        let item = settings.items[selected]
        let keys = [item.primary] + (item.secondary.map { [$0] } ?? [])
        let missing = keys.filter { store.data.limit($0) == nil }
        guard let key = missing.first else {
            if !settings.items[selected].iconStyle.isDual, settings.items[selected].iconStyle.group == .single, item.secondary != nil {
                return tr(
                    "Ce style ne dessine que la première valeur. La deuxième apparaît dans le texte.",
                    "This style draws only the first value. The second one appears in the text."
                )
            }
            return nil
        }
        switch key {
        case .chatgptSession, .chatgptWeekly:
            return tr(
                "Aucun chiffre ChatGPT : Tempo les lit dans les sessions de Codex sur ce Mac, et n'en trouve pas.",
                "No ChatGPT figures: Tempo reads them from Codex sessions on this Mac and finds none."
            )
        case .claudeSession:
            return tr(
                "Ton forfait Claude n'expose pas de fenêtre de 5 heures en ce moment.",
                "Your Claude plan exposes no 5-hour window right now."
            )
        default:
            return tr("Pas encore de chiffre pour cette valeur.", "No figure for this value yet.")
        }
    }

    // MARK: - Couleurs

    private var usesScale: Bool { settings.colorMode == .thresholds || settings.colorMode == .gradient }

    @ViewBuilder
    private var colorSection: some View {
        Section(tr("Couleurs", "Colors")) {
            Picker(tr("Première valeur", "First value"), selection: $settings.colorMode) {
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

            Picker(tr("Deuxième valeur", "Second value"), selection: $settings.modelColorMode) {
                ForEach(ModelColorMode.allCases) { Text($0.label).tag($0) }
            }
            if settings.modelColorMode == .fixed {
                ColorPicker(tr("Teinte de la deuxième valeur", "Second value tint"), selection: Binding(
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
    let index: Int
    let data: UsageData

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
        let selected = settings.items[index].iconStyle == style
        var options = settings.options(for: index)
        options.iconStyle = style
        options.barText = .none
        let preview = MenuBarContent.make(data: data, options: options, now: now, zoom: 1.6)

        return Button {
            settings.items[index].iconStyle = style
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let image = preview.image {
                        Image(nsImage: image)
                    } else {
                        Text(Fmt.pct(data.limit(options.primary)?.percent ?? 0))
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
