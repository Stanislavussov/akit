import Foundation
import NaturalLanguage

/// The language of AKit's comments in GitLab (`posting: language`, Czech by default). The
/// passes write findings, questions and gaps in it, and AKit's own texts of a draft (the header,
/// the summary) are Czech. Send lets only Czech text go to GitLab, whatever the setting or an
/// edit says. Translate only shows a translation: the drafts AKit sends stay the originals.
public enum ReviewLanguage {
    public static let czech = "cs"

    /// "Czech" for `cs`; the code itself when the system doesn't know it.
    public static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// Whether a code names a language: two or three lowercase letters the system knows.
    public static func isKnown(_ code: String) -> Bool {
        (2...3).contains(code.count) && code.allSatisfy { $0.isASCII && $0.isLowercase }
            && Locale(identifier: "en").localizedString(forLanguageCode: code) != nil
    }

    /// Whether a draft's text is Czech. Code, links, markup and AKit's header (the first line,
    /// `🤖 · …`) don't count: Czech words of the header would pass an English body. A text with
    /// no words left passes.
    public static func isCzech(_ text: String, marker: String) -> Bool {
        let prose = self.prose(text, marker: marker)
        guard prose.contains(where: \.isLetter) else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard let top = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value })?.key else { return false }
        if top == .czech { return true }
        // Short Czech often reads as Slovak: letters only Czech has settle it.
        return top == .slovak && prose.contains { "ěřůĚŘŮ".contains($0) }
    }

    /// The words of a text without code blocks, inline code, links, HTML tags, table rules,
    /// AKit's header line and the marker.
    static func prose(_ text: String, marker: String) -> String {
        var text = text
        if !marker.isEmpty {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix(marker + " · ") == true { lines.removeFirst() }
            text = lines.joined(separator: "\n")
            text = text.replacingOccurrences(of: marker, with: " ")
        }
        for pattern in ["```[\\s\\S]*?```", "`[^`\\n]*`", "https?://\\S+", "<[^>\\n]+>", "(?m)^\\|?[\\s|:-]+\\|[\\s|:-]*$"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text
    }
}
