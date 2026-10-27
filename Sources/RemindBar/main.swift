import AppKit

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--store-deepseek-key") {
        // Reads DEEPSEEK_API_KEY from the environment and stores it in the keychain as this app. Prints nothing secret.
        let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? ""
        guard !key.isEmpty else {
            print("DEEPSEEK_API_KEY is not set; nothing stored.")
            exit(2)
        }
        let ok = KeyBox.shared.save(key)
        print(ok ? "Stored the DeepSeek key in the keychain (\(key.count) characters)." : "Could not write to the keychain.")
        exit(ok ? 0 : 1)
    }
    if CommandLine.arguments.contains("--probe-speech") {
        SpeechProbe.run()
        exit(0)
    }
    if CommandLine.arguments.contains("--snapshot") {
        SnapshotTool.run(arguments: CommandLine.arguments)
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
