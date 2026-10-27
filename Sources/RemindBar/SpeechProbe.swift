import Foundation
import Speech

/// `RemindBar --probe-speech`: reports what the speech recognizer can do on this Mac. Never prompts for permission.
enum SpeechProbe {
    static func run() {
        print("authorization status:", describe(SFSpeechRecognizer.authorizationStatus()))
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
        print("supported locales:", supported.count, "| zh-CN:", supported.contains("zh-CN"), "| zh_CN:", supported.contains("zh_CN"))
        for id in ["zh-CN", "zh-Hans-CN", "en-US"] {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)) {
                print("\(id): available=\(recognizer.isAvailable) onDevice=\(recognizer.supportsOnDeviceRecognition) default=\(recognizer.defaultTaskHint.rawValue)")
            } else {
                print("\(id): recognizer not supported")
            }
        }
    }

    private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }
}
