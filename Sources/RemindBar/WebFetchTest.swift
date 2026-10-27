import AppKit
import RemindCore

/// `RemindBar --test-web-fetch <outfile>`: exercises the hidden web runner against the real sites without a login.
/// Expected result without a session: not logged in (401), which proves scripts run and cookies/headers work.
@MainActor
enum WebFetchTest {
    static func run(outputPath: String) async {
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); print(s) }
        defer { try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8) }

        let base = URL(string: "https://canvas.tongji.edu.cn")!
        let canvas = CanvasSource(session: WebSession.shared, base: base)
        let started = Date()
        log("canvas isLoggedIn: \(await canvas.isLoggedIn())  (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        do {
            let items = try await canvas.fetchItems()
            log("canvas items: \(items.count)")
        } catch {
            log("canvas fetchItems -> \(error)")
        }
        let ketangpai = KetangpaiSource(session: WebSession.shared)
        log("ketangpai isLoggedIn (token cookie present): \(await ketangpai.isLoggedIn())")
        log("DONE")
    }
}
