// Claude Switch: shared types, paths and helpers, and the readers for what the claude-switch hooks write.
import AppKit
import UserNotifications

struct Window: Codable { let utilization: Double; let resets_at: String? }
struct Usage: Codable {
    var five_hour: Window?, seven_day: Window?, seven_day_opus: Window?, seven_day_sonnet: Window?, extra_usage: Window?
    init(five_hour: Window?, seven_day: Window?, seven_day_opus: Window? = nil, seven_day_sonnet: Window? = nil, extra_usage: Window? = nil) {
        self.five_hour = five_hour
        self.seven_day = seven_day
        self.seven_day_opus = seven_day_opus
        self.seven_day_sonnet = seven_day_sonnet
        self.extra_usage = extra_usage
    }
    // Field by field, so one field in an unexpected shape (extra_usage isn't documented) can't lose the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func w(_ k: CodingKeys) -> Window? { (try? c.decodeIfPresent(Window.self, forKey: k)) ?? nil }
        self.init(five_hour: w(.five_hour), seven_day: w(.seven_day), seven_day_opus: w(.seven_day_opus),
                  seven_day_sonnet: w(.seven_day_sonnet), extra_usage: w(.extra_usage))
    }
}
struct Known: Codable { let usage: Usage; let at: Date }
struct Sample: Codable { let at: Date; let s: Double?; let w: Double? }  // one history point: session and week % used

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configPath = home + "/.claude.json"
let attentionPath = home + "/.claude/switch-attention"
let attentionOffPath = home + "/.claude/switch-attention-off"  // exists = the notify hook does nothing
let approvalsOnPath = home + "/.claude/switch-approvals-on"    // exists = permission prompts and questions come to the app
let requestsPath = home + "/.claude/switch-requests"           // one .json per prompt waiting for the app's answer
let sessionsPath = home + "/.claude/switch-sessions"           // one file per Claude session, written by the claude-switch hook
let projectsPath = home + "/.claude/projects"                  // Claude Code's own conversation logs, for token counts
let settingsPath = home + "/.claude/settings.json"
let switchPath = home + "/.local/bin/claude-switch"
let waitPath = home + "/.claude/switch-request-wait"  // seconds a prompt waits for an answer here before Claude asks the usual way
let supportDir = home + "/Library/Application Support/ClaudeSwitch"
let historyURL = URL(fileURLWithPath: supportDir + "/history.json")
let agentPath = home + "/Library/LaunchAgents/local.claude-switch.plist"
let appVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"  // build time, yyyyMMddHHmm, shown in Settings
let session = URLSession(configuration: .ephemeral)
let isApp = Bundle.main.bundleIdentifier != nil  // false for the bare selftest binary, which can't post notifications

// What `claude-switch hooks install` sets up: the hook on every event, and the request hook for prompts and questions.
let hookEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SubagentStop", "PreCompact"]
let hookParts = hookEvents.count + 2

func run(_ path: String, _ args: [String]) -> (ok: Bool, out: String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = pipe
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"  // apps don't get the shell PATH; jq may be in Homebrew
    p.environment = env
    guard (try? p.run()) != nil else { return (false, "Cannot run \(path)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

// Access token and expiry from a Keychain login (Claude's own item or a claude-switch copy), if still valid.
func accessToken(_ blob: String) -> (value: String, expires: Double)? {
    guard let o = (try? JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
          let v = o["accessToken"] as? String, let e = o["expiresAt"] as? Double, e / 1000 > Date().timeIntervalSince1970 else { return nil }
    return (v, e / 1000)
}

func fetchUsage(_ token: String, _ done: @escaping (Usage?, Int) -> Void) {
    var r = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    session.dataTask(with: r) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let u = code == 200 ? data.flatMap { try? JSONDecoder().decode(Usage.self, from: $0) } : nil
        DispatchQueue.main.async { done(u, code) }
    }.resume()
}

// Thresholds are always stored as "% used"; in remaining mode they're only shown and typed as "% left" (20% left = 80% used).
func percent(_ w: Window?, _ left: Bool = false, word: Bool = true) -> String {
    w.map { left ? "\(Int((100 - $0.utilization).rounded()))%\(word ? " left" : "")" : "\(Int($0.utilization.rounded()))%" } ?? "–"
}

func duration(_ seconds: TimeInterval) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = [.day, .hour, .minute]
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    return f.string(from: max(60, seconds)) ?? ""
}

func ago(_ d: Date) -> String {
    let s = -d.timeIntervalSinceNow
    return s < 60 ? "now" : duration(s) + " ago"
}

func resetText(_ w: Window?) -> String {
    guard let w, let d = resetDate(w) else { return "" }
    return d <= Date() ? "has reset" : "resets in \(duration(d.timeIntervalSinceNow))"
}

func line(_ w: Window?, _ left: Bool = false) -> String {
    let reset = resetText(w)
    return percent(w, left) + (reset.isEmpty ? "" : " · " + reset)
}

// % used, counting a window that has already reset as empty.
func used(_ w: Window?) -> Double {
    guard let w else { return 0 }
    return resetDate(w).map { $0 > Date() } ?? true ? w.utilization : 0
}

func prettyVersion(_ v: String) -> String {
    v.count == 12 ? "\(v.prefix(4))-\(v.dropFirst(4).prefix(2))-\(v.dropFirst(6).prefix(2)) \(v.dropFirst(8).prefix(2)):\(v.suffix(2))" : v
}

func resetDate(_ w: Window) -> Date? {
    w.resets_at.flatMap { ISO8601DateFormatter().date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)) }
}

func failure(_ code: Int) -> String {
    code == 429 ? "Rate limited by Anthropic, backing off" : code == 0 ? "Usage request failed (network)" : "Usage request failed (HTTP \(code))"
}

func tokens(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? String(format: "%.0fk", Double(n) / 1000) : "\(n)"
}

func initials(_ s: String) -> String {
    let base = s.split(separator: "@").first.map(String.init) ?? s
    let parts = base.split(whereSeparator: { " ._-".contains($0) }).prefix(2)
    let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
    return letters.isEmpty ? "?" : letters
}

var mutedUntil: Date? {
    get { UserDefaults.standard.object(forKey: "muteUntil") as? Date }
    set { UserDefaults.standard.set(newValue, forKey: "muteUntil") }
}
var isMuted: Bool { (mutedUntil ?? .distantPast) > Date() }

// Posted by the app itself, not through osascript: a click on an osascript notification opens Script Editor.
// A click goes where userInfo says (host app, folder, terminal) and otherwise just closes the notification.
func notify(_ text: String, _ subtitle: String, title: String = "Claude usage", id: String = UUID().uuidString,
            category: String = "", info: [String: String] = [:]) {
    guard isApp, !isMuted else { return }
    let c = UNMutableNotificationContent()
    c.title = title
    c.subtitle = subtitle
    c.body = text
    c.sound = .default
    c.categoryIdentifier = category
    c.userInfo = info
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
}

// What hooks install would still add to settings.json; none means the hooks are set up.
func hooksMissing() -> [String] {
    let o = (try? Data(contentsOf: URL(fileURLWithPath: settingsPath))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let hooks = o?["hooks"] as? [String: Any] ?? [:]
    func has(_ event: String, _ needle: String, matcher: String? = nil) -> Bool {
        ((hooks[event] as? [[String: Any]]) ?? []).contains { group in
            (matcher == nil || ((group["matcher"] as? String) ?? "").contains(matcher!)) &&
            ((group["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(needle) ?? false }
        }
    }
    return hookEvents.filter { !has($0, "claude-switch hook") }
        + (has("PermissionRequest", "claude-switch request") ? [] : ["PermissionRequest"])
        + (has("PreToolUse", "claude-switch request", matcher: "AskUserQuestion") ? [] : ["AskUserQuestion"])
}

// Where something came from: the app hosting it, its folder, and for a terminal its tty.
struct Place: Equatable {
    var host = "", folder = "", editor = false, tty = ""
    var label: String { editor ? "VS Code" : "Terminal" }
    var known: Bool { !host.isEmpty }
}

// What Claude is waiting on, from the notify hook: time, project, message, folder, host app, editor|terminal, tty.
struct Waiting: Identifiable, Equatable {
    let raw: String, at: Date, project: String, text: String, place: Place
    var id: String { raw }
    init?(_ line: String) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count > 2 else { return nil }
        raw = line
        at = Date(timeIntervalSince1970: Double(f[0]) ?? 0)
        project = f[1]
        text = f[2]
        place = Place(host: f.count > 4 ? f[4] : "", folder: f.count > 3 ? f[3] : "", editor: f.count > 5 && f[5] == "editor", tty: f.count > 6 ? f[6] : "")
    }
}

// A Claude session as its hook last described it.
struct Live: Identifiable, Equatable {
    let file: String, sid: String, updated: Date, event: String, status: String, project: String, place: Place, account: String, started: Date
    var files: [(path: String, add: Int, del: Int)] = []
    var tokens = 0
    var id: String { file }
    static func == (a: Live, b: Live) -> Bool { a.file == b.file && a.updated == b.updated && a.status == b.status && a.tokens == b.tokens }
    var state: State {
        switch event {
        case "Stop": return .done
        case "Notification": return .waiting
        case "PreToolUse" where status.hasPrefix("Asking"): return .waiting
        case "SessionStart": return .idle
        default: return .working
        }
    }
    enum State { case working, waiting, done, idle }
    var added: Int { files.reduce(0) { $0 + $1.add } }
    var removed: Int { files.reduce(0) { $0 + $1.del } }
}

// Sessions the hooks have seen, newest first. One whose process is gone (a closed window or a crash skips SessionEnd)
// or that has been quiet for a day is dropped, files and all.
func readSessions() -> [Live] {
    let fm = FileManager.default
    var out: [Live] = []
    for name in (try? fm.contentsOfDirectory(atPath: sessionsPath)) ?? [] where !name.contains(".") {
        let path = sessionsPath + "/" + name
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let f = text.trimmingCharacters(in: .newlines).split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 9, let t = Double(f[0]) else { continue }
        let updated = Date(timeIntervalSince1970: t), pid = Int32(f[7]) ?? 0
        if (pid > 0 && kill(pid, 0) != 0 && errno == ESRCH) || updated.timeIntervalSinceNow < -86400 {
            try? fm.removeItem(atPath: path)
            try? fm.removeItem(atPath: path + ".files")
            continue
        }
        var s = Live(file: path, sid: name, updated: updated, event: f[1], status: f[2], project: f[3],
                     place: Place(host: f[6], folder: f[4], editor: f[5] == "editor", tty: f.count > 10 ? f[10] : ""),
                     account: f[8], started: Date(timeIntervalSince1970: f.count > 9 ? Double(f[9]) ?? t : t))
        let touched = (try? String(contentsOfFile: path + ".files", encoding: .utf8)) ?? ""
        s.files = touched.split(separator: "\n").reversed().compactMap { l in
            let g = l.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            return g.count == 3 ? (g[0], Int(g[1]) ?? 0, Int(g[2]) ?? 0) : nil
        }
        out.append(s)
    }
    return out.sorted { $0.updated > $1.updated }
}

// A permission prompt or question from the request hook, waiting for an answer here.
struct Request: Identifiable, Equatable {
    struct Option: Equatable { let label: String, description: String }
    struct Question: Equatable { let question: String, header: String, multiSelect: Bool, options: [Option] }
    let id: String, kind: String, at: Date, project: String, place: Place, tool: String, detail: String, description: String
    let questions: [Question]
    var diff = "", always = ""  // for edits, the change; for permissions, the rule Always Allow would add
    var isQuestion: Bool { kind == "question" }

    static func read() -> [Request] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: requestsPath)) ?? []).filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = fm.contents(atPath: requestsPath + "/" + name),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["id"] as? String else { return nil }
            let qs = (o["questions"] as? [[String: Any]] ?? []).map { q in
                Question(question: q["question"] as? String ?? "", header: q["header"] as? String ?? "", multiSelect: q["multiSelect"] as? Bool ?? false,
                         options: (q["options"] as? [[String: Any]] ?? []).map { Option(label: $0["label"] as? String ?? "", description: $0["description"] as? String ?? "") })
            }
            return Request(id: id, kind: o["kind"] as? String ?? "", at: Date(timeIntervalSince1970: o["at"] as? Double ?? 0),
                           project: o["project"] as? String ?? "",
                           place: Place(host: o["host"] as? String ?? "", folder: o["folder"] as? String ?? "", editor: o["where"] as? String == "editor", tty: o["tty"] as? String ?? ""),
                           tool: o["tool"] as? String ?? "", detail: o["detail"] as? String ?? "", description: o["description"] as? String ?? "", questions: qs,
                           diff: o["diff"] as? String ?? "", always: o["always"] as? String ?? "")
        }.sorted { $0.at < $1.at }
    }

    // allow, deny, claude (ask in Claude), or the answers as JSON.
    func answer(_ text: String) {
        try? text.write(toFile: requestsPath + "/" + id + ".answer", atomically: true, encoding: .utf8)
    }
    func answer(message: String) {
        if let data = try? JSONSerialization.data(withJSONObject: ["message": message]), let s = String(data: data, encoding: .utf8) { answer(s) }
    }
    func answer(_ answers: [(question: String, answer: String)]) {
        let list = answers.map { ["question": $0.question, "answer": $0.answer] }
        if let data = try? JSONSerialization.data(withJSONObject: ["answers": list]), let s = String(data: data, encoding: .utf8) { answer(s) }
    }
}

// A session that has ended, kept so it can be resumed.
struct Recent: Codable, Identifiable, Equatable {
    let sid: String, project: String, folder: String, editor: Bool, ended: Date
    var id: String { sid }
}

// Tokens from Claude Code's conversation logs (~/.claude/projects/*/<session>.jsonl): per session, and for today.
// Each log is read once and then only what was added since, so a refresh costs little.
final class TokenCounter {
    struct FileState { var offset: UInt64 = 0, total = 0, today = 0, day = "" }
    private var files: [String: FileState] = [:]
    private(set) var bySession: [String: Int] = [:]
    private(set) var today = 0
    private let queue = DispatchQueue(label: "tokens")

    static func dayKey(_ d: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    func update(_ done: @escaping () -> Void) {
        queue.async {
            let fm = FileManager.default, day = TokenCounter.dayKey(), since = Date().addingTimeInterval(-36 * 3600)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for dir in (try? fm.contentsOfDirectory(atPath: projectsPath)) ?? [] {
                let folder = projectsPath + "/" + dir
                for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".jsonl") {
                    let path = folder + "/" + name
                    guard let attrs = try? fm.attributesOfItem(atPath: path), let mod = attrs[.modificationDate] as? Date, mod > since,
                          let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
                    var st = self.files[path] ?? FileState()
                    if st.day != day { st.today = 0; st.day = day; if st.offset > 0 && size >= st.offset { st.offset = 0; st.total = 0 } }
                    if size < st.offset { st = FileState(day: day) }  // rewritten: start over
                    guard size > st.offset, let h = FileHandle(forReadingAtPath: path) else { self.files[path] = st; continue }
                    try? h.seek(toOffset: st.offset)
                    let data = h.readDataToEndOfFile()
                    try? h.close()
                    // Only whole lines; a line still being written is read next time.
                    guard let lastNewline = data.lastIndex(of: 10) else { self.files[path] = st; continue }
                    let chunk = data[data.startIndex...lastNewline]
                    st.offset += UInt64(chunk.count)
                    for l in chunk.split(separator: 10) {
                        guard l.count > 20, let o = try? JSONSerialization.jsonObject(with: Data(l)) as? [String: Any],
                              let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { continue }
                        let n = ["input_tokens", "output_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
                        st.total += n
                        if let ts = o["timestamp"] as? String, let d = iso.date(from: ts), TokenCounter.dayKey(d) == day { st.today += n }
                    }
                    self.files[path] = st
                }
            }
            var by: [String: Int] = [:], t = 0
            for (path, st) in self.files {
                by[((path as NSString).lastPathComponent as NSString).deletingPathExtension, default: 0] += st.total
                if st.day == day { t += st.today }
            }
            DispatchQueue.main.async {
                self.bySession = by
                self.today = t
                done()
            }
        }
    }
}

// Watches a file or folder; the handler runs on the main queue whenever it changes, and the watch survives the file
// being replaced (it re-opens after a delete or rename).
final class Watch {
    private var source: DispatchSourceFileSystemObject?
    private let path: String, handler: () -> Void
    init(_ path: String, folder: Bool = false, _ handler: @escaping () -> Void) {
        self.path = path
        self.handler = handler
        let fm = FileManager.default
        if folder { try? fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        else if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        start()
    }
    private func start() {
        source?.cancel()
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            if !s.data.isDisjoint(with: [.delete, .rename]) { self.start() }
            self.handler()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}
