import AppKit
import SwiftUI

/// Produit les images du README avec le code de dessin de l'app elle-même :
///   Tempo --readme-assets docs
/// Les données sont fictives et fixes, pour que les images soient reproductibles.
@MainActor
enum ReadmeAssets {
    static func generate(into directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        Lang.setting = .en
        save(hero(), "\(directory)/hero.jpg")
        save(panels(), "\(directory)/panels.jpg")
        save(combos(), "\(directory)/combos.jpg")
        save(styles(), "\(directory)/styles.jpg")
        save(colors(), "\(directory)/colors.jpg")
    }

    // MARK: - Données de démonstration

    /// Un lundi soir, aux deux tiers de la fenêtre hebdomadaire.
    private static let now: Date = {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 11
        parts.day = 9
        parts.hour = 19
        return Calendar(identifier: .gregorian).date(from: parts) ?? Date()
    }()

    private static let elapsed = 0.67

    /// - Parameter chatgpt: vrai pour ajouter les limites de Codex aux données.
    private static func scene(_ weekly: Double, _ model: Double, chatgpt: Bool = true) -> UsageData {
        var data = DebugTools.fakeData(weekly: weekly, model: model, elapsed: elapsed, now: now)
        data.claude?.breakdown = [
            BreakdownRow(name: "Claude Code", percent: 91),
            BreakdownRow(name: "Chats", percent: 1),
            BreakdownRow(name: "Cowork", percent: 8),
        ]
        if !chatgpt { data.chatgpt = nil }
        return data
    }

    // MARK: - Outils

    private static let backdrop = LinearGradient(
        colors: [
            Color(red: 0.09, green: 0.08, blue: 0.19),
            Color(red: 0.17, green: 0.12, blue: 0.34),
            Color(red: 0.05, green: 0.21, blue: 0.29),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    private static func save<V: View>(_ view: V, _ path: String) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        // JPEG : dix fois plus léger que le PNG pour ces fonds en dégradé, sans perte visible.
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        try? jpeg.write(to: URL(fileURLWithPath: path))
        print(path)
    }

    /// Fige l'icône (et son texte) en pixels, comme la barre de menus sombre la montrerait.
    private static func raster(_ content: MenuBarContent, withTitle: Bool = false) -> NSImage {
        let title = NSMutableAttributedString(attributedString: content.title)
        title.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: title.length)) { value, range, _ in
            if value == nil { title.addAttribute(.foregroundColor, value: NSColor.white, range: range) }
        }
        let iconSize = content.image?.size ?? .zero
        let textSize = withTitle && title.length > 0 ? title.size() : .zero
        let gap: CGFloat = iconSize.width > 0 && textSize.width > 0 ? 5 : 0
        let size = NSSize(
            width: ceil(iconSize.width + gap + textSize.width),
            height: ceil(max(iconSize.height, textSize.height, 1))
        )
        let scale: CGFloat = 4
        guard size.width > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: 1, height: 1)) }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            if let image = content.image {
                let rect = NSRect(x: 0, y: (size.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
                image.draw(in: rect)
                if image.isTemplate {
                    NSColor.white.set()
                    rect.fill(using: .sourceAtop)
                }
            }
            if textSize.width > 0 {
                title.draw(at: NSPoint(x: iconSize.width + gap, y: (size.height - textSize.height) / 2))
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: size)
        output.addRepresentation(rep)
        return output
    }

    /// Une icône, telle que la barre la montrerait, pour des réglages donnés.
    private static func item(
        _ data: UsageData, zoom: CGFloat = 1, withTitle: Bool = false,
        configure: (inout DisplayOptions) -> Void = { _ in }
    ) -> NSImage {
        var options = DisplayOptions()
        options.colorMode = .gradient
        configure(&options)
        return raster(MenuBarContent.make(data: data, options: options, now: now, zoom: zoom), withTitle: withTitle)
    }

    private static func panel(_ data: UsageData, view: String, focus: MetricKey = .claudeWeekly) -> some View {
        PanelContent(
            data: data, focus: focus, state: .ok, now: now,
            chartView: .constant(view), onRefresh: {}, onSettings: {}, decorative: true
        )
        .padding(16)
        .frame(width: 348)
        .background(Color(red: 0.13, green: 0.13, blue: 0.15), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
    }

    // MARK: - Images

    /// Bannière : la barre de menus, le panneau ouvert et le titre.
    private static func hero() -> some View {
        let data = scene(56, 10, chatgpt: false)
        let icon = item(data, withTitle: true)

        return ZStack(alignment: .topLeading) {
            backdrop

            Rectangle().fill(Color.black.opacity(0.32)).frame(height: 30)
            HStack(spacing: 18) {
                Text("Finder").fontWeight(.semibold)
                Text("File")
                Text("Edit")
                Text("View")
                Text("Go")
                Text("Window")
                Text("Help")
            }
            .font(.system(size: 13))
            .padding(.leading, 22)
            .frame(height: 30)

            HStack(spacing: 16) {
                Image(nsImage: icon)
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("Mon 9 Nov  7:00 PM")
            }
            .font(.system(size: 13))
            .padding(.trailing, 22)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: 30)

            VStack(alignment: .leading, spacing: 16) {
                Text("Tempo")
                    .font(.system(size: 80, weight: .bold, design: .rounded))
                Text("Claude and ChatGPT usage in your\nmenu bar. And whether you're on pace.")
                    .font(.system(size: 27, weight: .medium))
                    .lineSpacing(4)
                Text("Weekly and 5-hour limits, a forecast of when the quota\nruns out, and 18 icon styles you can recolor.")
                    .font(.system(size: 17))
                    .lineSpacing(3)
                    .opacity(0.7)
            }
            .padding(.leading, 76)
            .padding(.top, 196)

            panel(data, view: "cum")
                .padding(.leading, 802)
                .padding(.top, 44)
        }
        .foregroundStyle(.white)
        .frame(width: 1280, height: 650, alignment: .topLeading)
    }

    /// Trois états du panneau : dans le rythme, les deux services ensemble, et trop vite.
    private static func panels() -> some View {
        HStack(alignment: .top, spacing: 28) {
            panel(scene(56, 10, chatgpt: false), view: "cum")
            panel(scene(56, 10), view: "day")
            panel(scene(81, 34, chatgpt: false), view: "cum")
        }
        .padding(44)
        .background(backdrop)
    }

    /// Des combinaisons de valeurs : chaque icône montre la paire qu'on lui donne.
    private static func combos() -> some View {
        let data = scene(56, 10)
        let examples: [(String, IconStyle, MetricKey, MetricKey?)] = [
            ("Claude weekly + Fable", .dial, .claudeWeekly, .claudeModel),
            ("Claude weekly + ChatGPT weekly", .arcs, .claudeWeekly, .chatgptWeekly),
            ("ChatGPT 5 h + Claude weekly", .parens, .chatgptSession, .claudeWeekly),
            ("ChatGPT weekly + ChatGPT 5 h", .duo, .chatgptWeekly, .chatgptSession),
        ]
        func icon(_ style: IconStyle, _ primary: MetricKey, _ secondary: MetricKey?) -> NSImage {
            item(data, zoom: 1.5, withTitle: true) { options in
                options.iconStyle = style
                options.primary = primary
                options.secondary = secondary
            }
        }
        func strip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
            HStack(spacing: 18) { content() }
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        func caption(_ text: String) -> some View {
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
        }

        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 22) {
                ForEach(examples, id: \.0) { title, style, primary, secondary in
                    VStack(alignment: .leading, spacing: 10) {
                        strip { Image(nsImage: icon(style, primary, secondary)) }
                        caption(title)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                strip {
                    Image(nsImage: icon(.dial, .claudeWeekly, .claudeModel))
                    Image(nsImage: icon(.arcs, .chatgptWeekly, .chatgptSession))
                }
                caption("Or two icons side by side, one per service")
            }
        }
        .padding(44)
        .background(backdrop)
    }

    /// Les dix-huit styles d'icône, par famille.
    private static func styles() -> some View {
        let data = scene(56, 10)
        return VStack(alignment: .leading, spacing: 26) {
            ForEach(StyleGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    HStack(spacing: 12) {
                        ForEach(IconStyle.allCases.filter { $0.group == group && $0 != .none }) { style in
                            VStack(spacing: 10) {
                                Image(nsImage: item(data, zoom: 2.4) { options in
                                    options.iconStyle = style
                                    options.barText = .none
                                })
                                .frame(height: 54)
                                Text(style.label)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .frame(width: 128, height: 100)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
        .padding(44)
        .frame(width: 1196, alignment: .leading)
        .background(backdrop)
    }

    /// La couleur qui change à mesure que le quota s'épuise, pour chaque palette.
    private static func colors() -> some View {
        let steps: [Double] = [5, 25, 45, 65, 85, 100]
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Palette.presets) { preset in
                HStack(spacing: 0) {
                    Text(preset.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 110, alignment: .leading)
                    ForEach(steps, id: \.self) { step in
                        VStack(spacing: 8) {
                            Image(nsImage: item(scene(step, step * 0.6), zoom: 2.6) { options in
                                options.iconStyle = .arcs
                                options.barText = .none
                                options.palette.low = RGB(hex: preset.low) ?? options.palette.low
                                options.palette.mid = RGB(hex: preset.mid) ?? options.palette.mid
                                options.palette.high = RGB(hex: preset.high) ?? options.palette.high
                                options.modelColorMode = .usage
                                options.showPace = false
                            })
                            Text(Fmt.pct(step))
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .frame(width: 132, height: 86)
                    }
                }
                .padding(.horizontal, 20)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(44)
        .background(backdrop)
    }
}
