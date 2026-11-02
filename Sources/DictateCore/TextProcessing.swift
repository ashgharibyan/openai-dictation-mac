import Foundation

/// How the raw transcript is post-processed before insertion.
public enum OutputMode: String, CaseIterable, Identifiable, Sendable {
    /// Exactly what the transcription model returned.
    case verbatim
    /// Local, deterministic: removes filler sounds and tidies spacing. No extra API call.
    case clean
    /// Separate text-model call (extra cost). Falls back to Clean output if anything looks off.
    case polished

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean: return "Clean"
        case .polished: return "Polished"
        }
    }

    public var explanation: String {
        switch self {
        case .verbatim: return "Inserts the transcript exactly as returned by the transcription model."
        case .clean: return "Removes filler sounds (um, uh, hmm) and tidies spacing on this Mac. No extra cost."
        case .polished: return "Sends the transcript to a separate OpenAI text model to fix grammar and readability. Extra API cost and latency; meaning is kept, and the app falls back to Clean if the result looks altered."
        }
    }
}

public enum TextCleaner {
    private static let filler = #"(?:u+m+|u+h+m*|e+r+m+|h+m+|m+h+m+)"#

    /// Removes standalone filler sounds and fixes the spacing and punctuation they leave behind.
    /// Real words are never touched (e.g. "um" inside "umbrella", or "like" / "you know").
    public static func clean(_ text: String) -> String {
        // A filler that starts a sentence: drop it and capitalize the word that now starts it.
        var s = replaceMatches(in: text, pattern: #"(?i)(^\s*|[.!?]\s+)\b"# + filler + #"\b,?\s+(\p{Ll})"#) { groups in
            groups[1] + groups[2].uppercased()
        }
        s = s.replacingOccurrences(of: #"(?i)\b"# + filler + #"\b,?"#, with: "", options: .regularExpression)
        let fixes: [(String, String)] = [
            (#"[ \t]+([,.!?;:])"#, "$1"),         // space before punctuation
            (#"([,;:])\s*(?=[,.!?;:])"#, ""),     // ", ," / ", ." left behind
            (#"^\s*[,;:]\s*"#, ""),               // leading comma
            (#"[ \t]{2,}"#, " "),
        ]
        for (pattern, template) in fixes {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceMatches(in text: String, pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result = result.replacingCharacters(in: match.range, with: transform(groups)) as NSString
        }
        return result as String
    }

    /// Final shaping before insertion. Never adds a trailing newline (which a terminal would
    /// treat as Return); with `singleLine`, interior line breaks become spaces too.
    public static func prepareForInsertion(_ text: String, singleLine: Bool) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine {
            s = s.replacingOccurrences(of: #"\s*[\r\n]+\s*"#, with: " ", options: .regularExpression)
        }
        return s
    }

    public static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Guards the Polished output against a text model that adds or drops content.
public enum PolishGuard {
    public static func isAcceptable(original: String, polished: String) -> Bool {
        let a = TextCleaner.wordCount(original)
        let b = TextCleaner.wordCount(polished)
        guard b > 0 else { return false }
        if a < 8 { return abs(a - b) <= 4 }
        let ratio = Double(b) / Double(a)
        return ratio >= 0.6 && ratio <= 1.3
    }
}
