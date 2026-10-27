import Foundation

/// UserDefaults keys shared by the model (reads) and SwiftUI `@AppStorage` (reads and writes).
enum Prefs {
    enum Key {
        static let defaultHour = "defaultHour"
        static let defaultMinute = "defaultMinute"
        static let showNextInMenuBar = "showNextInMenuBar"
        static let autoOpenOnFire = "autoOpenOnFire"
        static let voiceLocale = "voiceLocale"
        static let voiceAutoAdd = "voiceAutoAdd"
        static let voiceAutoAI = "voiceAutoAI"
        static let voiceAllowServer = "voiceAllowServer"
        static let aiEnabled = "aiEnabled"
        static let aiKeyPresent = "aiKeyPresent"
        static let aiTypedAuto = "aiTypedAuto"
        static let aiDailyBudget = "aiDailyBudget"
        static let aiMonthlyBudget = "aiMonthlyBudget"
        static let pollMinutes = "pollMinutes"
        static let debugCapture = "debugCapture"
        static let appleInviteDismissed = "appleInviteDismissed"
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            Key.defaultHour: 9,
            Key.defaultMinute: 0,
            Key.showNextInMenuBar: true,
            Key.autoOpenOnFire: true,
            Key.voiceLocale: "zh-CN",
            Key.voiceAutoAdd: false,
            Key.voiceAutoAI: true,
            Key.voiceAllowServer: false,
            Key.aiEnabled: true,
            Key.aiKeyPresent: false,
            Key.aiTypedAuto: false,
            Key.aiDailyBudget: 20_000,
            Key.aiMonthlyBudget: 300_000,
            Key.pollMinutes: 30,
            Key.debugCapture: false,
            Key.appleInviteDismissed: false
        ])
    }

    static var defaultHour: Int { UserDefaults.standard.integer(forKey: Key.defaultHour) }
    static var defaultMinute: Int { UserDefaults.standard.integer(forKey: Key.defaultMinute) }
    static var showNextInMenuBar: Bool { UserDefaults.standard.bool(forKey: Key.showNextInMenuBar) }
    static var autoOpenOnFire: Bool { UserDefaults.standard.bool(forKey: Key.autoOpenOnFire) }
    static var debugCapture: Bool { UserDefaults.standard.bool(forKey: Key.debugCapture) }
    static var aiEnabled: Bool { UserDefaults.standard.bool(forKey: Key.aiEnabled) }
    static var aiKeyPresent: Bool { UserDefaults.standard.bool(forKey: Key.aiKeyPresent) }
}
