import Foundation

/// The one form of an email address that Projects compares and stores.
nonisolated enum ProjectsAddress {
    /// The address in lowercase, as local@domain, or nil when the text is not one address.
    ///
    /// Takes a bare address or one in angle brackets, with or without a display name, such
    /// as "Mei Tan <Mei.Tan@Harbor.example>". Gives nil for text with no address, more than
    /// one address, white space, control or format characters (such as zero width and
    /// bidirectional controls), or a character that is never part of an unquoted address.
    /// Lookalike letters stay as they are, so a lookalike domain never matches the real one.
    static func normalized(_ text: String) -> String? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasSuffix(">"), let open = address.lastIndex(of: "<") {
            address = String(address[address.index(after: open)..<address.index(before: address.endIndex)])
                .trimmingCharacters(in: .whitespaces)
        }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first, !local.isEmpty,
              let domain = parts.last, !domain.isEmpty,
              !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains(".."),
              address.unicodeScalars.allSatisfy(isAllowed) else { return nil }
        return address.lowercased()
    }

    /// Characters that an unquoted address never holds.
    private static let forbidden: Set<Unicode.Scalar> = ["<", ">", "(", ")", "[", "]", ",", ";", ":", "\\", "\""]

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .unassigned, .privateUse, .surrogate:
            false
        default:
            !forbidden.contains(scalar)
        }
    }
}
