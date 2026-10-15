import AppKit
import SwiftUI

/// The floating caption window: always on top, on every Space and over full screen apps,
/// translucent, and moved by dragging anywhere on it. Closing it turns captions off.
/// macOS remembers where it was and its size.
final class CaptionWindow: NSObject, NSWindowDelegate {
    static let defaultSize = CGSize(width: 520, height: 260)
    static let minimumSize = CGSize(width: 300, height: 140)

    private let captions: MeetingCaptions
    private let pushToTalk: PushToTalkController
    private let cleanup: TextCleanup
    private var panel: NSPanel?

    init(captions: MeetingCaptions, pushToTalk: PushToTalkController, cleanup: TextCleanup) {
        self.captions = captions
        self.pushToTalk = pushToTalk
        self.cleanup = cleanup
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Without taking the focus from the call.
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Internal so tests can check the panel without showing it.
    func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = String(localized: "Meeting Captions")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        // On every Space, over full screen apps too.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = Self.minimumSize
        panel.delegate = self
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        let content = NSHostingView(rootView: CaptionView(captions: captions, pushToTalk: pushToTalk, cleanup: cleanup))
        content.translatesAutoresizingMaskIntoConstraints = false
        // Only the minimum size. With the default, the scroll view's growing content sets
        // the window's height, and the user could not make it shorter.
        content.sizingOptions = [.minSize]
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        if !panel.setFrameUsingName(Self.frameName) {
            place(panel)
        }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private static let frameName = "MeetingCaptions"

    /// The first time: bottom center of the main screen, above where the recording
    /// indicator shows.
    private func place(_ panel: NSPanel) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.midX - Self.defaultSize.width / 2, y: visible.minY + 140))
    }

    func windowWillClose(_ notification: Notification) {
        captions.setOn(false)
    }
}

/// The captions, newest at the bottom, with what is in the way above them and the display
/// mode at the top.
struct CaptionView: View {
    @Bindable var captions: MeetingCaptions
    let pushToTalk: PushToTalkController
    @Bindable var cleanup: TextCleanup

    /// What onScrollGeometryChange reports to CaptionFollow.
    private struct ScrollGeometry: Equatable {
        let offset: Double
        let contentHeight: Double
        let viewportHeight: Double
    }

    private static let bottom = "bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show", selection: Binding(get: { captions.displayMode }, set: { captions.setDisplayMode($0) })) {
                ForEach(CaptionDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            CaptionNotes(captions: captions, pushToTalk: pushToTalk, cleanup: cleanup)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if captions.store.sentences.isEmpty {
                            Text("Captions appear here when someone speaks.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(captions.store.sentences) { sentence in
                            CaptionSentenceView(lines: captions.displayMode.lines(for: sentence))
                                .id(sentence.id)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
                    ScrollGeometry(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height, viewportHeight: geometry.containerSize.height)
                } action: { _, geometry in
                    captions.follow.update(offset: geometry.offset, contentHeight: geometry.contentHeight, viewportHeight: geometry.viewportHeight)
                }
                // Without animation: the steps of an animated scroll would read as the user
                // scrolling up.
                .onChange(of: captions.store.sentences) {
                    if captions.follow.isFollowing {
                        proxy.scrollTo(Self.bottom, anchor: .bottom)
                    }
                }
                .onChange(of: captions.displayMode) {
                    if captions.follow.isFollowing {
                        proxy.scrollTo(Self.bottom, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !captions.follow.isFollowing, !captions.store.sentences.isEmpty {
                        Button("Jump to Latest") {
                            captions.follow.jumpToLatest()
                            proxy.scrollTo(Self.bottom, anchor: .bottom)
                        }
                        .controlSize(.small)
                        .padding(6)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 12)
        .frame(minWidth: CaptionWindow.minimumSize.width, minHeight: CaptionWindow.minimumSize.height)
        .alert("Download the model for translation?", isPresented: $cleanup.isConfirmingCaptionDownload) {
            Button(CleanupLabels.downloadButton(cleanup.models.state, total: cleanup.models.manifest.totalBytes)) {
                cleanup.confirmCaptionDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model comes from Hugging Face or a mirror. Your text stays on this Mac.")
        }
    }
}

/// One sentence: the main line large, the original small above it.
private struct CaptionSentenceView: View {
    let lines: [CaptionDisplayMode.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line.style {
                case .main:
                    Text(verbatim: line.text)
                        .font(.title3)
                case .secondary:
                    Text(verbatim: line.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Why captions are not complete yet: the capture, the speech model, the local model.
private struct CaptionNotes: View {
    let captions: MeetingCaptions
    let pushToTalk: PushToTalkController
    let cleanup: TextCleanup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch captions.capture {
            case .unavailable(.notConfigured):
                note("This build of Orra cannot capture the sound the Mac plays yet.")
            case .unavailable(.failed):
                note("Orra could not capture the sound the Mac plays. Turn Meeting Captions off and on again to try again.")
            case .off, .starting, .listening:
                if captions.hearsOnlySilence {
                    note("No sound from the Mac yet. If something is playing, allow Orra under Screen & System Audio Recording in Privacy & Security settings.")
                }
            }
            if pushToTalk.modelState != .ready || captions.speechModelMissing {
                note("The speech model is not ready. Captions start once it is loaded.")
            }
            // No translation notes or download until the capture runs. While it starts,
            // captions do not need the model yet, and a download agreed to then would be
            // ignored.
            if captions.capture == .listening {
                translationNote
            }
        }
    }

    @ViewBuilder
    private var translationNote: some View {
        let total = cleanup.models.manifest.totalBytes
        switch cleanup.models.state {
        case .installed:
            switch cleanup.engineState {
            case .loading:
                plainNote(CleanupLabels.loading(.translation))
            case .failed:
                plainNote(CleanupLabels.failedToLoad(.translation))
            case .unloaded, .ready:
                EmptyView()
            }
        case .missing:
            plainNote(String(localized: "The local model is not on this Mac yet. Until it is, captions show what was said without translation."))
            Button(CleanupLabels.downloadButton(cleanup.models.state, total: total)) {
                cleanup.isConfirmingCaptionDownload = true
            }
            .controlSize(.small)
        case .downloading(let bytes, _):
            plainNote(CleanupLabels.progress(bytes: bytes, total: total, use: .translation))
        case .failed:
            ForEach(cleanup.models.state.menuLines(total: total), id: \.self) { line in
                plainNote(line)
            }
            Button(CleanupLabels.downloadButton(cleanup.models.state, total: total)) {
                cleanup.confirmCaptionDownload()
            }
            .controlSize(.small)
        case .checking, .verifying:
            EmptyView()
        }
    }

    private func note(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func plainNote(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension CaptionDisplayMode {
    /// The name in the picker.
    var title: LocalizedStringKey {
        switch self {
        case .translationOnly: "Translation only"
        case .originalAndTranslation: "Original and translation"
        }
    }
}
