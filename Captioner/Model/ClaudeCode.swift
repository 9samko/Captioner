import AppKit
import Foundation

/// Runs the Claude Code command-line tool (`claude -p`) as a chat backend. It signs in with the
/// Claude Code install on this Mac, so it uses that account's Claude plan and needs no API key.
/// Tools, MCP servers and settings files are switched off: it only reads and writes text.
nonisolated enum ClaudeCode {
    enum Event: Sendable {
        case session(String)
        case text(String)
        case done(result: String, isError: Bool)
    }

    enum Failure: LocalizedError {
        case notInstalled
        case notLoggedIn
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Claude Code is not installed."
            case .notLoggedIn: "Claude Code is not logged in."
            case .failed(let message): message
            }
        }
    }

    /// The `claude` executable: the usual install locations first, then the login shell's PATH,
    /// which apps opened from the Dock or Finder do not inherit.
    static func locate() async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let found = await output(of: URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: found) ? URL(fileURLWithPath: found) : nil
    }

    /// Whether `claude auth status` reports a login. Versions without that command count as logged in.
    static func isLoggedIn(_ binary: URL) async -> Bool {
        guard let text = await output(of: binary, ["auth", "status"]),
              let data = text.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = status["loggedIn"] as? Bool else { return true }
        return loggedIn
    }

    /// Opens Terminal running `claude auth login`, so the user signs in in the browser as usual.
    static func openLoginInTerminal(_ binary: URL) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Captioner Claude Login.command")
        let quoted = "'" + binary.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let body = "#!/bin/zsh\n\(quoted) auth login\necho\necho 'Done. You can close this window and go back to Captioner.'\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            Task { @MainActor in NSWorkspace.shared.open(script) }
        } catch {}
    }

    /// Sends one message. Pass the session from an earlier `.session` event to continue that chat.
    static func send(_ prompt: String, resume sessionID: String?, model: String, systemPrompt: String,
                     binary: URL) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = binary
            var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                             "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                             "--model", model, "--system-prompt", systemPrompt]
            if let sessionID { arguments += ["--resume", sessionID] }
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.environment = environment
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            let reader = Task.detached {
                let errorText = Task.detached { String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
                var finished = false
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        guard let event = parse(line) else { continue }
                        if case .done(let result, let isError) = event {
                            finished = true
                            if isError, looksLikeAuthFailure(result) {
                                continuation.finish(throwing: Failure.notLoggedIn)
                                return
                            }
                        }
                        continuation.yield(event)
                    }
                    process.waitUntilExit()
                    let stderr = await errorText.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if finished {
                        continuation.finish()
                    } else if looksLikeAuthFailure(stderr) {
                        continuation.finish(throwing: Failure.notLoggedIn)
                    } else {
                        continuation.finish(throwing: Failure.failed(stderr.isEmpty ? "Claude Code stopped (exit code \(process.terminationStatus))." : stderr))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            // The prompt goes in on stdin: transcripts can be long.
            Task.detached {
                input.fileHandleForWriting.write(Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
            }
        }
    }

    /// One line of `--output-format stream-json`.
    static func parse(_ line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let id = object["session_id"] as? String else { return nil }
            return .session(id)
        case "stream_event":
            guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "result":
            return .done(result: object["result"] as? String ?? "", isError: object["is_error"] as? Bool ?? false)
        default:
            return nil
        }
    }

    private static func looksLikeAuthFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("authenticat") || lower.contains("/login") || lower.contains("not logged in") || lower.contains("oauth")
    }

    /// A folder of its own, so no project's CLAUDE.md is picked up and the chats are kept together.
    private static var workingDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captioner/Claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + path
        // Started from inside a Claude Code session (say, while testing), don't look nested.
        for key in environment.keys where key.hasPrefix("CLAUDECODE") || key == "CLAUDE_CODE_ENTRYPOINT" {
            environment[key] = nil
        }
        return environment
    }

    /// Runs a short command and returns its standard output.
    private static func output(of executable: URL, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
