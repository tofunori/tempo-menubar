import AppKit
import SwiftUI

/// Outils de vérification en ligne de commande, sans ouvrir l'app :
///   Tempo --dump                  lit l'usage des deux services, affiche limites, cadence et texte de la barre
///   Tempo --dump local            même chose sans appeler le service de Claude (cache et fichiers locaux)
///   Tempo --icons out.png [1.3]   dessine une planche de tous les styles d'icône, à la grosseur donnée
///   Tempo --panel out.png [over]  dessine le panneau (vues Cumul et Par jour) avec des données fictives
enum DebugTools {
    static func dump(localOnly: Bool) async {
        let now = Date()
        var data = UsageData(claude: UsageCache.load(), chatgpt: CodexUsage.loadLocal(now: now), samples: HistoryStore().samples)

        if !localOnly {
            do {
                data.claude = try await UsageClient().fetch()
            } catch {
                print("Claude : \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                print("  (repli sur le dernier relevé en cache)")
            }
        }
        print("Relevés en historique : \(data.samples.count)")

        for provider in Provider.allCases {
            guard let snapshot = data.snapshot(provider) else {
                print("\n\(provider.label) : aucune donnée")
                continue
            }
            print("\n=== \(provider.label), relevé \(Fmt.ago(snapshot.fetchedAt, now: now))")
            for insight in data.insights(provider, now: now) {
                let limit = insight.limit
                print("\(limit.label) : \(Fmt.pct(limit.percent))")
                if let start = insight.start { print("  début fenêtre   \(Fmt.dayTime(start))") }
                if let reset = limit.resetsAt {
                    print("  réinit.         \(Fmt.dayTime(reset)) (dans \(Fmt.duration(reset.timeIntervalSince(now))))")
                } else {
                    print("  réinit.         aucune fenêtre en cours")
                }
                if let f = insight.forecast {
                    print("  écoulé          \(Fmt.pct(f.elapsedFraction * 100))")
                    print("  écart au rythme \(Int(f.paceDelta.rounded())) pts")
                    print("  fin projetée    \(f.projectedEnd.map(Fmt.pct) ?? "trop tôt")")
                    print("  épuisement      \(f.exhaustionDate.map(Fmt.dayTime) ?? "aucun avant la réinit.")")
                }
                let days = Pace.dailyUsage(for: insight, samples: data.samples, now: now)
                if days.count > 1 {
                    let text = days.map { "\(Fmt.weekday($0.start)) \(Int($0.used.rounded()))+\(Int($0.possible.rounded()))" }
                    print("  par jour        \(text.joined(separator: "  "))")
                }
            }
        }

        print("\n=== Texte de la barre pour quelques combinaisons")
        let combos: [(MetricKey, MetricKey?)] = [
            (.claudeWeekly, .claudeModel), (.claudeWeekly, .chatgptWeekly),
            (.chatgptSession, .claudeWeekly), (.chatgptWeekly, .chatgptSession),
        ]
        for (primary, secondary) in combos {
            var options = DisplayOptions()
            options.iconStyle = .arcs
            options.primary = primary
            options.secondary = secondary
            let content = MenuBarContent.make(data: data, options: options, now: now)
            let names = [primary.label(modelName: data.modelName), secondary?.label(modelName: data.modelName)]
                .compactMap { $0 }.joined(separator: " + ")
            print("\(names) : \"\(content.title.string)\"")
        }
    }

    /// Relevés fictifs qui montent par paliers, comme de vraies journées de travail.
    static func fakeSamples(weekly: Double, model: Double, elapsed: Double, now: Date, chatgptWeekly: Double? = nil) -> [Sample] {
        let weights = [1.3, 0.7, 1.6, 0.5, 1.1, 0.9, 1.2]
        func cumulative(_ x: Double) -> Double {
            let x = min(max(x, 0), 7)
            let day = min(6, Int(x))
            let partial = x - Double(day)
            return weights[..<day].reduce(0, +) + weights[day] * (1 - cos(.pi * partial)) / 2
        }
        let days = 7 * elapsed
        let start = now.addingTimeInterval(-days * 86400)
        return (1..<60).map { i in
            let u = Double(i) / 60
            let share = cumulative(u * days) / cumulative(days)
            return Sample(
                t: start.addingTimeInterval(u * days * 86400),
                w: weekly * share, m: model * share, gw: chatgptWeekly.map { $0 * share }
            )
        }
    }

    /// Données fictives des deux services.
    static func fakeData(weekly: Double, model: Double, elapsed: Double, now: Date) -> UsageData {
        UsageData(
            claude: .sample(weekly: weekly, model: model, elapsed: elapsed, now: now),
            chatgpt: .sampleChatGPT(session: weekly * 0.8, weekly: weekly * 0.5, elapsed: elapsed, now: now),
            samples: fakeSamples(weekly: weekly, model: model, elapsed: elapsed, now: now, chatgptWeekly: weekly * 0.5)
        )
    }

    /// - Parameter iconScale: la grosseur des réglages à essayer (1 = normale).
    static func iconSheet(to path: String, iconScale: Double = 1) {
        let styles = IconStyle.allCases.filter { $0 != .none }
        let cases: [(weekly: Double, model: Double, elapsed: Double)] = [(8, 3, 0.15), (56, 10, 0.67), (92, 60, 0.80)]
        // Monochrome, puis dégradé avec deuxième valeur en couleur fixe, puis selon son usage.
        let variants: [(mode: ColorMode, model: ModelColorMode)] = [(.mono, .none), (.gradient, .fixed), (.gradient, .usage)]

        let cell = NSSize(width: 124, height: 32)
        let columns = cases.count * variants.count
        let half = NSSize(width: 92 + cell.width * CGFloat(columns), height: cell.height * CGFloat(styles.count))
        let total = NSSize(width: half.width, height: half.height * 2)
        let scale: CGFloat = 3

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(total.width * scale), pixelsHigh: Int(total.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = total

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let now = Date()
        for (index, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let originY = index == 0 ? half.height : 0
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                (index == 0 ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
                NSRect(x: 0, y: originY, width: half.width, height: half.height).fill()

                for (row, style) in styles.enumerated() {
                    let y = originY + half.height - CGFloat(row + 1) * cell.height
                    let label = NSAttributedString(string: style.label, attributes: [
                        .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor,
                    ])
                    label.draw(at: NSPoint(x: 6, y: y + (cell.height - label.size().height) / 2))

                    var column = 0
                    for sample in cases {
                        for variant in variants {
                            let data = fakeData(weekly: sample.weekly, model: sample.model, elapsed: sample.elapsed, now: now)
                            var options = DisplayOptions()
                            options.iconStyle = style
                            options.colorMode = variant.mode
                            options.modelColorMode = variant.model
                            options.scale = iconScale
                            let content = MenuBarContent.make(data: data, options: options, now: now)
                            draw(content, at: NSPoint(x: 92 + CGFloat(column) * cell.width, y: y), cellHeight: cell.height)
                            column += 1
                        }
                    }
                }
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print(path)
        }
    }

    private static func draw(_ content: MenuBarContent, at origin: NSPoint, cellHeight: CGFloat) {
        var x = origin.x
        if let image = content.image {
            let rect = NSRect(
                x: x, y: origin.y + (cellHeight - image.size.height) / 2,
                width: image.size.width, height: image.size.height
            )
            if image.isTemplate {
                // macOS colore les images monochromes selon la barre ; on l'imite ici.
                let tinted = NSImage(size: image.size, flipped: false) { r in
                    image.draw(in: r)
                    NSColor.labelColor.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect)
            } else {
                image.draw(in: rect)
            }
            x += image.size.width + 5
        }
        let text = NSMutableAttributedString(attributedString: content.title)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        }
        text.draw(at: NSPoint(x: x, y: origin.y + (cellHeight - text.size().height) / 2))
    }

    /// Dessine le panneau hors écran, dans les deux vues du graphique.
    /// - Parameter live: vrai pour utiliser le cache de Claude et les fichiers de Codex plutôt que des données fictives.
    @MainActor
    static func panel(to path: String, over: Bool, live: Bool, focus: MetricKey) {
        let now = Date()
        var data: UsageData
        if live {
            data = UsageData(claude: UsageCache.load(), chatgpt: CodexUsage.loadLocal(now: now), samples: HistoryStore().samples)
        } else {
            data = fakeData(weekly: over ? 81 : 56, model: over ? 34 : 10, elapsed: 0.67, now: now)
            data.claude?.breakdown = [
                BreakdownRow(name: "Claude Code", percent: 91),
                BreakdownRow(name: "Chats", percent: 1),
                BreakdownRow(name: "Cowork", percent: 8),
            ]
        }

        for (view, suffix) in [("cum", ""), ("day", "-jour")] {
            let content = PanelContent(
                data: data, focus: focus, state: .ok, now: now,
                chartView: .constant(view), onRefresh: {}, onSettings: {}, decorative: true
            )
            .padding(16)
            .frame(width: 348)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard
                let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:])
            else { continue }
            let target = path.replacingOccurrences(of: ".png", with: "\(suffix).png")
            try? png.write(to: URL(fileURLWithPath: target))
            print(target)
        }
    }
}
