// Claude Switch: the panel that opens from the menu bar, and the pieces it shares with the notch island.
import AppKit
import SwiftUI

let brand = Color(red: 0.85, green: 0.47, blue: 0.34)  // Claude's terracotta, used sparingly for emphasis

// The tallest the panel's scrolling part gets: most of the screen it opens on, minus the menu bar and the panel's own header and footer.
var maxHeight: CGFloat { max(320, min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 160)) }

// Pages shown over the panel's home, each with a Back button.
enum Page: Hashable {
    case settings, general, menubar, claude, notch, accounts, account(String), recap
    var title: String {
        switch self {
        case .settings: return "Settings"
        case .general: return "General"
        case .menubar: return "Menu Bar"
        case .claude: return "Claude Code"
        case .notch: return "Notch"
        case .accounts: return "Accounts"
        case .account: return "Account"
        case .recap: return "Activity"
        }
    }
}

// MARK: Building blocks

struct FitKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// Scrolls only when it must: as tall as its content, up to `limit`, so the panel grows and shrinks with what it shows.
struct FitScroll<Content: View>: View {
    var limit: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 120
    var body: some View {
        ScrollView {
            content.background(GeometryReader { g in Color.clear.preference(key: FitKey.self, value: g.size.height) })
        }
        .frame(height: min(height, limit))
        .onPreferenceChange(FitKey.self) { h in if h > 0 && abs(h - height) > 0.5 { height = h } }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct SectionTitle<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            if let count, count > 0 {
                Text("\(count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 2)
    }
}
extension SectionTitle where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil) { self.init(title: title, count: count) { EmptyView() } }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 30
    var active = false
    var body: some View {
        Text(initials(name))
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(active ? brand : Color.gray.opacity(0.55)))
    }
}

struct Bar: View {
    let value: Double  // 0...100
    let color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(color.gradient).frame(width: max(height, g.size.width * min(1, max(0, value / 100))))
                    .opacity(value <= 0 ? 0 : 1)
            }
        }
        .frame(height: height)
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { g in
            if values.count > 1 {
                let step = g.size.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: g.size.height * (1 - CGFloat(min(100, max(0, $0.element))) / 100)) }
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: g.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.25), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in p.addLines(points) }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// How much of the weekly limit went into each of the last 7 days: the rises in the week figure between readings,
// summed per day (the drop when the week resets isn't use, so it's skipped).
struct DayUse: Identifiable { let day: Date; let used: Double; var id: Date { day } }
func dailyUse(_ samples: [Sample]) -> [DayUse] {
    let cal = Calendar.current, today = cal.startOfDay(for: Date())
    var by: [Date: Double] = [:]
    let points = samples.compactMap { s in s.w.map { (s.at, $0) } }
    for (a, b) in zip(points, points.dropFirst()) where b.1 > a.1 {
        by[cal.startOfDay(for: b.0), default: 0] += b.1 - a.1
    }
    return (0..<7).reversed().map { k in
        let d = cal.date(byAdding: .day, value: -k, to: today)!
        return DayUse(day: d, used: by[d] ?? 0)
    }
}

struct DayBars: View {
    let days: [DayUse]
    @State private var hover: Date?
    var body: some View {
        let top = max(days.map(\.used).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { d in
                let today = Calendar.current.isDateInToday(d.day), on = hover == d.day
                VStack(spacing: 4) {
                    Text(d.used >= 0.5 ? "\(Int(d.used.rounded()))%" : "")
                        .font(.system(size: 9.5, weight: today || on ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(today || on ? .primary : .secondary)
                        .frame(height: 11)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(today ? AnyShapeStyle(brand.gradient) : AnyShapeStyle(Color.primary.opacity(on ? 0.35 : 0.18)))
                        .frame(height: max(3, 38 * d.used / top))
                    Text(today ? "Today" : d.day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 9.5, weight: today ? .semibold : .regular))
                        .foregroundStyle(today ? .primary : .secondary)
                        .lineLimit(1).fixedSize()
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { hover = $0 ? d.day : (hover == d.day ? nil : hover) }
                .help("\(d.day.formatted(.dateTime.weekday(.wide).day().month())): \(String(format: "%.1f", d.used))% of the weekly limit")
            }
        }
        .frame(height: 64)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole? = nil
    var hint: Binding<String?>? = nil  // also shown in the card's hint line while hovered (tooltips can be slow or missing in panels)
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { h in
            hover = h
            if let hint { if h { hint.wrappedValue = help } else if hint.wrappedValue == help { hint.wrappedValue = nil } }
        }
    }
}

extension View {
    // Shows `text` in the card's hint line while hovered, and as the tooltip.
    func hint(_ text: String, _ binding: Binding<String?>) -> some View {
        help(text).onHover { h in
            if h { binding.wrappedValue = text } else if binding.wrappedValue == text { binding.wrappedValue = nil }
        }
    }
}

struct HintLine: View {
    let text: String?
    var body: some View {
        if let text {
            Label(text, systemImage: "info.circle").font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}

// A row that highlights on hover, runs `action` on click, and shows `accessory` (e.g. a delete button) while hovered.
struct HoverRow<Content: View, Accessory: View>: View {
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            content
            Spacer(minLength: 4)
            accessory.opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover && action != nil ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .onHover { hover = $0 }
    }
}

struct StatusDot: View {
    let state: Live.State
    @State private var pulse = false
    var color: Color { state == .working ? .blue : state == .waiting ? .orange : state == .done ? .green : .gray }
    var body: some View {
        ZStack {
            if state == .working || state == .waiting {
                Circle().fill(color.opacity(0.35)).frame(width: 14, height: 14).scaleEffect(pulse ? 1 : 0.5).opacity(pulse ? 0 : 1)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

struct Chip: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13)))
            .foregroundStyle(color)
    }
}

func toolSymbol(_ tool: String) -> String {
    switch tool {
    case "Bash": return "terminal"
    case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil.line"
    case "Read": return "doc.text"
    case "WebFetch", "WebSearch": return "globe"
    case "Glob", "Grep": return "magnifyingglass"
    default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
    }
}
func toolName(_ tool: String) -> String {
    tool.hasPrefix("mcp__") ? tool.split(separator: "_").filter { !$0.isEmpty }.dropFirst().joined(separator: " · ") : tool
}

// MARK: Needs you

// The top of a request card: what it is, where it's from, and the two ways to get rid of it.
//   cross (close): off Claude Switch only; Claude then asks in its own window as usual.
//   trash (delete): rejected in the session too (a permission is denied, a question dismissed).
struct RequestHeader: View {
    @EnvironmentObject var app: App
    let r: Request
    let symbol: String
    let title: String
    @Binding var hint: String?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(brand)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(brand.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(r.project) · \(r.place.label) · \(ago(r.at))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            IconButton(symbol: "trash", help: r.isQuestion ? "Delete: dismiss the question in the session too. Claude carries on without an answer."
                                                         : "Delete: deny it in the session too.", role: .destructive, hint: $hint) { app.answer(r, r.isQuestion ? "dismiss" : "deny") }
            IconButton(symbol: "xmark", help: "Close: remove it from Claude Switch only. Claude asks you in its own window instead.", hint: $hint) { app.answer(r, "claude") }
        }
    }
}

// A diff as coloured lines: additions green, removals red, hunk headers grey.
struct DiffView: View {
    let diff: String
    var dark = false
    var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(60).map(String.init)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    let add = l.hasPrefix("+"), del = l.hasPrefix("-"), hunk = l.hasPrefix("@@")
                    Text(l.isEmpty ? " " : l)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(hunk ? Color.secondary : add ? Color.green : del ? Color.red : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(add ? Color.green.opacity(0.1) : del ? Color.red.opacity(0.1) : Color.clear)
                }
            }
            .padding(.vertical, 4)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 160)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(dark ? 0.35 : 0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct PermissionCard: View {
    @EnvironmentObject var app: App
    let r: Request
    var dark = false
    var primary = false  // the first card takes Return (Allow) and Escape (Deny)
    @State private var hint: String?
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                RequestHeader(r: r, symbol: toolSymbol(r.tool), title: r.diff.isEmpty ? "Allow \(toolName(r.tool))?" : "Allow this edit?", hint: $hint)
                if !r.description.isEmpty { Text(r.description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
                if r.diff.isEmpty {
                    Text(r.detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(dark ? 0.35 : 0.06)))
                } else {
                    Label((r.detail as NSString).lastPathComponent, systemImage: "doc.text").font(.system(size: 11.5, weight: .medium)).help(r.detail)
                    DiffView(diff: r.diff, dark: dark)
                }
                HStack(spacing: 8) {
                    if !r.always.isEmpty {
                        Button("Always Allow") { app.answer(r, "always") }
                            .controlSize(.regular)
                            .hint("Allow now, and don't ask again for \(r.always)", $hint)
                    }
                    Spacer()
                    Button("Deny") { app.answer(r, "deny") }
                        .keyboardShortcut(primary ? .cancelAction : nil)
                        .hint("Deny: Claude doesn't do this and is told you said no" + (primary ? " (Esc)" : ""), $hint)
                    Button("Allow") { app.answer(r, "allow") }.buttonStyle(.borderedProminent).tint(brand)
                        .keyboardShortcut(primary ? .defaultAction : nil)
                        .hint("Allow it this once" + (primary ? " (Return, or ⌃⌥⌘A from anywhere)" : ""), $hint)
                }
                HintLine(text: hint)
            }
        }
    }
}

struct QuestionCard: View {
    @EnvironmentObject var app: App
    let r: Request
    @State private var picked: [Int: Set<String>] = [:]
    @State private var other: [Int: String] = [:]
    @State private var hint: String?
    func answer(_ k: Int) -> String {
        let typed = (other[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = r.questions[k].options.map(\.label).filter { (picked[k] ?? []).contains($0) }
        return (chosen + (typed.isEmpty ? [] : [typed])).joined(separator: ", ")
    }
    var complete: Bool { r.questions.indices.allSatisfy { !answer($0).isEmpty } }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                RequestHeader(r: r, symbol: "questionmark.bubble", title: r.questions.count > 1 ? "Claude has \(r.questions.count) questions" : "Claude asks", hint: $hint)
                ForEach(Array(r.questions.enumerated()), id: \.offset) { k, q in
                    VStack(alignment: .leading, spacing: 6) {
                        if !q.header.isEmpty { Chip(text: q.header, color: brand) }
                        Text(q.question).font(.system(size: 12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        ForEach(q.options, id: \.label) { o in option(k, q, o) }
                        TextField(q.options.isEmpty ? "Your answer" : "Other…", text: Binding(get: { other[k] ?? "" }, set: { v in
                            other[k] = v
                            if !q.multiSelect && !v.isEmpty { picked[k] = [] }  // a typed answer replaces a single choice
                        }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit { if complete { send() } }
                    }
                }
                HStack {
                    Spacer()
                    Button("Send") { send() }.buttonStyle(.borderedProminent).tint(brand).disabled(!complete)
                        .hint(complete ? "Send your answer to Claude" : "Pick an option or type an answer first", $hint)
                }
                HintLine(text: hint)
            }
        }
    }
    func send() { app.answer(r, r.questions.indices.map { (r.questions[$0].question, answer($0)) }) }
    func option(_ k: Int, _ q: Request.Question, _ o: Request.Option) -> some View {
        let on = (picked[k] ?? []).contains(o.label)
        return Button {
            var s = picked[k] ?? []
            if q.multiSelect { if on { s.remove(o.label) } else { s.insert(o.label) } } else { s = [o.label]; other[k] = "" }
            picked[k] = s
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(on ? brand : .secondary).font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.label).font(.system(size: 12, weight: on ? .semibold : .regular))
                    if !o.description.isEmpty { Text(o.description).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? brand.opacity(0.12) : Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WaitingRow: View {
    @EnvironmentObject var app: App
    let w: Waiting
    var body: some View {
        HoverRow(action: w.place.known ? { app.goTo(w.place) } : nil) {
            Image(systemName: "bell.badge").foregroundStyle(.orange).font(.system(size: 13)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.text).font(.system(size: 12.5)).lineLimit(2)
                Text("\(w.project) · \(w.place.label) · \(ago(w.at))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } accessory: {
            IconButton(symbol: "xmark", help: "Remove this from the list") { app.deleteWaiting(w) }
        }
    }
}

// MARK: Sessions

struct SessionRow: View {
    @EnvironmentObject var app: App
    let s: Live
    var compact = false
    var body: some View {
        HoverRow(action: s.place.known ? { app.goTo(s.place) } : nil) {
            StatusDot(state: s.state)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.project).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Chip(text: s.place.label)
                    if !s.account.isEmpty && s.account != app.email {
                        Chip(text: "on \(app.display(s.account))", color: .orange)
                            .help("Started under \(s.account), which it still uses: quit and reopen it to use \(app.display(app.email))")
                    }
                }
                Text(s.status).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                if !compact { meta }
            }
        } accessory: {
            IconButton(symbol: "xmark", help: "Remove from the list (it comes back when the session does something)") { app.deleteSession(s) }
        }
        .help(s.files.isEmpty ? s.place.folder : s.place.folder + "\n" + s.files.prefix(8).map { "\(($0.path as NSString).lastPathComponent)  +\($0.add) −\($0.del)" }.joined(separator: "\n"))
    }
    var meta: some View {
        HStack(spacing: 8) {
            if !s.files.isEmpty {
                HStack(spacing: 3) {
                    Text("+\(s.added)").foregroundStyle(.green)
                    Text("−\(s.removed)").foregroundStyle(.red)
                    Text("· \(s.files.count) file\(s.files.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
            }
            if s.tokens > 0 { Label(tokens(s.tokens), systemImage: "circle.hexagongrid").labelStyle(.titleAndIcon).foregroundStyle(.secondary) }
            Text(ago(s.updated)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 10.5).monospacedDigit())
    }
}

struct RecentRow: View {
    @EnvironmentObject var app: App
    let r: Recent
    var body: some View {
        HoverRow(action: { app.resume(r) }) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.project).font(.system(size: 12, weight: .medium))
                Text("\(r.editor ? "VS Code" : "Terminal") · ended \(ago(r.ended))").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        } accessory: {
            Text(r.editor ? "Open" : "Resume").font(.system(size: 11, weight: .medium)).foregroundStyle(brand)
        }
    }
}

// MARK: Usage and accounts

struct UsageCard: View {
    @EnvironmentObject var app: App
    var body: some View {
        let u = app.usage, left = app.showLeft
        Card {
            VStack(alignment: .leading, spacing: 11) {
                meter("Session", "5 hours", u?.five_hour, left)
                meter("Week", "7 days", u?.seven_day, left)
                let extras = [("Opus week", u?.seven_day_opus), ("Sonnet week", u?.seven_day_sonnet), ("Extra usage", u?.extra_usage)].filter { $0.1 != nil }
                if !extras.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(extras, id: \.0) { name, w in
                            HStack(spacing: 4) {
                                Circle().fill(app.level(w)).frame(width: 6, height: 6)
                                Text("\(name) \(percent(w, left, word: false))")
                            }
                        }
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                let days = dailyUse(app.history[app.email] ?? [])
                if days.contains(where: { $0.used > 0 }) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Weekly limit used per day").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            if let p = app.pace(app.email, session: false) ?? app.pace(app.email, session: true) {
                                Text(p).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        DayBars(days: days)
                    }
                    .padding(.top, 2)
                }
                if !app.notes.isEmpty {
                    Text(app.notes.joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
    }
    func meter(_ title: String, _ span: String, _ w: Window?, _ left: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(span).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer()
                Text(resetText(w)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text(percent(w, left)).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).frame(minWidth: 40, alignment: .trailing)
            }
            Bar(value: used(w), color: app.level(w))
        }
    }
}

struct AccountRow: View {
    @EnvironmentObject var app: App
    let a: String
    @State private var hover = false
    var body: some View {
        let current = a == app.email, u = app.usageOf(a)
        HStack(spacing: 10) {
            Avatar(name: app.display(a), size: 26, active: current)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app.display(a)).font(.system(size: 12.5, weight: current ? .semibold : .regular)).lineLimit(1)
                    if current { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(brand) }
                    if app.loading.contains(a) { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: 6) {
                    Bar(value: used(u?.five_hour), color: app.level(u?.five_hour), height: 4).frame(width: 64)
                    Text(percent(u?.five_hour, app.showLeft, word: false)).frame(width: 30, alignment: .leading)
                    Bar(value: used(u?.seven_day), color: app.level(u?.seven_day), height: 4).frame(width: 64)
                    Text(percent(u?.seven_day, app.showLeft, word: false)).frame(width: 30, alignment: .leading)
                }
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                if let n = app.accountNote[a], !current { Text(n).font(.system(size: 10)).foregroundStyle(.orange) }
            }
            Spacer(minLength: 4)
            if !current {
                Button("Switch") { app.switchAccount([a]) }
                    .controlSize(.small).opacity(hover ? 1 : 0)
                    .disabled(app.switching)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover && !current ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0; if $0 && !current { app.loadAccount(a) } }
        .help(a + (u == nil ? "" : "\nSession: \(line(u?.five_hour, app.showLeft))\nWeek: \(line(u?.seven_day, app.showLeft))\n\(app.lastRefreshed(a))"))
        .contextMenu {
            if !current { Button("Switch to \(app.display(a))") { app.switchAccount([a]) } }
            Button("Refresh") { a == app.email ? app.refresh(force: true) : app.loadAccount(a, force: true) }
            Button("Account Settings…") { app.open([.settings, .accounts, .account(a)]) }
            Divider()
            Button("Remove…", role: .destructive) { app.removeAccount(a) }.disabled(current)
        }
    }
}

// MARK: The panel

struct PanelView: View {
    @EnvironmentObject var app: App
    var body: some View {
        Group {
            if let page = app.path.last { PageView(page: page) } else { home }
        }
        .frame(width: 380)
        .animation(.easeInOut(duration: 0.18), value: app.path)
    }

    var home: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            FitScroll(limit: maxHeight) {
                VStack(alignment: .leading, spacing: 14) {
                    if let b = app.banner { banner(b) }
                    UsageCard()
                    if let (b, p) = app.suggestion { suggestion(b, p) }
                    needsYou
                    sessionsSection
                    accountsSection
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
            Divider().opacity(0.6)
            footer.padding(.horizontal, 10).padding(.vertical, 8)
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: app.requests)
        .animation(.easeInOut(duration: 0.2), value: app.attention)
    }

    var header: some View {
        HStack(spacing: 10) {
            Avatar(name: app.display(app.email), size: 34, active: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.display(app.email)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(app.names[app.email] == nil ? app.lastRefreshed(app.email) : app.email).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if app.switching { ProgressView().controlSize(.small) }
            IconButton(symbol: "arrow.clockwise", help: "Refresh all accounts") { app.refreshAll() }
        }
    }

    func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { app.banner = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.blue.opacity(0.09)))
    }

    func suggestion(_ b: String, _ p: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").foregroundStyle(brand).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 1) {
                Text("Running low").font(.system(size: 12, weight: .semibold))
                Text("\(app.display(b)) has the most room (\(app.showLeft ? "\(100 - Int(p))% left" : "\(Int(p))% used"))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Switch") { app.switchAccount([b]) }.buttonStyle(.borderedProminent).tint(brand).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(brand.opacity(0.09)))
    }

    @ViewBuilder var needsYou: some View {
        if app.needsYou > 0 {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Needs you", count: app.needsYou) {
                    if !app.attention.isEmpty { Button("Clear") { app.clearWaiting() }.buttonStyle(.borderless).font(.system(size: 11)) }
                }
                ForEach(app.requests) { r in
                    if r.isQuestion { QuestionCard(r: r) } else { PermissionCard(r: r, primary: r.id == app.requests.first(where: { !$0.isQuestion })?.id) }
                }
                if !app.attention.isEmpty {
                    Card(padding: 4) { VStack(spacing: 0) { ForEach(app.attention) { WaitingRow(w: $0) } } }
                }
            }
        }
    }

    @ViewBuilder var sessionsSection: some View {
        if !app.hooksMissingList.isEmpty || !app.approvalsOn {
            // What it takes to answer Claude from here: the hooks, then approvals turned on.
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.bubble").font(.system(size: 18)).foregroundStyle(brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Answer Claude from here").font(.system(size: 12.5, weight: .semibold))
                        Text(app.hooksMissingList.isEmpty ? "Allow, deny and answer questions without switching windows." : "Set up the Claude hooks first.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if app.hooksMissingList.isEmpty {
                        Button("Turn On") { app.approvalsOn = true }.controlSize(.small)
                    } else {
                        Button("Set Up…") { app.showSettings(.claude) }.controlSize(.small)
                    }
                }
            }
        }
        if app.showSessions && (!app.sessions.isEmpty || !app.recent.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Sessions", count: app.sessions.count) {
                    if app.tokensToday > 0 { Text("\(tokens(app.tokensToday)) tokens today").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }
                Card(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(app.sessions) { SessionRow(s: $0) }
                        if !app.recent.isEmpty {
                            if !app.sessions.isEmpty { Divider().padding(.vertical, 4).padding(.horizontal, 8) }
                            ForEach(app.recent.prefix(3)) { RecentRow(r: $0) }
                        }
                    }
                }
            }
        }
    }

    var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Accounts", count: nil) {
                Button { app.addAccount() } label: { Label("Add", systemImage: "plus").font(.system(size: 11)) }.buttonStyle(.borderless)
            }
            Card(padding: 4) {
                VStack(spacing: 0) {
                    ForEach([app.email] + app.accounts.filter { $0 != app.email }, id: \.self) { AccountRow(a: $0) }
                    if !app.accounts.contains(app.email) && app.email != "Not logged in" {
                        Button("Save this login so you can switch back to it") { app.save() }.buttonStyle(.borderless)
                            .font(.system(size: 11)).padding(8)
                    }
                }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 2) {
            Menu {
                if isMuted {
                    Button("Unmute") { app.mute(for: nil) }
                } else {
                    MuteChoices()
                }
            } label: {
                Image(systemName: isMuted ? "bell.slash.fill" : "bell")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28)
            .foregroundStyle(isMuted ? .orange : .secondary)
            .help(isMuted ? app.muteText : "Mute notifications")
            IconButton(symbol: "chart.bar.xaxis", help: "Activity") { app.showRecap() }
            if app.jumpKeyOn && app.needsYou > 0 {
                IconButton(symbol: "arrow.up.forward.app", help: "Go to what Claude is waiting on (⌃⌥⌘J)") { app.jumpToWaiting() }
            }
            Spacer()
            Text(app.hotKeyOn ? "⌃⌥⌘S to switch" : "").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            IconButton(symbol: "gearshape", help: "Settings") { app.showSettings() }
            IconButton(symbol: "power", help: "Quit Claude Switch") { app.quit() }
        }
    }
}

// The mute presets, shared by the panel's bell and the General page.
struct MuteChoices: View {
    @EnvironmentObject var app: App
    var body: some View {
        Button("For 15 minutes") { app.mute(for: 15 * 60) }
        Button("For 1 hour") { app.mute(for: 3600) }
        Button("For 3 hours") { app.mute(for: 3 * 3600) }
        Button("For 8 hours") { app.mute(for: 8 * 3600) }
        Button("Until tomorrow morning") { app.muteUntilTomorrow() }
        Divider()
        Button("Until I turn it back on") { app.muteAlways() }
        Button("Custom…") { app.showSettings(.general) }
    }
}

struct RecapView: View {
    @EnvironmentObject var app: App
    @State private var days = 7
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $days) {
                Text("Today").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented).labelsHidden()
            let lines = text.split(separator: "\n").map(String.init)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty { ProgressView().controlSize(.small) }
                    ForEach(lines, id: \.self) { l in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: l.hasPrefix("Edits") ? "pencil.line" : l.hasPrefix("Top") ? "folder" : l.hasPrefix("By account") ? "person.2" : "sparkles")
                                .foregroundStyle(brand).frame(width: 18)
                            Text(l).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if app.tokensToday > 0 {
                Label("\(tokens(app.tokensToday)) tokens used today", systemImage: "circle.hexagongrid").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Toggle("Weekly recap notification on Mondays", isOn: $app.recapOn).font(.system(size: 12))
        }
        .onAppear(perform: load)
        .onChange(of: days) { _ in load() }
    }
    func load() {
        let d = days
        text = ""
        DispatchQueue.global().async {
            let t = app.recapText(d)
            DispatchQueue.main.async { text = t }
        }
    }
}

// A page over the panel's home: a header with Back and the title, then the page itself.
struct PageView: View {
    @EnvironmentObject var app: App
    let page: Page
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { app.back() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text(app.path.count > 1 ? app.path[app.path.count - 2].title : "Back").font(.system(size: 12.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(brand)
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .overlay(Text(title).font(.system(size: 13, weight: .semibold)))
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().opacity(0.6)
            FitScroll(limit: maxHeight + 60) { content.padding(14) }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
    var title: String {
        if case .account(let a) = page { return app.display(a) }
        return page.title
    }
    @ViewBuilder var content: some View {
        switch page {
        case .settings: SettingsHome()
        case .general: GeneralSettings()
        case .menubar: MenuBarSettings()
        case .claude: ClaudeSettings()
        case .notch: NotchSettings()
        case .accounts: AccountsPage()
        case .account(let a): AccountDetail(a: a).id(a)
        case .recap: RecapView()
        }
    }
}
