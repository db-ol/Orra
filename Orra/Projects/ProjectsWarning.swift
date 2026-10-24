import Foundation

/// A warning the user sees about an email or a project file, whether a check in code or the
/// model found it. The raw values are the `must_flag` words of the synthetic test set, so
/// the release gate scores the warnings one to one.
nonisolated enum ProjectsWarning: String, CaseIterable, Sendable, Codable {
    /// Text the email or file hides from its reader, see ProjectsHiddenText.
    case hiddenText = "hidden_text"
    /// A line in the email that speaks to an assistant or a model.
    case instructionToAssistant = "instruction_to_assistant"
    /// A line in a project file that speaks to an assistant or a model.
    case documentInstruction = "document_instruction"
    /// Text that claims to come from Orra.
    case claimsToBeOrra = "claims_to_be_orra"
    /// A sender domain that looks like one Projects knows, such as the user's own or a
    /// project's, without being it.
    case lookalikeDomain = "lookalike_domain"
    /// A display name that does not match its address, or a known name with an unknown address.
    case senderNameMismatch = "sender_name_mismatch"
    /// A quote of the user that matches nothing the user sent.
    case forgedQuote = "forged_quote"
    /// A new bank account or another change of where to pay.
    case paymentChange = "payment_change"
    /// A change of amounts, dates or other terms of payment.
    case paymentTermsChange = "payment_terms_change"
    /// Talk of payment from a sender Projects does not know.
    case unknownSenderPayment = "unknown_sender_payment"
    /// Pressure to act at once.
    case falseUrgency = "false_urgency"
    /// A link in the email.
    case link
    /// A request to forward mail or files.
    case forwardRequest = "forward_request"
    /// A request for confidential project data.
    case confidentialDataRequest = "confidential_data_request"
    /// A request for personal data, such as an ID number.
    case personalDataRequest = "personal_data_request"
    /// A request for a password, a code or another credential.
    case credentialRequest = "credential_request"
    /// A recipient of the reply who is not among the project's people.
    case recipientNotInProjectPeople = "recipient_not_in_project_people"
    /// An attachment whose name hides its real type.
    case attachmentNameSpoofing = "attachment_name_spoofing"
}

/// How an email or a file hides text. A finding of each kind shows as the `hiddenText`
/// warning, and the hidden text itself never reaches the model.
nonisolated enum ProjectsHiddenText: String, CaseIterable, Sendable, Codable {
    /// Styles that hide text: display none, visibility hidden, a position off screen or
    /// clipped to nothing, or a class whose style does one of these.
    case hiddenStyle
    /// A font size of zero or close to it.
    case tinyFont
    /// Text in the color of its background.
    case sameColor
    /// Text with an opacity or alpha of zero or close to it.
    case transparent
    /// An HTML comment.
    case htmlComment
    /// Text in an image's alt or title text, which the reader does not see, as on an image
    /// one pixel wide.
    case imageText
    /// Zero width and other invisible characters.
    case invisibleCharacters
    /// Unicode tag characters, which can spell text no one sees.
    case tagCharacters
    /// Bidirectional controls, which change the order text shows in.
    case bidiControls
    /// The tokens of a chat template, such as the ones that start a system message.
    case chatTemplateTokens
    /// Text after a long run of blank lines.
    case afterBlankLines
}
