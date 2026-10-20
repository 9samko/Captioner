import Foundation

/// Copies the captions out as numbered, timestamped lines and reads a corrected copy back in.
/// The round trip is built for proofreading with an assistant such as Claude: each line keeps
/// its `[n]` tag, so the corrected text lands on the right caption and every caption keeps its
/// timing. Timestamps in the pasted text are ignored; only the text is taken.
///
///     [1] 0:00.4 – 0:01.9 dobrý deň vitajte
///     [2] 0:02.0 – 0:03.6 v dnešnom videu
nonisolated enum TranscriptExchange {
    /// The captions as `[n] start – end text` lines.
    static func lines(for captions: [Caption]) -> String {
        let forceHours = (captions.last?.end ?? 0) >= 3600
        return captions.enumerated().map { index, caption in
            "[\(index + 1)] \(TimeFormat.cue(caption.start, forceHours: forceHours)) – \(TimeFormat.cue(caption.end, forceHours: forceHours)) \(caption.text)"
        }.joined(separator: "\n")
    }

    /// The lines with proofreading instructions in front, ready to paste into a chat.
    static func prompt(for captions: [Caption], localeIdentifier: String) -> String {
        let language = Locale(identifier: "en").localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
        return """
        Below is an automatic speech-to-text transcript of a video in \(language). Each line is one \
        on-screen caption: a number in brackets, its start and end time, then the recognized words. \
        The recognizer gets words, diacritics, capital letters and punctuation wrong, and it does not \
        know where sentences begin and end.

        Proofread it so it reads as correct, natural written \(language):
        - Fix misheard or misspelled words, missing or wrong diacritics, and grammar (endings, agreement).
        - Add proper punctuation and capital letters. Find the real sentence boundaries: a sentence may \
        run over several lines, and a new sentence may start in the middle of a line.
        - Capitalize names, places and brands correctly.
        - Keep what was said: do not paraphrase, summarize, translate or drop words, except obvious \
        recognition junk and repeated stutters.

        Format rules (the reply is pasted back into the app, so they matter):
        - Return every line, in the same order, with the same [number] at the start. Never merge, split, \
        add or remove lines.
        - Keep each word on the line it is on. Copy the timestamps unchanged.
        - Reply with only the corrected lines inside a single code block, and nothing else.

        \(lines(for: captions))
        """
    }

    struct Result {
        var captions: [Caption]
        var changed: Int
        var matched: Int
    }

    enum ParseError: LocalizedError {
        case noLines
        case outOfRange(Int, count: Int)

        var errorDescription: String? {
            switch self {
            case .noLines:
                "The clipboard has no caption lines. Copy the corrected reply, where every line starts with its [number]."
            case .outOfRange(let number, let count):
                "Line [\(number)] does not exist; this video has \(count) captions. Copy the captions again and paste the reply for the same video."
            }
        }
    }

    /// Applies corrected lines to `captions`. Captions whose line is missing stay as they were;
    /// a line left empty deletes its caption. When a caption keeps its word count each word keeps
    /// its exact timing, otherwise the new words share the caption's span by length.
    static func apply(_ pasted: String, to captions: [Caption]) throws -> Result {
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
        return Result(captions: result, changed: changed, matched: corrections.count)
    }

    /// Caption number → corrected text, from lines like `[12] 0:05.3 – 0:07.1 text`. Code fences,
    /// blank lines and chatter around the lines are skipped.
    static func parse(_ pasted: String) -> [Int: String] {
        var corrections: [Int: String] = [:]
        for line in pasted.components(separatedBy: .newlines) {
            if let (number, text) = captionLine(line) { corrections[number] = text }
        }
        return corrections
    }

    /// The text around the caption lines in a reply, without the lines or their code fences.
    static func prose(_ reply: String) -> String {
        reply.components(separatedBy: .newlines)
            .filter { captionLine($0) == nil && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `[n]`, then an optional `start – end` time range (any dash or arrow), then the text.
    static func captionLine(_ line: String) -> (Int, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = /\[(\d+)\]\s*(?:[\d:.,]+\s*[\-\u{2013}\u{2014}\u{2192}>]+\s*[\d:.,]+)?\s*(.*)/
        guard let match = trimmed.wholeMatch(of: pattern), let number = Int(match.1) else { return nil }
        return (number, String(match.2).trimmingCharacters(in: .whitespaces))
    }
}
