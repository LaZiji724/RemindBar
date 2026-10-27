import AppKit
import RemindCore

/// `RemindBar --ketangpai-check <outfile>`: read-only developer check. Compares what the app imports from 课堂派's
/// to-do list with an independent read of every course's homework list in the current semester.
@MainActor
enum KetangpaiCheck {
    private static let script = """
    const API = 'https://openapiv5.ketangpai.com/';
    function readToken() {
      const part = document.cookie.split(';').map(s => s.trim()).find(s => s.startsWith('token=') && s.length > 6);
      if (part) { try { return decodeURIComponent(part.slice(6)); } catch (e) { return part.slice(6); } }
      return localStorage.getItem('token') || '';
    }
    const token = readToken();
    if (!token) { return JSON.stringify({status: 401, body: ''}); }
    async function call(path, payload) {
      const response = await fetch(API + path, {method: 'POST', headers: {'Content-Type': 'application/json', 'token': token},
        body: JSON.stringify(Object.assign({}, payload, {reqtimestamp: Date.now()}))});
      if (!response.ok) { throw {http: response.status}; }
      return await response.json();
    }
    try {
      const courses = await call('/CourseApi/semesterCourseList', {isstudy: '1', search: '', semester: '2026-2027', term: '1'});
      const out = [];
      for (const c of (courses.data || [])) {
        const homework = [];
        for (let page = 1; page <= 5; page++) {
          const j = await call('/FutureV2/CourseMeans/getCourseContent', {courseid: c.id, contenttype: 4, dirid: 0, lessonlink: [], sort: [], page: page, limit: 50, desc: 3, courserole: 0, vtr_type: ''});
          if (!j || j.status !== 1) { break; }
          const list = (j.data && j.data.list) || [];
          homework.push(...list);
          if (page >= Number((j.data && j.data.pageTotal) || 1) || list.length === 0) { break; }
        }
        out.push({name: c.coursename, homework: homework});
      }
      return JSON.stringify({status: 200, body: JSON.stringify(out)});
    } catch (e) {
      return JSON.stringify({status: (e && e.http) || 599, body: String((e && e.message) || '')});
    }
    """

    static func run(outputPath: String) async {
        var lines: [String] = []
        func log(_ s: String = "") { lines.append(s) }
        defer { try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8) }

        let cal = Calendar.reminder
        func fmt(_ d: Date?) -> String {
            guard let d else { return "无截止时间" }
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        }

        let source = KetangpaiSource(session: WebSession.shared)
        guard await source.isLoggedIn() else {
            log("NOT LOGGED IN in this process (课堂派的登录没有保存下来，或这个进程看不到它).")
            return
        }
        log("已登录课堂派")

        log("")
        log("【1】提醒条会导入的（待办接口 + 课程作业列表里的截止时间）")
        var appKeys = Set<String>()
        do {
            let items = try await source.fetchItems()
            log("  共 \(items.count) 项")
            for i in items {
                log("  - \(fmt(i.due)) | \(i.course ?? "-") | \(i.title)")
                appKeys.insert("\(i.title)@\(fmt(i.due))")
            }
        } catch {
            log("  读取失败：\(error)")
        }

        log("")
        log("【2】独立读取：本学期每门课的作业列表")
        var listKeys = Set<String>()
        do {
            let result = try await WebSession.shared.fetch(script: script, baseURL: KetangpaiAPI.pageBase)
            guard result.status == 200, let data = result.body.data(using: .utf8),
                  let courses = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                log("  读取失败，状态 \(result.status)：\(result.body.prefix(120))")
                return
            }
            log("  共 \(courses.count) 门课")
            for course in courses {
                let name = course["name"] as? String ?? "-"
                let homework = course["homework"] as? [[String: Any]] ?? []
                var open = 0
                for hw in homework {
                    let state = (hw["timestate"] as? NSNumber)?.intValue ?? -1
                    let mine = (hw["mstatus"] as? NSNumber)?.intValue ?? -1
                    let title = hw["title"] as? String ?? "?"
                    let due = KetangpaiAPI.epochForTools(hw["endtime"])
                    // timestate 2 = in progress, 3 = ended; mstatus 0 = not handed in.
                    if state == 2 && mine == 0 {
                        open += 1
                        log("  - [\(name)] \(fmt(due)) | \(title) | 进行中·未交 (timestate \(state), mstatus \(mine))")
                        if due != nil { listKeys.insert("\(title)@\(fmt(due))") }
                    }
                }
                log("  · \(name)：共 \(homework.count) 项作业，进行中且未交 \(open) 项")
            }
        } catch {
            log("  读取失败：\(error)")
        }

        log("")
        log("【对比（按 作业名@截止时间）】提醒条 \(appKeys.count) 项 | 课程作业列表里进行中且未交（有截止时间）\(listKeys.count) 项")
        if appKeys == listKeys {
            log("  ✓ 完全一致")
        } else {
            let onlyApp = appKeys.subtracting(listKeys).sorted()
            let onlyList = listKeys.subtracting(appKeys).sorted()
            if !onlyApp.isEmpty { log("  ✗ 只有提醒条有: \(onlyApp.joined(separator: "；"))") }
            if !onlyList.isEmpty { log("  ✗ 只有课程作业列表有: \(onlyList.joined(separator: "；"))") }
        }
        log("DONE")
    }
}
