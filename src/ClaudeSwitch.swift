// Claude Switch: the app's state and logic. Usage for Claude Code logins, account switching through claude-switch,
// and what each Claude session is doing (from the claude-switch hooks). The UI lives in Panel, Settings and Notch.
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UserNotifications

final class App: NSObject, ObservableObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let defaults = UserDefaults.standard

    // Account and usage
    @Published var email = ""
    @Published var accounts: [String] = []
    @Published var usage: Usage?
    @Published var notes: [String] = []
    @Published var known: [String: Known] = [:]
    @Published var history: [String: [Sample]] = [:]
    @Published var loading: Set<String> = []
    @Published var accountNote: [String: String] = [:]
    @Published var banner: String?  // result of the last switch, save or setup, shown at the top of the panel
    @Published var switching = false
    var accountUuid: String?, cache: [String: Any]?, configDate: Date?
    var token: (email: String, value: String, expires: Double)?  // kept so the Keychain is read only when the login changes
    var timer: Timer?, lastFetch: Date?, lastTry: [String: Date] = [:]
    var backoffUntil: Date?, rateLimits = 0  // the usage endpoint rate-limits; after a 429 wait 2x, 4x... the interval, up to 15 min
    var fired: [String: Int] = [:]           // "account 5h:75" -> window it fired for
    var resetSeen: [String: Date] = [:]      // "account 5h" -> the reset time last seen for that window
    var switchedTo: String?                  // the account last switched to, watched for a running session switching it back

    // Claude sessions
    @Published var attention: [Waiting] = []
    @Published var sessions: [Live] = []
    @Published var requests: [Request] = []
    @Published var recent: [Recent] = []
    @Published var tokensToday = 0
    @Published var hooksMissingList: [String] = []
    let counter = TokenCounter()
    var watches: [Watch] = []
    var seenAttention: Set<String>?, seenRequests: Set<String>?, lastState: [String: Live.State] = [:]

    // Settings, saved as they change
    @Published var intervals: [String: Int] { didSet { defaults.set(intervals, forKey: "intervals"); retime() } }
    @Published var alerts: [String: [String]] { didSet { defaults.set(alerts, forKey: "alerts"); retime() } }
    @Published var showLeft: Bool { didSet { defaults.set(showLeft, forKey: "showLeft"); updateTitle() } }
    @Published var dots: [String: Int] { didSet { defaults.set(dots, forKey: "dots"); updateTitle() } }
    @Published var names: [String: String] { didSet { defaults.set(names, forKey: "names"); updateTitle() } }
    @Published var barModes: String { didSet { defaults.set(barModes, forKey: "barModes"); updateTitle() } }
    @Published var barLabels: String { didSet { defaults.set(barLabels, forKey: "barLabels"); updateTitle() } }
    @Published var barDelimiter: String { didSet { defaults.set(barDelimiter, forKey: "barDelimiter"); updateTitle() } }
    @Published var hotKeyOn: Bool { didSet { defaults.set(hotKeyOn, forKey: "hotKey"); registerHotKeys() } }
    @Published var jumpKeyOn: Bool { didSet { defaults.set(jumpKeyOn, forKey: "jumpKey"); registerHotKeys() } }
    @Published var allowKeyOn: Bool { didSet { defaults.set(allowKeyOn, forKey: "allowKey"); registerHotKeys() } }
    @Published var requestWait: Int { didSet { try? "\(requestWait)".write(toFile: waitPath, atomically: true, encoding: .utf8) } }
    @Published var rules: [String] = []  // always-allow rules in Claude Code's user settings
    @Published var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: "notifyFinished") } }
    @Published var recapOn: Bool { didSet { defaults.set(recapOn, forKey: "recapOn") } }
    @Published var showSessions: Bool { didSet { defaults.set(showSessions, forKey: "showSessions"); notch?.update() } }  // off: only what needs you
    @Published var resetSessionOn: Bool { didSet { defaults.set(resetSessionOn, forKey: "resetSessionOn") } }  // notify when the 5-hour limit resets
    @Published var resetWeekOn: Bool { didSet { defaults.set(resetWeekOn, forKey: "resetWeekOn") } }        // notify when the weekly limit resets
    @Published var notchOn: Bool { didSet { defaults.set(notchOn, forKey: "notchOn"); notch?.update() } }
    @Published var notchAlways: Bool { didSet { defaults.set(notchAlways, forKey: "notchAlways"); notch?.update() } }
    @Published var muteUntil: Date? { didSet { mutedUntil = muteUntil } }
    @Published var waitingOn: Bool {
        didSet {
            if waitingOn { try? FileManager.default.removeItem(atPath: attentionOffPath) }
            else { FileManager.default.createFile(atPath: attentionOffPath, contents: nil); writeAttention([]) }  // off means no bell either
        }
    }
    @Published var approvalsOn: Bool {
        didSet {
            if approvalsOn { FileManager.default.createFile(atPath: approvalsOnPath, contents: nil) }
            else { try? FileManager.default.removeItem(atPath: approvalsOnPath) }
        }
    }
    @Published var openAtLogin: Bool {
        didSet {  // setup.sh reads loginOff, so reinstalling doesn't turn this back on
            if openAtLogin {
                let plist: [String: Any] = ["Label": "local.claude-switch", "ProgramArguments": [Bundle.main.executablePath ?? ""], "RunAtLoad": true]
                (plist as NSDictionary).write(toFile: agentPath, atomically: true)
            } else {
                try? FileManager.default.removeItem(atPath: agentPath)
            }
            defaults.set(!openAtLogin, forKey: "loginOff")
        }
    }

    let popover = NSPopover()
    @Published var path: [Page] = []
    var outsideClick: Any?
    var notch: Notch?
    var hotKeys: [EventHotKeyRef] = []

    override init() {
        let d = UserDefaults.standard
        intervals = d.dictionary(forKey: "intervals") as? [String: Int] ?? [:]
        alerts = d.dictionary(forKey: "alerts") as? [String: [String]] ?? [:]
        showLeft = d.bool(forKey: "showLeft")
        dots = d.dictionary(forKey: "dots") as? [String: Int] ?? [:]
        names = d.dictionary(forKey: "names") as? [String: String] ?? [:]
        barModes = d.string(forKey: "barModes") ?? "both"
        barLabels = d.string(forKey: "barLabels") ?? "full"
        barDelimiter = d.string(forKey: "barDelimiter") ?? " · "
        d.removeObject(forKey: "resetOff")  // per-account reset settings are gone: resets are set once, in General
        hotKeyOn = d.object(forKey: "hotKey") as? Bool ?? true
        jumpKeyOn = d.object(forKey: "jumpKey") as? Bool ?? true
        allowKeyOn = d.object(forKey: "allowKey") as? Bool ?? true
        requestWait = Int(((try? String(contentsOfFile: waitPath, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 300
        notifyFinished = d.object(forKey: "notifyFinished") as? Bool ?? true
        recapOn = d.object(forKey: "recapOn") as? Bool ?? true
        showSessions = d.bool(forKey: "showSessions")
        resetSessionOn = d.object(forKey: "resetSessionOn") as? Bool ?? true
        resetWeekOn = d.object(forKey: "resetWeekOn") as? Bool ?? true
        notchOn = d.object(forKey: "notchOn") as? Bool ?? true
        notchAlways = d.bool(forKey: "notchAlways")
        muteUntil = mutedUntil
        waitingOn = !FileManager.default.fileExists(atPath: attentionOffPath)
        approvalsOn = FileManager.default.fileExists(atPath: approvalsOnPath)
        openAtLogin = FileManager.default.fileExists(atPath: agentPath)
        fired = d.dictionary(forKey: "fired") as? [String: Int] ?? [:]
        super.init()
        known = d.data(forKey: "known").flatMap { try? JSONDecoder().decode([String: Known].self, from: $0) } ?? [:]
        history = (try? Data(contentsOf: historyURL)).flatMap { try? JSONDecoder().decode([String: [Sample]].self, from: $0) } ?? [:]
        recent = d.data(forKey: "recent").flatMap { try? JSONDecoder().decode([Recent].self, from: $0) } ?? []
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.title = "Claude"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView().environmentObject(self))
        host.sizingOptions = [.preferredContentSize]  // the popover follows the panel's size as pages change
        popover.contentViewController = host

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { (NSApp.delegate as? App)?.hotKeyPressed(id.id) }
            return noErr
        }, 1, &spec, nil, nil)
        registerHotKeys()

        // Notifications: "Claude is waiting" ones can be deleted from the notification itself; permission prompts
        // can be allowed or denied there.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "waiting", actions: [UNNotificationAction(identifier: "delete", title: "Delete", options: [.destructive])], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission", actions: [
                UNNotificationAction(identifier: "allow", title: "Allow", options: []),
                UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])], intentIdentifiers: []),
            UNNotificationCategory(identifier: "question", actions: [UNNotificationAction(identifier: "claude", title: "Answer in Claude", options: [])], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        watches = [
            Watch(attentionPath) { [weak self] in self?.readAttention() },
            Watch(sessionsPath, folder: true) { [weak self] in self?.readLive() },
            Watch(requestsPath, folder: true) { [weak self] in self?.readRequests() },
            Watch(settingsPath) { [weak self] in self?.hooksMissingList = hooksMissing(); self?.loadRules() },
        ]
        hooksMissingList = hooksMissing()
        readAttention()
        readLive()
        readRequests()
        notch = Notch(self)
        refresh(force: true)
    }

    func display(_ a: String) -> String { names[a] ?? a }

    // MARK: Status item and panel

    @objc func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        configDate = nil
        refresh()
        hooksMissingList = hooksMissing()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // A click anywhere outside closes it, even in another app (a transient popover alone misses some of those).
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.closePanel() }
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
    func closePanel() { if popover.isShown { popover.performClose(nil) } }

    func updateTitle() {
        // One dot per window, each right before its own figure.
        let font = NSFont.menuBarFont(ofSize: 0), title = NSMutableAttributedString(), left = showLeft
        let mode = barModes, dotsOnly = mode == "dots"
        func part(_ label: String, _ w: Window?) {
            if let c = dotColor(w, force: dotsOnly) {
                let dot = NSTextAttachment()
                dot.image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in c.setFill(); NSBezierPath(ovalIn: r).fill(); return true }
                dot.bounds = CGRect(x: 0, y: (font.capHeight - 8) / 2, width: 8, height: 8)
                title.append(NSAttributedString(attachment: dot))
                if !dotsOnly { title.append(NSAttributedString(string: " ")) }
            }
            if !dotsOnly { title.append(NSAttributedString(string: "\(label) \(percent(w, left, word: false))")) }  // menu bar stays short
        }
        if !requests.isEmpty || !attention.isEmpty { title.append(NSAttributedString(string: "● ")) }  // Claude is waiting on you
        if let u = usage {
            let short = barLabels == "short"
            let parts = mode == "session" ? [(short ? "S" : "5h", u.five_hour)] : mode == "week" ? [(short ? "W" : "7d", u.seven_day)]
                : [(short ? "S" : "5h", u.five_hour), (short ? "W" : "7d", u.seven_day)]
            for (k, p) in parts.enumerated() {
                if k > 0 { title.append(NSAttributedString(string: dotsOnly ? " " : barDelimiter)) }
                part(p.0, p.1)
            }
        } else {
            title.append(NSAttributedString(string: "Claude"))
        }
        title.addAttributes([.font: font], range: NSRange(location: 0, length: title.length))
        if !requests.isEmpty || !attention.isEmpty {
            title.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: NSRange(location: 0, length: 1))
        }
        item.button?.attributedTitle = title
        item.button?.toolTip = ([display(email)] + ["Session (5h): \(line(usage?.five_hour, left))", "Week: \(line(usage?.seven_day, left))"] + notes).joined(separator: "\n")
        notch?.update()
    }

    func dotSetting(_ key: String) -> Int { dots[key] ?? ["show": 1, "yellow": 50, "red": 80][key]! }

    // Colour for one window (session or week); a window that has already reset counts as 0%.
    func dotColor(_ w: Window?, force: Bool = false) -> NSColor? {
        guard let w, force || dotSetting("show") == 1 else { return nil }
        let p = used(w)
        return p >= Double(dotSetting("red")) ? .systemRed : p >= Double(dotSetting("yellow")) ? .systemYellow : .systemGreen
    }
    func level(_ w: Window?) -> Color {
        let p = used(w)
        return p >= Double(dotSetting("red")) ? .red : p >= Double(dotSetting("yellow")) ? .orange : .green
    }

    // MARK: Usage

    func intervalFor(_ a: String) -> Int { intervals[a] ?? defaults.object(forKey: "interval") as? Int ?? 60 }

    // One timer, ticking at the shortest interval in use: the current account's, or that of an account with alerts.
    func retime() {
        let polled = [email] + alerts.filter { $0.key != email && !$0.value.isEmpty && accounts.contains($0.key) }.map(\.key)
        let tick = Double(polled.map(intervalFor).min() ?? 60)
        if timer?.timeInterval == tick { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = tick / 5  // lets macOS batch this wake-up with others
    }

    func lastRefreshed(_ a: String) -> String {
        guard let at = known[a]?.at else { return "Not refreshed yet" }
        let style: Date.FormatStyle = Calendar.current.isDateInToday(at) ? .dateTime.hour().minute() : .dateTime.month().day().hour().minute()
        return "Updated \(at.formatted(style))"
    }

    func remember(_ account: String, _ u: Usage) {
        known[account] = Known(usage: u, at: Date())
        defaults.set(try? JSONEncoder().encode(known), forKey: "known")
        record(account, u)
        check(account, u)
    }

    func check(_ account: String, _ u: Usage) {
        let hint = account == email ? roomiest(than: account).map { " Most room: \(display($0.0)) (\(Int($0.1))% used)." } ?? "" : ""
        due(account, u).forEach { notify($0 + hint, display(account)) }
        resets(account, u).forEach { notify($0, display(account)) }
    }

    // One point per 5 minutes per account, 7 days kept: enough for the pace estimate and the sparkline, and a small file.
    func record(_ a: String, _ u: Usage) {
        var h = history[a] ?? []
        if let last = h.last, Date().timeIntervalSince(last.at) < 300 { return }
        h.append(Sample(at: Date(), s: u.five_hour?.utilization, w: u.seven_day?.utilization))
        h.removeAll { $0.at.timeIntervalSinceNow < -7 * 86400 }
        history[a] = h
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: historyURL)
    }

    // A window has reset when the reset time last seen for it has passed and a newer reading no longer shows it.
    func resets(_ account: String, _ u: Usage) -> [String] {
        var out: [String] = []
        for (key, name, w) in [("5h", "Session (5h)", u.five_hour), ("7d", "Week", u.seven_day)] {
            let k = "\(account) \(key)", next = w.flatMap(resetDate)
            if let prev = resetSeen[k], prev <= Date(), next.map({ abs($0.timeIntervalSince(prev)) > 60 }) ?? true {
                if resetsOn(account, key) { out.append("\(name) limit has reset: back to full") }
                resetSeen[k] = nil
            }
            if let next, next > Date() { resetSeen[k] = next }
        }
        return out
    }

    // Reset notifications: one setting per window (5-hour and week) in General, for every account.
    func resetsOn(_ account: String, _ key: String) -> Bool { key == "5h" ? resetSessionOn : resetWeekOn }

    // From this window's readings over the last hour (session) or 12 hours (week); nil until there are 10+ minutes of them.
    func pace(_ a: String, session: Bool) -> String? {
        guard let now = known[a], let w = session ? now.usage.five_hour : now.usage.seven_day,
              let reset = resetDate(w), reset > Date() else { return nil }
        let start = max(reset.addingTimeInterval(session ? -5 * 3600 : -7 * 86400), now.at.addingTimeInterval(session ? -3600 : -12 * 3600))
        guard let first = (history[a] ?? []).first(where: { $0.at >= start && (session ? $0.s : $0.w) != nil }),
              let v0 = session ? first.s : first.w, now.at.timeIntervalSince(first.at) >= 600 else { return nil }
        let rate = (w.utilization - v0) / now.at.timeIntervalSince(first.at)  // % per second
        let left = showLeft, name = session ? "Session" : "Week"
        if rate <= 0 { return "\(name) pace: no recent use" }
        let toFull = (100 - w.utilization) / rate
        if toFull < reset.timeIntervalSinceNow { return "\(name) pace: \(left ? "runs out" : "100%") in \(duration(toFull))" }
        let atReset = min(100, w.utilization + rate * reset.timeIntervalSinceNow).rounded()
        return "\(name) pace: about \(left ? "\(Int(100 - atReset))% left" : "\(Int(atReset))%") at reset"
    }

    // The other saved account with the most room (lowest of its higher window), if it has more room than this one.
    func roomiest(than a: String) -> (String, Double)? {
        let mine = max(used(usage?.five_hour), used(usage?.seven_day))
        return accounts.filter { $0 != a }
            .compactMap { b in known[b].map { (b, max(used($0.usage.five_hour), used($0.usage.seven_day))) } }
            .filter { $0.1 < mine }.min { $0.1 < $1.1 }
    }
    var suggestion: (String, Double)? {
        [usage?.five_hour, usage?.seven_day].contains { used($0) >= Double(dotSetting("red")) } ? roomiest(than: email) : nil
    }

    // Each alert fires once per usage window. The window is keyed by its reset minute, since resets_at jitters by a fraction of a second.
    func due(_ account: String, _ u: Usage) -> [String] {
        var out: [String] = []
        for rule in alerts[account] ?? [] {
            let parts = rule.split(separator: ":")
            let isSession = parts[0] == "5h", limit = Double(parts[1]) ?? 101
            guard let w = isSession ? u.five_hour : u.seven_day, w.utilization >= limit,
                  let reset = resetDate(w), reset > Date() else { continue }  // past windows are stale figures
            let key = "\(account) \(rule)", window = Int((reset.timeIntervalSince1970 / 60).rounded())
            if fired[key] == window { continue }
            fired[key] = window
            let left = showLeft, set = left ? "\(100 - Int(limit))% left" : "\(Int(limit))%"
            out.append("\(isSession ? "Session (5h)" : "Week"): \(percent(w, left)), alert set at \(set)")
        }
        defaults.set(fired, forKey: "fired")
        return out
    }

    func readConfig() {
        let date = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
        if date == configDate { return }  // unchanged since the last read
        configDate = date
        let config = (try? Data(contentsOf: URL(fileURLWithPath: configPath)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let account = config?["oauthAccount"] as? [String: Any]
        email = account?["emailAddress"] as? String ?? "Not logged in"
        accountUuid = account?["accountUuid"] as? String
        cache = config?["cachedUsageUtilization"] as? [String: Any]
        accounts = ((try? String(contentsOfFile: home + "/.claude/switch-accounts", encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func liveToken() -> String? {
        if let t = token, t.email == email, t.expires > Date().timeIntervalSince1970 { return t.value }
        let r = run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"])
        token = r.ok ? accessToken(r.out).map { (email, $0.value, $0.expires) } : nil
        return token?.value
    }

    func refresh(force: Bool = false) {
        readConfig()
        retime()
        weeklyRecap()
        counter.update { [weak self] in
            guard let self else { return }
            self.tokensToday = self.counter.today
            self.readLive()
        }
        // Other accounts are only polled when they have alerts; the usage on them can move if they're in use on another machine.
        for (a, rules) in alerts where a != email && !rules.isEmpty && accounts.contains(a) { loadAccount(a) }
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < Double(intervalFor(email)) - 1 { return }  // not due yet
        if !force, let until = backoffUntil, Date() < until { return }
        lastFetch = Date()
        guard let t = liveToken() else { return show(nil, "Login token expired: open Claude to refresh it") }
        let account = email
        fetchUsage(t) { u, code in
            if code == 401 { self.token = nil }  // revoked or refreshed elsewhere; read the Keychain again next time
            self.noteRateLimit(code)
            if let u { self.remember(account, u) }
            self.show(u, failure(code))
        }
    }

    func noteRateLimit(_ code: Int) {
        if code == 429 {
            rateLimits += 1
            backoffUntil = Date().addingTimeInterval(min(900, Double(intervalFor(email)) * pow(2, Double(rateLimits))))
        } else if code == 200 {
            rateLimits = 0
            backoffUntil = nil
        }
    }

    // Live figures when there are any. Otherwise the newest known ones: this app's last live fetch,
    // or Claude's own cache if that's newer and belongs to this account. Never swap in older figures.
    func show(_ live: Usage?, _ failure: String) {
        notes = []
        if let live { usage = live } else {
            notes.append(failure)
            var best = known[email]
            if let c = cache, c["accountUuid"] as? String == accountUuid,
               let data = try? JSONSerialization.data(withJSONObject: c["utilization"] ?? [:]),
               let u = try? JSONDecoder().decode(Usage.self, from: data) {
                let at = Date(timeIntervalSince1970: (c["fetchedAtMs"] as? Double ?? 0) / 1000)
                if best == nil || at > best!.at { best = Known(usage: u, at: at) }
            }
            usage = best?.usage
            if let b = best { notes.append("Showing figures from \(b.at.formatted(date: .omitted, time: .shortened))") }
        }
        updateTitle()
    }

    // Other accounts are fetched with their saved login: when their details are shown, or for their alerts.
    func loadAccount(_ a: String, force: Bool = false) {
        if !force, let t = lastTry[a], Date().timeIntervalSince(t) < Double(intervalFor(a)) - 1 { return }  // at most once per its refresh interval
        if !force, let until = backoffUntil, Date() < until { return }
        lastTry[a] = Date()
        loading.insert(a)
        DispatchQueue.global().async {
            let r = run("/usr/bin/security", ["find-generic-password", "-s", "claude-switch", "-a", a, "-w"])
            let t = r.ok ? accessToken(r.out) : nil
            DispatchQueue.main.async {
                guard let t else {
                    self.loading.remove(a)
                    self.accountNote[a] = "Saved login expired: switch to it for fresh figures"
                    return
                }
                fetchUsage(t.value) { u, code in
                    self.noteRateLimit(code)
                    self.loading.remove(a)
                    if let u { self.remember(a, u) }
                    self.accountNote[a] = u == nil ? failure(code) : nil
                }
            }
        }
    }

    func refreshAll() {
        configDate = nil
        lastTry = [:]
        refresh(force: true)
        for a in accounts where a != email { loadAccount(a, force: true) }
    }

    func usageOf(_ a: String) -> Usage? { a == email ? usage : known[a]?.usage }

    // MARK: Switching

    // Claude sessions left running keep the old login and write it back when they save, undoing the switch.
    // So when any are running, ask first: quit them and switch, or switch anyway.
    func switchAccount(_ args: [String], announce: Bool = false) {
        if args.isEmpty && accounts.filter({ $0 != email }).isEmpty { return claudeSwitch(args, announce: announce) }  // nothing to switch to
        DispatchQueue.global().async {
            let r = run(switchPath, ["running"])
            let procs = r.ok ? r.out.split(separator: "\n").map(String.init) : []
            DispatchQueue.main.async {
                guard !procs.isEmpty else { return self.claudeSwitch(args, announce: announce) }
                let inEditor = procs.filter { $0.hasSuffix("\teditor") }.count, inTerminal = procs.count - inEditor
                let places = [inEditor > 0 ? "\(inEditor) in VS Code" : nil, inTerminal > 0 ? "\(inTerminal) in a terminal" : nil]
                    .compactMap { $0 }.joined(separator: " and ")
                self.closePanel()
                let alert = NSAlert()
                alert.messageText = "Claude is running (\(places))"
                alert.informativeText = "Running sessions keep using \(self.display(self.email)), and put it back when they save, undoing the switch. "
                    + "Quitting them stops what they're doing; their conversations are kept, so you can pick them up again "
                    + "(VS Code: open Claude and choose a past conversation; terminal: claude --resume)."
                alert.addButton(withTitle: "Quit Them and Switch")
                alert.addButton(withTitle: "Switch Anyway")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)  // menu bar apps aren't frontmost, so the dialog would open behind other windows
                switch alert.runModal() {
                case .alertFirstButtonReturn: self.claudeSwitch(["--quit-running"] + args, announce: announce)
                case .alertSecondButtonReturn: self.claudeSwitch(args, announce: announce)
                default: break
                }
            }
        }
    }

    // A session still running can switch the login back a little later: look again after a while, and say so if it did.
    func watchSwitch(to target: String) {
        switchedTo = target
        for delay in [15.0, 90.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.switchedTo == target else { return }
                self.configDate = nil
                self.readConfig()
                guard self.email != target else { return }
                self.switchedTo = nil
                let text = "The switch to \(self.display(target)) was undone: a Claude session still running put \(self.display(self.email)) back. Quit it, then switch again."
                self.banner = text
                notify(text, "Claude Switch")
                self.refresh(force: true)
            }
        }
    }

    func claudeSwitch(_ args: [String], announce: Bool = false) {
        switching = true
        DispatchQueue.global().async {
            let r = run(switchPath, args)
            DispatchQueue.main.async {
                self.switching = false
                let lines = r.out.split(separator: "\n").map(String.init)
                self.banner = lines.isEmpty ? nil : lines.joined(separator: "\n")
                if announce, let first = lines.first(where: { $0.hasPrefix("Switched") }) ?? lines.first {
                    notify(first, "Claude Switch")  // from the shortcut there's no panel to show it in
                }
                self.configDate = nil
                self.refresh(force: true)
                if r.ok, let line = lines.first(where: { $0.hasPrefix("Switched: ") }), let target = line.split(separator: " ").last {
                    self.watchSwitch(to: String(target))
                }
                if !r.ok {
                    self.closePanel()
                    let alert = NSAlert()
                    alert.messageText = "That didn't work"
                    alert.informativeText = r.out
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }
    func save() { claudeSwitch(["save"]) }

    func removeAccount(_ a: String) {
        guard a != email else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(display(a))?"
        alert.informativeText = "Claude Switch forgets \(a) and its saved login. To use it again, add it with Add Account."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        known[a] = nil
        claudeSwitch(["remove", a])
    }

    // Signing in needs a browser and may ask for a pasted code, so `claude-switch add` runs in Terminal.
    // The new account shows up once ~/.claude.json changes.
    func addAccount() {
        closePanel()
        openCommand("add-account", "exec \"$HOME/.local/bin/claude-switch\" add")
    }

    // MARK: Waiting, sessions and requests

    // A new line gets a notification; a line that's gone (deleted, cleared, or answered in Claude) takes its notification with it.
    func readAttention() {
        let lines = ((try? String(contentsOfFile: attentionPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let now = Set(lines)
        if let seen = seenAttention {
            let gone = seen.subtracting(now).map { "waiting " + $0 }
            if !gone.isEmpty && isApp { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone) }
            for l in lines where !seen.contains(l) {
                guard let w = Waiting(l) else { continue }
                notify(w.text, "\(w.project) · \(w.place.label)", title: "Claude is waiting", id: "waiting " + l, category: "waiting",
                       info: placeInfo(w.place, ["raw": l]))
            }
        }
        seenAttention = now
        attention = lines.suffix(5).reversed().compactMap(Waiting.init)
        updateTitle()
    }
    func writeAttention(_ lines: [String]) {
        try? lines.map { $0 + "\n" }.joined().write(toFile: attentionPath, atomically: false, encoding: .utf8)  // in place: the watch keeps working
    }
    func deleteWaiting(_ w: Waiting) {
        var lines = ((try? String(contentsOfFile: attentionPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        if let k = lines.lastIndex(of: w.raw) { lines.remove(at: k) }
        writeAttention(lines)
    }
    func clearWaiting() { writeAttention([]) }

    // Sessions: tokens joined in from the conversation logs; one that ends is kept as recent (to resume); one that
    // finishes a turn gets a notification when that's on.
    func readLive() {
        var list = readSessions()
        for k in list.indices { list[k].tokens = counter.bySession[list[k].sid] ?? 0 }
        let current = Set(list.map(\.file))
        for old in sessions where !current.contains(old.file) {
            recent.removeAll { $0.sid == old.sid }
            recent.insert(Recent(sid: old.sid, project: old.project, folder: old.place.folder, editor: old.place.editor, ended: Date()), at: 0)
        }
        recent = Array(recent.filter { $0.ended.timeIntervalSinceNow > -3 * 86400 && !current.contains(sessionsPath + "/" + $0.sid) }.prefix(5))
        defaults.set(try? JSONEncoder().encode(recent), forKey: "recent")
        for s in list {
            if notifyFinished, s.state == .done, let was = lastState[s.file], was != .done {
                let edits = s.files.isEmpty ? "" : " · \(s.files.count) file\(s.files.count == 1 ? "" : "s"), +\(s.added) −\(s.removed)"
                notify("Finished\(edits)", "\(s.project) · \(s.place.label)", title: "Claude is done", id: "done " + s.sid, info: placeInfo(s.place))
            }
            lastState[s.file] = s.state
        }
        if sessions != list { sessions = list }
        notch?.update()
    }
    func deleteSession(_ s: Live) {
        try? FileManager.default.removeItem(atPath: s.file)
        try? FileManager.default.removeItem(atPath: s.file + ".files")
    }
    func clearSessions() { sessions.forEach(deleteSession) }

    // Requests: a new one gets a notification with Allow/Deny (or, for a question, Answer in Claude).
    func readRequests() {
        let list = Request.read(), ids = Set(list.map(\.id))
        if let seen = seenRequests {
            let gone = seen.subtracting(ids).map { "request " + $0 }
            if !gone.isEmpty && isApp { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone) }
            for r in list where !seen.contains(r.id) {
                if r.isQuestion {
                    notify(r.questions.first?.question ?? "Claude has a question", "\(r.project) · \(r.place.label)", title: "Claude asks",
                           id: "request " + r.id, category: "question", info: placeInfo(r.place, ["request": r.id]))
                } else {
                    notify(r.detail, "\(r.project) · \(r.place.label)", title: "Allow \(r.tool)?", id: "request " + r.id, category: "permission",
                           info: placeInfo(r.place, ["request": r.id]))
                }
            }
        }
        seenRequests = ids
        if requests != list { requests = list }
        updateTitle()
        if !list.isEmpty && seenRequests != nil { notch?.attention() }
    }
    func answer(_ r: Request, _ text: String) {
        r.answer(text)
        requests.removeAll { $0.id == r.id }
        updateTitle()
    }
    func answer(_ r: Request, message: String) {
        r.answer(message: message)
        requests.removeAll { $0.id == r.id }
        updateTitle()
    }
    func answer(_ r: Request, _ answers: [(question: String, answer: String)]) {
        r.answer(answers)
        requests.removeAll { $0.id == r.id }
        updateTitle()
    }

    var needsYou: Int { requests.count + attention.count }

    // MARK: Going places

    func placeInfo(_ p: Place, _ extra: [String: String] = [:]) -> [String: String] {
        extra.merging(["host": p.host, "folder": p.folder, "editor": p.editor ? "1" : "", "tty": p.tty]) { a, _ in a }
    }

    // Where it came from, when that's known: the editor window for the folder, or the exact terminal tab.
    // Otherwise nothing opens (never a Finder window or another app instead).
    func goTo(_ p: Place) {
        closePanel()
        guard p.known else { return }
        if !p.tty.isEmpty, let script = tabScript(p.host, p.tty) {
            DispatchQueue.global().async {
                if !run("/usr/bin/osascript", ["-e", script]).ok { _ = run("/usr/bin/open", ["-b", p.host]) }
            }
            return
        }
        let args = p.editor && !p.folder.isEmpty ? ["-b", p.host, p.folder] : ["-b", p.host]
        DispatchQueue.global().async { _ = run("/usr/bin/open", args) }
    }
    func tabScript(_ host: String, _ tty: String) -> String? {
        switch host {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return
                  end if
                end repeat
              end repeat
              activate
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                      activate
                      return
                    end if
                  end repeat
                end repeat
              end repeat
              activate
            end tell
            """
        default: return nil
        }
    }

    // A small .command script opened in Terminal: for signing in, and for resuming a session.
    func openCommand(_ name: String, _ body: String) {
        let script = supportDir + "/\(name).command"
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        try? "#!/bin/bash\n\(body)\n".write(toFile: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        DispatchQueue.global().async { _ = run("/usr/bin/open", [script]) }
    }
    func resume(_ r: Recent) {
        closePanel()
        if r.editor { return goTo(Place(host: "com.microsoft.VSCode", folder: r.folder, editor: true)) }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        openCommand("resume", "cd \(q(r.folder)) && exec claude --resume \(q(r.sid))")
    }

    func jumpToWaiting() {
        if let r = requests.first { return r.isQuestion || !r.place.known ? showPanel() : goTo(r.place) }
        if let w = attention.first, w.place.known { return goTo(w.place) }
        if let s = sessions.first(where: { $0.state == .waiting }) { return goTo(s.place) }
        NSSound.beep()
    }
    func showPanel() { if !popover.isShown { togglePanel() } }

    // MARK: Notifications

    // A click goes where the notification came from (or just closes it). Delete removes that waiting entry;
    // Allow / Deny answer a permission prompt; Answer in Claude hands a question back.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            let place = Place(host: info["host"] ?? "", folder: info["folder"] ?? "", editor: info["editor"] == "1", tty: info["tty"] ?? "")
            let request = info["request"].flatMap { id in self.requests.first { $0.id == id } }
            switch action {
            case "delete": if let raw = info["raw"], let w = Waiting(raw) { self.deleteWaiting(w) }
            case "allow", "deny", "claude": if let r = request { self.answer(r, action) }
            case UNNotificationDefaultActionIdentifier:
                if info["recap"] != nil { self.showRecap() } else if let r = request, r.isQuestion { self.showPanel() } else { self.goTo(place) }
            default: break
            }
            done()
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // MARK: Hooks, recap, hotkeys, windows

    func runHooks(_ action: String) {
        DispatchQueue.global().async {
            let r = run(switchPath, ["hooks", action])
            DispatchQueue.main.async {
                self.banner = r.out
                self.hooksMissingList = hooksMissing()
            }
        }
    }
    func loadRules() {
        DispatchQueue.global().async {
            let list = run(switchPath, ["rules", "list"]).out.split(separator: "\n").map(String.init)
            DispatchQueue.main.async { self.rules = list }
        }
    }
    func removeRule(_ rule: String) {
        DispatchQueue.global().async {
            _ = run(switchPath, ["rules", "remove", rule])
            self.loadRules()
        }
    }
    func hooksPreview(_ action: String) -> String { run(switchPath, ["hooks", "preview", action]).out }
    func recapText(_ days: Int = 7) -> String { run(switchPath, ["recap", "\(days)"]).out }

    // Mondays: a notification with last week's summary, once per week.
    func weeklyRecap() {
        guard recapOn, isApp else { return }
        let cal = Calendar.current, now = Date(), week = "\(cal.component(.yearForWeekOfYear, from: now))-\(cal.component(.weekOfYear, from: now))"
        guard cal.component(.weekday, from: now) == 2, cal.component(.hour, from: now) >= 9, defaults.string(forKey: "recapWeek") != week else { return }
        defaults.set(week, forKey: "recapWeek")
        DispatchQueue.global().async {
            let text = self.recapText()
            guard !text.hasPrefix("No activity") else { return }
            DispatchQueue.main.async { notify(text, "Last 7 days", title: "Your week with Claude", id: "recap", info: ["recap": "1"]) }
        }
    }
    // Settings and the recap open inside the panel, with a Back button: path is the stack of pages shown over home.
    func open(_ pages: [Page]) {
        path = pages
        showPanel()
    }
    func showRecap() { open([.recap]) }
    func showSettings(_ page: Page? = nil) { open(page.map { $0 == .settings ? [.settings] : [.settings, $0] } ?? [.settings]) }
    func back() { if !path.isEmpty { path.removeLast() } }
    func popoverDidClose(_ n: Notification) {
        path = []
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
    }

    // Control-Option-Command-S switches to the next account; Control-Option-Command-J goes to what Claude is waiting on.
    // Carbon hot keys need no Accessibility permission.
    func registerHotKeys() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        for (on, key, id) in [(hotKeyOn, kVK_ANSI_S, UInt32(1)), (jumpKeyOn, kVK_ANSI_J, UInt32(2)), (allowKeyOn, kVK_ANSI_A, UInt32(3))] where on {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey | controlKey), EventHotKeyID(signature: 0x43535754, id: id),
                                GetApplicationEventTarget(), 0, &ref)
            if let ref { hotKeys.append(ref) }
        }
    }
    func hotKeyPressed(_ id: UInt32) {
        switch id {
        case 1: switchAccount([], announce: true)
        case 3:  // allow the oldest permission prompt without opening anything
            if let r = requests.first(where: { !$0.isQuestion }) {
                answer(r, "allow")
                notify(r.detail, "\(r.project) · \(r.place.label)", title: "Allowed \(toolName(r.tool))")
            } else { NSSound.beep() }
        default: jumpToWaiting()
        }
    }

    func mute(for seconds: TimeInterval?) {
        muteUntil = seconds.map { Date().addingTimeInterval($0) }
    }
    func muteUntilTomorrow() {
        let cal = Calendar.current
        muteUntil = cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date())!)
    }
    func muteAlways() { muteUntil = .distantFuture }  // until unmuted
    var muteText: String {
        guard isMuted, let until = muteUntil else { return "" }
        if until > Date().addingTimeInterval(5 * 365 * 86400) { return "Muted until you unmute" }
        let style: Date.FormatStyle = Calendar.current.isDateInToday(until) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).day().month().hour().minute()
        return "Muted until \(until.formatted(style))"
    }

    func quit() { NSApp.terminate(nil) }
}
