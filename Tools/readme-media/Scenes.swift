import AppKit
import SwiftUI

/// One animation of the README: its file name, its size and what it shows at time t.
struct Scene {
    let name: String
    var size = CGSize(width: 600, height: 380)
    let duration: (Lang) -> Double
    let frame: @MainActor (Double, Lang) -> AnyView
}

@MainActor
func allScenes(icon: NSImage?) -> [Scene] {
    [dictationScene, vocabularyScene, cleanupScene, translationScene, meetingScene, updatesScene(icon: icon)]
}

// MARK: - A dictation from key down to paste

/// How the key starts and ends a dictation, as under Keys in Settings, General.
enum KeyMode {
    /// The key is down while the person speaks, and its release pastes.
    case hold
    /// A tap of the key starts, and the next tap pastes. Meanwhile the capsule says how to
    /// finish.
    case pressToStartAndStop(finishHint: String)
}

/// The times of one dictation: key down, speaking, release, paste. In Press to start and
/// stop the key is tapped twice, and each tap counts at its release, as in the app, where a
/// press shorter than 0.3 s starts hands free at its release and the next press of the key
/// pastes at its release.
struct Dictation {
    let said: [(text: String, dropped: Bool)]
    let start: Double
    let processing: Double
    var mode = KeyMode.hold

    /// How long a tap holds the key down.
    static let tap = 0.2

    var characters: Int { said.reduce(0) { $0 + $1.text.count } }
    var rate: Double { speakingRate(said.map(\.text).joined()) }
    var keyDown: Double { start }
    /// Whether the key is tapped twice, in Press to start and stop.
    var taps: Bool {
        if case .pressToStartAndStop = mode { return true }
        return false
    }

    /// When the capsule starts listening: at the key down for Hold, at the first tap's
    /// release for Press to start and stop.
    var listenStart: Double { taps ? start + Self.tap : start }
    var speakStart: Double { listenStart + 0.25 }
    var speakEnd: Double { speakStart + Double(characters) / rate }
    /// The key down of the second tap.
    var secondKeyDown: Double { speakEnd + 0.35 }
    /// The release that ends the recording.
    var release: Double { taps ? secondKeyDown + Self.tap : speakEnd + 0.35 }
    var pasteAt: Double { release + processing }

    func pressed(_ t: Double) -> Bool {
        guard taps else { return t >= keyDown && t < release }
        return (t >= keyDown && t < listenStart) || (t >= secondKeyDown && t < release)
    }

    func shown(_ t: Double) -> Int { t < speakStart ? 0 : min(characters, Int((t - speakStart) * rate)) }
    func pasted(_ t: Double) -> Bool { t >= pasteAt }

    func capsule(_ t: Double) -> CapsuleState {
        // In Press to start and stop the first tap records silently until its release.
        if t < listenStart || t >= pasteAt { return .idle }
        if t >= release { return .transcribing(phase: (t - release) / 1.2) }
        let level = t < speakStart ? 0 : t < speakEnd ? voiceLevel(t) : 0.05
        if case .pressToStartAndStop(let hint) = mode {
            return .handsFree(level: level, hint: hint)
        }
        return .listening(level: level)
    }
}

/// The layout every dictation scene shares: the key at the top left, what is said next to
/// it, a window in the middle and the capsule at the bottom.
struct DictationStage<Window: View>: View {
    let key: (symbol: String, name: String, caption: String)
    let dictation: Dictation
    let t: Double
    var badge: String? = nil
    var corner: AnyView? = nil
    @ViewBuilder let window: Window

    var body: some View {
        ZStack {
            Palette.wallpaper
            KeyCap(symbol: key.symbol, name: key.name, caption: key.caption, pressed: dictation.pressed(t))
                .position(x: 70, y: 56)
            SaidLine(segments: dictation.said, shown: dictation.shown(t), strike: dictation.pasted(t))
                .frame(width: 440, height: 60, alignment: .topLeading)
                .position(x: 360, y: 58)
            window
                .position(x: 300, y: 204)
            OrraCapsule(state: dictation.capsule(t), badge: badge)
                .position(x: 300, y: 350)
            if let corner {
                corner.position(x: 96, y: 350)
            }
        }
    }
}

struct PastedLine: View {
    let text: String
    let shown: Bool

    var body: some View {
        HStack(spacing: 1) {
            if shown {
                T(text).font(.system(size: 15)).foregroundStyle(Palette.ink)
            }
            Caret()
        }
    }
}

// The talk key is in Hold, as for everyone who set Orra up before 0.5.0. Its caption is Hold
// %@ to talk without the key's name, which is on the key. The Spanish one is Orra's name of
// the key, since “Mantén presionada %@ para hablar” does not fit under the key on one line.
//
// The translation key is in Press to start and stop, where it starts since 0.5.1 for
// everyone who never turned Translation on. Its caption is the hint of that mode, Press %@
// to translate, and again to finish, without the key's name, on two lines. The Chinese one
// says 按一下 where the hint has the key's name. While it records, the capsule shows Press
// %@ to finish with the name, as the app does.
let talkKey = (symbol: "⌃", name: "control", caption: L("Hold to talk", "按住说话", "押したまま話す", "Tecla para hablar"))
let translationKey = (
    symbol: "⌥",
    name: "option",
    caption: L("Press to translate,\nand again to finish", "按一下翻译，\n再按一下结束", "押して翻訳し、\nもう一度押して終了", "Presiona para traducir\ny otra vez para terminar")
)
let translationFinishHint = L(
    "Press right Option to finish",
    "按右侧 Option 键结束",
    "右Optionキーを押して終了",
    "Presiona la tecla Opción derecha para terminar"
)
func translationKeyMode(_ lang: Lang) -> KeyMode {
    .pressToStartAndStop(finishHint: translationFinishHint(lang))
}

/// The badge of the translation key with Automatic, as TranslationCue.badge draws it for
/// each dictation language.
let translationBadge = L("译", "译", "訳", "⇄")

/// The window of the Notes app, as macOS names it in each language.
let notesTitle = L("Notes", "备忘录", "メモ", "Notas")

// MARK: - Dictation

// The filler rule knows Chinese and English fillers only, and it does not run on a Japanese
// or Spanish sentence, so those say none and are pasted as they are said.
let dictationSaid: [Lang: [(text: String, dropped: Bool)]] = [
    .en: [("Um, ", true), ("I’ll post Wednesday’s meeting notes this afternoon.", false)],
    .zh: [("呃，", true), ("周三的 meeting notes 我整理好了，下午发到群里。", false)],
    .ja: [("水曜日の議事録は、今日の午後に共有します。", false)],
    .es: [("Esta tarde comparto las notas de la reunión del miércoles.", false)],
]

func dictation(_ lang: Lang) -> Dictation {
    Dictation(said: dictationSaid[lang]!, start: 0.8, processing: 0.5)
}

@MainActor
let dictationScene = Scene(
    name: "dictation",
    duration: { dictation($0).pasteAt + 3 },
    frame: { t, lang in
        let d = dictation(lang)
        let pasted = d.said.filter { !$0.dropped }.map(\.text).joined()
        return AnyView(
            DictationStage(key: (talkKey.symbol, talkKey.name, talkKey.caption(lang)), dictation: d, t: t) {
                AppWindow(title: notesTitle(lang), width: 540, height: 170) {
                    VStack(alignment: .leading, spacing: 10) {
                        T(L("Project update", "项目进展", "プロジェクトの進捗", "Avances del proyecto")(lang))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Palette.ink)
                        PastedLine(text: pasted, shown: d.pasted(t))
                    }
                    .padding(18)
                }
            }
        )
    }
)

// MARK: - Cleanup

// With Japanese or Spanish as the dictation language, the cleanup model and the filler rule
// take English sentences only, so those GIFs say the English sentence.
let cleanupEnglish: [(text: String, dropped: Bool)] = [("Let’s go over the quote at ", false), ("three, oh wait, ", true), ("four tomorrow.", false)]
let cleanupSaid: [Lang: [(text: String, dropped: Bool)]] = [
    .en: cleanupEnglish,
    .zh: [("明天下午", false), ("三点，哦不对，", true), ("四点，跟客户过一下报价。", false)],
    .ja: cleanupEnglish,
    .es: cleanupEnglish,
]
let cleanupEnglishPasted = "Let’s go over the quote at four tomorrow."
let cleanupPasted = L(cleanupEnglishPasted, "明天下午四点跟客户过一下报价。", cleanupEnglishPasted, cleanupEnglishPasted)
// The email is in English when the sentence is.
let cleanupSubject = L("Quote", "报价", "Quote", "Quote")

func cleanup(_ lang: Lang) -> Dictation {
    Dictation(said: cleanupSaid[lang]!, start: 0.8, processing: 0.9)
}

@MainActor
let cleanupScene = Scene(
    name: "cleanup",
    duration: { cleanup($0).pasteAt + 3 },
    frame: { t, lang in
        let d = cleanup(lang)
        return AnyView(
            DictationStage(
                key: (talkKey.symbol, talkKey.name, talkKey.caption(lang)),
                dictation: d,
                t: t,
                corner: AnyView(SwitchPill(label: L("Clean Up Text", "整理文字", "テキストを整える", "Limpiar texto")(lang)))
            ) {
                AppWindow(title: L("New Message", "新邮件", "新規メッセージ", "Nuevo mensaje")(lang), width: 540, height: 170) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            T(L("Subject:", "主题：", "件名:", "Asunto:")(lang)).foregroundStyle(Palette.muted)
                            T(cleanupSubject(lang)).foregroundStyle(Palette.ink)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        Rectangle().fill(Palette.line).frame(height: 1)
                        PastedLine(text: cleanupPasted(lang), shown: d.pasted(t))
                            .padding(18)
                    }
                }
            }
        )
    }
)

// MARK: - Translation

// The English GIF shows the Chinese speaker. The translation key with Automatic turns a
// Japanese or Spanish sentence into English.
let translationSaid: [Lang: [(text: String, dropped: Bool)]] = [
    .en: [("我这边周五之前能把设计稿发给你。", false)],
    .zh: [("我这边周五之前能把设计稿发给你。", false)],
    .ja: [("デザインは金曜日までにお送りできます。", false)],
    .es: [("Te puedo mandar los diseños antes del viernes.", false)],
]
let translationPasted = L(
    "I can send you the designs before Friday.",
    "I can send you the designs before Friday.",
    "I can send you the designs by Friday.",
    "I can send you the designs before Friday."
)

func translation(_ lang: Lang) -> Dictation {
    Dictation(said: translationSaid[lang]!, start: 0.8, processing: 0.8, mode: translationKeyMode(lang))
}

@MainActor
let translationScene = Scene(
    name: "translation",
    duration: { translation($0).pasteAt + 3 },
    frame: { t, lang in
        let d = translation(lang)
        return AnyView(
            DictationStage(
                key: (translationKey.symbol, translationKey.name, translationKey.caption(lang)),
                dictation: d,
                t: t,
                badge: translationBadge(lang)
            ) {
                AppWindow(width: 540, height: 170) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Circle().fill(Color(red: 0.55, green: 0.42, blue: 0.85)).frame(width: 22, height: 22)
                                .overlay(T("S").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                            T("Sam").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        }
                        T("When can I see the designs?")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.91, green: 0.91, blue: 0.93)))
                        Spacer(minLength: 0)
                        PastedLine(text: translationPasted(lang), shown: d.pasted(t))
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
                    }
                    .padding(14)
                }
            }
        )
    }
)

// MARK: - Vocabulary and learning from corrections

// With Japanese or Spanish as the dictation language, Orra learns from corrections of
// English sentences only, so those GIFs fix an English sentence. The vocabulary reaches the
// speech model in every language, and a learned word replaces its heard spelling in every
// language too, so the next dictation, in the GIF's language, writes the word.
let englishHeard = "Ora"
let englishFirstLine = ("We tested ", " on the new build.")
let heard = L(englishHeard, "奥拉", englishHeard, englishHeard)
let firstLine = L(englishFirstLine, ("这次用", "测了新版本。"), englishFirstLine, englishFirstLine)
let vocabularySaid: [Lang: [(text: String, dropped: Bool)]] = [
    .en: [("Orra ships on Friday.", false)],
    .zh: [("Orra 周五上线。", false)],
    .ja: [("Orraは金曜日にリリースします。", false)],
    .es: [("Orra sale el viernes.", false)],
]
let addedWord = L("Added “Orra” to Vocabulary", "已把“Orra”加入个人词库", "“Orra”を用語集に追加しました", "Se agregó “Orra” al Vocabulario")
let heardAs = L("Heard as “%@”", "原来听成了“%@”", "“%@”と認識されていました", "Se oyó como “%@”")

extension L {
    init(_ en: (String, String), _ zh: (String, String), _ ja: (String, String), _ es: (String, String)) {
        self.init(en.0 + "\u{1}" + en.1, zh.0 + "\u{1}" + zh.1, ja.0 + "\u{1}" + ja.1, es.0 + "\u{1}" + es.1)
    }

    func parts(_ lang: Lang) -> (String, String) {
        let pieces = self(lang).components(separatedBy: "\u{1}")
        return (pieces[0], pieces[1])
    }
}

func vocabularyDictation(_ lang: Lang) -> Dictation {
    Dictation(said: vocabularySaid[lang]!, start: 5.8, processing: 0.5)
}

@MainActor
let vocabularyScene = Scene(
    name: "vocabulary",
    duration: { vocabularyDictation($0).pasteAt + 3 },
    frame: { t, lang in
        let d = vocabularyDictation(lang)
        let typed = "Orra"
        let typingStart = 1.6
        let letters = t < typingStart ? 0 : min(typed.count, Int((t - typingStart) / 0.15) + 1)
        // Chinese text puts a space around a Latin word.
        let word = letters == 0 ? heard(lang) : (lang == .zh ? " \(typed.prefix(letters)) " : String(typed.prefix(letters)))
        let selected = t >= 0.8 && t < typingStart
        let (before, after) = firstLine.parts(lang)
        let noticeShown = t >= 2.5 && t < 5.4
        // The seconds the notice has left, and the part of its ring. Nil seconds is the
        // pause sign.
        let secondsLeft: Int?
        let ringLeft: Double
        let pointerLeft = pointerWay(t)
        if lang.keepsFirstDrawing {
            let seconds = max(1, Int((5.4 - t).rounded(.up)))
            secondsLeft = seconds
            ringLeft = Double(seconds) / 3
        } else if let pointerLeft, pointerLeft < pointerOverNotice {
            // The pointer over the notice holds it, as in the app: a full ring with a
            // pause sign. Then it clicks the close button before the next dictation.
            secondsLeft = nil
            ringLeft = 1
        } else {
            // The app's 10 seconds, in a ring that empties smoothly.
            let left = 10 - (t - 2.5)
            secondsLeft = Int(left.rounded(.up))
            ringLeft = left / 10
        }
        // Kept in place after it closes, unseen, so the pointer stays where it clicked.
        let noticeKept = lang.keepsFirstDrawing ? noticeShown : t >= 2.5
        return AnyView(
            ZStack {
                Palette.wallpaper
                KeyCap(symbol: talkKey.symbol, name: talkKey.name, caption: talkKey.caption(lang), pressed: d.pressed(t))
                    .position(x: 70, y: 56)
                if t >= d.keyDown {
                    SaidLine(segments: d.said, shown: d.shown(t), strike: false)
                        .frame(width: 440, height: 60, alignment: .topLeading)
                        .position(x: 360, y: 58)
                }
                AppWindow(title: notesTitle(lang), width: 540, height: 170) {
                    VStack(alignment: .leading, spacing: 10) {
                        T(L("Test notes", "测试记录", "テスト記録", "Registro de pruebas")(lang))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Palette.ink)
                        HStack(spacing: 0) {
                            T(before)
                            T(word)
                                .background(selected ? Color(red: 0.7, green: 0.84, blue: 1.0) : .clear)
                            if letters > 0 && letters < typed.count + 1 && !d.pasted(t) && t < d.keyDown {
                                Caret().padding(.horizontal, 1)
                            }
                            T(after)
                        }
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.ink)
                        if t >= d.keyDown {
                            PastedLine(text: d.said[0].text, shown: d.pasted(t))
                        }
                    }
                    .padding(18)
                }
                .position(x: 300, y: 204)
                if noticeKept {
                    HUDBox {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Palette.green)
                            VStack(alignment: .leading, spacing: 2) {
                                T(addedWord(lang))
                                T(heardAs(lang).replacingOccurrences(of: "%@", with: heard(lang)))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }
                            T(L("Undo", "撤销", "取り消す", "Deshacer")(lang))
                                .font(.system(size: 12))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18)))
                            ZStack {
                                Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
                                Circle()
                                    .trim(from: 0, to: ringLeft)
                                    .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                Group {
                                    if let secondsLeft {
                                        T("\(secondsLeft)").font(.system(size: 9))
                                    } else {
                                        Image(systemName: "pause.fill").font(.system(size: 7))
                                    }
                                }
                                .foregroundStyle(Color.white.opacity(0.6))
                            }
                            .frame(width: 20, height: 20)
                            if !lang.keepsFirstDrawing {
                                // A borderless button, as in the app.
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.6))
                                    .frame(width: 18, height: 18)
                                    .anchorPreference(key: CloseButton.self, value: .center) { $0 }
                            }
                        }
                    }
                    .opacity(noticeShown ? 1 : 0)
                    .position(x: 330, y: 56)
                }
                OrraCapsule(state: t < d.keyDown ? .idle : d.capsule(t))
                    .position(x: 300, y: 350)
            }
            .overlayPreferenceValue(CloseButton.self) { button in
                if let button, let pointerLeft {
                    GeometryReader { proxy in
                        let target = proxy[button]
                        Pointer().offset(x: target.x + 60 * pointerLeft, y: target.y + 120 * pointerLeft)
                    }
                }
            }
        )
    }
)

/// The part of the way the pointer still has to go to the close button of the notice, nil
/// before it shows. It shows at 4.3 s and slows down to reach the button at 4.8 s, where it
/// stays.
func pointerWay(_ t: Double) -> Double? {
    guard t >= 4.3 else { return nil }
    let done = min(1, (t - 4.3) / 0.5)
    return pow(1 - done, 3)
}

/// The pointer comes from below and to the right of the close button, 60 and 120 points
/// away. The notice reaches about 25 points below its close button, so the pointer is over
/// it from this part of the way on.
let pointerOverNotice = 0.2

/// Where the close button of the notice is, for the pointer.
struct CloseButton: PreferenceKey {
    static var defaultValue: Anchor<CGPoint>? { nil }

    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

/// The Mac's arrow pointer, its tip at the top left.
struct Pointer: View {
    var body: some View {
        let arrow = Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: 17))
            path.addLine(to: CGPoint(x: 4, y: 13))
            path.addLine(to: CGPoint(x: 7, y: 19.5))
            path.addLine(to: CGPoint(x: 9.5, y: 18.5))
            path.addLine(to: CGPoint(x: 6.6, y: 12.3))
            path.addLine(to: CGPoint(x: 12, y: 12.3))
            path.closeSubpath()
        }
        return ZStack(alignment: .topLeading) {
            arrow.stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            arrow.fill(Color.black)
        }
        .frame(width: 13, height: 20, alignment: .topLeading)
        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
    }
}

// MARK: - Meeting Interpretation

struct Caption {
    let original: String
    let translation: L
    let originalAt: Double
    let translationAt: Double
}

// Alex speaks English, which Live Captions translate into the dictation language. The
// English GIF shows the Chinese captions and reply.
let meetingCaptions = [
    Caption(
        original: "Can we move the launch to next Thursday?",
        translation: L("我们能把发布挪到下周四吗？", "我们能把发布挪到下周四吗？", "リリースを来週の木曜日にずらせますか？", "¿Podemos mover el lanzamiento al próximo jueves?"),
        originalAt: 2.4,
        translationAt: 2.9
    ),
    Caption(
        original: "The test report isn’t ready yet.",
        translation: L("测试报告还没准备好。", "测试报告还没准备好。", "テストレポートはまだできていません。", "El reporte de pruebas todavía no está listo."),
        originalAt: 5.0,
        translationAt: 5.5
    ),
]
let meetingReplySaid: [Lang: [(text: String, dropped: Bool)]] = [
    .en: [("可以，我周三之前把测试做完。", false)],
    .zh: [("可以，我周三之前把测试做完。", false)],
    .ja: [("いいですよ、水曜日までにテストを終わらせます。", false)],
    .es: [("Claro, termino las pruebas para el miércoles.", false)],
]
let spokenReply = "Sure, I’ll finish testing by Wednesday."

func meetingReply(_ lang: Lang) -> Dictation {
    Dictation(said: meetingReplySaid[lang]!, start: 6.6, processing: 0.7, mode: translationKeyMode(lang))
}

/// The voice speaks the translation of the reply from just after its paste, so its times
/// follow the length of the reply in each language.
func voiceStart(_ lang: Lang) -> Double {
    meetingReply(lang).pasteAt + 0.2
}

func voiceEnd(_ lang: Lang) -> Double {
    voiceStart(lang) + 2.4
}

/// A person in the call.
struct Tile<Footer: View>: View {
    let initial: String
    let name: String
    let color: Color
    let speaking: Bool
    @ViewBuilder let footer: Footer

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 0.22, green: 0.22, blue: 0.24))
            Circle().fill(color).frame(width: 50, height: 50)
                .overlay(T(initial).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white))
                .offset(y: -12)
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    T(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                    Spacer()
                    footer
                }
            }
            .padding(8)
        }
        .frame(width: 266, height: 150)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(speaking ? Palette.green : .clear, lineWidth: 3)
        )
    }
}

@MainActor
let meetingScene = Scene(
    name: "meeting",
    // Taller than the others, for the caption of the translation key on two lines.
    size: CGSize(width: 600, height: 440),
    duration: { voiceEnd($0) + 2.6 },
    frame: { t, lang in
        let reply = meetingReply(lang)
        let alexSpeaks = (t >= 0.3 && t < 2.1) || (t >= 3.1 && t < 4.7)
        let voicePlays = t >= voiceStart(lang) && t < voiceEnd(lang)
        let shown = meetingCaptions.filter { t >= $0.originalAt }
        return AnyView(
            ZStack {
                Palette.wallpaper
                AppWindow(title: L("Video Call", "视频会议", "ビデオ通話", "Videollamada")(lang), width: 568, height: 200, dark: true) {
                    HStack(spacing: 12) {
                        Tile(initial: "A", name: "Alex", color: Color(red: 0.85, green: 0.45, blue: 0.3), speaking: alexSpeaks) {
                            EmptyView()
                        }
                        Tile(initial: L("Y", "我", "あ", "T")(lang), name: L("You", "我", "あなた", "Tú")(lang), color: Color(red: 0.3, green: 0.55, blue: 0.85), speaking: voicePlays) {
                            HStack(spacing: 4) {
                                if voicePlays {
                                    Bars(heights: Bars.heights(level: voiceLevel(t)).map { $0 * 0.6 }, color: Palette.green)
                                        .scaleEffect(0.8)
                                }
                                Image(systemName: "mic.fill").font(.system(size: 10))
                                T("Orra Microphone").font(.system(size: 10))
                            }
                            .foregroundStyle(Color.white.opacity(0.85))
                        }
                    }
                    .padding(12)
                }
                .position(x: 300, y: 112)
                if voicePlays {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 10))
                        T(spokenReply).font(.system(size: 11))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
                    .position(x: 437, y: 96)
                }
                captionPanel(lang: lang, captions: shown, t: t)
                    .position(x: 300, y: 268)
                KeyCap(symbol: translationKey.symbol, name: translationKey.name, caption: translationKey.caption(lang), pressed: reply.pressed(t))
                    .position(x: 70, y: 392)
                if t >= reply.keyDown {
                    SaidLine(segments: reply.said, shown: reply.shown(t), strike: false)
                        .frame(width: 440, height: 24, alignment: .topLeading)
                        .position(x: 360, y: 376)
                }
                // Centered below the captions, or just right of the key's caption when it
                // is too wide for that, as in Spanish. A hidden copy of the capsule with
                // the hint, its widest state, keeps every state at the same center, as the
                // app keeps it.
                HStack(spacing: 0) {
                    Color.clear.frame(width: 146, height: 1)
                    ZStack {
                        OrraCapsule(state: .handsFree(level: 0, hint: translationFinishHint(lang)), badge: translationBadge(lang))
                            .hidden()
                        OrraCapsule(state: reply.capsule(t), badge: translationBadge(lang))
                    }
                    .frame(minWidth: 308)
                    Spacer(minLength: 0)
                }
                .frame(width: 600)
                .position(x: 300, y: 420)
            }
        )
    }
)

/// The names of the three display modes, as the caption window shows them.
let captionModes = [
    L("Original", "原文", "原文", "Original"),
    L("Translated", "译文", "訳文", "Traducción"),
    L("Both", "双语", "両方", "Ambos"),
]

/// The caption target, the dictation language of each GIF, by its name in the interface.
let captionTarget = L("Chinese", "中文", "日本語", "Español")

/// The Live Captions window as CaptionWindow.swift draws it: the title, then the display
/// mode on the left with Both chosen, the caption target and Copy on the right, then the
/// captions. Copy is dimmed until the first sentence, as the app keeps it off until then.
@MainActor
func captionPanel(lang: Lang, captions: [Caption], t: Double) -> some View {
    VStack(spacing: 8) {
        T(L("Live Captions", "实时字幕", "ライブキャプション", "Subtítulos en vivo")(lang))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.7))
        HStack(spacing: 10) {
            CaptionModes(names: captionModes.map { $0(lang) }, chosen: 2)
            Spacer(minLength: 0)
            MenuLabel(symbol: "translate", title: captionTarget(lang))
            MenuLabel(symbol: "doc.on.doc", title: nil)
                .opacity(captions.isEmpty ? 0.35 : 1)
        }
        VStack(alignment: .leading, spacing: 8) {
            if captions.isEmpty {
                T(L(
                    "Captions appear here when someone speaks.",
                    "有人说话时，字幕会显示在这里。",
                    "誰かが話すと、ここにキャプションが表示されます。",
                    "Los subtítulos aparecen aquí cuando alguien habla."
                )(lang))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            ForEach(captions.indices, id: \.self) { index in
                let caption = captions[index]
                // The original in the small style, alone while its translation is
                // pending, then above it.
                VStack(alignment: .leading, spacing: 1) {
                    T(caption.original).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
                    if t >= caption.translationAt {
                        T(caption.translation(lang)).font(.system(size: 16)).foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 10)
    .frame(width: 480, height: 150)
    .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(red: 0.17, green: 0.17, blue: 0.19).opacity(0.97))
    )
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
}

/// A segmented control on the dark window, with a thin line between two segments that are
/// not chosen.
struct CaptionModes: View {
    let names: [String]
    let chosen: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(names.indices, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(index == chosen || index - 1 == chosen ? 0 : 0.18))
                        .frame(width: 1, height: 12)
                }
                T(names[index])
                    .foregroundStyle(index == chosen ? .white : Color.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(index == chosen ? Color.white.opacity(0.22) : .clear))
            }
        }
        .font(.system(size: 11))
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
    }
}

/// A borderless menu button on the dark window: a symbol, an optional title and the small
/// arrow of the menu.
struct MenuLabel: View {
    let symbol: String
    let title: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 12))
            if let title {
                T(title).font(.system(size: 11))
            }
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .foregroundStyle(Color.white.opacity(0.85))
        .fixedSize()
    }
}

// MARK: - Updates

@MainActor
func updatesScene(icon: NSImage?) -> Scene {
    Scene(
        name: "updates",
        duration: { _ in 9.0 },
        frame: { t, lang in
            let menuOpen = t >= 0.5 && t < 2.2
            let hover = t >= 1.4
            let dialog = t >= 2.5
            let installing = t >= 4.4
            let progress = min(1, max(0, (t - 4.6) / 1.6))
            let ready = t >= 6.4
            let iconView: (CGFloat) -> AnyView = { size in
                if let icon {
                    return AnyView(Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size))
                }
                return AnyView(RoundedRectangle(cornerRadius: size / 4).fill(Palette.accent).frame(width: size, height: size))
            }
            return AnyView(
                ZStack(alignment: .topLeading) {
                    Palette.wallpaper
                    // The menu bar.
                    HStack(spacing: 16) {
                        Spacer()
                        iconView(16)
                            .padding(3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(menuOpen ? Color.black.opacity(0.12) : .clear))
                        Image(systemName: "wifi").font(.system(size: 13))
                        Image(systemName: "battery.75percent").font(.system(size: 13))
                        T(L("Thu 9:41", "周四 9:41", "木 9:41", "jue 9:41")(lang)).font(.system(size: 13))
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .frame(width: 600, height: 26)
                    .background(Color.white.opacity(0.8))
                    if menuOpen {
                        // The top of the menu meets the menu bar.
                        menu(menuItems(lang), hover: hover)
                            .offset(x: 275, y: 26)
                    }
                    if dialog {
                        updateDialog(lang: lang, icon: iconView(56), pressed: t >= 4.1 && t < 4.4, installing: installing, progress: progress, ready: ready)
                            .position(x: 300, y: 205)
                    }
                }
            )
        }
    )
}

/// An item of Orra's menu: its title, whether the scene picks it and whether it opens a
/// submenu. Nil is a divider.
typealias MenuItem = (title: String, isTarget: Bool, submenu: Bool)?

/// A few items of Orra's menu, the others left out.
func menuItems(_ lang: Lang) -> [MenuItem] {
    let copy: MenuItem = (L("Copy Last Dictation", "拷贝上次听写", "最後の音声入力をコピー", "Copiar último dictado")(lang), false, false)
    let check: MenuItem = (L("Check for Updates…", "检查更新…", "アップデートを確認…", "Buscar actualizaciones…")(lang), true, false)
    let report: MenuItem = (L("Report a Problem…", "报告问题…", "問題を報告…", "Reportar un problema…")(lang), false, false)
    let settings: MenuItem = (L("Settings…", "设置…", "設定…", "Configuración…")(lang), false, false)
    let quit: MenuItem = (L("Quit Orra", "退出 Orra", "Orraを終了", "Salir de Orra")(lang), false, false)
    if lang.keepsFirstDrawing {
        // The line of the Talk Key submenu, at the top level.
        let talkKeyLine: MenuItem = (lang == .en ? "Talk Key: ⌃ Right Control" : "说话键：⌃ 右侧 Control 键", false, false)
        return [copy, talkKeyLine, nil, check, report, nil, settings, quit]
    }
    // The Talk Key submenu and the dividers where StatusMenu.swift puts them.
    let talkKey: MenuItem = (L("Talk Key", "说话键", "音声入力キー", "Tecla para hablar")(lang), false, true)
    return [copy, nil, talkKey, nil, check, report, settings, nil, quit]
}

@MainActor
private func menu(_ items: [MenuItem], hover: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        ForEach(items.indices, id: \.self) { index in
            if let item = items[index] {
                let lit = item.isTarget && hover
                T(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(lit ? .white : Palette.ink)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if item.submenu {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.muted)
                                .padding(.trailing, 10)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 5).fill(lit ? Palette.accent : .clear))
            } else {
                Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 10)
            }
        }
    }
    .padding(5)
    .frame(width: 250)
    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.97)))
    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
}

@MainActor
private func updateDialog(lang: Lang, icon: AnyView, pressed: Bool, installing: Bool, progress: Double, ready: Bool) -> some View {
    func button(_ title: String, primary: Bool, down: Bool = false) -> some View {
        T(title)
            .font(.system(size: 13))
            .foregroundStyle(primary ? .white : Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(primary ? (down ? Color(red: 0.0, green: 0.3, blue: 0.65) : Palette.accent) : .white)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(primary ? 0 : 0.15), lineWidth: 1))
    }
    func bar(_ progress: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Palette.line)
            Capsule().fill(Palette.accent).frame(width: max(6, 300 * (progress * 10).rounded() / 10))
        }
        .frame(width: 300, height: 6)
    }
    // The Japanese and Spanish texts are Sparkle's own, as Orra shows them. Their buttons
    // are longer, so the window is wider.
    let width: CGFloat = lang == .ja || lang == .es ? 580 : 460
    return AppWindow(width: width, height: 190) {
        HStack(alignment: .top, spacing: 16) {
            icon
            VStack(alignment: .leading, spacing: 8) {
                if !installing {
                    T(L("A new version of Orra is available.", "Orra 有新版本了。", "新しいバージョンのOrraが入手できます!", "¡Una nueva versión de Orra está disponible!")(lang))
                        .font(.system(size: 14, weight: .bold))
                    T(L("Would you like to install it now?", "现在要安装吗？", "今すぐダウンロードしますか?", "¿Querrías descargarla ahora?")(lang))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        button(L("Skip This Version", "跳过这个版本", "このバージョンはスキップ", "No instalar esta versión")(lang), primary: false)
                        Spacer(minLength: 0)
                        button(L("Remind Me Later", "以后提醒我", "あとで通知", "Recordármelo")(lang), primary: false)
                        button(L("Install Update", "安装更新", "アップデートをインストール", "Instalar actualización")(lang), primary: true, down: pressed)
                    }
                } else if !ready {
                    T(L("Downloading update…", "正在下载更新…", "アップデートをダウンロードしています…", "Descargando actualización…")(lang))
                        .font(.system(size: 14, weight: .bold))
                    bar(progress)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        button(L("Cancel", "取消", "キャンセル", "Cancelar")(lang), primary: false)
                    }
                } else {
                    T(L("Ready to Install", "可以安装了", "インストールできます", "Lista para instalarse")(lang))
                        .font(.system(size: 14, weight: .bold))
                    if lang.keepsFirstDrawing {
                        T(lang == .en ? "Orra restarts with the new version." : "Orra 会以新版本重新打开。")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                    } else {
                        // Sparkle shows no text here, only the full bar.
                        bar(1)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        button(L("Install and Relaunch", "安装并重新启动", "インストールして再起動", "Instalar y volver a abrir")(lang), primary: true)
                    }
                }
            }
            .foregroundStyle(Palette.ink)
        }
        .padding(18)
    }
}
