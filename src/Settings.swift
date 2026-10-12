// Claude Switch: the settings pages, shown inside the panel. Built from the same cards and rows as the panel, and sized
// to their content so the panel grows and shrinks with each page.
import SwiftUI

// A titled group of rows in a card, with hairlines between rows.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { SectionTitle(title) }
            Card(padding: 0) {
                _VariadicView.Tree(Rows()) { content }
            }
            if let footer { Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true) }
        }
    }
    struct Rows: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { k, child in
                    if k > 0 { Divider().padding(.leading, 12) }
                    child
                }
            }
        }
    }
}

// One setting: a label (with an optional note under it) and its control on the right.
struct Row<Control: View>: View {
    let label: String
    var note: String? = nil
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: note == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12.5))
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minHeight: 38)
    }
}

struct Switch: View {
    let isOn: Binding<Bool>
    var body: some View { Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(brand) }
}

// Navigates to a page.
struct LinkRow: View {
    @EnvironmentObject var app: App
    let page: Page
    let symbol: String
    let color: Color
    let detail: String
    var body: some View {
        HoverRow(action: { app.path.append(page) }) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(page.title).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        } accessory: {
            EmptyView()
        }
        .overlay(alignment: .trailing) { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).padding(.trailing, 10) }
        .padding(4)
    }
}

struct SettingsHome: View {
    @EnvironmentObject var app: App
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup {
                LinkRow(page: .general, symbol: "gearshape.fill", color: .gray, detail: "Login, shortcuts, notifications")
                LinkRow(page: .menubar, symbol: "menubar.rectangle", color: .blue, detail: "What the menu bar shows")
                LinkRow(page: .claude, symbol: "terminal.fill", color: brand,
                        detail: app.hooksMissingList.isEmpty ? "Hooks set up" + (app.approvalsOn ? " · approvals on" : "") : "Hooks not set up")
                LinkRow(page: .notch, symbol: "rectangle.topthird.inset.filled", color: .purple, detail: app.notchOn ? "On" : "Off")
                LinkRow(page: .accounts, symbol: "person.2.fill", color: .green, detail: "\(max(1, app.accounts.count)) saved")
            }
            SettingsGroup {
                LinkRow(page: .recap, symbol: "chart.bar.xaxis", color: .orange, detail: "What Claude did this week")
            }
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Text("Made with")
                    Image(systemName: "heart.fill").foregroundStyle(brand).font(.system(size: 10))
                    Text("by Saransh")
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text("Claude Switch \(prettyVersion(appVersion))").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.top, 4)
        }
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var app: App
    @State private var hours = 1
    @State private var minutes = 0
    @State private var until = Date().addingTimeInterval(2 * 3600)
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup {
                Row(label: "Open at login") { Switch(isOn: $app.openAtLogin) }
                Row(label: "Show usage as") {
                    Picker("", selection: $app.showLeft) {
                        Text("Used").tag(false)
                        Text("Remaining").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            SettingsGroup(footer: "Off: the panel and notch only show what Claude needs from you.") {
                Row(label: "Show Claude sessions") { Switch(isOn: $app.showSessions) }
            }
            SettingsGroup(title: "Keyboard shortcuts") {
                Row(label: "Switch to the next account") { HStack(spacing: 8) { keys("⌃⌥⌘S"); Switch(isOn: $app.hotKeyOn) } }
                Row(label: "Go to what Claude is waiting on") { HStack(spacing: 8) { keys("⌃⌥⌘J"); Switch(isOn: $app.jumpKeyOn) } }
                Row(label: "Allow the oldest permission prompt") { HStack(spacing: 8) { keys("⌃⌥⌘A"); Switch(isOn: $app.allowKeyOn) } }
            }
            SettingsGroup(title: "Notifications") {
                Row(label: "When Claude is waiting on you") { Switch(isOn: $app.waitingOn) }
                Row(label: "When Claude finishes") { Switch(isOn: $app.notifyFinished) }
                Row(label: "Session (5-hour) limit resets") { Switch(isOn: $app.resetSessionOn) }
                Row(label: "Weekly limit resets") { Switch(isOn: $app.resetWeekOn) }
                Row(label: "Weekly recap on Mondays") { Switch(isOn: $app.recapOn) }
            }
            SettingsGroup(title: "Mute", footer: "Mute silences every notification, for all accounts. The panel, menu bar and notch still update.") {
                Row(label: isMuted ? app.muteText : "Notifications are on") {
                    if isMuted {
                        Button("Unmute") { app.mute(for: nil) }.controlSize(.small)
                    } else {
                        Menu("Mute") { MuteChoices() }.controlSize(.small).fixedSize()
                    }
                }
                Row(label: "Mute for") {
                    HStack(spacing: 6) {
                        Stepper(value: $hours, in: 0...72) { Text("\(hours) h").monospacedDigit().frame(width: 36, alignment: .trailing) }
                        Stepper(value: $minutes, in: 0...55, step: 5) { Text("\(minutes) min").monospacedDigit().frame(width: 48, alignment: .trailing) }
                        Button("Mute") { app.mute(for: TimeInterval(hours * 3600 + minutes * 60)) }.controlSize(.small).disabled(hours == 0 && minutes == 0)
                    }
                }
                Row(label: "Mute until") {
                    HStack(spacing: 6) {
                        DatePicker("", selection: $until, in: Date()..., displayedComponents: [.date, .hourAndMinute]).labelsHidden().datePickerStyle(.field)
                        Button("Mute") { app.muteUntil = until }.controlSize(.small)
                    }
                }
                Row(label: "Mute until I turn it back on") {
                    Switch(isOn: Binding(get: { (app.muteUntil ?? .distantPast) > Date().addingTimeInterval(5 * 365 * 86400) },
                                         set: { $0 ? app.muteAlways() : app.mute(for: nil) }))
                }
            }
        }
    }
    func keys(_ k: String) -> some View {
        Text(k).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.4)))
    }
}

struct MenuBarSettings: View {
    @EnvironmentObject var app: App
    let presets = ["", " ", " · ", " | ", " / "]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Text(previewText).font(.system(size: 13, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                Spacer()
            }
            SettingsGroup(title: "Menu bar") {
                Row(label: "Shows") {
                    Picker("", selection: $app.barModes) {
                        Text("Session and week").tag("both")
                        Text("Session only").tag("session")
                        Text("Week only").tag("week")
                        Text("Dots only").tag("dots")
                    }
                    .labelsHidden().fixedSize()
                }
                Row(label: "Labels") {
                    Picker("", selection: $app.barLabels) {
                        Text("5h · 7d").tag("full")
                        Text("S · W").tag("short")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Row(label: "Between the two") {
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(get: { presets.contains(app.barDelimiter) ? app.barDelimiter : "custom" },
                                                      set: { if $0 != "custom" { app.barDelimiter = $0 } else if presets.contains(app.barDelimiter) { app.barDelimiter = " ~ " } })) {
                            Text("Nothing").tag("")
                            Text("Space").tag(" ")
                            Text("·").tag(" · ")
                            Text("|").tag(" | ")
                            Text("/").tag(" / ")
                            Text("Custom").tag("custom")
                        }
                        .labelsHidden().fixedSize()
                        if !presets.contains(app.barDelimiter) {
                            TextField("", text: $app.barDelimiter).frame(width: 50).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            SettingsGroup(title: "Status dots") {
                Row(label: "Coloured dot for each window") {
                    Switch(isOn: Binding(get: { app.dotSetting("show") == 1 }, set: { app.dots["show"] = $0 ? 1 : 0 }))
                }
                threshold("Yellow", "yellow", .orange)
                threshold("Red", "red", .red)
            }
        }
    }
    var previewText: String {
        let short = app.barLabels == "short", u = app.usage, left = app.showLeft
        let s = "\(short ? "S" : "5h") \(percent(u?.five_hour, left, word: false))", w = "\(short ? "W" : "7d") \(percent(u?.seven_day, left, word: false))"
        switch app.barModes {
        case "session": return s
        case "week": return w
        case "dots": return "● ●"
        default: return s + app.barDelimiter + w
        }
    }
    func threshold(_ name: String, _ key: String, _ color: Color) -> some View {
        let v = app.dotSetting(key), left = app.showLeft
        return Row(label: left ? "\(name) at \(100 - v)% left or less" : "\(name) from \(v)% used") {
            Stepper("", value: Binding(get: { left ? 100 - v : v }, set: { app.dots[key] = left ? 100 - $0 : $0 }), in: left ? 0...99 : 1...100, step: 5)
                .labelsHidden()
                .overlay(alignment: .leading) { Circle().fill(color).frame(width: 8, height: 8).offset(x: -16) }
        }
    }
}

struct ClaudeSettings: View {
    @EnvironmentObject var app: App
    @State private var preview: String?
    var installed: Bool { app.hooksMissingList.isEmpty }
    var none: Bool { app.hooksMissingList.count >= hookParts }
    // Other apps with a PermissionRequest hook, named by the folder or file their command runs.
    var others: [String] {
        let o = (try? Data(contentsOf: URL(fileURLWithPath: settingsPath))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let groups = (o?["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
        let commands = groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }.filter { !$0.contains("claude-switch") }
        return Array(Set(commands.map { c in
            let parts = c.replacingOccurrences(of: "\"", with: "").split(separator: "/")
            return parts.count > 1 ? String(parts[parts.count - 2]) : String(parts.last ?? "another app")
        })).sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: installed ? "checkmark.seal.fill" : none ? "seal" : "exclamationmark.triangle.fill")
                        .font(.system(size: 22)).foregroundStyle(installed ? .green : none ? .secondary : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(installed ? "Claude hooks are set up" : none ? "Claude hooks are not set up" : "Claude hooks are partly set up")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Claude Code tells Claude Switch what each session is doing: status, edits, tokens, when it needs you, and when it's done. Your other hooks stay as they are.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !installed && !none {
                            Text("Missing: \(app.hooksMissingList.joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                }
            }
            SettingsGroup(footer: "Sessions already running pick up changes when they're restarted.") {
                Row(label: "Claude hooks") {
                    Switch(isOn: Binding(get: { installed }, set: { on in
                        if on { preview = app.hooksPreview("install") } else { preview = nil; app.runHooks("remove") }
                    }))
                }
            }
            if let preview {
                VStack(alignment: .leading, spacing: 8) {
                    Text("These changes will be made to ~/.claude/settings.json (the current file is kept as settings.json.before-claude-switch):")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Text(diffText(preview)).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                    HStack {
                        Spacer()
                        Button("Cancel") { self.preview = nil }
                        Button("Set Up Hooks") { app.runHooks("install"); self.preview = nil }.buttonStyle(.borderedProminent).tint(brand)
                    }
                }
            }
            if !others.isEmpty {
                Card {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("\(others.joined(separator: ", ")) also answer\(others.count == 1 ? "s" : "") Claude's permission prompts. With two apps answering, a prompt can show in both or be answered by the other one first. Keep approvals on in only one of them.")
                            .font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SettingsGroup(title: "Approvals", footer: "While Claude Switch isn't running, Claude asks the usual way. \"Answer in Claude\" on any request hands it back.") {
                Row(label: "Answer prompts and questions here",
                    note: "Allow or deny what Claude wants to do, and answer its questions, from the panel, the notch or the notification.") {
                    Switch(isOn: $app.approvalsOn).disabled(!installed)
                }
                Row(label: "Wait for your answer", note: "Then Claude asks in its own window instead.") {
                    Picker("", selection: $app.requestWait) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("1 hour").tag(3600)
                        Text("Until I answer").tag(86000)
                        if ![60, 300, 900, 3600, 86000].contains(app.requestWait) { Text("\(app.requestWait) seconds").tag(app.requestWait) }
                    }
                    .labelsHidden().fixedSize().disabled(!app.approvalsOn)
                }
            }
            SettingsGroup(title: "Always allowed", footer: "Rules in ~/.claude/settings.json that let Claude go ahead without asking, in every project. Always Allow on a prompt adds one here (or to the project's own settings, when Claude suggests that).") {
                if app.rules.isEmpty {
                    Row(label: "None yet") { EmptyView() }
                }
                ForEach(app.rules, id: \.self) { rule in
                    Row(label: rule) {
                        Button { app.removeRule(rule) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Remove: Claude asks again for this")
                    }
                }
            }
            .onAppear { app.loadRules() }
        }
    }
    func diffText(_ diff: String) -> AttributedString {
        var out = AttributedString()
        for l in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            var a = AttributedString(String(l) + "\n")
            if l.hasPrefix("+") && !l.hasPrefix("+++") { a.foregroundColor = .green } else if l.hasPrefix("-") && !l.hasPrefix("---") { a.foregroundColor = .red }
            else if l.hasPrefix("@@") { a.foregroundColor = .secondary }
            out += a
        }
        return out
    }
}

struct NotchSettings: View {
    @EnvironmentObject var app: App
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(footer: "A small island around the notch (or at the top of the screen on displays without one) shows what Claude is doing. Point at it to see your sessions and answer requests.") {
                Row(label: "Show Claude in the notch") { Switch(isOn: $app.notchOn) }
                Row(label: "Visible") {
                    Picker("", selection: $app.notchAlways) {
                        Text("When active").tag(false)
                        Text("Always").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().disabled(!app.notchOn)
                }
            }
        }
    }
}

struct AccountsPage: View {
    @EnvironmentObject var app: App
    var all: [String] { [app.email] + app.accounts.filter { $0 != app.email } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup {
                ForEach(all, id: \.self) { a in
                    HoverRow(action: { app.path.append(.account(a)) }) {
                        Avatar(name: app.display(a), size: 26, active: a == app.email)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.display(a)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text(a == app.email ? "Current · \(a)" : a).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } accessory: { EmptyView() }
                    .overlay(alignment: .trailing) { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).padding(.trailing, 10) }
                    .padding(4)
                }
            }
            HStack {
                Button { app.addAccount() } label: { Label("Add Account", systemImage: "plus") }
                Spacer()
                Button { app.save() } label: { Label("Save Current Login", systemImage: "square.and.arrow.down") }
            }
            .buttonStyle(.borderless).font(.system(size: 12)).padding(.horizontal, 4)
        }
    }
}

struct AccountDetail: View {
    @EnvironmentObject var app: App
    let a: String
    @State private var name = ""
    @State private var newSession = 80
    @State private var newWeek = 90
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Avatar(name: app.display(a), size: 40, active: a == app.email)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.display(a)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(a == app.email ? "Current account" : a).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
            SettingsGroup {
                Row(label: "Nickname") {
                    TextField("None", text: $name).textFieldStyle(.roundedBorder).frame(width: 150).multilineTextAlignment(.trailing)
                        .onSubmit(saveName).onChange(of: name) { _ in saveName() }
                }
                Row(label: "Refresh every") {
                    Picker("", selection: Binding(get: { app.intervalFor(a) }, set: { app.intervals[a] = $0 })) {
                        ForEach([15, 30, 60, 120, 300], id: \.self) { Text($0 < 60 ? "\($0) seconds" : "\($0 / 60) minute\($0 == 60 ? "" : "s")").tag($0) }
                        if ![15, 30, 60, 120, 300].contains(app.intervalFor(a)) { Text("\(app.intervalFor(a)) seconds").tag(app.intervalFor(a)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsGroup(title: "Notify when limits reset", footer: app.resetSessionOn && app.resetWeekOn ? nil : "Turned off for every account in General → Notifications.") {
                Row(label: "Session (5-hour) limit") {
                    Switch(isOn: Binding(get: { app.resetsOn(a, "5h") }, set: { app.setResets(a, "5h", $0) })).disabled(!app.resetSessionOn)
                }
                Row(label: "Weekly limit") {
                    Switch(isOn: Binding(get: { app.resetsOn(a, "7d") }, set: { app.setResets(a, "7d", $0) })).disabled(!app.resetWeekOn)
                }
            }
            SettingsGroup(title: "Alerts") {
                ForEach((app.alerts[a] ?? []).sorted(), id: \.self) { rule in
                    Row(label: describe(rule)) {
                        Button { app.alerts[a]?.removeAll { $0 == rule } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Remove this alert")
                    }
                }
                addRow("Session", "5h", $newSession)
                addRow("Week", "7d", $newWeek)
            }
            if a != app.email {
                Button("Remove This Account…", role: .destructive) { app.removeAccount(a) }.buttonStyle(.borderless).foregroundStyle(.red)
                    .font(.system(size: 12)).padding(.horizontal, 4)
            }
        }
        .onAppear { name = app.names[a] ?? "" }
    }
    func saveName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if app.names[a] != (n.isEmpty ? nil : n) { app.names[a] = n.isEmpty ? nil : n }
    }
    func describe(_ rule: String) -> String {
        let p = rule.split(separator: ":"), v = Int(p.last ?? "") ?? 0
        return "\(p.first == "5h" ? "Session" : "Week") at " + (app.showLeft ? "\(100 - v)% left" : "\(v)% used")
    }
    func addRow(_ label: String, _ metric: String, _ value: Binding<Int>) -> some View {
        Row(label: "\(label) at \(app.showLeft ? "\(100 - value.wrappedValue)% left" : "\(value.wrappedValue)% used")") {
            HStack(spacing: 6) {
                Stepper("", value: value, in: 5...100, step: 5).labelsHidden()
                Button("Add") {
                    let rule = "\(metric):\(value.wrappedValue)"
                    var list = app.alerts[a] ?? []
                    if !list.contains(rule) { list.append(rule) }
                    app.alerts[a] = list
                    if let u = app.usageOf(a) { app.check(a, u) }  // already past it: say so now
                }
                .controlSize(.small)
            }
        }
    }
}
