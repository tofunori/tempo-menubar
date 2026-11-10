import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let store = UsageStore()
    private let alerts = AlertCenter()
    private var alertTimer: Timer?
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

        // Alertes : à chaque nouveau relevé, à chaque changement de réglage, et aux cinq minutes
        // pour les prévisions qui avancent avec l'horloge.
        alerts.onOpen = { [weak self] in self?.status?.showPanel() }
        if settings.alerts.enabled {
            Task { await alerts.requestPermission() }
        }
        store.$snapshot.map { _ in () }
            .merge(with: store.$chatgpt.map { _ in () }, settings.$alerts.map { _ in () })
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in self?.checkAlerts() }
            .store(in: &bag)
        alertTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAlerts() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.store.refresh() }
        }
    }

    private func checkAlerts() {
        alerts.evaluate(data: store.data, settings: settings.alerts)
    }

    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: settings, store: store, alerts: alerts)
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
