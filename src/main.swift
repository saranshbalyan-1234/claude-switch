// Claude Switch: menu bar usage for Claude Code logins, account switching, and live Claude sessions.
// Entry point: with --selftest (as scripts/test.sh runs it) it checks the app's logic and exits; otherwise it runs the app.
import AppKit
import SwiftUI

let app = NSApplication.shared

// Run the bare binary (not the .app) with --selftest, as scripts/test.sh does: it then has its own settings domain, apart from the installed app's.
if CommandLine.arguments.contains("--selftest") {
    let t = App(), a = "selftest@x", soon = Date().addingTimeInterval(3600)
    let iso = { (d: Date, frac: String) in ISO8601DateFormatter().string(from: d).replacingOccurrences(of: "Z", with: frac + "+00:00") }
    func u(_ s: Double, _ w: Double, _ sr: String? = nil, _ wr: String? = nil) -> Usage {
        Usage(five_hour: Window(utilization: s, resets_at: sr ?? iso(soon, "")), seven_day: Window(utilization: w, resets_at: wr ?? iso(soon, "")))
    }
    var failed = 0
    func expect(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL: \(what)") } }
    t.dots = [:]; t.alerts = [:]; t.fired = [:]
    let mixed = u(10, 55)
    expect(t.dotColor(mixed.five_hour) == .systemGreen, "session dot green below yellow")
    expect(t.dotColor(mixed.seven_day) == .systemYellow, "week dot coloured on its own")
    expect(t.dotColor(u(85, 0).five_hour) == .systemRed, "red from 80")
    expect(t.dotColor(u(95, 0, iso(Date().addingTimeInterval(-60), "")).five_hour) == .systemGreen, "reset window counts as 0")
    t.dots = ["yellow": 70]
    expect(t.dotColor(u(60, 0).five_hour) == .systemGreen, "custom yellow threshold")
    t.dots = ["show": 0]
    expect(t.dotColor(u(99, 99).seven_day) == nil, "dots hidden")
    t.alerts[a] = ["5h:75", "7d:90"]
    let base = Calendar.current.date(bySetting: .second, value: 0, of: soon)!
    expect(t.due(a, u(80, 50, iso(base.addingTimeInterval(-1), ".799837"))).count == 1, "session alert fires")
    expect(t.due(a, u(85, 50, iso(base, ".178258"))).isEmpty, "same window despite reset jitter")
    expect(t.due(a, u(85, 95, iso(base, ".1"))).count == 1, "week alert fires")
    expect(t.due(a, u(80, 95, iso(base.addingTimeInterval(5 * 3600), ".1"))).count == 1, "new session window fires again")
    t.fired = [:]
    expect(t.due(a, u(99, 99, iso(Date().addingTimeInterval(-60), ""), iso(Date().addingTimeInterval(-60), ""))).isEmpty, "stale figures never alert")
    t.fired = [:]; t.alerts[a] = ["5h:80"]; t.showLeft = true
    expect(percent(Window(utilization: 82.4, resets_at: nil), true) == "18% left", "remaining shown as left")
    expect(percent(Window(utilization: 82.4, resets_at: nil), true, word: false) == "18%", "menu bar drops the word left")
    expect(t.due(a, u(82, 0)) == ["Session (5h): 18% left, alert set at 20% left"], "remaining-mode alert text")
    t.dots = [:]
    expect(t.dotColor(u(82, 0).five_hour) == .systemRed, "18% left is past red at 20% left")
    // A failed refresh must not swap in Claude's older cache over this app's newer figures, and the reverse.
    t.showLeft = false; t.email = a; t.accountUuid = "u1"
    let window = { (v: Double) in ["utilization": v, "resets_at": NSNull()] as [String: Any] }
    t.known[a] = Known(usage: u(27, 41), at: Date())
    t.cache = ["accountUuid": "u1", "fetchedAtMs": (Date().timeIntervalSince1970 - 3600) * 1000,
               "utilization": ["five_hour": window(2), "seven_day": window(38)]]
    t.show(nil, failure(429))
    expect(t.usage?.five_hour?.utilization == 27 && t.usage?.seven_day?.utilization == 41, "failed refresh keeps newer own figures")
    t.known[a] = Known(usage: u(27, 41), at: Date().addingTimeInterval(-7200))
    t.show(nil, failure(429))
    expect(t.usage?.five_hour?.utilization == 2, "Claude's cache used when it's newer")
    t.noteRateLimit(429); t.noteRateLimit(429)
    expect((t.backoffUntil?.timeIntervalSinceNow ?? 0) > 200, "backs off after repeated 429s")
    t.noteRateLimit(200)
    expect(t.backoffUntil == nil, "backoff cleared on success")
    // Usage decoding: an unexpected shape in one field keeps the rest.
    let odd = #"{"five_hour":{"utilization":12,"resets_at":null},"seven_day":{"utilization":30,"resets_at":null},"extra_usage":{"is_enabled":true},"seven_day_opus":{"utilization":5,"resets_at":null}}"#
    let decoded = try? JSONDecoder().decode(Usage.self, from: Data(odd.utf8))
    expect(decoded?.five_hour?.utilization == 12 && decoded?.extra_usage == nil && decoded?.seven_day_opus?.utilization == 5, "tolerant decode")
    // Pace: 30% -> 50% over 30 minutes is 20% per half hour.
    let now = Date(), inHour = iso(now.addingTimeInterval(3600), ""), in3h = iso(now.addingTimeInterval(3 * 3600), "")
    t.history = [a: [Sample(at: now.addingTimeInterval(-1800), s: 30, w: 38)]]
    t.known[a] = Known(usage: u(50, 40, inHour, inHour), at: now)
    expect(t.pace(a, session: true) == "Session pace: about 90% at reset", "pace to reset: \(t.pace(a, session: true) ?? "nil")")
    t.known[a] = Known(usage: u(50, 40, in3h, in3h), at: now)
    expect(t.pace(a, session: true) == "Session pace: 100% in 1h 15m", "pace to full: \(t.pace(a, session: true) ?? "nil")")
    t.history = [a: [Sample(at: now.addingTimeInterval(-120), s: 30, w: 38)]]
    expect(t.pace(a, session: true) == nil, "no pace from under 10 minutes")
    // Resets: announced once, when the last seen reset time has passed.
    t.resetSessionOn = true; t.resetSeen = ["\(a) 5h": now.addingTimeInterval(-60)]
    expect(t.resets(a, u(0, 40, in3h, in3h)) == ["Session (5h) limit has reset: back to full"], "reset announced")
    expect(t.resets(a, u(1, 40, in3h, in3h)).isEmpty, "reset announced once")
    t.resetSeen = ["\(a) 5h": now.addingTimeInterval(-60)]; t.resetSessionOn = false
    expect(t.resets(a, u(0, 40, in3h, in3h)).isEmpty, "reset notifications can be turned off")
    // Suggestion: the other account with the most room, only if it has more than this one.
    t.accounts = [a, "b", "c"]; t.email = a; t.usage = u(90, 50)
    t.known["b"] = Known(usage: u(20, 30), at: now); t.known["c"] = Known(usage: u(60, 10), at: now)
    expect(t.roomiest(than: a)?.0 == "b" && t.roomiest(than: a)?.1 == 30, "roomiest account")
    t.usage = u(10, 10)
    expect(t.roomiest(than: a) == nil, "no suggestion when nothing has more room")
    expect(prettyVersion("202609281530") == "2026-09-28 15:30", "version display")
    print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
    exit(failed == 0 ? 0 : 1)
}

// --snapshot <folder>: renders the panel, notch and settings to PNGs, with sample requests and sessions mixed into
// the real data, so the design can be checked without opening anything on screen.
if let k = CommandLine.arguments.firstIndex(of: "--snapshot"), k + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[k + 1], t = App()
    t.readConfig()
    t.show(nil, "")
    t.notes = []
    t.readLive()
    let now = Date()
    let place = Place(host: "com.microsoft.VSCode", folder: "/Users/you/gamerun-app", editor: true, tty: "")
    t.requests = [
        Request(id: "1", kind: "permission", at: now.addingTimeInterval(-40), project: "gamerun-app", place: place, tool: "Bash",
                detail: "npm run test -- --watch=false", description: "Run the test suite", questions: []),
        Request(id: "2", kind: "question", at: now.addingTimeInterval(-90), project: "claude-switch", place: Place(host: "com.apple.Terminal", folder: "/x", editor: false, tty: "/dev/ttys003"),
                tool: "AskUserQuestion", detail: "", description: "", questions: [
                    .init(question: "Which database should the sessions store use?", header: "Storage", multiSelect: false, options: [
                        .init(label: "SQLite", description: "Single file, no server"), .init(label: "Postgres", description: "Shared with the API")])]),
    ]
    if t.sessions.isEmpty {
        t.sessions = [
            Live(file: "a", sid: "a", updated: now.addingTimeInterval(-20), event: "PostToolUse", status: "Edited LoginScreen.tsx (+12 −3)", project: "gamerun-app",
                 place: place, account: t.email, started: now.addingTimeInterval(-3000), files: [("/x/LoginScreen.tsx", 12, 3), ("/x/api.ts", 30, 8)], tokens: 412_000),
            Live(file: "b", sid: "b", updated: now.addingTimeInterval(-300), event: "Stop", status: "Done", project: "claude-switch",
                 place: Place(host: "com.apple.Terminal", folder: "/x", editor: false, tty: ""), account: "other@example.com", started: now.addingTimeInterval(-6000), tokens: 1_250_000),
        ]
    }
    t.tokensToday = 2_400_000
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func shot<V: View>(_ v: V, _ width: CGFloat, _ height: CGFloat?, _ name: String, dark: Bool) {
        let host = NSHostingView(rootView: v.environmentObject(t))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 800), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let size = height.map { NSSize(width: width, height: $0) } ?? NSSize(width: width, height: host.fittingSize.height)
        w.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    for dark in [false, true] {
        shot(PanelView().background(Color(nsColor: .windowBackgroundColor)), 380, nil, "panel-\(dark ? "dark" : "light")", dark: dark)
    }
    let m = NotchModel()
    m.notchWidth = 185
    m.notchHeight = 32
    shot(NotchView(model: m, collapse: {}).background(Color(white: 0.85)), 600, 60, "notch-collapsed", dark: true)
    m.expanded = true
    m.contentHeight = 470
    shot(NotchView(model: m, collapse: {}).background(Color(white: 0.85)), 600, 540, "notch-expanded", dark: true)
    for page in [Page.settings, .general, .menubar, .claude, .notch, .accounts, .account(t.email), .recap] {
        t.path = [.settings, page]
        shot(PanelView().background(Color(nsColor: .windowBackgroundColor)), 380, nil, "page-\(page.title.lowercased().replacingOccurrences(of: " ", with: "-"))", dark: false)
    }
    exit(0)
}

let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
