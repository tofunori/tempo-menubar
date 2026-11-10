import AppKit
import UserNotifications

/// Ce qui déclenche une alerte, et pour quelles valeurs.
struct AlertSettings: Equatable {
    var enabled = true
    /// Alerte quand l'usage franchit un seuil. 100 % (quota épuisé) s'ajoute toujours aux deux seuils.
    var thresholdsOn = true
    var firstThreshold = 80.0
    var secondThreshold = 95.0
    /// Alerte quand, au rythme moyen, le quota s'épuise avant la réinitialisation.
    var runOut = true
    var watched: Set<MetricKey> = [.claudeWeekly, .claudeModel, .chatgptWeekly]

    static let thresholdChoices: [Double] = [50, 60, 70, 75, 80, 85, 90, 95]
}

/// Une alerte prête à partir.
struct PendingAlert: Equatable {
    /// Identifiants à marquer comme envoyés : l'alerte elle-même et les seuils plus bas qu'elle couvre.
    let ids: [String]
    let title: String
    let body: String
}

/// Les règles, sans effet de bord : elles disent quoi envoyer, sans rien envoyer.
enum AlertRules {
    /// Avant cette part de fenêtre écoulée, une prévision d'épuisement est trop fragile pour déranger.
    static let minimumElapsedForRunOut = 0.1

    /// Identifie une fenêtre de quota. Le service décale parfois l'heure de réinitialisation de
    /// quelques millisecondes d'un relevé à l'autre : on l'arrondit aux dix minutes.
    static func windowID(_ key: MetricKey, reset: Date) -> String {
        "\(key.rawValue)|\(Int((reset.timeIntervalSince1970 / 600).rounded()))"
    }

    static func due(data: UsageData, settings: AlertSettings, sent: Set<String>, now: Date) -> [PendingAlert] {
        guard settings.enabled else { return [] }
        var alerts: [PendingAlert] = []

        for key in MetricKey.allCases where settings.watched.contains(key) {
            guard
                let insight = data.insight(key, now: now),
                let reset = insight.limit.resetsAt, reset > now
            else { continue }
            let window = windowID(key, reset: reset)
            let name = key.label(modelName: data.modelName)
            let percent = insight.limit.percent

            if settings.thresholdsOn {
                let levels = Set([settings.firstThreshold, settings.secondThreshold, 100]).filter { $0 > 0 }.sorted()
                let crossed = levels.filter { percent >= $0 }
                // Une seule alerte, pour le seuil le plus haut franchi ; elle couvre les seuils plus bas.
                if let top = crossed.last, !sent.contains("\(window)|t\(Int(top))") {
                    alerts.append(threshold(name, top: top, percent: percent, reset: reset, now: now,
                                            ids: crossed.map { "\(window)|t\(Int($0))" }))
                }
            }

            if settings.runOut, percent < 100,
               let forecast = insight.forecast, let date = forecast.exhaustionDate,
               forecast.elapsedFraction >= minimumElapsedForRunOut,
               !sent.contains("\(window)|runout") {
                let early = Fmt.duration(reset.timeIntervalSince(date))
                let budget = Fmt.points(forecast.dailyBudget)
                alerts.append(PendingAlert(
                    ids: ["\(window)|runout"],
                    title: tr("\(name) : trop vite", "\(name): too fast"),
                    body: tr(
                        "À ce rythme, quota épuisé \(Fmt.dayTime(date)), \(early) avant la réinitialisation. "
                            + (insight.limit.isWeekly ? "Limite-toi à \(budget) par jour pour tenir." : ""),
                        "At this rate, empty \(Fmt.dayTime(date)), \(early) before the reset. "
                            + (insight.limit.isWeekly ? "Keep to \(budget) a day to make it." : "")
                    ).trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        return alerts
    }

    private static func threshold(
        _ name: String, top: Double, percent: Double, reset: Date, now: Date, ids: [String]
    ) -> PendingAlert {
        if top >= 100 {
            return PendingAlert(
                ids: ids,
                title: tr("\(name) : quota épuisé", "\(name): quota used up"),
                body: tr("Retour \(Fmt.dayTime(reset)).", "Back \(Fmt.dayTime(reset)).")
            )
        }
        let left = Fmt.points(100 - percent)
        let wait = Fmt.duration(reset.timeIntervalSince(now))
        return PendingAlert(
            ids: ids,
            title: tr("\(name) : \(Fmt.pct(percent))", "\(name): \(Fmt.pct(percent))"),
            body: tr(
                "Il reste \(left) jusqu'à la réinitialisation, dans \(wait).",
                "\(left) left until the reset, in \(wait)."
            )
        )
    }
}

/// Envoie les alertes par le centre de notifications de macOS et retient ce qui est déjà parti.
@MainActor
final class AlertCenter: NSObject, ObservableObject {
    enum Permission { case unknown, allowed, denied }

    @Published private(set) var permission: Permission = .unknown
    /// Appelé quand on clique une notification : ouvre le panneau.
    var onOpen: () -> Void = {}

    private let defaults = UserDefaults.standard
    private let sentKey = "alertsSent"
    /// Le centre de notifications plante sans identifiant d'app : on s'en passe hors de Tempo.app.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
        Task { await refreshPermission() }
    }

    func refreshPermission() async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional: permission = .allowed
        case .denied: permission = .denied
        default: permission = .unknown
        }
    }

    /// Demande la permission la première fois ; macOS ne redemande pas ensuite.
    func requestPermission() async {
        guard let center else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshPermission()
    }

    func evaluate(data: UsageData, settings: AlertSettings, now: Date = Date()) {
        guard settings.enabled else { return }
        var sent = loadSent(now: now)
        let alerts = AlertRules.due(data: data, settings: settings, sent: Set(sent.keys), now: now)
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            post(alert)
            for id in alert.ids { sent[id] = now.timeIntervalSince1970 }
        }
        defaults.set(sent, forKey: sentKey)
    }

    func sendTest() async {
        if permission != .allowed { await requestPermission() }
        post(PendingAlert(
            ids: [],
            title: tr("Tempo : alerte d'essai", "Tempo: test alert"),
            body: tr("Les alertes de Tempo s'afficheront comme celle-ci.", "Tempo's alerts will look like this one.")
        ))
    }

    private func post(_ alert: PendingAlert) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: alert.ids.last ?? UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// Les alertes déjà envoyées, sans celles de plus de neuf jours.
    private func loadSent(now: Date) -> [String: Double] {
        let all = defaults.dictionary(forKey: sentKey) as? [String: Double] ?? [:]
        let cutoff = now.timeIntervalSince1970 - 9 * 86400
        return all.filter { $0.value >= cutoff }
    }
}

extension AlertCenter: UNUserNotificationCenterDelegate {
    /// Affiche la bannière même quand Tempo est au premier plan (son panneau ouvert, par exemple).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { self.onOpen() }
    }
}
