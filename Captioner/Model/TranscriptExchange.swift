import Foundation

/// Copies the captions out for proofreading with an assistant such as Claude, and reads the
/// reply back in. Both directions are kept lean, since the whole transcript is sent each time:
///
/// - Out: `[n] start text` per caption, start in seconds. Pauses of `pauseMark` or more show as
///   `(1.2s)`, and words the speech engine was unsure of are followed by `(?)`.
/// - Back, inside a code block, either the complete new caption list as plain text, one caption
///   per line (the app times every word by lining it up with the recognized words), or only the
///   captions to change as `[n] text`. A line written `start–end text` is retimed to those times.
///
/// A reply can also name words for the speech engine to listen for (`Vocabulary: a; b`).
nonisolated enum TranscriptExchange {
    /// Below this the engine's confidence in a word is marked for the proofreader.
    static let lowConfidence = 0.5
    /// Gaps between words at least this long are shown, so captions can break at pauses.
    static let pauseMark: TimeInterval = 0.3

    // MARK: - Writing

    /// `[n] start – end text` for people. With `compact`, the proofreading form: `[n] start text`
    /// with pauses and unsure words marked.
    static func lines(for captions: [Caption], compact: Bool = false) -> String {
        var previousEnd: TimeInterval?
        return captions.enumerated().map { index, caption in
            guard compact else {
                return "[\(index + 1)] \(TimeFormat.cue(caption.start)) – \(TimeFormat.cue(caption.end)) \(caption.text)"
            }
            var pieces: [String] = []
            for word in caption.words {
                if let previousEnd, word.start - previousEnd >= pauseMark, !pieces.isEmpty {
                    pieces.append("(\(String(format: "%.1f", word.start - previousEnd))s)")
                }
                pieces.append((word.confidence ?? 1) < lowConfidence ? word.text + "(?)" : word.text)
                previousEnd = word.end
            }
            // A pause before the caption shows in its start time; mark it too when it is long.
            var line = "[\(index + 1)] \(seconds(caption.start)) "
            if let gap = index > 0 ? caption.start - captions[index - 1].end : nil, gap >= pauseMark {
                line += "(\(String(format: "%.1f", gap))s) "
            }
            return line + pieces.joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func seconds(_ time: TimeInterval) -> String { String(format: "%.2f", max(0, time)) }

    static func languageName(_ localeIdentifier: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
    }

    static func limits(_ grouping: CaptionGrouping) -> String {
        let characters = grouping.maxCharactersPerLine * max(grouping.maxLines, 1)
        return "at most \(grouping.maxWords) words, ~\(characters) characters, \(Int(grouping.maxDuration.rounded())) s"
    }

    /// How the captions are written and how to reply. Goes in the system prompt in the app, and
    /// at the top of the copied prompt.
    static func formatRules(_ grouping: CaptionGrouping) -> String {
        """
        Input: one caption per line, `[n] start words`, start in seconds. `(1.2s)` marks a pause; \
        `(?)` follows a word the speech engine was unsure of, so check those hardest.

        Reply with caption lines in one code block, in one of these forms:
        - Whole list (to re-cut or proofread everything): every caption in order, one per line, \
        text only, no numbers or times. The app times each word from the recognition, so keep every \
        word in spoken order; never reorder, paraphrase or invent words.
        - A few captions: only those lines, as `[n] new text`.
        - To retime a caption on purpose, write it as `start–end text` in seconds.
        Captions: \(limits(grouping)). Break at sentence ends first, then commas, phrases and \
        pauses. Don't end a caption on a preposition or conjunction; avoid one-word captions.
        If names or terms were misheard, add after the block one line `Vocabulary: a; b` (max 30) \
        so the engine can listen for them in a new transcription.
        """
    }

    /// The task, without the format rules (the app sends those as the system prompt).
    static func task(localeIdentifier: String) -> String {
        let language = languageName(localeIdentifier)
        return """
        Proofread these \(language) speech-recognition captions into correct, natural written \
        \(language): fix misheard words, diacritics, grammar, punctuation, capitals and sentence \
        boundaries, and re-cut them into readable captions. Keep what was said; drop only \
        recognition junk and stutters. Reply with the whole list.
        """
    }

    /// Everything in one message, for pasting into a chat outside the app.
    static func prompt(for captions: [Caption], localeIdentifier: String, grouping: CaptionGrouping, instructions: String = "") -> String {
        "\(task(localeIdentifier: localeIdentifier))\n\n\(formatRules(grouping))\(styleSection(instructions))\n\n\(lines(for: captions, compact: true))"
    }

    /// The user's own style rules, if any, set apart so they win over the defaults.
    static func styleSection(_ instructions: String) -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "\n\nThe user's style instructions. Follow them; they override the defaults above, but not the reply format:\n\(trimmed)"
    }

    // MARK: - Reading

    struct Result {
        var captions: [Caption]
        var changed: Int
        var matched: Int
        /// The reply was a complete new caption list rather than per-caption text edits.
        var restructured: Bool
    }

    enum ParseError: LocalizedError {
        case noLines
        case outOfRange(Int, count: Int)

        var errorDescription: String? {
            switch self {
            case .noLines:
                "No caption lines were found. Copy the whole reply: lines like `0.40 – 1.80 text` or `[12] text`."
            case .outOfRange(let number, let count):
                "Line [\(number)] does not exist; this video has \(count) captions. Copy the captions again and paste the reply for the same video."
            }
        }
    }

    struct TimedLine {
        var start: TimeInterval?
        var end: TimeInterval?
        var text: String
    }

    /// Applies a reply to `captions`: a whole list rebuilds them, numbered lines edit them.
    static func apply(_ pasted: String, to captions: [Caption]) throws -> Result {
        let reply = replyLines(pasted)
        if !reply.list.isEmpty {
            let rebuilt = rebuild(reply.list, from: captions)
            return Result(captions: rebuilt, changed: countChanges(from: captions, to: rebuilt),
                          matched: reply.list.count, restructured: true)
        }
        let corrections = reply.numbered
        guard !corrections.isEmpty else { throw ParseError.noLines }
        if let bad = corrections.keys.first(where: { $0 < 1 || $0 > captions.count }) {
            throw ParseError.outOfRange(bad, count: captions.count)
        }
        var result: [Caption] = []
        var changed = 0
        for (index, caption) in captions.enumerated() {
            guard let text = corrections[index + 1] else {
                result.append(caption)
                continue
            }
            let pieces = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard pieces != caption.words.map(\.text) else {
                result.append(caption)
                continue
            }
            changed += 1
            if pieces.isEmpty { continue }
            if pieces.count == caption.words.count {
                var words = caption.words
                for i in words.indices { words[i].text = pieces[i] }
                result.append(Caption(id: caption.id, words: words))
            } else {
                result.append(caption.replacingText(pieces.joined(separator: " ")))
            }
        }
        return Result(captions: result, changed: changed, matched: corrections.count, restructured: false)
    }

    /// How many caption lines a reply holds, of either shape (also while it is still arriving).
    static func lineCount(_ reply: String) -> Int {
        let lines = replyLines(reply)
        return lines.list.isEmpty ? lines.numbered.count : lines.list.count
    }

    /// The caption lines of a reply. Inside a code block, numbered lines are edits and any other
    /// line is part of a whole list; with no code block, only numbered and timed lines count.
    static func replyLines(_ reply: String) -> (list: [TimedLine], numbered: [Int: String]) {
        let all = reply.components(separatedBy: .newlines)
        var block: [String] = []
        var inBlock = false, sawBlock = false
        for line in all {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inBlock.toggle()
                sawBlock = true
                continue
            }
            if inBlock { block.append(line) }
        }
        let candidates = sawBlock ? block : all
        var list: [TimedLine] = []
        var numbered: [Int: String] = [:]
        for line in candidates {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let (number, text) = captionLine(trimmed) {
                numbered[number] = text
            } else if let timed = timedLine(trimmed) {
                list.append(timed)
            } else if sawBlock {
                list.append(TimedLine(start: nil, end: nil, text: clean(trimmed)))
            }
        }
        return (list, numbered)
    }

    /// Caption number → corrected text, from lines like `[12] text`.
    static func parse(_ pasted: String) -> [Int: String] {
        replyLines(pasted).numbered
    }

    private static func timedLine(_ line: String) -> TimedLine? {
        let pattern = /(\d[\d:.,]*)\s*[\-\u{2013}\u{2014}\u{2192}>]+\s*(\d[\d:.,]*)\s*\|?\s*(.*)/
        guard let match = line.wholeMatch(of: pattern),
              let start = TimeFormat.parse(String(match.1)), let end = TimeFormat.parse(String(match.2)) else { return nil }
        return TimedLine(start: start, end: max(end, start), text: clean(String(match.3)))
    }

    /// Terms from a `Vocabulary: a; b; c` line, for the speech engine to listen for.
    static func vocabulary(_ reply: String) -> [String] {
        for line in reply.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            guard trimmed.lowercased().hasPrefix("vocabulary:") else { continue }
            let list = trimmed.dropFirst("vocabulary:".count)
            return list.split(whereSeparator: { $0 == ";" || $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "`\"'."))) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    /// The text around the caption lines in a reply: no code blocks, caption lines or vocabulary.
    static func prose(_ reply: String) -> String {
        var inBlock = false
        return reply.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") { inBlock.toggle(); return false }
                return !inBlock && captionLine(trimmed) == nil && timedLine(trimmed) == nil
                    && !trimmed.replacingOccurrences(of: "**", with: "").lowercased().hasPrefix("vocabulary:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `[n]`, then an optional start time or `start – end` range, then the text.
    static func captionLine(_ line: String) -> (Int, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = /\[(\d+)\]\s*(?:\d[\d:.,]*(?:\s*[\-\u{2013}\u{2014}\u{2192}>]+\s*\d[\d:.,]*)?\s)?\s*(.*)/
        guard let match = trimmed.wholeMatch(of: pattern), let number = Int(match.1) else { return nil }
        return (number, clean(String(match.2)))
    }

    /// Drops markers copied back from the input: `(1.2s)`, `(?)`, `{…}` word times.
    private static func clean(_ text: String) -> String {
        text.replacing(/\{[^}]*\}/, with: "")
            .replacing(/\(\d+(?:\.\d+)?s\)/, with: "")
            .replacing("(?)", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Rebuilding from a complete list

    /// New captions from a complete timed list. Words are timed from the recognized words they
    /// line up with; a caption whose given times differ noticeably is retimed to them.
    static func rebuild(_ lines: [TimedLine], from captions: [Caption]) -> [Caption] {
        let pieces = lines.map { $0.text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        let timedWords = align(pieces.flatMap { $0 }, to: captions.flatMap(\.words))
        var result: [Caption] = []
        var cursor = 0
        for (line, words) in zip(lines, pieces) {
            guard !words.isEmpty else { continue }
            var caption = Caption(words: Array(timedWords[cursor..<(cursor + words.count)]))
            cursor += words.count
            let tolerance = 0.12
            if let start = line.start, let end = line.end, end > start,
               abs(start - caption.start) > tolerance || abs(end - caption.end) > tolerance {
                caption = caption.retimed(start: start, end: end)
            }
            result.append(caption)
        }
        return CaptionBuilder.normalized(result)
    }

    private static func countChanges(from old: [Caption], to new: [Caption]) -> Int {
        func signature(_ caption: Caption) -> String { "\(caption.text)|\(seconds(caption.start))|\(seconds(caption.end))" }
        let oldSet = Set(old.map(signature))
        return new.filter { !oldSet.contains(signature($0)) }.count + max(0, old.count - new.count)
    }

    /// Times `words` from `original` by lining the two up (diacritics, case and punctuation
    /// ignored, near-misses allowed). Words with no partner share the time around them by length.
    static func align(_ words: [String], to original: [TranscriptWord]) -> [TranscriptWord] {
        let n = words.count, m = original.count
        guard n > 0 else { return [] }
        let a = words.map(key), b = original.map { key($0.text) }
        guard m > 0 else { return spread(words, from: 0, to: 0.3 * Double(n)) }

        // Best-scoring alignment: exact matches score 3, near-misses 2.
        var score = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1
        for i in 1...n {
            for j in 1...m {
                var best = max(score[(i - 1) * width + j], score[i * width + j - 1])
                let s = similarity(a[i - 1], b[j - 1])
                if s > 0 { best = max(best, score[(i - 1) * width + j - 1] + Int32(s)) }
                score[i * width + j] = best
            }
        }
        var partner = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0, j > 0 {
            let s = similarity(a[i - 1], b[j - 1])
            if s > 0, score[i * width + j] == score[(i - 1) * width + j - 1] + Int32(s) {
                partner[i - 1] = j - 1
                i -= 1; j -= 1
            } else if score[i * width + j] == score[(i - 1) * width + j] {
                i -= 1
            } else {
                j -= 1
            }
        }

        var result: [TranscriptWord] = []
        var k = 0
        var previousOriginal: Int? = nil
        while k < n {
            if let o = partner[k] {
                var start = original[o].start
                // Recognized words dropped just before this one (a merged "na príklad" → "napríklad")
                // lend it their time.
                let firstSkipped = (previousOriginal ?? -1) + 1
                if firstSkipped < o, original[o].start - original[firstSkipped].start < 1 { start = original[firstSkipped].start }
                result.append(TranscriptWord(text: words[k], start: start, end: original[o].end))
                previousOriginal = o
                k += 1
                continue
            }
            // A run of words without partners, timed from the gap between the neighbors.
            var runEnd = k
            while runEnd < n, partner[runEnd] == nil { runEnd += 1 }
            let nextOriginal = runEnd < n ? partner[runEnd] : nil
            let skippedFrom = (previousOriginal ?? -1) + 1
            let skippedTo = (nextOriginal ?? m) - 1
            var from: TimeInterval, to: TimeInterval
            if skippedFrom <= skippedTo {
                from = original[skippedFrom].start
                to = original[skippedTo].end
            } else {
                from = previousOriginal.map { original[$0].end } ?? (original.first?.start ?? 0)
                to = nextOriginal.map { original[$0].start } ?? (original.last?.end ?? from)
            }
            let count = runEnd - k
            if to - from < 0.1 * Double(count) { to = from + 0.1 * Double(count) }
            result += spread(Array(words[k..<runEnd]), from: from, to: to)
            if skippedFrom <= skippedTo { previousOriginal = skippedTo }
            k = runEnd
        }
        return result
    }

    private static func spread(_ words: [String], from start: TimeInterval, to end: TimeInterval) -> [TranscriptWord] {
        let total = Double(words.reduce(0) { $0 + max($1.count, 1) })
        var cursor = start
        return words.map { word in
            let wordEnd = cursor + (end - start) * Double(max(word.count, 1)) / total
            defer { cursor = wordEnd }
            return TranscriptWord(text: word, start: cursor, end: wordEnd)
        }
    }

    /// Lowercased letters and digits, without diacritics: "Dobrý," → "dobry".
    private static func key(_ word: String) -> String {
        String(word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func similarity(_ x: String, _ y: String) -> Int {
        if x.isEmpty || y.isEmpty { return 0 }
        if x == y { return 3 }
        let longer = max(x.count, y.count)
        guard abs(x.count - y.count) <= max(2, longer / 3) else { return 0 }
        return Double(editDistance(x, y)) <= Double(longer) * 0.34 ? 2 : 0
    }

    private static func editDistance(_ x: String, _ y: String) -> Int {
        let s = Array(x), t = Array(y)
        var row = Array(0...t.count)
        for i in 1...s.count {
            var previous = row[0]
            row[0] = i
            for j in 1...t.count {
                let current = row[j]
                row[j] = s[i - 1] == t[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return row[t.count]
    }
}
