import SwiftUI

/// Proofread and edit the captions by chatting with Claude, through Claude Code on this Mac.
struct ClaudeChatView: View {
    let item: CaptionItem
    @AppStorage(ClaudeChat.modelKey) private var model = "opus"
    @AppStorage(ClaudeChat.autoApplyKey) private var autoApply = true
    @FocusState private var inputFocused: Bool

    private var chat: ClaudeChat { item.claude }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch chat.setup {
            case .unknown, .checking:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notInstalled:
                ContentUnavailableView {
                    Label("Claude Code Not Found", systemImage: "terminal")
                } description: {
                    Text("Captioner talks to Claude through Claude Code, using your Claude plan. Install it, log in once, then check again.")
                } actions: {
                    Link("Install Claude Code", destination: URL(string: "https://claude.com/product/claude-code")!)
                    Button("Check Again") { Task { await chat.checkSetup() } }
                }
            case .notLoggedIn:
                ContentUnavailableView {
                    Label("Log In to Claude Code", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Claude Code on this Mac isn't logged in. Log In opens Terminal and your browser; sign in with your Claude account, then check again.")
                } actions: {
                    Button("Log In…") { chat.logIn() }
                        .buttonStyle(.borderedProminent)
                    Button("Check Again") { Task { await chat.checkSetup() } }
                }
            case .ready:
                if chat.messages.isEmpty { emptyState } else { transcript }
                Divider()
                composer
            }
        }
        .task { if chat.setup == .unknown { await chat.checkSetup() } }
        .onChange(of: item.status) { _, status in chat.statusChanged(to: status) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Claude", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Picker("Model", selection: $model) {
                ForEach(ClaudeChat.models, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("Which Claude model answers")
            Menu {
                Button("Proofread All Captions") { chat.proofreadAll() }
                    .disabled(!item.hasCaptions || chat.isRunning || chat.isRetranscribing)
                Button("New Chat") { chat.newChat() }
                    .disabled(chat.messages.isEmpty)
                Divider()
                Toggle("Apply Corrections Automatically", isOn: $autoApply)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Proofread with Claude", systemImage: "text.badge.checkmark")
        } description: {
            Text("Claude fixes words, diacritics, capitals and punctuation, re-cuts the captions into readable phrases using every word's timing, and focuses on the words the speech engine was unsure of. It can also hand names back to the engine for a second, sharper transcription. Afterwards, ask for changes in your own words.")
        } actions: {
            Button("Proofread All Captions") { chat.proofreadAll() }
                .buttonStyle(.borderedProminent)
                .disabled(!item.hasCaptions || item.isTranscribing)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        MessageView(message: message, chat: chat)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: chat.messages.last?.text) {
                if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(chat.messages.isEmpty ? "Ask Claude about the captions…" : "Ask for a change…", text: Bindable(chat).draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { chat.sendDraft() }
                .disabled(chat.isRunning || chat.isRetranscribing)
            if chat.isRunning {
                Button { chat.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .help("Stop")
            } else {
                Button { chat.sendDraft() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Send (Return)")
            }
        }
        .padding(10)
    }
}

private struct MessageView: View {
    let message: ClaudeChat.Message
    let chat: ClaudeChat
    @Environment(CaptionQueue.self) private var queue
    @State private var showLines = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.title ?? message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        case .notice:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .assistant:
            assistant
        }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 6) {
            let prose = message.prose
            if !prose.isEmpty {
                Text(LocalizedStringKey(prose))
                    .textSelection(.enabled)
            }
            let lines = message.lineCount
            if lines > 0 {
                DisclosureGroup(isExpanded: $showLines) {
                    Text(TranscriptExchange.parse(message.text).sorted { $0.key < $1.key }.map { "[\($0.key)] \($0.value)" }.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(message.isStreaming ? "Correcting… \(lines) lines" : "\(lines) caption lines")
                        .font(.callout.weight(.medium))
                }
                if !message.isStreaming { applyRow }
            }
            let vocabulary = message.vocabulary
            if !vocabulary.isEmpty, !message.isStreaming {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Words the speech engine misheard: \(vocabulary.joined(separator: ", "))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Transcribe Again Listening for These") { chat.transcribeAgain(with: vocabulary, queue: queue) }
                        .controlSize(.small)
                        .disabled(chat.isRunning || chat.isRetranscribing)
                        .help("The on-device engine hears the audio again knowing these words, then Claude proofreads the new captions")
                }
            }
            if message.isStreaming {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var applyRow: some View {
        HStack(spacing: 8) {
            if let applied = message.applied {
                Label(applied == 0 ? "No changes" : "Applied \(applied) changes", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                if message.canUndo {
                    Button("Undo") { chat.undo(message.id) }
                        .controlSize(.small)
                }
            } else {
                Button("Apply to Captions") { chat.apply(message.id) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
