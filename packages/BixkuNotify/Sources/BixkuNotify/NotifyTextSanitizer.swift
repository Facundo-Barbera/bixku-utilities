import Foundation

/// Cleans text that arrives from outside the app (URLs, other processes) before it is
/// stored, matched against rules or shown. Treat everything it returns as display text only.
public enum NotifyTextSanitizer {
    /// Returns `raw` without control characters, invisible formatting characters
    /// (bidirectional overrides, zero-width marks, BOM) or unassigned / private-use scalars,
    /// with whitespace normalized, trimmed and cut to at most `maxLength` characters
    /// (the last one is `…` when cut).
    ///
    /// - Parameter allowNewlines: keep line breaks (at most one blank line in a row). When
    ///   `false` every line break becomes a space.
    public static func clean(_ raw: String, maxLength: Int, allowNewlines: Bool = false) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        var pendingBreaks = 0
        var previousWasCR = false

        for scalar in raw.unicodeScalars {
            if scalar == "\n", previousWasCR {
                previousWasCR = false
                continue // second half of "\r\n"
            }
            previousWasCR = scalar == "\r"

            switch scalar {
            case "\n", "\r", "\u{85}", "\u{2028}", "\u{2029}":
                pendingBreaks += 1
            case "\t":
                pendingSpace = true
            default:
                if scalar.properties.generalCategory == .spaceSeparator {
                    pendingSpace = true
                } else if isAllowed(scalar) {
                    if !result.isEmpty {
                        if pendingBreaks > 0 && allowNewlines {
                            result.append("\n")
                            if pendingBreaks > 1 { result.append("\n") }
                        } else if pendingBreaks > 0 || pendingSpace {
                            result.append(" ")
                        }
                    }
                    pendingBreaks = 0
                    pendingSpace = false
                    result.append(scalar)
                }
            }
        }
        return truncate(String(result), to: maxLength)
    }

    /// Whether `text` has nothing visible once cleaned.
    public static func isBlank(_ text: String) -> Bool {
        clean(text, maxLength: 1).isEmpty
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
            return false
        case .format:
            // Zero-width joiner glues emoji sequences; every other format character
            // (bidi controls, zero-width space, BOM, tag characters...) is dropped.
            return scalar == "\u{200D}"
        default:
            return true
        }
    }

    private static func truncate(_ text: String, to maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        guard text.count > maxLength else { return text }
        let kept = String(text.prefix(maxLength - 1))
        return kept.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
