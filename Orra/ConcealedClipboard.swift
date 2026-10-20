import AppKit

/// Puts text on a pasteboard for the user to paste: the dictation TextInserter pastes, Copy
/// Last Dictation, the copy of Live Captions, and the draft of a Projects reply.
///
/// The text is marked with org.nspasteboard.ConcealedType so clipboard managers skip it,
/// and kept on this Mac, so Universal Clipboard does not offer it to other devices. Code in
/// Orra/Projects never names it. Projects gets it as a closure, see ReplyHandoff.
enum ConcealedClipboard {
    nonisolated static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Replaces the pasteboard's contents with the text, concealed and kept on this Mac.
    /// Nothing puts the old contents back. Not followed by declareTypes, which would clear
    /// the host only option again. Returns whether the pasteboard took the text.
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: concealedType)
        return pasteboard.writeObjects([item])
    }
}
