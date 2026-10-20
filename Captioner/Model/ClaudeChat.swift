import Foundation
import Observation

/// A conversation with Claude (through Claude Code) about one video's captions. Replies that
/// contain `[n] start – end text` lines are applied to the captions, keeping their timing.
@Observable
final class ClaudeChat {
    enum Role { case user, assistant, notice }

    struct Message: Identifiable {
        let id = UUID()
        var role: Role
        var text: String
        /// Shown instead of `text` for a long generated prompt.
        var title: String?
        var isStreaming = false
        /// How many captions this reply changed when applied, or nil if not applied (yet).
        var applied: Int?
        var canUndo = false

        var prose: String { TranscriptExchange.prose(text) }
        var lineCount: Int { TranscriptExchange.parse(text).count }
    }

    enum Setup: Equatable {
        case unknown, checking, ready, notInstalled, notLoggedIn
    }

    static let models: [(id: String, name: String)] = [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
    static let modelKey = "claudeModel"
    static let autoApplyKey = "claudeAutoApply"

    weak var item: CaptionItem?
    private(set) var messages: [Message] = []
    private(set) var setup: Setup = .unknown
    private(set) var isRunning = false
    var draft = ""

    @ObservationIgnored private var binary: URL?
    @ObservationIgnored private var sessionID: String?
    /// The caption lines as Claude last saw them; a change is sent along with the next message.
    @ObservationIgnored private var sentLines: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    var model: String { UserDefaults.standard.string(forKey: Self.modelKey) ?? "opus" }
    var autoApply: Bool { UserDefaults.standard.object(forKey: Self.autoApplyKey) as? Bool ?? true }

    // MARK: - Setup

    func checkSetup() async {
        guard setup != .checking else { return }
        setup = .checking
        guard let binary = await ClaudeCode.locate() else {
            setup = .notInstalled
            return
        }
        self.binary = binary
        setup = await ClaudeCode.isLoggedIn(binary) ? .ready : .notLoggedIn
    }

    func logIn() {
        if let binary { ClaudeCode.openLoginInTerminal(binary) }
    }

    // MARK: - Sending

    /// Starts a new conversation that proofreads every caption.
    func proofreadAll() {
        guard let item, item.hasCaptions else { return }
        newChat()
        let prompt = TranscriptExchange.prompt(for: item.captions, localeIdentifier: item.localeIdentifier)
        send(prompt, title: "Proofread all \(item.captions.count) captions", lines: TranscriptExchange.lines(for: item.captions))
    }

    /// Sends what the user typed. The captions go along when Claude has not seen them as they are now.
    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let item else { return }
        draft = ""
        let lines = TranscriptExchange.lines(for: item.captions)
        var prompt = text
        if lines != sentLines, item.hasCaptions {
            let header = sessionID == nil ? "The captions:" : "The captions have changed since; here they are now:"
            prompt = "\(header)\n```\n\(lines)\n```\n\n\(text)"
        }
        send(prompt, displayText: text, lines: lines)
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func newChat() {
        stop()
        messages = []
        sessionID = nil
        sentLines = nil
    }

    private func send(_ prompt: String, displayText: String? = nil, title: String? = nil, lines: String) {
        guard let binary, let item, !isRunning else { return }
        messages.append(Message(role: .user, text: displayText ?? prompt, title: title))
        messages.append(Message(role: .assistant, text: "", isStreaming: true))
        let replyID = messages[messages.count - 1].id
        sentLines = lines
        isRunning = true
        let stream = ClaudeCode.send(prompt, resume: sessionID, model: model,
                                     systemPrompt: Self.systemPrompt(localeIdentifier: item.localeIdentifier), binary: binary)
        task = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .session(let id):
                        sessionID = id
                    case .text(let chunk):
                        update(replyID) { $0.text += chunk }
                    case .done(let result, let isError):
                        update(replyID) {
                            if !result.isEmpty { $0.text = result }
                            $0.isStreaming = false
                            if isError { $0.role = .notice }
                        }
                        if !isError { finished(replyID) }
                    }
                }
                self?.update(replyID) { $0.isStreaming = false }
            } catch {
                guard let self else { return }
                if case ClaudeCode.Failure.notLoggedIn = error { setup = .notLoggedIn }
                update(replyID) {
                    $0.isStreaming = false
                    $0.role = .notice
                    $0.text = error.localizedDescription
                }
            }
            if Task.isCancelled { self?.update(replyID) { if $0.text.isEmpty { $0.role = .notice; $0.text = "Stopped." } } }
            self?.isRunning = false
        }
    }

    private func finished(_ replyID: UUID) {
        guard autoApply, let message = messages.first(where: { $0.id == replyID }), message.lineCount > 0 else { return }
        apply(replyID)
    }

    // MARK: - Applying

    func apply(_ messageID: UUID) {
        guard let item, let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let countBefore = item.captions.count
        do {
            let result = try item.applyCorrections(messages[index].text)
            for i in messages.indices { messages[i].canUndo = false }
            messages[index].applied = result.changed
            messages[index].canUndo = result.changed > 0
            // Claude's own reply is now what the captions say. If lines were deleted the numbers
            // moved, so send the captions again with the next message.
            sentLines = item.captions.count == countBefore ? TranscriptExchange.lines(for: item.captions) : nil
        } catch {
            messages.append(Message(role: .notice, text: error.localizedDescription))
        }
    }

    func undo(_ messageID: UUID) {
        guard let item, let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        item.undoCorrections()
        messages[index].applied = nil
        messages[index].canUndo = false
        sentLines = nil
    }

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    static func systemPrompt(localeIdentifier: String) -> String {
        let language = Locale(identifier: "en").localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
        return """
        You are the proofreader built into Captioner, a Mac app that burns captions into videos. The \
        captions come from on-device speech recognition in \(language). They are given as lines like \
        `[12] 0:05.3 – 0:07.1 text`: the caption number, its time range, and its words.

        Whenever you change captions, put the changed lines in exactly that format inside one code \
        block, with their numbers and timestamps unchanged. The app applies them to the video right \
        away. Lines you leave out stay as they are; a line with no text deletes that caption. Never \
        renumber, merge or split lines, and keep each word on the line it is on.

        Outside the code block, keep it short, and answer in the language the user writes in. If the \
        user only asks a question, answer it without a code block.
        """
    }
}
