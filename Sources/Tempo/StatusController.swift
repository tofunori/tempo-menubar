import AppKit
import Combine
import SwiftUI

/// L'élément de la barre de menus et son panneau.
@MainActor
final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: UsageStore
    private let settings: Settings
    private var bag = Set<AnyCancellable>()
    private var minuteTimer: Timer?
    private var openSettings: () -> Void = {}

    init(store: UsageStore, settings: Settings, openSettings: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        super.init()

        self.openSettings = openSettings
        popover.behavior = .transient
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }

        // objectWillChange part avant le changement : on redessine au tour de boucle suivant.
        store.objectWillChange
            .merge(with: settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &bag)

        // Le repère de rythme et la prévision avancent avec l'horloge, même sans nouveau relevé.
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }

        render()
    }

    func render() {
        guard let button = item.button else { return }
        let content = MenuBarContent.make(
            snapshot: store.snapshot, samples: store.samples,
            options: settings.options, now: Date()
        )
        button.image = content.image
        button.imagePosition = content.title.length == 0 ? .imageOnly : .imageLeading
        let title = NSMutableAttributedString()
        if content.image != nil, content.title.length > 0 {
            title.append(NSAttributedString(string: " ", attributes: [.font: MenuBarContent.font]))
        }
        title.append(content.title)
        button.attributedTitle = title
        button.toolTip = content.tooltip
        button.appearsDisabled = store.snapshot != nil && store.isStale
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Le panneau SwiftUI n'existe que pendant qu'il est ouvert : l'app reste légère au repos.
            let host = NSHostingController(rootView: PopoverView(
                store: store, settings: settings,
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openSettings()
                }
            ))
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            host.view.window?.makeKey()
        }
    }
}

extension StatusController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
