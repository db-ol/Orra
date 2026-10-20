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
    /// The result is in the composed form, so the same address always has the same bytes.
    static func normalized(_ text: String) -> String? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasSuffix(">"), let open = address.lastIndex(of: "<") {
            guard isDisplayName(address[..<open]) else { return nil }
            address = String(address[address.index(after: open)..<address.index(before: address.endIndex)])
                .trimmingCharacters(in: .whitespaces)
        }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first, !local.isEmpty,
              let domain = parts.last, !domain.isEmpty,
              !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains(".."),
              address.unicodeScalars.allSatisfy(isAllowed) else { return nil }
        return address.lowercased().precomposedStringWithCanonicalMapping
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

    /// Whether the text before the angle brackets is a display name and not more addresses.
    /// Outside quotes it must hold no angle bracket, and no comma or semicolon after an @,
    /// as in "lu@harbor.example, Mei". A name such as "Tan, Mei" in quotes, or an address
    /// used as the name, passes.
    private static func isDisplayName(_ name: Substring) -> Bool {
        var quoted = false
        var escaped = false
        var sawAt = false
        for character in name {
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
                continue
            }
            switch character {
            case "\"":
                quoted = true
            case "<", ">":
                return false
            case "@":
                sawAt = true
            case ",", ";":
                if sawAt { return false }
            default:
                break
            }
        }
        return !quoted
    }
}
