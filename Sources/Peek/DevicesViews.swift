import SwiftUI

/// Battery outline with a level fill; while charging, a light sweep runs
/// across the fill and the bolt breathes.
struct BatteryGlyph: View {
    let percent: Int
    var charging = false
    var width: CGFloat = 30

    private var color: Color {
        if charging { return Peek.mint }
        if percent <= 10 { return Peek.rose }
        if percent <= 20 { return Peek.amber }
        return .white
    }

    var body: some View {
        let h = width * 0.48
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !charging)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 1.5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: h * 0.3, style: .continuous)
                        .stroke(Color.white.opacity(0.45), lineWidth: 1.2)
                    GeometryReader { geo in
                        let inner = geo.size.width - 4
                        let fill = max(2, inner * CGFloat(min(100, max(0, percent))) / 100)
                        RoundedRectangle(cornerRadius: h * 0.18, style: .continuous)
                            .fill(color)
                            .frame(width: fill)
                            .overlay(
                                LinearGradient(colors: [.clear, .white.opacity(charging ? 0.7 : 0), .clear],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: fill * 0.5)
                                    .offset(x: CGFloat((t * 0.8).truncatingRemainder(dividingBy: 1)) * fill * 1.5 - fill * 0.5)
                                    .clipped()
                            )
                            .clipShape(RoundedRectangle(cornerRadius: h * 0.18, style: .continuous))
                            .padding(2)
                    }
                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: h * 0.7, weight: .heavy))
                            .foregroundStyle(.black.opacity(0.75))
                            .scaleEffect(1 + 0.12 * sin(t * 4))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: width, height: h)
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.45)).frame(width: 2, height: h * 0.4)
            }
        }
    }
}

/// The banner shown around the closed notch for charging and device events.
struct ActivityBanner: View {
    @EnvironmentObject var state: NotchState
    let activity: LiveActivity

    var body: some View {
        HStack(spacing: 0) {
            left.padding(.leading, 12).frame(width: state.wingWidth, alignment: .leading)
            Color.clear.frame(width: state.notchSize.width)
            right.padding(.trailing, 12).frame(width: state.wingWidth, alignment: .trailing)
        }
        .frame(width: state.collapsedSize.width)
        .clipped()
        .transition(.opacity)
    }

    @ViewBuilder private var left: some View {
        switch activity.kind {
        case .charging(_, let charging):
            HStack(spacing: 6) {
                Image(systemName: charging ? "bolt.fill" : "powerplug")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(charging ? Peek.mint : Peek.dim)
                Text(charging ? "Charging" : "On battery").font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
        case .lowBattery:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Peek.rose)
                Text("Low battery").font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
        case .device(let d, let connected):
            HStack(spacing: 6) {
                Image(systemName: d.icon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(connected ? .white : Peek.dim)
                Text(d.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var right: some View {
        switch activity.kind {
        case .charging(let p, let charging):
            HStack(spacing: 6) {
                Text("\(p)%").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(charging ? Peek.mint : .white)
                BatteryGlyph(percent: p, charging: charging, width: 26)
            }
        case .lowBattery(let p):
            HStack(spacing: 6) {
                Text("\(p)%").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Peek.rose)
                BatteryGlyph(percent: p, width: 26)
            }
        case .device(let d, let connected):
            if !connected {
                Text("Disconnected").font(.system(size: 11)).foregroundStyle(Peek.dim)
            } else if let l = d.left, let r = d.right {
                HStack(spacing: 6) {
                    Text("L \(l)%").font(.system(size: 11, weight: .bold, design: .rounded))
                    Text("R \(r)%").font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(min(l, r) <= 20 ? Peek.amber : Peek.mint)
            } else if let m = d.lowest {
                HStack(spacing: 6) {
                    Text("\(m)%").font(.system(size: 12, weight: .bold, design: .rounded))
                    BatteryGlyph(percent: m, width: 24)
                }
            } else {
                Text("Connected").font(.system(size: 11, weight: .medium)).foregroundStyle(Peek.mint)
            }
        }
    }
}

struct DevicesTab: View {
    @EnvironmentObject var power: PowerService

    var body: some View {
        HStack(spacing: 10) {
            macCard.frame(width: 230)
            VStack(alignment: .leading, spacing: 8) {
                Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Peek.dim)
                if power.devices.isEmpty {
                    Spacer()
                    Text("No Bluetooth devices connected").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
                    Text("Connect AirPods, a speaker or a mouse — its battery pops up here.")
                        .font(.system(size: 11)).foregroundStyle(Peek.dim).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 6) { ForEach(power.devices) { DeviceRow(device: $0) } }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card(14)
        }
    }

    private var macCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This Mac", systemImage: "laptopcomputer").font(.system(size: 11, weight: .semibold)).foregroundStyle(Peek.dim)
            if let b = power.battery, b.hasBattery {
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 12) {
                    BatteryGlyph(percent: b.percent, charging: b.isCharging, width: 64)
                    Text("\(b.percent)%").font(.system(size: 34, weight: .semibold, design: .rounded))
                }
                Text(status(b)).font(.system(size: 12, weight: .medium)).foregroundStyle(b.isCharging ? Peek.mint : .white.opacity(0.85))
                if let t = timeText(b) { Text(t).font(.system(size: 11)).foregroundStyle(Peek.dim) }
                if b.lowPowerMode {
                    Label("Low Power Mode", systemImage: "leaf.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Peek.amber)
                }
                Spacer(minLength: 0)
            } else {
                Spacer()
                Text("Powered by AC").font(.system(size: 14, weight: .semibold))
                Text("This Mac has no battery.").font(.system(size: 11)).foregroundStyle(Peek.dim)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(14)
    }

    private func status(_ b: MacBattery) -> String {
        if b.isCharged || (b.onAC && b.percent >= 100) { return "Fully charged" }
        if b.isCharging { return "Charging" }
        if b.onAC { return "Plugged in, not charging" }
        return "On battery"
    }

    private func timeText(_ b: MacBattery) -> String? {
        func fmt(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
        if b.isCharging, let m = b.minutesToFull { return "\(fmt(m)) until full" }
        if !b.onAC, let m = b.minutesToEmpty { return "\(fmt(m)) remaining" }
        return nil
    }
}

struct DeviceRow: View {
    let device: BTDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.icon).font(.system(size: 16, weight: .semibold)).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 10) {
                    if let l = device.left { level("L", l) }
                    if let r = device.right { level("R", r) }
                    if let c = device.caseLevel { level("Case", c) }
                    if let m = device.main, device.left == nil { level(nil, m) }
                    if device.lowest == nil && device.caseLevel == nil {
                        Text("Connected").font(.system(size: 10)).foregroundStyle(Peek.dim)
                    }
                }
            }
            Spacer()
            if let low = device.lowest { BatteryGlyph(percent: low, width: 26) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Peek.card))
    }

    private func level(_ label: String?, _ v: Int) -> some View {
        HStack(spacing: 3) {
            if let label { Text(label).foregroundStyle(Peek.faint) }
            Text("\(v)%").foregroundStyle(v <= 20 ? Peek.amber : .white.opacity(0.85))
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
    }
}

