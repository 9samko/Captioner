import AppKit
import Foundation
import Observation
import os
import UniformTypeIdentifiers

/// The videos dropped on the app, transcribed one at a time and exported one at a time.
@Observable
final class CaptionQueue {
    static let shared = CaptionQueue()

    private(set) var items: [CaptionItem] = []
    var selectedID: CaptionItem.ID?
    private(set) var exportPending: [CaptionItem.ID] = []
    private(set) var exportingItem: CaptionItem?
    private(set) var lastError: String?

    @ObservationIgnored private var transcribingItem: CaptionItem?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var batchOutputs: [URL] = []

    private var settings: AppSettings { AppSettings.shared }

    var selected: CaptionItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    var isExporting: Bool { exportingItem != nil || !exportPending.isEmpty }
    var readyItems: [CaptionItem] { items.filter { $0.status == .ready || $0.status == .exported } }

    static let acceptedTypes: [UTType] = [.movie]

    nonisolated static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) else {
            return false
        }
        return type.conforms(to: .movie)
    }

    // MARK: - Adding and removing

    func add(_ urls: [URL]) {
        let projects = urls.filter { $0.pathExtension.lowercased() == CaptionProject.fileExtension }
        for url in projects { openProject(at: url) }
        let videos = urls.filter(Self.isVideo)
        var added: [CaptionItem] = []
        for url in videos where !items.contains(where: { $0.url == url }) {
            let item = CaptionItem(url: url, settings: settings)
            items.append(item)
            added.append(item)
        }
        if selectedID == nil { selectedID = added.first?.id }
        start(added)
    }

    /// Adds an item with saved work: its captions are kept, not generated again.
    @discardableResult
    private func add(_ project: CaptionProject, video: URL) -> CaptionItem {
        if let existing = items.first(where: { $0.url == video }) { return existing }
        let item = CaptionItem(url: video, settings: settings)
        item.restore(from: project)
        items.append(item)
        start([item])
        return item
    }

    private func start(_ added: [CaptionItem]) {
        for item in added {
            Task {
                await item.load()
                pumpTranscription()
            }
        }
    }

    func remove(_ ids: Set<CaptionItem.ID>) {
        for item in items where ids.contains(item.id) {
            item.cancelTranscription()
            if exportingItem === item { cancelExport() }
        }
        exportPending.removeAll { ids.contains($0) }
        items.removeAll { ids.contains($0.id) }
        if let selectedID, ids.contains(selectedID) { self.selectedID = items.first?.id }
        pumpTranscription()
    }

    func clearError() {
        lastError = nil
    }

    func clearFinished() {
        remove(Set(items.filter { $0.status == .exported }.map(\.id)))
    }

    // MARK: - Transcription

    func pumpTranscription() {
        if let current = transcribingItem, current.isTranscribing { return }
        transcribingItem = nil
        guard let next = items.first(where: { $0.status == .waiting && $0.source == .video }) else { return }
        transcribingItem = next
        next.startTranscription { [weak self, weak next] in
            self?.transcribingItem = nil
            self?.pumpTranscription()
            #if DEBUG
            // Development aid: CAPTIONER_DEBUG_AUTOEXPORT=1 exports each video as soon as its captions are ready.
            // "2" exports twice in a row, to exercise exporting the same video again.
            if let mode = ProcessInfo.processInfo.environment["CAPTIONER_DEBUG_AUTOEXPORT"], mode == "1" || mode == "2", let next, next.status == .ready {
                self?.export([next.id])
                if mode == "2" { self?.exportPending.append(next.id) }
            }
            #endif
        }
    }

    func transcribeAgain(_ item: CaptionItem) {
        item.cancelTranscription()
        item.source = .video
        item.status = .waiting
        if transcribingItem === item { transcribingItem = nil }
        pumpTranscription()
    }

    // MARK: - Export

    func export(_ ids: [CaptionItem.ID]) {
        for id in ids where !exportPending.contains(id) && exportingItem?.id != id {
            if let item = items.first(where: { $0.id == id }), item.hasCaptions, !item.status.isBusy {
                exportPending.append(id)
            }
        }
        pumpExport()
    }

    func exportAll() {
        export(items.filter { $0.hasCaptions && !$0.status.isBusy }.map(\.id))
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportPending.removeAll()
        if let item = exportingItem {
            item.status = item.hasCaptions ? .ready : .waiting
            item.exportProgress = 0
        }
        exportingItem = nil
    }

    private func pumpExport() {
        guard exportingItem == nil else { return }
        guard !exportPending.isEmpty else {
            if !batchOutputs.isEmpty, settings.revealOutputInFinder {
                NSWorkspace.shared.activateFileViewerSelecting(batchOutputs)
            }
            batchOutputs = []
            return
        }
        let id = exportPending.removeFirst()
        guard let item = items.first(where: { $0.id == id }), let composition = item.exportComposition() else {
            pumpExport()
            return
        }
        exportingItem = item
        item.status = .exporting
        item.exportProgress = 0
        let output = VideoExporter.outputURL(for: item.url, in: settings.exportFolder)
        let codec = settings.exportCodec
        let started = Date()
        exportTask = Task {
            do {
                try await VideoExporter.export(sourceURL: item.url, composition: composition, to: output, codec: codec) { fraction in
                    Task { @MainActor in item.exportProgress = fraction }
                }
                item.exportedURL = output
                item.status = .exported
                batchOutputs.append(output)
                CaptionItem.log.notice("Exported \(item.name, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            } catch is CancellationError {
                item.status = .ready
            } catch {
                if Task.isCancelled {
                    item.status = .ready
                } else {
                    item.status = .failed(error.localizedDescription)
                    lastError = "\(item.name): \(error.localizedDescription)"
                }
            }
            item.exportProgress = 0
            exportingItem = nil
            exportTask = nil
            pumpExport()
        }
    }

    // MARK: - Projects

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [CaptionProject.type]
        panel.message = "Choose Captioner projects to open."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openProject(at: url) }
    }

    func openProject(at url: URL) {
        do {
            var project = try CaptionProject.read(from: url)
            project.projectPath = url.path
            guard let video = project.resolveVideo(projectURL: url) ?? locateVideo(for: project) else { return }
            let item = add(project, video: video)
            selectedID = item.id
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Asks where the video went when a project's video isn't where it was saved.
    private func locateVideo(for project: CaptionProject) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.acceptedTypes
        panel.message = "Where is “\((project.videoPath as NSString).lastPathComponent)”? It isn't where the project was saved."
        panel.prompt = "Use Video"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Saves to the item's project file, asking for one the first time.
    func saveProject(_ item: CaptionItem, choosingLocation: Bool = false) {
        var target = item.projectURL
        if choosingLocation || target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [CaptionProject.type]
            panel.nameFieldStringValue = "\(item.name).\(CaptionProject.fileExtension)"
            panel.directoryURL = target?.deletingLastPathComponent() ?? item.url.deletingLastPathComponent()
            panel.message = "Keep the project next to its video to open it on another Mac."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
        }
        guard let target else { return }
        do {
            try item.project(savingTo: target).write(to: target)
            item.projectURL = target
            NSDocumentController.shared.noteNewRecentDocumentURL(target)
            autosave()
        } catch {
            lastError = "\(target.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Autosave

    @ObservationIgnored private var autosaveTimer: Timer?
    @ObservationIgnored private var lastAutosave: Data?

    /// Brings back the videos and captions from the last run, then keeps saving them.
    func restoreSession() {
        if let data = try? Data(contentsOf: SavedSession.url),
           let session = try? JSONDecoder().decode(SavedSession.self, from: data) {
            lastAutosave = data
            var restored: [CaptionItem] = []
            for project in session.projects {
                let projectURL = project.projectPath.map { URL(fileURLWithPath: $0) }
                guard let video = project.resolveVideo(projectURL: projectURL) else {
                    CaptionItem.log.notice("Not restoring \(project.videoPath, privacy: .public): the video is gone")
                    continue
                }
                restored.append(add(project, video: video))
            }
            if let index = session.selectedIndex, restored.indices.contains(index) { selectedID = restored[index].id }
        }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { CaptionQueue.shared.autosave() }
        }
    }

    /// Writes the session when something changed. Videos still being transcribed for the first
    /// time have nothing to keep yet; they are transcribed again next time.
    func autosave() {
        let kept = items.filter { $0.hasCaptions }
        let session = SavedSession(projects: kept.map { $0.project() },
                                   selectedIndex: kept.firstIndex { $0.id == selectedID })
        guard let data = try? JSONEncoder().encode(session), data != lastAutosave else { return }
        do {
            try data.write(to: SavedSession.url, options: .atomic)
            lastAutosave = data
        } catch {
            CaptionItem.log.error("Autosave failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Panels

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.acceptedTypes
        panel.message = "Choose one or more videos to caption."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }
}
