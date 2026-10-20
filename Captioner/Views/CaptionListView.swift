import AppKit
import SwiftUI

/// The captions as an editable list. Click a time to jump there; edit the text in place.
struct CaptionListView: View {
    @Bindable var item: CaptionItem
    @Environment(AppState.self) private var appState
    @State private var followPlayback = true

    private var player: PlayerController { appState.player }

    private var currentIndex: Int? {
        item.captions.index(at: player.currentTime)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Captions")
                    .font(.headline)
                Spacer()
                Text("\(item.captions.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button { appState.addCaption(to: item) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(item.info == nil || item.isTranscribing)
                .help("Add a caption at the playhead (⌘N)")
                ProofreadMenu(item: item)
                Toggle(isOn: $followPlayback) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Follow playback")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if item.captions.isEmpty {
                ContentUnavailableView {
                    Label(item.isTranscribing ? "Listening…" : "No Captions Yet", systemImage: "text.bubble")
                } description: {
                    Text(item.isTranscribing ? "Captions appear here as the speech is recognized." : "Captions are generated from the video's audio, or import a subtitle file in the inspector.")
                }
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(item.captions.enumerated()), id: \.element.id) { index, caption in
                            CaptionRow(caption: caption, isCurrent: index == currentIndex, item: item,
                                       onSeek: { player.seek(to: caption.start) })
                                .id(caption.id)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: currentIndex) { _, index in
                        guard followPlayback, player.isPlaying, let index, item.captions.indices.contains(index) else { return }
                        withAnimation { proxy.scrollTo(item.captions[index].id, anchor: .center) }
                    }
                }
            }
            if item.hasEdits {
                Divider()
                HStack {
                    Text("Edited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rebuild from Transcript") { item.rebuildCaptions() }
                        .controlSize(.small)
                        .help("Regroup the captions from the original recognition, discarding edits")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}

/// Copy the captions out for proofreading and paste the corrected lines back.
struct ProofreadMenu: View {
    let item: CaptionItem
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            Button("Proofread with Claude") {
                appState.showClaude = true
                if item.claude.setup == .ready { item.claude.proofreadAll() }
            }
            .disabled(item.claude.isRunning)
            Divider()
            Button("Copy for Claude") { TranscriptClipboard.copyPrompt(item) }
            Button("Copy Captions with Timestamps") { TranscriptClipboard.copyLines(item) }
            Divider()
            Button("Paste Corrections") { TranscriptClipboard.pasteCorrections(into: item) }
            Button("Undo Pasted Corrections") { item.undoCorrections() }
                .disabled(item.beforeCorrections == nil)
        } label: {
            Image(systemName: "text.badge.checkmark")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
        .disabled(!item.hasCaptions || item.isTranscribing)
        .help("Copy the captions with timestamps for proofreading, then paste the corrected lines back")
    }
}

enum TranscriptClipboard {
    /// The numbered lines with proofreading instructions in front.
    static func copyPrompt(_ item: CaptionItem) {
        copy(TranscriptExchange.prompt(for: item.captions, localeIdentifier: item.localeIdentifier, grouping: item.style.grouping,
                                        instructions: ClaudeChat.instructions))
    }

    static func copyLines(_ item: CaptionItem) {
        copy(TranscriptExchange.lines(for: item.captions))
    }

    static func pasteCorrections(into item: CaptionItem) {
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        let count = item.captions.count
        do {
            let result = try item.applyCorrections(pasted)
            // Stay quiet when every line came back and something changed; explain anything else.
            guard result.changed == 0 || result.matched < count else { return }
            let alert = NSAlert()
            if result.changed == 0 {
                alert.messageText = "No Changes"
                alert.informativeText = "The pasted lines match the captions as they are."
            } else {
                alert.messageText = "Some Lines Were Missing"
                alert.informativeText = "\(result.matched) of \(count) lines were pasted, and \(result.changed) captions changed. Captions without a line were left as they were."
            }
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Paste Corrections"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct CaptionRow: View {
    let caption: Caption
    let isCurrent: Bool
    let item: CaptionItem
    let onSeek: () -> Void
    @Environment(AppState.self) private var appState

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSeek) {
                Text(TimeFormat.cue(caption.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 56, alignment: .leading)
            .padding(.top, 3)
            TextField("Caption", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onChange(of: caption.text) { _, new in if !focused { text = new } }
                .font(.body)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear { text = caption.text }
        .contextMenu {
            if caption.words.count > 1 {
                Menu("Split Before") {
                    ForEach(Array(caption.words.enumerated().dropFirst()), id: \.offset) { index, word in
                        Button(word.text) { item.split(caption.id, atWord: index) }
                    }
                }
            }
            Button("Edit Text & Timing…") {
                appState.captionDraft = CaptionDraft(captionID: caption.id, text: caption.text, start: caption.start, end: caption.end)
            }
            Button("Insert Caption After…") {
                let span = item.suggestedSpan(at: caption.end + 0.05)
                appState.captionDraft = CaptionDraft(start: span.start, end: span.end)
            }
            Divider()
            Button("Set Start to Playhead") { item.setStart(of: caption.id, to: appState.player.currentTime) }
            Button("Set End to Playhead") { item.setEnd(of: caption.id, to: appState.player.currentTime) }
                .disabled(appState.player.currentTime <= caption.start)
            Divider()
            Button("Merge with Next") { item.mergeWithNext(caption.id) }
                .disabled(item.captions.last?.id == caption.id)
            Divider()
            Button("Delete", role: .destructive) { item.delete(caption.id) }
        }
    }

    private func commit() {
        item.updateText(of: caption.id, to: text)
    }
}

/// Adds a caption or edits one's text and timing. Times take `M:SS.mmm`, `SS.s` or `H:MM:SS`.
struct CaptionEditorSheet: View {
    let item: CaptionItem
    @State var draft: CaptionDraft
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var startText = ""
    @State private var endText = ""
    @FocusState private var textFocused: Bool

    private var player: PlayerController { appState.player }
    private var start: TimeInterval? { TimeFormat.parse(startText) }
    private var end: TimeInterval? { TimeFormat.parse(endText) }
    private var isValid: Bool {
        guard let start, let end else { return false }
        return end > start && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.captionID == nil ? "Add Caption" : "Edit Caption")
                .font(.title3.weight(.semibold))
            TextField("What is said", text: $draft.text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                timeRow("Start", text: $startText)
                timeRow("End", text: $endText)
            }
            if let start, let end, end <= start {
                Text("The end must come after the start.")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if draft.captionID == nil {
                Text("Tip: put the playhead where the words begin, then use Playhead. Words share the time by length.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let id = draft.captionID {
                    Button("Delete", role: .destructive) {
                        item.delete(id)
                        dismiss()
                    }
                }
                Button("Play") { if let start { player.seek(to: start, thenPlay: true) } }
                    .disabled(start == nil)
                    .help("Play from the start time to check it")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.captionID == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            startText = TimeFormat.precise(draft.start)
            endText = TimeFormat.precise(draft.end)
            textFocused = true
        }
    }

    private func timeRow(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .frame(width: 130)
            Button("Playhead") { text.wrappedValue = TimeFormat.precise(player.currentTime) }
                .help("Use the current playhead position")
        }
    }

    private func save() {
        guard let start, let end, isValid else { return }
        if let id = draft.captionID {
            item.editCaption(id, text: draft.text, start: start, end: end)
        } else {
            item.insertCaption(draft.text, start: start, end: end)
        }
        dismiss()
    }
}
