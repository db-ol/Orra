import SwiftUI

/// The guide in the welcome window, drawn from the app icon: its violet to blue gradient as
/// a round body, the icon's white ring as a face, two of its bars as eyes, and the three
/// bars again as a tuft that moves like a voice. It blinks, bobs, and looks and points down
/// at the steps. With Reduce Motion on it stands still.
struct OrraGuide: View {
    /// Waves instead of pointing, once Orra is ready.
    var waves = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            OrraGuideFigure(
                time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                waves: waves
            )
        }
        .accessibilityHidden(true)
    }
}

/// The guide at one moment, drawn in a square of 100 points scaled to the frame. Time 0
/// is a still pose with open eyes.
struct OrraGuideFigure: View {
    let time: Double
    var waves = false

    /// The icon's gradient, from icon.json.
    static let top = Color(.displayP3, red: 0.48, green: 0.40, blue: 1.00)
    static let bottom = Color(.displayP3, red: 0.16, green: 0.27, blue: 0.86)
    private static let ink = Color(.displayP3, red: 0.10, green: 0.11, blue: 0.36)
    private static let cheek = Color(.displayP3, red: 1.00, green: 0.55, blue: 0.78)

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            context.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 100 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            draw(in: &context)
        }
    }

    /// Up and down by up to 2.5 points, once every 2.6 s.
    private var bob: Double {
        sin(time * 2 * .pi / 2.6) * 2.5
    }

    /// How open the eyes are, 1 open, near 0 shut: a blink of 0.16 s every 4.2 s, and a
    /// second one right after it every third time.
    private var eyeOpening: Double {
        guard time != 0 else { return 1 }
        let cycle = time.truncatingRemainder(dividingBy: 12.6)
        let phase = cycle.truncatingRemainder(dividingBy: 4.2)
        func closed(_ t: Double) -> Double {
            guard t >= 0, t < 0.16 else { return 0 }
            return sin(t / 0.16 * .pi)
        }
        var shut = closed(phase)
        if cycle >= 8.4 {
            shut = max(shut, closed(phase - 0.28))
        }
        return 1 - 0.88 * shut
    }

    private func draw(in context: inout GraphicsContext) {
        let y = bob
        let gradient = Gradient(colors: [Self.top, Self.bottom])

        // The shadow on the ground, smaller while the body is up.
        let shadowWidth = 46 + y * 2
        context.fill(
            Path(ellipseIn: CGRect(x: 50 - shadowWidth / 2, y: 92, width: shadowWidth, height: 6)),
            with: .color(.black.opacity(0.14))
        )

        // The far arm, resting.
        drawArm(in: &context, shoulder: CGPoint(x: 21, y: 63 + y), angle: .degrees(145), gradient: gradient)

        // The tuft: the icon's three bars, moving like a voice.
        let heights = [9.0, 14.0, 11.0].enumerated().map { index, height in
            height + (time == 0 ? 0 : sin(time * 5.2 + Double(index) * 1.9) * 2.2)
        }
        for (index, height) in heights.enumerated() {
            let x = 42.5 + Double(index) * 6
            let rect = CGRect(x: x, y: 13 + y - height, width: 4, height: height + 4)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 2),
                with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: 0 + y), endPoint: CGPoint(x: 0, y: 17 + y))
            )
        }

        // The body.
        let body = CGRect(x: 12, y: 12 + y, width: 76, height: 76)
        context.fill(
            Path(ellipseIn: body),
            with: .linearGradient(gradient, startPoint: CGPoint(x: 50, y: body.minY), endPoint: CGPoint(x: 50, y: body.maxY))
        )
        // A soft highlight, like the icon's glass.
        context.fill(
            Path(ellipseIn: CGRect(x: 24, y: 18 + y, width: 30, height: 16)),
            with: .color(.white.opacity(0.22))
        )

        // The ring of the glyph, as the face.
        context.stroke(
            Path(ellipseIn: CGRect(x: 23, y: 23 + y, width: 54, height: 54)),
            with: .color(.white),
            lineWidth: 6
        )

        // The eyes, two of the glyph's bars, looking down to the right at the steps.
        let opening = eyeOpening
        for x in [41.0, 59.0] {
            let height = 15 * opening
            let eye = CGRect(x: x - 3.8, y: 47 + y - height / 2, width: 7.6, height: max(height, 1.6))
            context.fill(Path(roundedRect: eye, cornerRadius: min(3.8, eye.height / 2)), with: .color(.white))
            if opening > 0.5 {
                let pupil = CGRect(x: x - 2.4 + 1.2, y: 47 + y + 2.6 - 2.4, width: 4.8, height: 4.8)
                context.fill(Path(ellipseIn: pupil), with: .color(Self.ink))
                context.fill(Path(ellipseIn: CGRect(x: pupil.minX + 0.8, y: pupil.minY + 0.7, width: 1.6, height: 1.6)), with: .color(.white))
            }
        }

        // The cheeks.
        for x in [33.0, 67.0] {
            context.fill(
                Path(ellipseIn: CGRect(x: x - 4, y: 57 + y, width: 8, height: 4.4)),
                with: .color(Self.cheek.opacity(0.55))
            )
        }

        // The smile, wider while waving.
        var mouth = Path()
        let half = waves ? 6.5 : 5.0
        mouth.move(to: CGPoint(x: 50 - half, y: 59 + y))
        mouth.addQuadCurve(to: CGPoint(x: 50 + half, y: 59 + y), control: CGPoint(x: 50, y: (waves ? 66.5 : 64.5) + y))
        context.stroke(mouth, with: .color(.white), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))

        // The near arm: points down at the steps, or waves.
        let swing = time == 0 ? 0 : sin(time * 2 * .pi / (waves ? 0.9 : 1.6))
        let angle: Angle = waves ? .degrees(-55 + swing * 22) : .degrees(38 + swing * 7)
        drawArm(in: &context, shoulder: CGPoint(x: 79, y: 63 + y), angle: angle, gradient: gradient)
    }

    /// A short round arm from the shoulder, with a round hand at its end.
    private func drawArm(in context: inout GraphicsContext, shoulder: CGPoint, angle: Angle, gradient: Gradient) {
        let length = 21.0
        let end = CGPoint(x: shoulder.x + cos(angle.radians) * length, y: shoulder.y + sin(angle.radians) * length)
        var arm = Path()
        arm.move(to: shoulder)
        arm.addLine(to: end)
        context.stroke(
            arm,
            with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: 30), endPoint: CGPoint(x: 0, y: 95)),
            style: StrokeStyle(lineWidth: 6.5, lineCap: .round)
        )
        let hand = CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: hand), with: .color(Self.top))
        context.stroke(Path(ellipseIn: hand.insetBy(dx: 0.8, dy: 0.8)), with: .color(.white.opacity(0.9)), lineWidth: 1.6)
    }
}

/// The guide's line for the step, in a bubble whose tail points at the guide.
struct GuideBubble: View {
    let line: String

    var body: some View {
        // Already in the window's language, so shown as it is.
        Text(verbatim: line)
            .font(.callout.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(alignment: .leading) {
                BubbleShape()
                    .fill(.quaternary)
            }
            .padding(.leading, 8)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: line)
    }
}

/// A rounded rectangle with a small tail on its left edge.
nonisolated private struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 10, style: .continuous)
        let middle = rect.midY
        path.move(to: CGPoint(x: rect.minX + 1, y: middle - 6))
        path.addLine(to: CGPoint(x: rect.minX - 8, y: middle))
        path.addLine(to: CGPoint(x: rect.minX + 1, y: middle + 6))
        path.closeSubpath()
        return path
    }
}
