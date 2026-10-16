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

/// The times of one dictation: key down, speaking, release, paste.
struct Dictation {
    let said: [(text: String, dropped: Bool)]
    let start: Double
    let processing: Double

    var characters: Int { said.reduce(0) { $0 + $1.text.count } }
    var rate: Double { speakingRate(said.map(\.text).joined()) }
    var keyDown: Double { start }
    var speakStart: Double { start + 0.25 }
    var speakEnd: Double { speakStart + Double(characters) / rate }
    var release: Double { speakEnd + 0.35 }
    var pasteAt: Double { release + processing }

    func pressed(_ t: Double) -> Bool { t >= keyDown && t < release }
    func shown(_ t: Double) -> Int { t < speakStart ? 0 : min(characters, Int((t - speakStart) * rate)) }
    func pasted(_ t: Double) -> Bool { t >= pasteAt }

    func capsule(_ t: Double) -> CapsuleState {
        if t < keyDown || t >= pasteAt { return .idle }
        if t < speakStart { return .listening(level: 0) }
        if t < speakEnd { return .listening(level: voiceLevel(t)) }
        if t < release { return .listening(level: 0.05) }
        return .transcribing(phase: (t - release) / 1.2)
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

let talkKey = (symbol: "⌃", name: "control", caption: L("Hold to talk", "按住说话"))
let translationKey = (symbol: "⌥", name: "option", caption: L("Hold to translate", "按住翻译"))

// MARK: - Dictation

let dictationSaid: [Lang: [(text: String, dropped: Bool)]] = [
    .en: [("Um, ", true), ("I’ll post Wednesday’s meeting notes this afternoon.", false)],
    .zh: [("呃，", true), ("周三的 meeting notes 我整理好了，下午发到群里。", false)],
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
                AppWindow(title: L("Notes", "备忘录")(lang), width: 540, height: 170) {
                    VStack(alignment: .leading, spacing: 10) {
                        T(L("Project update", "项目进展")(lang))
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

let cleanupSaid: [Lang: [(text: String, dropped: Bool)]] = [
    .en: [("Let’s go over the quote at ", false), ("three, oh wait, ", true), ("four tomorrow.", false)],
    .zh: [("明天下午", false), ("三点，哦不对，", true), ("四点，跟客户过一下报价。", false)],
]
let cleanupPasted = L("Let’s go over the quote at four tomorrow.", "明天下午四点跟客户过一下报价。")

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
                corner: AnyView(SwitchPill(label: L("Clean Up Text", "整理文字")(lang)))
            ) {
                AppWindow(title: L("New Message", "新邮件")(lang), width: 540, height: 170) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            T(L("Subject:", "主题：")(lang)).foregroundStyle(Palette.muted)
                            T(L("Quote", "报价")(lang)).foregroundStyle(Palette.ink)
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

let translationSaid: [(text: String, dropped: Bool)] = [("我这边周五之前能把设计稿发给你。", false)]

func translation(_ lang: Lang) -> Dictation {
    Dictation(said: translationSaid, start: 0.8, processing: 0.8)
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
                badge: "译"
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
                        PastedLine(text: "I can send you the designs before Friday.", shown: d.pasted(t))
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

let heard = L("Ora", "奥拉")
let firstLine = L(("We tested ", " on the new build."), ("这次用", "测了新版本。"))
let vocabularySaid: [Lang: [(text: String, dropped: Bool)]] = [
    .en: [("Orra ships on Friday.", false)],
    .zh: [("Orra 周五上线。", false)],
]

extension L {
    init(_ en: (String, String), _ zh: (String, String)) {
        self.init(en.0 + "\u{1}" + en.1, zh.0 + "\u{1}" + zh.1)
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
        let secondsLeft = max(1, Int((5.4 - t).rounded(.up)))
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
                AppWindow(title: L("Notes", "备忘录")(lang), width: 540, height: 170) {
                    VStack(alignment: .leading, spacing: 10) {
                        T(L("Test notes", "测试记录")(lang))
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
                if noticeShown {
                    HUDBox {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Palette.green)
                            VStack(alignment: .leading, spacing: 2) {
                                T(L("Added “Orra” to Vocabulary", "已把“Orra”加入个人词库")(lang))
                                T(lang == .en ? "Heard as “\(heard(lang))”" : "原来听成了“\(heard(lang))”")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }
                            T(L("Undo", "撤销")(lang))
                                .font(.system(size: 12))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18)))
                            ZStack {
                                Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
                                Circle()
                                    .trim(from: 0, to: Double(secondsLeft) / 3)
                                    .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                T("\(secondsLeft)").font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.6))
                            }
                            .frame(width: 20, height: 20)
                        }
                    }
                    .position(x: 330, y: 56)
                }
                OrraCapsule(state: t < d.keyDown ? .idle : d.capsule(t))
                    .position(x: 300, y: 350)
            }
        )
    }
)

// MARK: - Meeting Interpretation

struct Caption {
    let original: String
    let translation: String
    let originalAt: Double
    let translationAt: Double
}

let meetingCaptions = [
    Caption(original: "Can we move the launch to next Thursday?", translation: "我们能把发布挪到下周四吗？", originalAt: 2.4, translationAt: 2.9),
    Caption(original: "The test report isn’t ready yet.", translation: "测试报告还没准备好。", originalAt: 5.0, translationAt: 5.5),
]
let meetingReply = Dictation(said: [("可以，我周三之前把测试做完。", false)], start: 6.6, processing: 0.7)
let spokenReply = "Sure, I’ll finish testing by Wednesday."
let voiceStart = meetingReply.pasteAt + 0.2
let voiceEnd = voiceStart + 2.4

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
    size: CGSize(width: 600, height: 420),
    duration: { _ in voiceEnd + 2.6 },
    frame: { t, lang in
        let alexSpeaks = (t >= 0.3 && t < 2.1) || (t >= 3.1 && t < 4.7)
        let voicePlays = t >= voiceStart && t < voiceEnd
        let shown = meetingCaptions.filter { t >= $0.originalAt }
        return AnyView(
            ZStack {
                Palette.wallpaper
                AppWindow(title: L("Video Call", "视频会议")(lang), width: 568, height: 200, dark: true) {
                    HStack(spacing: 12) {
                        Tile(initial: "A", name: "Alex", color: Color(red: 0.85, green: 0.45, blue: 0.3), speaking: alexSpeaks) {
                            EmptyView()
                        }
                        Tile(initial: L("Y", "我")(lang), name: L("You", "我")(lang), color: Color(red: 0.3, green: 0.55, blue: 0.85), speaking: voicePlays) {
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
                KeyCap(symbol: translationKey.symbol, name: translationKey.name, caption: translationKey.caption(lang), pressed: meetingReply.pressed(t))
                    .position(x: 62, y: 380)
                if t >= meetingReply.keyDown {
                    SaidLine(segments: meetingReply.said, shown: meetingReply.shown(t), strike: false)
                        .frame(width: 440, height: 24, alignment: .topLeading)
                        .position(x: 360, y: 368)
                }
                OrraCapsule(state: t < meetingReply.keyDown || t >= meetingReply.pasteAt ? .idle : meetingReply.capsule(t), badge: "译")
                    .position(x: 300, y: 400)
            }
        )
    }
)

@MainActor
func captionPanel(lang: Lang, captions: [Caption], t: Double) -> some View {
    VStack(spacing: 8) {
        T(L("Live Captions", "实时字幕")(lang))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.7))
        HStack(spacing: 0) {
            T(L("Translation only", "只显示译文")(lang))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            T(L("Original and translation", "原文和译文逐句对照")(lang))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.22)))
        }
        .font(.system(size: 11))
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
        VStack(alignment: .leading, spacing: 8) {
            if captions.isEmpty {
                T(L("Captions appear here when someone speaks.", "有人说话时，字幕会显示在这里。")(lang))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            ForEach(captions.indices, id: \.self) { index in
                let caption = captions[index]
                VStack(alignment: .leading, spacing: 1) {
                    if t >= caption.translationAt {
                        T(caption.original).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
                        T(caption.translation).font(.system(size: 16)).foregroundStyle(.white)
                    } else {
                        T(caption.original).font(.system(size: 16)).foregroundStyle(.white)
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
                        T(L("Thu 9:41", "周四 9:41")(lang)).font(.system(size: 13))
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .frame(width: 600, height: 26)
                    .background(Color.white.opacity(0.8))
                    if menuOpen {
                        menu(lang: lang, hover: hover)
                            .position(x: 400, y: 112)
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

@MainActor
private func menu(lang: Lang, hover: Bool) -> some View {
    let items: [(String, Bool)] = [
        (L("Copy Last Dictation", "拷贝上次听写")(lang), false),
        (L("Talk Key: ⌃ Right Control", "说话键：⌃ 右侧 Control 键")(lang), false),
        (L("Check for Updates…", "检查更新…")(lang), true),
        (L("Report a Problem…", "报告问题…")(lang), false),
        (L("Settings…", "设置…")(lang), false),
        (L("Quit Orra", "退出 Orra")(lang), false),
    ]
    return VStack(alignment: .leading, spacing: 0) {
        ForEach(items.indices, id: \.self) { index in
            let (title, isTarget) = items[index]
            let lit = isTarget && hover
            T(title)
                .font(.system(size: 13))
                .foregroundStyle(lit ? .white : Palette.ink)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(lit ? Palette.accent : .clear))
            if index == 1 || index == 3 {
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
    return AppWindow(width: 460, height: 190) {
        HStack(alignment: .top, spacing: 16) {
            icon
            VStack(alignment: .leading, spacing: 8) {
                if !installing {
                    T(L("A new version of Orra is available.", "Orra 有新版本了。")(lang))
                        .font(.system(size: 14, weight: .bold))
                    T(L("Would you like to install it now?", "现在要安装吗？")(lang))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        button(L("Skip This Version", "跳过这个版本")(lang), primary: false)
                        Spacer(minLength: 0)
                        button(L("Remind Me Later", "以后提醒我")(lang), primary: false)
                        button(L("Install Update", "安装更新")(lang), primary: true, down: pressed)
                    }
                } else if !ready {
                    T(L("Downloading update…", "正在下载更新…")(lang))
                        .font(.system(size: 14, weight: .bold))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.line)
                        Capsule().fill(Palette.accent).frame(width: max(6, 300 * (progress * 10).rounded() / 10))
                    }
                    .frame(width: 300, height: 6)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        button(L("Cancel", "取消")(lang), primary: false)
                    }
                } else {
                    T(L("Ready to Install", "可以安装了")(lang))
                        .font(.system(size: 14, weight: .bold))
                    T(L("Orra restarts with the new version.", "Orra 会以新版本重新打开。")(lang))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        button(L("Install and Relaunch", "安装并重新启动")(lang), primary: true)
                    }
                }
            }
            .foregroundStyle(Palette.ink)
        }
        .padding(18)
    }
}
