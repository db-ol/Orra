import Foundation

nonisolated extension DraftCheck {
    /// The sentences of a draft that say a file is attached to it, such as "Attached is the
    /// floor plan.", "Please find attached", 附上平面图, 随信附上, 図面を添付いたします or "Te
    /// adjunto el plano", as the draft writes them.
    ///
    /// The window shows a line when the draft in the editor says so while no file is ticked
    /// for the reply, read when typing pauses, never at each key press. It never changes the
    /// draft, and `check(_:)` does not call it, so every draft the model makes is checked as
    /// before.
    ///
    /// A sentence about the other side's attachment, such as "Thanks for the attached plan",
    /// 感谢您附上的文件 or "el archivo que me adjuntaste", and a request, such as "please
    /// attach", 请附上 or "adjunta el plano", is no claim: those words are taken out of the
    /// sentence before the claim patterns read it, so a sentence that also makes a claim of
    /// its own still counts. The patterns read the matching form of SortingText and are
    /// bounded, and the first `claimedLength` characters are read.
    static func attachmentClaims(in draft: String) -> [String] {
        let text = String(SortingText.withoutFormatCharacters(draft).prefix(claimedLength))
        return sentenceRanges(in: text).compactMap { range in
            let sentence = String(text[range])
            var form = SortingText.matchingForm(sentence)
            for pattern in notClaims {
                form = pattern.stringByReplacingMatches(in: form, range: NSRange(form.startIndex..., in: form), withTemplate: " ")
            }
            return ContentChecks.matches(claims, form) ? sentence : nil
        }
    }

    /// How much of a draft the claim check reads. A reply is far shorter.
    static let claimedLength = 20_000

    /// Words that say a file is attached to the draft, in its matching form.
    private static let claims = ContentChecks.patterns([
        // English
        #"\battached (?:is|are|please find|you will find|you['’]ll find|herewith|to this (?:e-?mail|message|mail))\b"#,
        #"\b(?:please )?(?:find|see) (?:the )?(?:attached|enclosed)\b"#,
        #"\b(?:i|we)(?:['’]ve| have)(?: also| just| now)? (?:attached|enclosed)\b"#,
        #"\b(?:i['’]m|i am|we['’]re|we are) (?:also |now )?(?:attaching|enclosing)\b"#,
        #"\bsee (?:the )?attachments?\b|\bin the attachments?\b|\bas (?:an )?attachments?\b"#,
        #"\benclosed (?:is|are|please find)\b|\bplease find enclosed\b"#,
        // Chinese
        #"附上|随信附|随函附|附件是|附件为|见附件|请查收附件|附件中|已附|作为附件|在附件里"#,
        // Japanese
        #"添付(?:いた|致)します|添付します|添付しました|添付(?:いた|致)しました|添付しております|添付させていただ|添付のファイル|添付の資料|添付ファイルをご確認|同封(?:いた|致)します"#,
        // Spanish, with and without accents
        #"\b(?:te |le |les |os )?adjunto\b|\badjuntamos\b|\b(?:he|hemos) adjuntado\b|\bvan? adjunt[oa]s?\b|\bencontrar[aá]s? adjunt[oa]s?\b|\ben el (?:archivo|documento) adjunto\b|\bte env[ií]o adjunt[oa]s?\b"#,
    ])

    /// Words about the other side's attachment, and requests to attach, taken out of a
    /// sentence before the claim patterns read it.
    private static let notClaims = ContentChecks.patterns([
        // English
        #"\b(?:thanks|thank you|thx|many thanks)(?: so much| very much| again)? for (?:the|your|sending|attaching|sharing)\b[^.!?]{0,40}?\b(?:attached|attachments?|enclosed)\b"#,
        #"\byour (?:attached|attachments?|enclosed)\b"#,
        #"\b(?:attached|attachments?|enclosed)(?: [a-z]+){0,3} (?:you|they|he|she) (?:sent|shared|attached|forwarded|included)\b"#,
        #"\b(?:you|they|he|she)(?:['’]ve| have| had)?(?: also| just)? (?:attached|enclosed)\b"#,
        #"\b(?:please|kindly|could you|can you|would you)(?: also)? (?:attach|enclose)\b"#,
        // Chinese
        #"(?:感谢|谢谢|多谢)(?:您|你|贵司)?(?:的)?附上"#,
        #"(?:您|你|贵司|对方)(?:们)?(?:之前|刚才|上次)?附上的"#,
        #"收到(?:了)?(?:您|你|贵司)(?:们)?的附件"#,
        #"(?:您|你|贵司)(?:们)?(?:的|发来的)附件"#,
        #"(?:请|麻烦|劳烦|烦请|能否|可否|是否|能不能|可不可以|记得)(?:您|你)?(?:们)?(?:再|也)?附上"#,
        // Japanese
        #"ご添付いただ|添付していただ|添付してください|添付をお願い|(?:いただいた|頂いた|くださった|下さった)添付"#,
        // Spanish
        #"\bque (?:me |nos |le |les )?adjunt(?:aste|asteis|aron|[oó]|aba|abas)\b"#,
        #"\b(?:tu|tus|su|sus|vuestro|vuestra|vuestros|vuestras)(?: [a-záéíóúñ]+){0,2} adjunt[oa]s?\b"#,
        #"\bgracias por (?:el|la|los|las|tu|tus|su|sus|enviar|mandar|compartir)\b[^.!?]{0,40}?\badjunt[oa]s?\b"#,
    ])
}
