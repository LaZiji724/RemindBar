import AppKit
import RemindCore

/// `RemindBar --canvas-crosscheck <outfile>`: read-only. Fetches the same assignments three independent ways with the
/// logged-in session (planner, "to do" list, per-course assignment lists) and compares them with what the app imports.
@MainActor
enum CanvasCrossCheck {
    private struct Row: Hashable {
        var title: String
        var due: Date?
        var id: String
    }

    static func run(outputPath: String) async {
        var lines: [String] = []
        func log(_ s: String = "") { lines.append(s) }
        defer { try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8) }

        let base = URL(string: "https://canvas.tongji.edu.cn")!
        let session = WebSession.shared
        let now = Date()
        let cal = Calendar.reminder
        let windowStart = now.addingTimeInterval(-14 * 86_400)

        guard await CanvasSource(session: session, base: base).isLoggedIn() else {
            log("NOT LOGGED IN in this process (the session is not shared); nothing to compare.")
            return
        }

        func fetch(_ path: String, _ query: [(String, String)]) async -> [[String: Any]]? {
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            comps.path = path
            comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            guard let url = comps.url else { return nil }
            do {
                let result = try await session.fetch(script: CanvasAPI.pagedScript(startURL: url, maxPages: 10), baseURL: base)
                guard result.status == 200 else { log("  \(path) -> HTTP \(result.status)"); return nil }
                return (try? JSONSerialization.jsonObject(with: Data(result.body.utf8))) as? [[String: Any]] ?? []
            } catch {
                log("  \(path) -> \(error)")
                return nil
            }
        }
        func date(_ s: Any?) -> Date? { CanvasAPI.parseDateForTools(s as? String) }
        func idString(_ any: Any?) -> String { (any as? String) ?? (any as? NSNumber)?.stringValue ?? "?" }
        func fmt(_ d: Date?) -> String {
            guard let d else { return "无截止日期" }
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        }

        // 1. What the app imports (planner)
        log("【1】提醒条使用的 planner 接口")
        let plannerURL = CanvasAPI.plannerURL(base: base, now: now, calendar: cal)
        let plannerQuery = (URLComponents(url: plannerURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        var plannerOpen = Set<Row>()
        if let planner = await fetch("/api/v1/planner/items", plannerQuery) {
            var byType: [String: Int] = [:]
            for raw in planner { byType[raw["plannable_type"] as? String ?? "?", default: 0] += 1 }
            log("  共 \(planner.count) 项：" + byType.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "，"))
            for raw in planner {
                guard let type = raw["plannable_type"] as? String, CanvasAPI.types.contains(type) else { continue }
                let p = raw["plannable"] as? [String: Any] ?? [:]
                let sub = raw["submissions"] as? [String: Any]
                let override = raw["planner_override"] as? [String: Any]
                let submitted = sub?["submitted"] as? Bool ?? false
                let graded = sub?["graded"] as? Bool ?? false
                let excused = sub?["excused"] as? Bool ?? false
                let marked = override?["marked_complete"] as? Bool ?? false
                let due = date(p["due_at"] ?? raw["plannable_date"])
                let done = submitted || excused || marked
                let state = done ? "已完成(\(submitted ? "已提交" : "")\(graded ? "·已批改" : "")\(excused ? "·豁免" : "")\(marked ? "·计划中标完成" : ""))" : "未完成"
                log("  - [\(state)] \(fmt(due)) | \(raw["context_name"] as? String ?? "-") | \(p["title"] as? String ?? "?")")
                if !done, let due { plannerOpen.insert(Row(title: p["title"] as? String ?? "?", due: due, id: idString(raw["plannable_id"]))) }
            }
        }
        let appItems = (try? await CanvasSource(session: session, base: base).fetchItems()) ?? []
        let appOpen = appItems.filter { !$0.completed }
        log("  提醒条会导入 \(appOpen.count) 项未完成：" + appOpen.map { "\($0.title)（\(fmt($0.due))）" }.joined(separator: "；"))

        // 2. Canvas's own "to do" list
        log("")
        log("【2】Canvas 自己的“待办事项”接口 /users/self/todo")
        var todoOpen = Set<Row>()
        if let todo = await fetch("/api/v1/users/self/todo", [("per_page", "100")]) {
            log("  共 \(todo.count) 项")
            for raw in todo {
                let a = raw["assignment"] as? [String: Any] ?? [:]
                let due = date(a["due_at"])
                log("  - [\(raw["type"] as? String ?? "?")] \(fmt(due)) | \(raw["context_name"] as? String ?? "-") | \(a["name"] as? String ?? "?")")
                if let due { todoOpen.insert(Row(title: a["name"] as? String ?? "?", due: due, id: idString(a["id"]))) }
            }
        }

        // 3. Every active course's assignment list
        log("")
        log("【3】逐门课程的作业列表（只看未提交、有截止日期、截止日在近两周之后的）")
        var courseOpen = Set<Row>()
        if let courses = await fetch("/api/v1/courses", [("enrollment_state", "active"), ("per_page", "100")]) {
            log("  共 \(courses.count) 门进行中的课程")
            for course in courses {
                guard let cid = course["id"] else { continue }
                let cname = course["name"] as? String ?? "-"
                guard let assignments = await fetch("/api/v1/courses/\(idString(cid))/assignments",
                                                    [("include[]", "submission"), ("per_page", "100")]) else { continue }
                var open = 0
                for a in assignments {
                    guard let due = date(a["due_at"]), due >= windowStart else { continue }
                    let sub = a["submission"] as? [String: Any]
                    let state = sub?["workflow_state"] as? String ?? "unsubmitted"
                    let excused = sub?["excused"] as? Bool ?? false
                    let isOpen = state == "unsubmitted" && !excused && (a["published"] as? Bool ?? true)
                    if isOpen {
                        open += 1
                        courseOpen.insert(Row(title: a["name"] as? String ?? "?", due: due, id: idString(a["id"])))
                        log("  - [\(cname)] \(fmt(due)) | \(a["name"] as? String ?? "?") | 提交状态 \(state)")
                    }
                }
                log("  · \(cname)：共 \(assignments.count) 项作业，其中近期未提交 \(open) 项")
            }
        }

        // 4. Compare by (title, due minute)
        func keys(_ rows: Set<Row>) -> Set<String> { Set(rows.map { "\($0.title)@\(fmt($0.due))" }) }
        let app = Set(appOpen.map { "\($0.title)@\(fmt($0.due))" })
        let planner = keys(plannerOpen), todo = keys(todoOpen), courses = keys(courseOpen)
        log("")
        log("【对比（按 作业名@截止时间）】")
        log("  提醒条导入: \(app.count) | planner 未完成: \(planner.count) | 待办接口: \(todo.count) | 课程作业列表未提交: \(courses.count)")
        func diff(_ name: String, _ other: Set<String>) {
            let onlyApp = app.subtracting(other), onlyOther = other.subtracting(app)
            if onlyApp.isEmpty && onlyOther.isEmpty { log("  ✓ 与「\(name)」一致") }
            else {
                if !onlyApp.isEmpty { log("  ✗ 只有提醒条有、「\(name)」没有: \(onlyApp.sorted().joined(separator: "；"))") }
                if !onlyOther.isEmpty { log("  ✗ 「\(name)」有、提醒条没有: \(onlyOther.sorted().joined(separator: "；"))") }
            }
        }
        diff("待办接口", todo)
        diff("课程作业列表", courses)
        log("DONE")
    }
}
