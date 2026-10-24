import AppKit
import SwiftUI

// Shared pieces of the README animations, drawn to look like Orra's own interface: the
// dark capsule with white bars, the translation badge, the notice. They are drawn here
// with plain shapes, since ImageRenderer cannot draw AppKit controls or blurred
// backgrounds, and the app's views need the app's state.

enum Lang: String, CaseIterable {
    case en, zh, ja, es

    /// Whether the GIF keeps the details it was first drawn with. The Japanese and Spanish
    /// GIFs were checked against Orra 0.5.0 and draw a few things closer to the app: the
    /// Talk Key submenu, the close button and the 10 second countdown of a learned word's
    /// notice, which the pointer pauses and closes, and the update window when it is ready,
    /// with a full bar and no line of text. The English and Chinese GIFs of vocabulary and
    /// updates keep their first drawing, and their files stay the same, until they are made
    /// again with these details. Every meeting GIF shows a caption in the small style while
    /// its translation is pending, as the app does.
    var keepsFirstDrawing: Bool {
        self == .en || self == .zh
    }
}

/// A text in each language.
struct L {
    let en: String
    let zh: String
    let ja: String
    let es: String

    init(_ en: String, _ zh: String, _ ja: String, _ es: String) {
        self.en = en
        self.zh = zh
        self.ja = ja
        self.es = es
    }

    init(_ every: String) {
        self.init(every, every, every, every)
    }

    func callAsFunction(_ lang: Lang) -> String {
        switch lang {
        case .en: en
        case .zh: zh
        case .ja: ja
        case .es: es
        }
    }
}

enum Palette {
    static let wallpaper = Color(red: 0.925, green: 0.933, blue: 0.957)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let muted = Color(red: 0.43, green: 0.43, blue: 0.45)
    static let line = Color(red: 0.91, green: 0.91, blue: 0.93)
    static let accent = Color(red: 0.0, green: 0.4, blue: 0.8)
    static let green = Color(red: 0.2, green: 0.78, blue: 0.35)
}

/// Text that is never looked up in a string catalog.
func T(_ string: String) -> Text {
    Text(verbatim: string)
}

/// Whether a text is mostly Chinese or Japanese characters, kana among them, which sets how
/// fast it is spoken.
func isInCharacters(_ string: String) -> Bool {
    let characters = string.unicodeScalars.filter {
        (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
    }.count
    return characters * 3 > string.count
}

/// Characters a second: about 8.5 Chinese characters or 3 English words, as on the website.
/// Japanese is spoken at the rate of Chinese, and Spanish at the rate of English.
func speakingRate(_ string: String) -> Double {
    isInCharacters(string) ? 8.5 : 15
}

/// A voice level that moves like speech, from 0 to 1.
func voiceLevel(_ t: Double) -> Double {
    let raw = 0.45 + 0.3 * sin(t * 11.0) + 0.2 * sin(t * 17.3 + 1.0) + 0.1 * sin(t * 5.1)
    return min(max(raw, 0.05), 1)
}

// MARK: - The capsule

enum CapsuleState {
    case hidden
    case idle
    case listening(level: Double)
    /// A dictation started with a press, with how to finish it, as in Press to start and
    /// stop.
    case handsFree(level: Double, hint: String)
    case transcribing(phase: Double)
}

/// White bars, highest in the middle, as in RecordingIndicator.swift.
struct Bars: View {
    let heights: [CGFloat]
    var color: Color = .white

    static let weights = [0.45, 0.7, 0.9, 1.0, 0.9, 0.7, 0.45]
    static let minimum: CGFloat = 4
    static let maximum: CGFloat = 18

    static func heights(level: Double) -> [CGFloat] {
        weights.map { minimum + (maximum - minimum) * CGFloat(min(max(level, 0), 1) * $0) }
    }

    static func wave(phase: Double) -> [CGFloat] {
        (0..<7).map { index in
            let angle = 2 * Double.pi * (phase - Double(index) / 7)
            return minimum + 4 * CGFloat(0.5 + 0.5 * sin(angle))
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: heights[index])
            }
        }
        .frame(height: Self.maximum)
    }
}

/// The badge of a dictation that will be translated.
struct Badge: View {
    let text: String

    var body: some View {
        T(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white))
    }
}

struct OrraCapsule: View {
    let state: CapsuleState
    var badge: String? = nil

    var body: some View {
        switch state {
        case .hidden:
            Color.clear.frame(width: 1, height: 1)
        case .idle:
            Capsule()
                .fill(Color.black.opacity(0.45))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5))
                .frame(width: 40, height: 6)
        case .listening(let level):
            capsule(Bars(heights: Bars.heights(level: level)))
        case .handsFree(let level, let hint):
            capsule(Bars(heights: Bars.heights(level: level)), hint: hint)
        case .transcribing(let phase):
            capsule(Bars(heights: Bars.wave(phase: phase)))
        }
    }

    /// The bars, the badge and the hint in white, as RecordingIndicator.swift draws them.
    private func capsule(_ bars: Bars, hint: String? = nil) -> some View {
        HStack(spacing: hint == nil ? 8 : 10) {
            bars
            if let badge {
                Badge(text: badge)
            }
            if let hint {
                T(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.85))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        )
    }
}

// MARK: - Keys, spoken words, windows

/// A key of a Mac keyboard, pressed or not, with what it does below it, on one line or
/// two.
struct KeyCap: View {
    let symbol: String
    let name: String
    let caption: String
    let pressed: Bool

    var body: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    T(symbol).font(.system(size: 13))
                }
                Spacer(minLength: 0)
                T(name).font(.system(size: 11))
            }
            .foregroundStyle(pressed ? Palette.accent : Palette.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(width: 78, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(pressed ? Color(red: 0.86, green: 0.92, blue: 1.0) : .white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(pressed ? Palette.accent.opacity(0.7) : Color.black.opacity(0.18), lineWidth: 1)
            )
            .offset(y: pressed ? 2 : 0)
            T(caption)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                // Centered on two lines. One line keeps the default, which draws it a
                // fraction of a pixel apart, so the GIFs with one line stay the same.
                .multilineTextAlignment(caption.contains("\n") ? .center : .leading)
        }
    }
}

/// What the person says, shown as it is spoken. Words the paste leaves out are struck
/// through once the text is pasted.
struct SaidLine: View {
    let segments: [(text: String, dropped: Bool)]
    let shown: Int
    let strike: Bool

    var body: some View {
        T("").font(.system(size: 15)) // keeps the line height when nothing is said yet
            .overlay(alignment: .topLeading) { text }
    }

    /// 「」 around Japanese speech, which has kana, as Japanese quotes speech, and “” around
    /// any other.
    private var quotes: (open: String, close: String) {
        let japanese = segments.contains { segment in
            segment.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        }
        return japanese ? ("「", "」") : ("“", "”")
    }

    private var text: some View {
        var result = AttributedString()
        var left = shown
        var all: [(String, Bool, Bool)] = [(quotes.open, false, false)]
        for segment in segments {
            for character in segment.text {
                all.append((String(character), segment.dropped, left > 0))
                left -= 1
            }
        }
        all.append((quotes.close, false, shown >= segments.reduce(0) { $0 + $1.text.count }))
        all[0].2 = shown > 0
        for (character, dropped, visible) in all {
            var piece = AttributedString(character)
            if !visible {
                piece.foregroundColor = .clear
            } else if dropped && strike {
                piece.foregroundColor = Palette.muted.opacity(0.55)
                piece.strikethroughStyle = .single
            } else {
                piece.foregroundColor = Palette.muted
            }
            result += piece
        }
        return Text(result)
            .font(.system(size: 15))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 440, alignment: .leading)
    }
}

/// A plain Mac window with the three buttons and an optional title.
struct AppWindow<Content: View>: View {
    var title: String? = nil
    let width: CGFloat
    let height: CGFloat
    var dark = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 11, height: 11)
                Spacer()
                if let title {
                    T(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(dark ? Color.white.opacity(0.7) : Palette.muted)
                }
                Spacer()
                Color.clear.frame(width: 47, height: 1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Rectangle().fill(dark ? Color.white.opacity(0.08) : Palette.line).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : .white))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }
}

/// A text insertion point.
struct Caret: View {
    var body: some View {
        Rectangle().fill(Palette.accent).frame(width: 2, height: 18)
    }
}

/// The dark rounded box of Orra's notices, as indicatorStyle() draws it, without the blur.
struct HUDBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.16, blue: 0.17).opacity(0.97))
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}

/// A small switch and its label, to say a feature is turned on.
struct SwitchPill: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            T(label).font(.system(size: 12)).foregroundStyle(Palette.ink)
            Capsule()
                .fill(Palette.accent)
                .frame(width: 30, height: 18)
                .overlay(alignment: .trailing) {
                    Circle().fill(.white).frame(width: 14, height: 14).padding(.trailing, 2)
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white))
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
    }
}
