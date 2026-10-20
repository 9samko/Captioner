import Foundation

/// Copies the captions out as timestamped lines and reads a corrected copy back in. Built for
/// proofreading with an assistant such as Claude. Times are plain seconds, so no arithmetic on
/// minutes is needed. A reply comes back in one of two shapes:
///
/// - Numbered lines change the text of those captions only, keeping their timing:
///
///       [2] v dnešnom videu.
///
/// - Unnumbered timed lines are the complete new caption list, so captions can be regrouped,
///   split, merged and retimed. Each word takes its timing from the recognized word it lines up
///   with; a caption's own times win when they differ, so timing can be changed on purpose:
///
///       0.40 – 1.80 Dobrý deň, vitajte
///       2.00 – 3.70 v dnešnom videu.
///
/// A reply can also suggest words for the speech engine to listen for (`Vocabulary: a; b`), which
/// a second transcription uses to recognize names and terms correctly.
nonisolated enum TranscriptExchange {
    /// Below this the engine's confidence in a word is marked for the proofreader.
    static let lowConfidence = 0.5

    // MARK: - Writing

    /// `[n] start – end text`. With `wordTimes` each word is followed by `{start-end}`, and by
    /// `{start-end?}` when the speech engine was unsure of it.
    static func lines(for captions: [Caption], wordTimes: Bool = false) -> String {
        captions.enumerated().map { index, caption in
            let text = wordTimes ? caption.words.map(annotated).joined(separator: " ") : caption.text
            return "[\(index + 1)] \(seconds(caption.start)) – \(seconds(caption.end)) \(text)"
        }.joined(separator: "\n")
    }

    private static func annotated(_ word: TranscriptWord) -> String {
        let unsure = (word.confidence ?? 1) < lowConfidence ? "?" : ""
        return "\(word.text){\(seconds(word.start))-\(seconds(word.end))\(unsure)}"
    }

    static func seconds(_ time: TimeInterval) -> String { String(format: "%.2f", max(0, time)) }

    static func languageName(_ localeIdentifier: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
    }

    /// How long a caption may be, from the style, in words the model can follow.
    static func limits(_ grouping: CaptionGrouping) -> String {
        let characters = grouping.maxCharactersPerLine * max(grouping.maxLines, 1)
        return "at most \(grouping.maxWords) words, about \(characters) characters and \(Int(grouping.maxDuration.rounded())) seconds"
    }

    /// The format rules for a reply, shared by the copied prompt and the in-app chat.
    static func formatRules(_ grouping: CaptionGrouping) -> String {
        """
        How to reply (the app reads the reply, so this matters):
        - To restructure (change where captions break, merge, split or retime them), give the \
        complete new caption list, every caption from the first to the last, one per line as \
        `start – end text`, with no [numbers] and no word times. Times are seconds with two decimals.
        - A caption's start is the start of its first word and its end is the end of its last word, \
        copied from the word times, unless you are asked to change the timing.
        - Keep every word in the order it was spoken. The app lines your words up with the \
        recognized ones to time them, so do not reorder, paraphrase or invent words.
        - Each caption: \(limits(grouping)). Break at sentence ends first, then at commas, natural \
        phrases and pauses (gaps between word times). Avoid ending a caption on a preposition or \
        conjunction, and avoid one-word captions unless the word stands alone.
        - To change only the text of a few captions, reply instead with just those lines as \
        `[n] text`, using their numbers; the other captions stay as they are.
        - Put the caption lines in a single code block.
        - Words marked `?` in the word times are ones the speech engine was unsure of: check them \
        hardest, using the context.
        - After the code block, if the recognizer misheard names, places, brands or special terms, \
        add one line `Vocabulary: term; term; …` with their correct spelling (at most 30). The app \
        can transcribe the audio again listening for them. Leave the line out if there are none.
        """
    }

    /// The captions with word times and proofreading instructions, ready to paste into a chat.
    static func prompt(for captions: [Caption], localeIdentifier: String, grouping: CaptionGrouping) -> String {
        let language = languageName(localeIdentifier)
        return """
        Below is an automatic speech-to-text transcript of a video in \(language), already cut into \
        on-screen captions. Each line is `[number] start – end words`, and every word carries its \
        spoken time as {start-end} in seconds. The recognizer gets words, diacritics, capital \
        letters and punctuation wrong, does not know where sentences end, and cuts captions badly.

        Make it read as correct, natural written \(language), and cut it into good captions:
        - Fix misheard or misspelled words, missing or wrong diacritics, and grammar.
        - Add punctuation and capital letters, with real sentence boundaries. Capitalize names, \
        places and brands correctly.
        - Re-cut the captions so each one is a readable phrase that fits on screen.
        - Keep what was said: no paraphrasing, summarizing or translating; drop only obvious \
        recognition junk and stutters.

        \(formatRules(grouping))

        Reply with the complete new caption list.

        \(lines(for: captions, wordTimes: true))
        """
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
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// Applies a reply to `captions`: a complete timed list rebuilds them, numbered lines edit them.
    static func apply(_ pasted: String, to captions: [Caption]) throws -> Result {
        let timed = timedLines(pasted)
        if !timed.isEmpty {
            let rebuilt = rebuild(timed, from: captions)
            let changed = countChanges(from: captions, to: rebuilt)
            return Result(captions: rebuilt, changed: changed, matched: timed.count, restructured: true)
        }
        let corrections = parse(pasted)
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

    /// How many caption lines a reply holds, of either shape.
    static func lineCount(_ reply: String) -> Int {
        let timed = timedLines(reply).count
        return timed > 0 ? timed : parse(reply).count
    }

    /// Caption number → corrected text, from lines like `[12] text` (times and word times allowed).
    static func parse(_ pasted: String) -> [Int: String] {
        var corrections: [Int: String] = [:]
        for line in pasted.components(separatedBy: .newlines) {
            if let (number, text) = captionLine(line) { corrections[number] = text }
        }
        return corrections
    }

    /// Unnumbered `start – end text` lines, in order.
    static func timedLines(_ reply: String) -> [TimedLine] {
        reply.components(separatedBy: .newlines).compactMap(timedLine)
    }

    private static func timedLine(_ line: String) -> TimedLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = /(\d[\d:.,]*)\s*[\-\u{2013}\u{2014}\u{2192}>]+\s*(\d[\d:.,]*)\s*\|?\s*(.*)/
        guard let match = trimmed.wholeMatch(of: pattern),
              let start = TimeFormat.parse(String(match.1)), let end = TimeFormat.parse(String(match.2)) else { return nil }
        return TimedLine(start: start, end: max(end, start), text: stripWordTimes(String(match.3)))
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

    /// The text around the caption lines in a reply, without the lines, their code fences or the
    /// vocabulary line.
    static func prose(_ reply: String) -> String {
        reply.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return captionLine(line) == nil && timedLine(line) == nil && !trimmed.hasPrefix("```")
                    && !trimmed.replacingOccurrences(of: "**", with: "").lowercased().hasPrefix("vocabulary:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `[n]`, then an optional `start – end` time range (any dash or arrow), then the text.
    static func captionLine(_ line: String) -> (Int, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = /\[(\d+)\]\s*(?:[\d:.,]+\s*[\-\u{2013}\u{2014}\u{2192}>]+\s*[\d:.,]+)?\s*(.*)/
        guard let match = trimmed.wholeMatch(of: pattern), let number = Int(match.1) else { return nil }
        return (number, stripWordTimes(String(match.2)))
    }

    private static func stripWordTimes(_ text: String) -> String {
        text.replacing(/\{[^}]*\}/, with: "").trimmingCharacters(in: .whitespaces)
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
            if line.end > line.start, abs(line.start - caption.start) > tolerance || abs(line.end - caption.end) > tolerance {
                caption = caption.retimed(start: line.start, end: line.end)
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
