import SwiftUI

/// A small looping picture of where to click in System Settings: the Privacy & Security
/// list with Orra's row, and a pointer that turns its switch on. Only a demonstration,
/// it changes nothing. With Reduce Motion on it shows the switch on, still.
struct PermissionDemo: View {
    nonisolated enum Kind: Sendable {
        case microphone
        case accessibility
    }

    let kind: Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the welcome window shows the picture for a permission: Accessibility while
    /// the talk key is not active for want of it, and the microphone once access was
    /// turned off. Before the first request macOS asks with its own prompt, so the
    /// microphone has no picture then.
    nonisolated static func isShown(for kind: Kind, microphone: MicrophoneAccess, hotkeyActive: Bool) -> Bool {
        switch kind {
        case .microphone: microphone == .denied
        case .accessibility: !hotkeyActive
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            PermissionDemoFrame(kind: kind, time: reduceMotion ? nil : context.date.timeIntervalSinceReferenceDate)
        }
        .accessibilityHidden(true)
    }
}

/// The picture at one moment. A nil time is the still picture with the switch on.
struct PermissionDemoFrame: View {
    let kind: PermissionDemo.Kind
    let time: Double?

    static let size = CGSize(width: 250, height: 118)
    /// One loop, in seconds.
    static let loop = 4.6
    private static let switchCenter = CGPoint(x: 222, y: 83)

    /// Where the loop stands: the pointer's place, whether it presses, and how far the
    /// switch is on.
    struct Pose: Equatable {
        var pointer: CGPoint
        var pointerOpacity: Double
        var pressing: Bool
        var switchOn: Double
        var rowHighlight: Double
    }

    static func pose(at time: Double?) -> Pose {
        let target = CGPoint(x: switchCenter.x + 2, y: switchCenter.y + 2)
        guard let time else {
            return Pose(pointer: target, pointerOpacity: 1, pressing: false, switchOn: 1, rowHighlight: 1)
        }
        let t = time.truncatingRemainder(dividingBy: loop)
        func progress(_ start: Double, _ end: Double) -> Double {
            let raw = min(max((t - start) / (end - start), 0), 1)
            // Ease in and out.
            return raw * raw * (3 - 2 * raw)
        }
        let start = CGPoint(x: 120, y: 132)
        let move = progress(0.4, 1.5)
        let pointer = CGPoint(x: start.x + (target.x - start.x) * move, y: start.y + (target.y - start.y) * move)
        let fadeIn = progress(0.1, 0.4)
        let fadeOut = 1 - progress(3.5, 3.9)
        let switchOn = progress(1.75, 1.95) * (1 - progress(4.1, 4.4))
        return Pose(
            pointer: pointer,
            pointerOpacity: fadeIn * fadeOut,
            pressing: t >= 1.65 && t < 1.85,
            switchOn: switchOn,
            rowHighlight: progress(1.2, 1.6) * (1 - progress(3.5, 4.1))
        )
    }

    var body: some View {
        let pose = Self.pose(at: time)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)

            // The title bar.
            HStack(spacing: 5) {
                Circle().fill(Color(.sRGB, red: 1.0, green: 0.37, blue: 0.34)).frame(width: 7, height: 7)
                Circle().fill(Color(.sRGB, red: 1.0, green: 0.74, blue: 0.18)).frame(width: 7, height: 7)
                Circle().fill(Color(.sRGB, red: 0.16, green: 0.79, blue: 0.25)).frame(width: 7, height: 7)
            }
            .position(x: 28, y: 11)
            Text("Privacy & Security")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .position(x: Self.size.width / 2, y: 11)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: Self.size.width, height: 1)
                .position(x: Self.size.width / 2, y: 22)
            title
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
                .frame(width: Self.size.width - 24, alignment: .leading)
                .position(x: Self.size.width / 2, y: 36)

            // The list: another app, Orra, another app.
            otherRow(y: 59, width: 58)
            Rectangle()
                .fill(Color.accentColor.opacity(0.14 * pose.rowHighlight))
                .frame(width: Self.size.width - 16, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .position(x: Self.size.width / 2, y: Self.switchCenter.y)
            orraRow(on: pose.switchOn)
            otherRow(y: 107, width: 44)

            Pointer()
                .scaleEffect(pose.pressing ? 0.86 : 1, anchor: .topLeading)
                .frame(width: 13, height: 19)
                .opacity(pose.pointerOpacity)
                .position(x: pose.pointer.x + 6.5, y: pose.pointer.y + 9.5)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder private var title: some View {
        switch kind {
        case .microphone: Text("Microphone")
        case .accessibility: Text("Accessibility")
        }
    }

    /// A row of another app, as grey shapes.
    private func otherRow(y: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(.quaternary)
                .frame(width: 15, height: 15)
                .position(x: 24, y: y)
            Capsule()
                .fill(.quaternary)
                .frame(width: width, height: 6)
                .position(x: 42 + width / 2, y: y)
            MockSwitch(on: 0)
                .position(x: Self.switchCenter.x, y: y)
        }
    }

    private func orraRow(on: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(LinearGradient(colors: [OrraGuideFigure.top, OrraGuideFigure.bottom], startPoint: .top, endPoint: .bottom))
                Circle()
                    .strokeBorder(.white, lineWidth: 1.6)
                    .padding(3)
            }
            .frame(width: 15, height: 15)
            .position(x: 24, y: Self.switchCenter.y)
            Text(verbatim: "Orra")
                .font(.system(size: 10, weight: .medium))
                .fixedSize()
                .position(x: 54, y: Self.switchCenter.y)
            MockSwitch(on: on)
                .position(Self.switchCenter)
        }
    }
}

/// A small switch, on by the given fraction.
private struct MockSwitch: View {
    let on: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.gray.opacity(0.3))
            Capsule()
                .fill(Color.accentColor)
                .opacity(on)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 0.8, y: 0.5)
                .frame(width: 11, height: 11)
                .offset(x: 1.5 + 10 * on)
        }
        .frame(width: 24, height: 14)
    }
}

/// The arrow pointer, black with a white edge.
private struct Pointer: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.height / 19
            context.scaleBy(x: scale, y: scale)
            var arrow = Path()
            arrow.move(to: CGPoint(x: 1, y: 1))
            arrow.addLine(to: CGPoint(x: 1, y: 15.5))
            arrow.addLine(to: CGPoint(x: 4.6, y: 12.2))
            arrow.addLine(to: CGPoint(x: 7.2, y: 17.8))
            arrow.addLine(to: CGPoint(x: 9.6, y: 16.7))
            arrow.addLine(to: CGPoint(x: 7.1, y: 11.3))
            arrow.addLine(to: CGPoint(x: 11.8, y: 11.3))
            arrow.closeSubpath()
            context.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            context.fill(arrow, with: .color(.black))
        }
    }
}
