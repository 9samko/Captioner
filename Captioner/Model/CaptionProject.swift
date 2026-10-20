import Foundation
import UniformTypeIdentifiers

/// Everything about one video except the video itself: its captions, the transcript they were
/// grouped from, and how they look. Saved as a `.captioner` file, and in the autosaved session.
nonisolated struct CaptionProject: Codable, Sendable {
    static let fileExtension = "captioner"
    static let type = UTType(exportedAs: "io.github.9samko.captioner.project", conformingTo: .json)

    var version = 1
    var videoPath: String
    /// Follows the video if it is moved or renamed on the same Mac.
    var videoBookmark: Data?
    /// The video's path relative to the project file, so a project kept next to its video still
    /// finds it on another Mac.
    var videoRelativePath: String?
    var subtitlePath: String?
    var projectPath: String?
    var localeIdentifier: String
    var captions: [Caption]
    var rawWords: [TranscriptWord]
    var style: CaptionStyle
    var placement: PlacementSettings
    var textOptions: TextOptions
    var hasEdits: Bool
    var vocabulary: [String]? = nil

    /// The video, wherever it can be found: the bookmark, the saved path, then next to the project.
    func resolveVideo(projectURL: URL?) -> URL? {
        var stale = false
        if let videoBookmark,
           let url = try? URL(resolvingBookmarkData: videoBookmark, options: [.withoutUI], bookmarkDataIsStale: &stale),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if FileManager.default.fileExists(atPath: videoPath) { return URL(fileURLWithPath: videoPath) }
        if let projectURL, let videoRelativePath {
            let url = projectURL.deletingLastPathComponent().appendingPathComponent(videoRelativePath).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> CaptionProject {
        try JSONDecoder().decode(CaptionProject.self, from: Data(contentsOf: url))
    }

    /// `target`'s path relative to `base`'s folder, such as `Clip.mp4` or `../Footage/Clip.mp4`.
    static func relativePath(of target: URL, from base: URL) -> String {
        let targetParts = target.standardizedFileURL.pathComponents
        let baseParts = base.deletingLastPathComponent().standardizedFileURL.pathComponents
        var shared = 0
        while shared < min(targetParts.count, baseParts.count), targetParts[shared] == baseParts[shared] { shared += 1 }
        let ups = Array(repeating: "..", count: baseParts.count - shared)
        return (ups + targetParts[shared...]).joined(separator: "/")
    }
}

/// The queue as it was, restored at the next launch so unexported work is never lost.
nonisolated struct SavedSession: Codable, Sendable {
    var projects: [CaptionProject]
    var selectedIndex: Int?

    static var url: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captioner", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Session.json")
    }
}
