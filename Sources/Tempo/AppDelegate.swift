import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let store = UsageStore()
    private var status: StatusController?
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusController(store: store, settings: settings) { [weak self] in
            self?.showSettings()
        }

        // Émet tout de suite la valeur courante, puis à chaque changement du réglage.
        settings.$refreshMinutes
            .removeDuplicates()
            .sink { [weak self] minutes in self?.store.start(every: TimeInterval(minutes * 60)) }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.store.refresh() }
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: settings, store: store)
            ))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = tr("Réglages de Tempo", "Tempo Settings")
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
