import AppKit
import Combine
import SwiftUI

/// Les icônes de la barre de menus et leur panneau commun.
@MainActor
final class StatusController: NSObject {
    /// Une entrée par icône configurée ; nil quand l'icône est masquée.
    private var items: [NSStatusItem?] = []
    private let popover = NSPopover()
    private let store: UsageStore
    private let settings: Settings
    private var bag = Set<AnyCancellable>()
    private var minuteTimer: Timer?
    private var openSettings: () -> Void = {}
    private var diagnostics: [Int: String] = [:]

    init(store: UsageStore, settings: Settings, openSettings: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        super.init()

        self.openSettings = openSettings
        popover.behavior = .transient
        popover.delegate = self

        // objectWillChange part avant le changement : on redessine au tour de boucle suivant.
        store.objectWillChange
            .merge(with: settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &bag)

        // Le repère de rythme et la prévision avancent avec l'horloge, même sans nouveau relevé.
        // On en profite pour relire les fichiers de Codex, ce qui ne coûte aucun appel réseau.
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.store.refreshLocal()
                self?.render()
            }
        }

        render()
    }

    func render() {
        let configs = settings.items
        while items.count < configs.count { items.append(nil) }
        let data = store.data
        let now = Date()

        for (index, config) in configs.enumerated() {
            // La première icône reste toujours là : c'est la porte d'entrée de l'app.
            guard config.enabled || index == 0 else {
                if let item = items[index] {
                    NSStatusBar.system.removeStatusItem(item)
                    items[index] = nil
                }
                continue
            }

            let item = items[index] ?? makeItem(index)
            items[index] = item
            guard let button = item.button else { continue }

            let options = settings.options(for: index)
            // La place réelle dans la barre : sur un Mac à encoche, le bouton est plus haut que l'épaisseur annoncée.
            let room = max(button.bounds.height, NSStatusBar.system.thickness)
            let content = MenuBarContent.make(data: data, options: options, now: now, maxHeight: room)
            // Trace de ce qui est réellement affiché, lisible avec `defaults read app.tempo.menubar diagnostics`.
            diagnostics[index] = "icône \(index + 1) : \(options.iconStyle.rawValue) à \(Int(options.scale * 100)) %, "
                + "image \(content.image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "aucune"), "
                + "bouton \(Int(button.bounds.width))x\(Int(button.bounds.height)), barre \(Int(NSStatusBar.system.thickness))"
            button.image = content.image
            button.imagePosition = content.title.length == 0 ? .imageOnly : .imageLeading
            let title = NSMutableAttributedString()
            if content.image != nil, content.title.length > 0 {
                title.append(NSAttributedString(string: " ", attributes: [.font: MenuBarContent.font(CGFloat(options.scale))]))
            }
            title.append(content.title)
            button.attributedTitle = title
            button.toolTip = content.tooltip

            // On grise l'icône quand le service de sa valeur principale n'a plus de relevé récent.
            let provider = config.primary.provider
            button.appearsDisabled = provider == .claude && store.snapshot != nil && store.isStale
        }

        let report = diagnostics.keys.sorted().compactMap { diagnostics[$0] }.joined(separator: " | ")
        if report != UserDefaults.standard.string(forKey: "diagnostics") {
            UserDefaults.standard.set(report, forKey: "diagnostics")
        }
    }

    private func makeItem(_ index: Int) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "tempo.item.\(index)"
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
        }
        return item
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Le panneau met en avant la valeur principale de l'icône sur laquelle on a cliqué.
        let index = items.firstIndex { $0?.button === sender } ?? 0
        let focus = settings.items[index].primary

        // Le panneau SwiftUI n'existe que pendant qu'il est ouvert : l'app reste légère au repos.
        let host = NSHostingController(rootView: PopoverView(
            store: store, settings: settings, focus: focus,
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openSettings()
            }
        ))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        host.view.window?.makeKey()
        Task { await store.refreshLocal() }
    }
}

extension StatusController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
