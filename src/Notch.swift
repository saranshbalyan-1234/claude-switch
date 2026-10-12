// Claude Switch: the island around the notch. Collapsed, it shows what Claude is doing in the two "wings" beside the
// notch; pointed at, it opens into the sessions and anything that needs you. New permission prompts and questions open
// it by themselves until they're answered (or it's hidden with the chevron). On displays without a notch it sits at the
// top centre of the screen.
import AppKit
import SwiftUI

final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 190
    @Published var notchHeight: CGFloat = 32
    @Published var hasNotch = true
    @Published var contentHeight: CGFloat = 200
    @Published var hideAt: Date?          // when an auto-opened island folds away by itself; nil: no countdown (or paused)
    @Published var hideAfter: TimeInterval = 15
    @Published var wings = true  // the parts beside the notch; shown only while there's something to show, so menu bar icons stay visible
    var wing: CGFloat { 52 }
    var collapsedSize: CGSize { CGSize(width: notchWidth + (wings || !hasNotch ? wing * 2 : 0), height: notchHeight) }
    var expandedSize: CGSize { CGSize(width: max(440, notchWidth + 120), height: min(560, notchHeight + contentHeight)) }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }  // for the buttons in cards; it never takes focus on its own
}

final class Notch {
    let app: App, model = NotchModel(), panel: NotchPanel
    var poll: Timer?, hoverSince: Date?, outSince: Date?
    var pinned = false, dismissed: Set<String> = []

    init(_ app: App) {
        self.app = app
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: NotchView(model: model, collapse: { [weak self] in self?.dismiss() }).environmentObject(app))
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layout()
        }
        layout()
        update()
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.model.expanded, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.dismiss()
        }
    }

    var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    func layout() {
        guard let s = screen else { return }
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            model.hasNotch = true
            model.notchWidth = s.frame.width - l.width - r.width
            model.notchHeight = s.safeAreaInsets.top
        } else {
            model.hasNotch = false
            model.notchWidth = 120
            model.notchHeight = max(24, NSStatusBar.system.thickness)
        }
        place()
    }

    func place() {
        guard let s = screen else { return }
        let size = model.expanded ? model.expandedSize : model.collapsedSize
        panel.setFrame(NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    var active: Bool { app.needsYou > 0 || (app.showSessions && app.sessions.contains { $0.state == .working || $0.state == .waiting }) }

    func update() {
        // Wings only when Claude needs you or is working; at rest it's just the notch, which hides nothing and still opens on hover.
        let wings = app.needsYou > 0 || (app.showSessions && app.sessions.contains { $0.state == .working })
        if model.wings != wings {
            model.wings = wings
            if !model.expanded { place() }
        }
        let visible = app.notchOn && (app.notchAlways || active || model.expanded || model.hasNotch)
        // New requests open the island until they're answered, unless hidden with the chevron.
        let open = app.requests.filter { !dismissed.contains($0.id) }
        if !open.isEmpty && !pinned { pinned = true; setExpanded(true); startCountdown() }
        if open.isEmpty && pinned { pinned = false; model.hideAt = nil; if hoverSince == nil { setExpanded(false) } }
        if !model.hasNotch && !(app.notchAlways || active || model.expanded) { panel.orderOut(nil) }
        dismissed.formIntersection(Set(app.requests.map(\.id)))
        if visible {
            if !panel.isVisible { place(); panel.orderFrontRegardless() }
            startPolling()
        } else if panel.isVisible && hoverSince == nil {
            panel.orderOut(nil)
            poll?.invalidate()
            poll = nil
        }
    }

    func attention() { update() }

    // An island that opened by itself for a request folds away after the time set in Settings (the request stays in the
    // panel and the menu bar). Pointing at it pauses the countdown; leaving starts it again from the full time.
    func startCountdown() {
        model.hideAfter = TimeInterval(app.notchHide)
        model.hideAt = app.notchHide > 0 ? Date().addingTimeInterval(model.hideAfter) : nil
    }

    func dismiss() {
        dismissed.formUnion(app.requests.map(\.id))
        pinned = false
        model.hideAt = nil
        setExpanded(false)
    }

    func setExpanded(_ on: Bool) {
        guard model.expanded != on else { return }
        if on {
            model.expanded = true  // window first, so the shape has room to grow into
            place()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { model.expanded = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.model.expanded else { return }
                self.place()
                self.update()
            }
        }
    }

    // Hover by polling the pointer (cheap, and works while another app is active): open after a short rest over the
    // island, close a moment after leaving it.
    func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
    }
    func tick() {
        guard panel.isVisible else { return }
        let inside = panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if inside {
            outSince = nil
            if hoverSince == nil { hoverSince = Date(); if pinned { model.hideAt = nil } }  // pointing at it pauses the countdown
            if !model.expanded, Date().timeIntervalSince(hoverSince!) > 0.15 { setExpanded(true) }
        } else {
            if hoverSince != nil && pinned && model.hideAt == nil { startCountdown() }  // left it: start again from the full time
            hoverSince = nil
            if pinned, let at = model.hideAt, Date() >= at { dismiss() }
            if model.expanded && !pinned {
                if outSince == nil { outSince = Date() }
                if Date().timeIntervalSince(outSince!) > 0.35 { outSince = nil; setExpanded(false) }
            }
        }
    }
}

// The notch's own shape: flat across the top, rounded below, with the small outward curves where it meets the bar.
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat { get { radius } set { radius = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        let top: CGFloat = 6
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + radius, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - radius), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// How long until the auto-opened island folds away: a bar that shrinks from full to empty.
struct CountdownBar: View {
    let end: Date
    let total: TimeInterval
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let left = max(0, end.timeIntervalSince(ctx.date)), f = total > 0 ? left / total : 0
            HStack(spacing: 8) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(brand).frame(width: g.size.width * f)
                    }
                }
                .frame(height: 3)
                Text("\(Int(left.rounded(.up)))s").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
            .help("Folds away when this runs out; point at it to pause. The request stays in the panel.")
        }
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct NotchView: View {
    @EnvironmentObject var app: App
    @ObservedObject var model: NotchModel
    let collapse: () -> Void

    var body: some View {
        let size = model.expanded ? model.expandedSize : model.collapsedSize
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: model.expanded ? 22 : 10).fill(Color.black)
                if model.expanded {
                    expanded.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else if model.wings || !model.hasNotch {
                    wings.transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.expanded)
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.contentHeight)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    var working: [Live] { app.sessions.filter { $0.state == .working } }

    // Collapsed: left wing says what's happening, right wing gives the number that matters.
    var wings: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if app.needsYou > 0 {
                    Image(systemName: "bell.fill").foregroundStyle(.orange).font(.system(size: 11, weight: .semibold))
                } else if !working.isEmpty {
                    StatusDot(state: .working)
                } else {
                    Image(systemName: "sparkle").foregroundStyle(brand).font(.system(size: 11, weight: .semibold))
                }
            }
            .frame(width: model.wing, alignment: .center)
            Spacer(minLength: model.notchWidth)
            Group {
                if app.needsYou > 0 {
                    Text("\(app.needsYou)").foregroundStyle(.orange)
                } else if working.count > 1 {
                    Text("\(working.count)").foregroundStyle(.white)
                } else {
                    Text(percent(app.usage?.five_hour, app.showLeft, word: false)).foregroundStyle(app.level(app.usage?.five_hour))
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            .frame(width: model.wing, alignment: .center)
        }
        .frame(height: model.notchHeight)
        .padding(.horizontal, 6)
    }

    var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Avatar(name: app.display(app.email), size: 24, active: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.display(app.email)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("Session \(percent(app.usage?.five_hour, app.showLeft)) · Week \(percent(app.usage?.seven_day, app.showLeft))")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if !app.requests.isEmpty {
                    Button(action: collapse) { Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide until something new comes in")
                }
                Button { app.showPanel() } label: { Image(systemName: "rectangle.expand.vertical").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open the full panel")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(app.requests) { r in
                        if r.isQuestion { QuestionCard(r: r) } else { PermissionCard(r: r, dark: true, primary: r.id == app.requests.first(where: { !$0.isQuestion })?.id) }
                    }
                    ForEach(app.attention) { WaitingRow(w: $0) }
                    if app.showSessions && !app.sessions.isEmpty {
                        VStack(spacing: 0) { ForEach(app.sessions.prefix(6)) { SessionRow(s: $0) } }
                    } else if app.needsYou == 0 {
                        Text("Nothing needs you right now").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .frame(maxHeight: 460)
            if let at = model.hideAt { CountdownBar(end: at, total: model.hideAfter) }
        }
        .padding(.top, model.notchHeight + 6)
        .padding(.horizontal, 18).padding(.bottom, 16)
        .onPreferenceChange(HeightKey.self) { h in
            let total = h + 34 + 6 + 16 + 10 + 16  // header, gaps, padding, and room for the countdown bar
            if abs(total - model.contentHeight) > 1 {
                model.contentHeight = total
                (NSApp.delegate as? App)?.notch?.place()
            }
        }
    }
}
