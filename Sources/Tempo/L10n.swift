import Foundation

/// Langue de l'interface : celle du système, ou un choix forcé dans les réglages.
enum AppLanguage: String, CaseIterable, Identifiable {
    case auto, fr, en
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return tr("Automatique", "Automatic")
        case .fr: return "Français"
        case .en: return "English"
        }
    }
}

enum Lang {
    /// Mis à jour par les réglages au démarrage et à chaque changement.
    static var setting: AppLanguage = .auto

    static var isFrench: Bool {
        switch setting {
        case .fr: return true
        case .en: return false
        case .auto: return Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
        }
    }
}

/// Les deux versions d'un texte restent côte à côte dans le code : une seule ligne à relire.
func tr(_ french: String, _ english: String) -> String {
    Lang.isFrench ? french : english
}
