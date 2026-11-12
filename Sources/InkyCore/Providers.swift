import Foundation

public protocol Provider: AnyObject, Sendable {
    var displayName: String { get }
    /// Returns the model's full text answer.
    func complete(system: String, user: String) async throws -> String
}

public enum ProviderError: LocalizedError {
    case executableNotFound(String)
    case processFailed(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let n): "Couldn't find `\(n)`. Install it or set its path in Settings."
        case .processFailed(let m): m
        case .badResponse(let m): "Unexpected response: \(m)"
        }
    }
}

/// GUI apps don't inherit the user's shell PATH, so resolve CLIs through a login shell.
public enum CommandResolver {
    public static func resolve(_ name: String, override: String? = nil) -> String? {
        let fm = FileManager.default
        if let o = override, !o.isEmpty, fm.isExecutableFile(atPath: o) { return o }
        let home = fm.homeDirectoryForCurrentUser.path
        for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"] {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    static func workingDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inky/work", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Claude Code

/// Keeps one `claude -p` process alive (stream-json in/out) so each request skips the
/// ~1 s startup. Recycled every `maxRequests` to keep the session context small.
public actor ClaudeCodeProvider: Provider {
    public nonisolated let displayName: String
    private let model: String
    private let executableOverride: String?
    private let maxRequests = 15

    private var process: Process?
    private var stdin: FileHandle?
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator?
    private var requests = 0
    private var currentSystem = ""

    public init(model: String = "haiku", executable: String? = nil) {
        self.model = model
        self.executableOverride = executable
        self.displayName = "Claude \(model.capitalized)"
    }

    /// Starts the process ahead of the first hotkey press.
    public func warmUp(system: String) {
        if process == nil { try? start(system: system) }
    }

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Requests share one pipe, so they must not interleave (a cancelled Swift task keeps running).
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    public func complete(system: String, user: String) async throws -> String {
        await acquire()
        defer { release() }
        if process?.isRunning != true || requests >= maxRequests || system != currentSystem {
            stop()
            try start(system: system)
        }
        requests += 1
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": user]]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        do {
            try stdin?.write(contentsOf: line)
            // Copy the iterator out of actor state; requests are serialized by the app.
            var it = lines
            defer { lines = it }
            while let raw = try await it?.next() {
                guard let ev = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      ev["type"] as? String == "result" else { continue }
                if ev["is_error"] as? Bool == true {
                    throw ProviderError.processFailed("Claude: \(ev["result"] as? String ?? "error")")
                }
                return ev["result"] as? String ?? ""
            }
            throw ProviderError.processFailed("Claude exited unexpectedly. Is `claude` logged in?")
        } catch {
            stop()
            throw error
        }
    }

    private func start(system: String) throws {
        guard let exe = CommandResolver.resolve("claude", override: executableOverride) else {
            throw ProviderError.executableNotFound("claude")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.currentDirectoryURL = CommandResolver.workingDirectory()
        p.arguments = [
            "-p", "--model", model,
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--tools", "", "--strict-mcp-config", "--setting-sources", "",
            "--system-prompt", system,
        ]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        lines = outPipe.fileHandleForReading.bytes.lines.makeAsyncIterator()
        requests = 0
        currentSystem = system
    }

    private func stop() {
        try? stdin?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; stdin = nil; lines = nil
    }
}

// MARK: - Codex

/// One `codex exec` per request (~5 s). stdin must be closed or codex waits for input.
public final class CodexProvider: Provider, @unchecked Sendable {
    public let displayName: String
    private let model: String?
    private let executableOverride: String?

    public init(model: String? = nil, executable: String? = nil) {
        self.model = model
        self.executableOverride = executable
        self.displayName = model.map { "Codex \($0)" } ?? "Codex"
    }

    public func complete(system: String, user: String) async throws -> String {
        guard let exe = CommandResolver.resolve("codex", override: executableOverride) else {
            throw ProviderError.executableNotFound("codex")
        }
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("inky-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outFile) }
        var args = ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-o", outFile.path]
        if let model, !model.isEmpty { args += ["-m", model] }
        args.append("\(system)\n\n\(user)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.currentDirectoryURL = CommandResolver.workingDirectory()
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { _ in c.resume() }
            do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: error) }
        }
        guard p.terminationStatus == 0, let text = try? String(contentsOf: outFile, encoding: .utf8) else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ProviderError.processFailed("Codex failed: \(msg.suffix(300))")
        }
        return text
    }
}

// MARK: - OpenAI-compatible (Ollama, LM Studio, OpenAI, OpenRouter…)

public final class OpenAICompatibleProvider: Provider, @unchecked Sendable {
    public let displayName: String
    private let baseURL: URL
    private let model: String
    private let apiKey: String?

    public init(baseURL: URL, model: String, apiKey: String?) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.displayName = model
    }

    public func complete(system: String, user: String) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
        else { throw ProviderError.badResponse(String(decoding: data.prefix(300), as: UTF8.self)) }
        return content
    }
}
