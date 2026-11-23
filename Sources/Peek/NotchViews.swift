import AppKit
import SwiftUI

// MARK: - Palette

enum Peek {
    static let amber = Color(red: 0.93, green: 0.55, blue: 0.33)
    static let mint = Color(red: 0.36, green: 0.86, blue: 0.58)
    static let rose = Color(red: 0.98, green: 0.42, blue: 0.45)
    static let sky = Color(red: 0.42, green: 0.70, blue: 1.0)
    static let card = Color.white.opacity(0.07)
    static let cardStroke = Color.white.opacity(0.06)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.35)
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.86)
}

struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let b = min(bottom, h / 2)
        var p = Path()
        p.move(to: .init(x: 0, y: 0))
        p.addQuadCurve(to: .init(x: top, y: top), control: .init(x: top, y: 0))
        p.addLine(to: .init(x: top, y: h - b))
        p.addQuadCurve(to: .init(x: top + b, y: h), control: .init(x: top, y: h))
        p.addLine(to: .init(x: w - top - b, y: h))
        p.addQuadCurve(to: .init(x: w - top, y: h - b), control: .init(x: w - top, y: h))
        p.addLine(to: .init(x: w - top, y: top))
        p.addQuadCurve(to: .init(x: w, y: 0), control: .init(x: w - top, y: 0))
        p.closeSubpath()
        return p
    }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Peek.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Peek.cardStroke))
    }
}

extension View {
    func card(_ padding: CGFloat = 12) -> some View { modifier(CardBackground(padding: padding)) }
}

struct PillButtonStyle: ButtonStyle {
    var tint: Color = .white.opacity(0.12)
    var foreground: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.7 : 1)))
            .foregroundStyle(foreground)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.09)))
            .foregroundStyle(.white)
    }
}

// MARK: - Root

struct NotchRootView: View {
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var hub: ClaudeHub
    @EnvironmentObject var music: MusicService
    @EnvironmentObject var power: PowerService
    let openSettings: () -> Void

    private var live: Bool {
        hub.indicator != .none || (music.current?.isPlaying ?? false)
    }

    var body: some View {
        let size = state.visibleSize
        ZStack(alignment: .top) {
            NotchShape(top: state.expanded ? 14 : 7, bottom: state.expanded ? 30 : 11)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)

            if state.expanded {
                ExpandedView(openSettings: openSettings)
                    .frame(width: size.width, height: size.height)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                                            removal: .opacity))
            } else {
                CollapsedView()
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(state.expanded ? NotchState.openAnimation : NotchState.closeAnimation, value: state.expanded)
        .animation(Peek.spring, value: state.wingWidth)
        .onAppear { updateWings() }
        .onChange(of: live) { _, _ in updateWings() }
        .onChange(of: power.activity) { _, _ in updateWings() }
        .environment(\.colorScheme, .dark)
    }

    private func updateWings() {
        withAnimation(Peek.spring) { state.wingWidth = power.activity != nil ? 118 : (live ? 58 : 0) }
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var hub: ClaudeHub
    @EnvironmentObject var music: MusicService
    @EnvironmentObject var power: PowerService

    var body: some View {
        if let a = power.activity, state.wingWidth > 0 {
            ActivityBanner(activity: a)
                .frame(height: state.notchSize.height)
                .contentShape(Rectangle())
                .onTapGesture { power.activity = nil; state.open(.devices) }
        } else {
            wings
        }
    }

    private var wings: some View {
        HStack(spacing: 0) {
            leftWing.frame(width: state.wingWidth)
            Color.clear.frame(width: state.notchSize.width)
            rightWing.frame(width: state.wingWidth)
        }
        .frame(height: state.notchSize.height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { state.toggle() }
    }

    @ViewBuilder private var leftWing: some View {
        if state.wingWidth > 0 {
            if hub.indicator != .none {
                ClaudeGlyph(indicator: hub.indicator, size: 16)
            } else if let art = music.artwork, music.current?.isPlaying == true {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5))
            } else if music.current?.isPlaying == true {
                Image(systemName: "music.note").font(.system(size: 12, weight: .bold)).foregroundStyle(Peek.dim)
            }
        }
    }

    @ViewBuilder private var rightWing: some View {
        if state.wingWidth > 0 {
            if music.current?.isPlaying == true {
                SpectrumBars(playing: true, bars: 4, height: 12, color: Peek.mint)
            } else {
                switch hub.indicator {
                case .attention(let n):
                    Text("\(n)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Peek.amber)
                case .working(let n):
                    Text("\(n)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                case .done:
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Peek.mint)
                case .none:
                    EmptyView()
                }
            }
        }
    }
}

struct ClaudeGlyph: View {
    let indicator: HubIndicator
    var size: CGFloat = 16
    @StateObject private var spinBox = Box(false)
    @StateObject private var pulseBox = Box(false)

    var body: some View {
        switch indicator {
        case .attention:
            ZStack {
                Circle().fill(Peek.amber.opacity(0.35)).frame(width: size, height: size)
                    .scaleEffect(pulseBox.v ? 1.25 : 0.8).opacity(pulseBox.v ? 0 : 1)
                Circle().fill(Peek.amber).frame(width: size * 0.55, height: size * 0.55)
            }
            .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulseBox.v = true } }
        case .working:
            Circle()
                .trim(from: 0.1, to: 0.8)
                .stroke(Peek.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: size * 0.8, height: size * 0.8)
                .rotationEffect(.degrees(spinBox.v ? 360 : 0))
                .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinBox.v = true } }
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: size * 0.85)).foregroundStyle(Peek.mint)
        case .none:
            Image(systemName: "sparkles").font(.system(size: size * 0.75)).foregroundStyle(Peek.faint)
        }
    }
}

struct SpectrumBars: View {
    var playing: Bool
    var bars = 5
    var height: CGFloat = 14
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let speed = 5.0 + Double(i) * 1.7
                    let v = playing ? (0.3 + 0.7 * abs(sin(t * speed + Double(i) * 1.3) * cos(t * 2.1 + Double(i)))) : 0.18
                    Capsule().fill(color).frame(width: 3, height: max(3, height * v))
                }
            }
            .frame(height: height)
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var hub: ClaudeHub
    @EnvironmentObject var weather: WeatherService
    @EnvironmentObject var power: PowerService
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch state.tab {
                case .home: HomeTab()
                case .claude: ClaudeTab()
                case .calendar: CalendarTab()
                case .music: MusicTab()
                case .weather: WeatherTab()
                case .devices: DevicesTab()
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
            .id(state.tab)
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        let side = (state.expandedSize.width - state.notchSize.width) / 2 - 22
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(NotchTab.allCases) { tab in
                    TabButton(tab: tab, selected: state.tab == tab, badge: tab == .claude ? hub.pending.count : 0) {
                        withAnimation(.easeInOut(duration: 0.15)) { state.tab = tab }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: side)
            Spacer(minLength: state.notchSize.width)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if let now = weather.now {
                    Button { state.tab = .weather } label: {
                        HStack(spacing: 4) {
                            Image(systemName: WeatherCode.symbol(now.code, isDay: now.isDay)).symbolRenderingMode(.multicolor)
                            Text(weather.format(now.temperature)).font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }
                if let b = power.battery, b.hasBattery {
                    Button { state.tab = .devices } label: {
                        HStack(spacing: 4) {
                            Text("\(b.percent)%").font(.system(size: 11, weight: .semibold, design: .rounded))
                            BatteryGlyph(percent: b.percent, charging: b.isCharging, width: 20)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }
                Button { state.pinned.toggle() } label: {
                    Image(systemName: state.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help(state.pinned ? "Unpin (closes when the mouse leaves)" : "Keep open")
                Button(action: openSettings) { Image(systemName: "gearshape.fill") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Settings")
            }
            .frame(width: side)
        }
        .padding(.horizontal, 22)
        .frame(height: max(state.notchSize.height, 30))
        .padding(.top, 4)
    }
}

struct TabButton: View {
    let tab: NotchTab
    let selected: Bool
    var badge: Int = 0
    let action: () -> Void
    @StateObject private var hoverBox = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 24)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.16 : (hoverBox.v ? 0.08 : 0))))
                .foregroundStyle(selected ? .white : Peek.dim)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3).frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(Peek.amber)).foregroundStyle(.black)
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hoverBox.v = $0 }
        .help(tab.title)
    }
}

// MARK: - Home

struct HomeTab: View {
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var hub: ClaudeHub
    @EnvironmentObject var weather: WeatherService
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var music: MusicService

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                clockCard.frame(width: 200)
                upNextCard
                nowPlayingCard.frame(width: 210)
            }
            claudeStrip
        }
    }

    private var clockCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 0) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Peek.dim)
                }
            }
            Spacer(minLength: 4)
            if let now = weather.now {
                HStack(spacing: 6) {
                    Image(systemName: WeatherCode.symbol(now.code, isDay: now.isDay)).symbolRenderingMode(.multicolor)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(weather.format(now.temperature)) · \(WeatherCode.text(now.code))")
                            .font(.system(size: 12, weight: .semibold))
                        if !weather.place.isEmpty {
                            Text(weather.place).font(.system(size: 10)).foregroundStyle(Peek.dim)
                        }
                    }
                }
                .onTapGesture { state.tab = .weather }
            } else {
                Text(weather.status ?? "Loading weather…").font(.system(size: 11)).foregroundStyle(Peek.dim).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(14)
    }

    private var upNextCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Up next", systemImage: "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(Peek.dim)
            if !calendar.calendarAccess {
                Text("See your next meetings and join with one click.").font(.system(size: 12)).foregroundStyle(Peek.dim)
                Button("Connect Calendar") { calendar.requestCalendar() }.buttonStyle(PillButtonStyle(tint: Peek.sky.opacity(0.3)))
            } else if calendar.events.filter({ !$0.isAllDay }).isEmpty {
                Text("Nothing else scheduled").font(.system(size: 13, weight: .medium))
                Text("Enjoy the free time.").font(.system(size: 11)).foregroundStyle(Peek.dim)
            } else {
                // Show as many upcoming events as the card has room for.
                GeometryReader { geo in
                    let upcoming = calendar.events.filter { !$0.isAllDay }
                    let rowHeight: CGFloat = 30, spacing: CGFloat = 6
                    let fit = max(1, Int((geo.size.height + spacing) / (rowHeight + spacing)))
                    let overflow = upcoming.count > fit
                    let shown = overflow ? max(1, fit - 1) : upcoming.count
                    VStack(alignment: .leading, spacing: spacing) {
                        ForEach(upcoming.prefix(shown)) { e in
                            EventRow(event: e, compact: true).frame(height: rowHeight)
                        }
                        if overflow {
                            Button { state.tab = .calendar } label: {
                                Text("+\(upcoming.count - shown) more")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Peek.sky)
                            }
                            .buttonStyle(.plain)
                            .frame(height: rowHeight, alignment: .leading)
                        }
                    }
                }
            }
            if calendar.remindersAccess && !calendar.reminders.isEmpty {
                Button { state.tab = .calendar } label: {
                    Label("\(calendar.reminders.count) reminder\(calendar.reminders.count == 1 ? "" : "s") today", systemImage: "checklist")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Peek.dim)
                }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(14)
    }

    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let np = music.current {
                HStack(spacing: 10) {
                    Artwork(image: music.artwork, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(np.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(np.artist).font(.system(size: 11)).foregroundStyle(Peek.dim).lineLimit(1)
                    }
                }
                .onTapGesture { state.tab = .music }
                Spacer(minLength: 0)
                HStack {
                    SpectrumBars(playing: np.isPlaying, bars: 5, height: 14, color: Peek.mint)
                    Spacer()
                    Button { music.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(IconButtonStyle())
                    Button { music.playPause() } label: { Image(systemName: np.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(IconButtonStyle(size: 32))
                    Button { music.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(IconButtonStyle())
                }
            } else {
                Label("Now playing", systemImage: "music.note").font(.system(size: 11, weight: .semibold)).foregroundStyle(Peek.dim)
                Text("Nothing playing").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Button("Open Music") { music.openPlayer() }.buttonStyle(PillButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(14)
    }

    private var claudeStrip: some View {
        Button { state.tab = .claude } label: {
            HStack(spacing: 10) {
                ClaudeGlyph(indicator: hub.indicator, size: 14)
                Text(claudeSummary).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if !hub.hooksInstalled {
                    Text("Set up").font(.system(size: 11, weight: .semibold)).foregroundStyle(Peek.amber)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Peek.faint)
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Peek.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var claudeSummary: String {
        if !hub.hooksInstalled { return "Connect Claude Code to follow your sessions here" }
        if let p = hub.pending.first, let s = hub.session(p.sessionId) {
            let what: String
            switch p.kind {
            case .question: what = "has a question"
            case .plan: what = "has a plan for you"
            case .notice: what = "is waiting for you"
            case .permission: what = "needs approval"
            }
            return "\(s.displayTitle) — \(what)"
        }
        if let waiting = hub.sessions.first(where: { $0.phase.needsUser }) {
            return "\(waiting.displayTitle) — \(waiting.phase.label)"
        }
        let working = hub.sessions.filter { $0.phase.isWorking }
        if let first = working.first {
            return working.count == 1 ? "\(first.displayTitle) — \(first.phase.label)" : "\(working.count) Claude sessions working"
        }
        if let last = hub.sessions.first { return "\(last.displayTitle) — \(last.phase.label)" }
        return "No Claude sessions right now"
    }
}

struct Artwork: View {
    let image: NSImage?
    var size: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Peek.sky.opacity(0.5), Peek.amber.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.35, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}

// MARK: - Claude

struct ClaudeTab: View {
    @EnvironmentObject var hub: ClaudeHub

    var body: some View {
        if let req = hub.pending.first {
            switch req.kind {
            case .question: QuestionCard(request: req, total: hub.pending.count).id(req.id)
            case .plan: PlanCard(request: req, total: hub.pending.count).id(req.id)
            case .notice: NoticeCard(request: req, total: hub.pending.count).id(req.id)
            case .permission: PermissionCard(request: req, total: hub.pending.count).id(req.id)
            }
        } else if !hub.hooksInstalled {
            SetupClaudeCard()
        } else if hub.sessions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(Peek.amber)
                Text("No Claude sessions yet").font(.system(size: 14, weight: .semibold))
                Text("Start a chat in the Claude app or run `claude` in a terminal — it shows up here live.")
                    .font(.system(size: 12)).foregroundStyle(Peek.dim).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                HStack {
                    Text("\(hub.sessions.count) session\(hub.sessions.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Peek.dim)
                    Spacer()
                    Button("Clear finished") { withAnimation { hub.clearFinished() } }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Peek.dim)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(hub.sessions) { s in SessionRow(session: s) }
                    }
                }
            }
        }
    }
}

struct SetupClaudeCard: View {
    @EnvironmentObject var hub: ClaudeHub
    @StateObject private var errorBox = Box<String?>(nil)
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(Peek.amber)
            Text("Follow Claude from the notch").font(.system(size: 15, weight: .semibold))
            Text("Peek adds a small hook to ~/.claude/settings.json (a backup is kept). You'll see every session live, and approve or deny tool use without switching windows.")
                .font(.system(size: 12)).foregroundStyle(Peek.dim).multilineTextAlignment(.center).frame(maxWidth: 480)
            Button("Connect Claude Code") {
                do { try HookInstaller.install(); hub.refreshInstallState(); errorBox.v = nil }
                catch { errorBox.v = error.localizedDescription }
            }
            .buttonStyle(PillButtonStyle(tint: Peek.amber, foreground: .black))
            if let e = errorBox.v { Text(e).font(.system(size: 11)).foregroundStyle(Peek.rose) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SessionRow: View {
    @EnvironmentObject var hub: ClaudeHub
    let session: ClaudeSession

    private var indicator: HubIndicator {
        switch session.phase {
        case .thinking, .running: return .working(1)
        case .needsApproval, .waiting: return .attention(1)
        case .completed: return .done
        default: return .none
        }
    }

    private var phaseColor: Color {
        switch session.phase {
        case .needsApproval, .waiting: return Peek.amber
        case .completed: return Peek.mint
        case .failed: return Peek.rose
        default: return Peek.dim
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ClaudeGlyph(indicator: indicator, size: 16).frame(width: 18, height: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(session.project).font(.system(size: 10, weight: .medium)).foregroundStyle(Peek.faint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    Image(systemName: session.host == "desktop" ? "macwindow" : "terminal")
                        .font(.system(size: 9)).foregroundStyle(Peek.faint)
                }
                Text(session.phase.label).font(.system(size: 11)).foregroundStyle(phaseColor).lineLimit(1)
                if session.phase == .completed, let reply = session.lastReply {
                    Text(reply).font(.system(size: 11)).foregroundStyle(Peek.dim).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                if let start = session.startedAt {
                    if session.phase.isWorking || session.phase.needsUser {
                        Text(start, style: .timer).font(.system(size: 10, design: .monospaced)).foregroundStyle(Peek.faint)
                    } else if let end = session.finishedAt {
                        Text(Self.duration(end.timeIntervalSince(start))).font(.system(size: 10, design: .monospaced)).foregroundStyle(Peek.faint)
                    }
                }
                HStack(spacing: 4) {
                    Button { hub.open(session.id) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(IconButtonStyle(size: 22)).help("Open")
                    if session.phase.isWorking || session.phase.needsUser, session.pid > 1 {
                        Button { hub.stop(session.id) } label: { Image(systemName: "stop.fill") }
                            .buttonStyle(IconButtonStyle(size: 22)).help("Stop (interrupt Claude)")
                    } else {
                        Button { withAnimation { hub.dismiss(session.id) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(IconButtonStyle(size: 22)).help("Dismiss")
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Peek.card))
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
}

struct PermissionCard: View {
    @EnvironmentObject var hub: ClaudeHub
    let request: PendingRequest
    let total: Int

    private var riskColor: Color {
        switch request.risk { case .high: return Peek.rose; case .medium: return Peek.amber; case .low: return Peek.mint }
    }

    var body: some View {
        let s = hub.session(request.sessionId)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Peek.amber)
                Text("Claude wants to use \(request.tool)").font(.system(size: 14, weight: .semibold))
                Text(request.risk.rawValue.uppercased()).font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(riskColor.opacity(0.22))).foregroundStyle(riskColor)
                Spacer()
                if total > 1 { Text("1 of \(total)").font(.system(size: 11)).foregroundStyle(Peek.dim) }
            }
            if let s {
                Text("\(s.displayTitle) · \(s.project)").font(.system(size: 11)).foregroundStyle(Peek.dim).lineLimit(1)
            }
            if !request.context.isEmpty {
                Text(request.context).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }
            if !request.command.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(request.command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 76)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button { hub.skip(request.id) } label: { Text("Answer in Claude") }
                    .buttonStyle(PillButtonStyle(tint: .white.opacity(0.06), foreground: Peek.dim))
                Spacer()
                Button { withAnimation(Peek.spring) { hub.deny(request.id) } } label: {
                    Label("Deny", systemImage: "xmark")
                }
                .buttonStyle(PillButtonStyle(tint: Peek.rose.opacity(0.25), foreground: Peek.rose))
                if let always = request.alwaysAllowLabel {
                    Button { withAnimation(Peek.spring) { hub.allowAlways(request.id) } } label: {
                        Text(always).lineLimit(1).truncationMode(.tail).frame(maxWidth: 290)
                    }
                    .buttonStyle(PillButtonStyle(tint: Peek.amber.opacity(0.25), foreground: Peek.amber))
                    .help(always)
                }
                Button { withAnimation(Peek.spring) { hub.allow(request.id) } } label: {
                    Label(request.alwaysAllowLabel == nil ? "Allow" : "Allow once", systemImage: "checkmark")
                }
                .buttonStyle(PillButtonStyle(tint: Peek.amber, foreground: .black))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(14)
    }
}

struct PlanCard: View {
    @EnvironmentObject var hub: ClaudeHub
    let request: PendingRequest
    let total: Int

    private var plan: AttributedString {
        (try? AttributedString(markdown: request.planText,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(request.planText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(Peek.amber)
                Text("Plan ready for approval").font(.system(size: 14, weight: .semibold))
                Spacer()
                if total > 1 { Text("1 of \(total)").font(.system(size: 11)).foregroundStyle(Peek.dim) }
            }
            if let s = hub.session(request.sessionId) {
                Text("\(s.displayTitle) · \(s.project)").font(.system(size: 11)).foregroundStyle(Peek.dim).lineLimit(1)
            }
            ScrollView(.vertical, showsIndicators: true) {
                Text(plan.characters.isEmpty ? "Claude finished planning." : plan)
                    .font(.system(size: 11.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            HStack(spacing: 8) {
                Button { hub.skip(request.id) } label: { Text("Answer in Claude") }
                    .buttonStyle(PillButtonStyle(tint: .white.opacity(0.06), foreground: Peek.dim))
                Spacer()
                Button { withAnimation(Peek.spring) { hub.keepPlanning(request.id) } } label: { Text("Keep planning") }
                    .buttonStyle(PillButtonStyle(tint: Color.white.opacity(0.1)))
                Button { withAnimation(Peek.spring) { hub.approvePlan(request.id, autoAcceptEdits: true) } } label: {
                    Text("Approve + auto-accept edits")
                }
                .buttonStyle(PillButtonStyle(tint: Peek.amber.opacity(0.25), foreground: Peek.amber))
                Button { withAnimation(Peek.spring) { hub.approvePlan(request.id, autoAcceptEdits: false) } } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .buttonStyle(PillButtonStyle(tint: Peek.amber, foreground: .black))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(14)
    }
}

/// Claude is showing a prompt Peek can't answer directly (no hook gate reached
/// us). Pop up anyway and offer to jump to it.
struct NoticeCard: View {
    @EnvironmentObject var hub: ClaudeHub
    let request: PendingRequest
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Peek.amber)
                Text("Claude is waiting for you").font(.system(size: 14, weight: .semibold))
                Spacer()
                if total > 1 { Text("1 of \(total)").font(.system(size: 11)).foregroundStyle(Peek.dim) }
            }
            if let s = hub.session(request.sessionId) {
                Text("\(s.displayTitle) · \(s.project)").font(.system(size: 11)).foregroundStyle(Peek.dim).lineLimit(1)
            }
            Text(request.context).font(.system(size: 13, weight: .medium)).lineLimit(3)
            Text("This prompt can only be answered in Claude.").font(.system(size: 11)).foregroundStyle(Peek.faint)
            Spacer(minLength: 0)
            HStack {
                Button("Dismiss") { withAnimation(Peek.spring) { hub.dismissNotice(request.id) } }
                    .buttonStyle(PillButtonStyle(tint: .white.opacity(0.06), foreground: Peek.dim))
                Spacer()
                Button { hub.open(request.sessionId); hub.dismissNotice(request.id) } label: {
                    Label("Open Claude", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(PillButtonStyle(tint: Peek.amber, foreground: .black))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(14)
    }
}

struct QuestionCard: View {
    @EnvironmentObject var hub: ClaudeHub
    let request: PendingRequest
    let total: Int
    @StateObject private var picksBox = Box<[[String]]>([])

    private var ready: Bool {
        picksBox.v.count == request.questions.count && picksBox.v.allSatisfy { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Peek.amber)
                Text(hub.session(request.sessionId)?.displayTitle ?? "Claude").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if total > 1 { Text("1 of \(total)").font(.system(size: 11)).foregroundStyle(Peek.dim) }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(request.questions.enumerated()), id: \.offset) { i, q in
                        VStack(alignment: .leading, spacing: 6) {
                            if !q.header.isEmpty {
                                Text(q.header.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Peek.faint)
                            }
                            Text(q.question).font(.system(size: 13, weight: .medium))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                                ForEach(q.options, id: \.self) { opt in
                                    let on = i < picksBox.v.count && picksBox.v[i].contains(opt)
                                    Button { toggle(i, opt, multi: q.multiSelect) } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                                            Text(opt).lineLimit(2).multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                        }
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                        .background(RoundedRectangle(cornerRadius: 9).fill(on ? Peek.amber.opacity(0.28) : Color.white.opacity(0.07)))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Answer in Claude") { hub.skip(request.id) }
                    .buttonStyle(PillButtonStyle(tint: .white.opacity(0.06), foreground: Peek.dim))
                Spacer()
                Button("Send answer") { hub.answer(request.id, answers: picksBox.v) }
                    .buttonStyle(PillButtonStyle(tint: ready ? Peek.amber : .white.opacity(0.08), foreground: ready ? .black : Peek.faint))
                    .disabled(!ready)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(14)
        .onAppear { picksBox.v = Array(repeating: [], count: request.questions.count) }
    }

    private func toggle(_ i: Int, _ opt: String, multi: Bool) {
        guard i < picksBox.v.count else { return }
        if multi {
            if let idx = picksBox.v[i].firstIndex(of: opt) { picksBox.v[i].remove(at: idx) } else { picksBox.v[i].append(opt) }
        } else {
            picksBox.v[i] = [opt]
            // One single-choice question: answer right away.
            if request.questions.count == 1 { hub.answer(request.id, answers: picksBox.v) }
        }
    }
}

// MARK: - Calendar

struct EventRow: View {
    let event: AgendaEvent
    var compact = false

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: event.start)
    }

    private var relative: String? {
        let now = Date()
        if event.start <= now && event.end > now { return "Now" }
        let mins = Int(event.start.timeIntervalSince(now) / 60)
        if mins < 60 && mins >= 0 { return "in \(mins)m" }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3, height: compact ? 28 : 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: compact ? 12 : 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(timeText)
                    if let r = relative { Text("· \(r)").foregroundStyle(Peek.amber) }
                    if !compact, let loc = event.location, !loc.isEmpty, event.meetingURL == nil {
                        Text("· \(loc)").lineLimit(1)
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(Peek.dim)
            }
            Spacer(minLength: 4)
            if let url = event.meetingURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Join", systemImage: "video.fill") }
                    .buttonStyle(PillButtonStyle(tint: Peek.mint.opacity(0.25), foreground: Peek.mint))
            }
        }
    }
}

struct CalendarTab: View {
    @EnvironmentObject var calendar: CalendarService
    @StateObject private var newReminderBox = Box("")

    private var grouped: [(String, [AgendaEvent])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: calendar.events) { cal.startOfDay(for: max($0.start, Date())) }
        return groups.keys.sorted().map { day in
            let label = cal.isDateInToday(day) ? "Today" : cal.isDateInTomorrow(day) ? "Tomorrow"
                : day.formatted(.dateTime.weekday(.wide).day().month())
            return (label, groups[day]!.sorted { $0.start < $1.start })
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Calendar", systemImage: "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(Peek.dim)
                    Spacer()
                    Button { calendar.openCalendarApp() } label: { Image(systemName: "arrow.up.forward") }
                        .buttonStyle(IconButtonStyle(size: 20))
                }
                if !calendar.calendarAccess {
                    permission("Show your upcoming events and meeting links.", "Connect Calendar") { calendar.requestCalendar() }
                } else if calendar.events.isEmpty {
                    Text("No upcoming events in the next 3 days.").font(.system(size: 12)).foregroundStyle(Peek.dim)
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(grouped, id: \.0) { label, items in
                                Text(label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Peek.faint)
                                ForEach(items) { EventRow(event: $0) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card(14)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Reminders", systemImage: "checklist").font(.system(size: 11, weight: .semibold)).foregroundStyle(Peek.dim)
                    Spacer()
                    Button { calendar.openRemindersApp() } label: { Image(systemName: "arrow.up.forward") }
                        .buttonStyle(IconButtonStyle(size: 20))
                }
                if !calendar.remindersAccess {
                    permission("See today's reminders and tick them off.", "Connect Reminders") { calendar.requestReminders() }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            if calendar.reminders.isEmpty {
                                Text("All done for today.").font(.system(size: 12)).foregroundStyle(Peek.dim)
                            }
                            ForEach(calendar.reminders) { r in
                                HStack(spacing: 8) {
                                    Button { calendar.complete(r.id) } label: {
                                        Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(r.color)
                                    }.buttonStyle(.plain)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(r.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        if r.isOverdue, let d = r.due {
                                            Text("Overdue · \(d.formatted(.dateTime.month().day()))").font(.system(size: 10)).foregroundStyle(Peek.rose)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Peek.faint)
                        TextField("New reminder", text: $newReminderBox.v)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .onSubmit { calendar.addReminder(newReminderBox.v); newReminderBox.v = "" }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                }
            }
            .frame(width: 250)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .card(14)
        }
    }

    private func permission(_ text: String, _ button: String, _ action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 12)).foregroundStyle(Peek.dim)
            Button(button, action: action).buttonStyle(PillButtonStyle(tint: Peek.sky.opacity(0.3)))
            Spacer()
        }
    }
}

// MARK: - Music

struct MusicTab: View {
    @EnvironmentObject var music: MusicService
    @StateObject private var scrubBox = Box<Double?>(nil)
    var body: some View {
        if let np = music.current {
            HStack(spacing: 18) {
                Artwork(image: music.artwork, size: 150)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        HStack(spacing: 5) {
                            if let icon = music.appIcon {
                                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "music.note")
                            }
                            Text(np.appName)
                        }
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Peek.faint)
                        Spacer()
                        SpectrumBars(playing: np.isPlaying, bars: 7, height: 16, color: Peek.mint)
                    }
                    Text(np.title).font(.system(size: 19, weight: .bold)).lineLimit(1)
                    Text(np.artist).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    Text(np.album).font(.system(size: 11)).foregroundStyle(Peek.dim).lineLimit(1)
                    Spacer(minLength: 2)
                    progress(np)
                    HStack(spacing: 14) {
                        Spacer()
                        Button { music.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 16)) }
                            .buttonStyle(IconButtonStyle(size: 36))
                        Button { music.playPause() } label: {
                            Image(systemName: np.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20))
                        }
                        .buttonStyle(IconButtonStyle(size: 46))
                        Button { music.next() } label: { Image(systemName: "forward.fill").font(.system(size: 16)) }
                            .buttonStyle(IconButtonStyle(size: 36))
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(Peek.dim)
                        Slider(value: Binding(get: { Double(music.systemVolume) }, set: { music.setVolume(Int($0)) }), in: 0...100)
                            .controlSize(.mini).tint(.white)
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(Peek.dim)
                        Button { music.openPlayer() } label: { Image(systemName: "arrow.up.forward.app") }
                            .buttonStyle(IconButtonStyle(size: 22))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "music.note.list").font(.system(size: 30)).foregroundStyle(Peek.dim)
                Text("Nothing playing").font(.system(size: 15, weight: .semibold))
                Text("Play anything — Music, Spotify, YouTube in your browser, podcasts — and it appears here.")
                    .font(.system(size: 12)).foregroundStyle(Peek.dim)
                Button("Open Music") { music.openPlayer() }.buttonStyle(PillButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func progress(_ np: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let pos = scrubBox.v ?? music.livePosition
            let dur = max(np.duration, 1)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Color.white).frame(width: max(4, geo.size.width * CGFloat(min(pos / dur, 1))))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in scrubBox.v = max(0, min(dur, Double(v.location.x / geo.size.width) * dur)) }
                        .onEnded { _ in if let s = scrubBox.v { music.seek(to: s) }; scrubBox.v = nil })
                }
                .frame(height: 5)
                HStack {
                    Text(Self.time(pos)); Spacer(); Text("-" + Self.time(max(0, dur - pos)))
                }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Peek.faint)
            }
        }
    }

    static func time(_ t: Double) -> String {
        let s = Int(t.isFinite ? t : 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Weather

struct WeatherTab: View {
    @EnvironmentObject var weather: WeatherService

    var body: some View {
        if let now = weather.now {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        Image(systemName: WeatherCode.symbol(now.code, isDay: now.isDay))
                            .symbolRenderingMode(.multicolor).font(.system(size: 34))
                        Spacer()
                        Button { weather.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(IconButtonStyle(size: 22))
                    }
                    Text(weather.format(now.temperature)).font(.system(size: 44, weight: .semibold, design: .rounded))
                    Text(WeatherCode.text(now.code)).font(.system(size: 13, weight: .semibold))
                    Text(weather.place.isEmpty ? " " : weather.place).font(.system(size: 11)).foregroundStyle(Peek.dim)
                    Spacer(minLength: 2)
                    HStack(spacing: 10) {
                        stat("thermometer.medium", "Feels \(weather.format(now.feelsLike))")
                        stat("humidity.fill", "\(now.humidity)%")
                    }
                    stat("wind", "\(Int(now.wind.rounded())) km/h")
                }
                .frame(width: 190)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .card(14)

                VStack(spacing: 10) {
                    HStack(spacing: 0) {
                        ForEach(weather.hours.prefix(9)) { h in
                            VStack(spacing: 5) {
                                Text(h.time, format: .dateTime.hour()).font(.system(size: 10)).foregroundStyle(Peek.dim)
                                Image(systemName: WeatherCode.symbol(h.code, isDay: isDay(h.time)))
                                    .symbolRenderingMode(.multicolor).font(.system(size: 15)).frame(height: 18)
                                Text(weather.format(h.temperature)).font(.system(size: 12, weight: .semibold))
                                Text(h.precipChance > 0 ? "\(h.precipChance)%" : " ").font(.system(size: 9)).foregroundStyle(Peek.sky)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .card(10)

                    HStack(spacing: 0) {
                        ForEach(weather.days.prefix(6)) { d in
                            VStack(spacing: 5) {
                                Text(Calendar.current.isDateInToday(d.date) ? "Today" : d.date.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Peek.dim)
                                Image(systemName: WeatherCode.symbol(d.code)).symbolRenderingMode(.multicolor)
                                    .font(.system(size: 15)).frame(height: 18)
                                Text(weather.format(d.high)).font(.system(size: 12, weight: .semibold))
                                Text(weather.format(d.low)).font(.system(size: 11)).foregroundStyle(Peek.dim)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .card(10)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor).font(.system(size: 30))
                Text(weather.status ?? "Loading weather…").font(.system(size: 13)).foregroundStyle(Peek.dim)
                HStack {
                    Button("Allow location") { weather.requestPermission() }.buttonStyle(PillButtonStyle(tint: Peek.sky.opacity(0.3)))
                    Button("Retry") { weather.refresh() }.buttonStyle(PillButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isDay(_ t: Date) -> Bool {
        guard let today = weather.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: t) }),
              let rise = today.sunrise, let set = today.sunset else {
            let h = Calendar.current.component(.hour, from: t); return h >= 7 && h < 19
        }
        return t >= rise && t < set
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
    }
}

/// Stand-in for @State (the SwiftUI macro plugin ships only with full Xcode).
final class Box<T>: ObservableObject {
    @Published var v: T
    init(_ v: T) { self.v = v }
}
