import AppKit
import CryptoKit
import Darwin
import Foundation
import Network
import Security
import SwiftUI

private struct UsageSnapshot: Codable {
    let usedPercent: Int
    let resetsAt: Date?
}

private struct UsageReading {
    var remaining: Int?
    var resetsAt: Date?
    var error: String?

    static let loading = UsageReading(remaining: nil, resetsAt: nil, error: nil)

    init(remaining: Int?, resetsAt: Date?, error: String? = nil) {
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.error = error
    }

    init(_ snapshot: UsageSnapshot) {
        self.init(remaining: 100 - snapshot.usedPercent, resetsAt: snapshot.resetsAt)
    }
}

private enum UsageError: LocalizedError {
    case codexNotFound
    case invalidResponse(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .codexNotFound: return "Codex CLI was not found"
        case .invalidResponse(let detail): return detail.isEmpty ? "Codex returned an unreadable response" : detail
        case .timedOut: return "Codex did not respond in time"
        }
    }
}

private final class CodexUsageReader {
    private let queue = DispatchQueue(label: "com.stevie.codexusage.reader", qos: .utility)

    func fetch(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        queue.async {
            do {
                completion(.success(try self.fetchSynchronously()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func fetchSynchronously() throws -> UsageSnapshot {
        let codexPath = try findCodex()
        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        let codexBin = URL(fileURLWithPath: codexPath).deletingLastPathComponent().path
        environment["PATH"] = codexBin + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = stderr

        try process.run()

        // FileHandle.availableData can otherwise block forever when the helper
        // stays alive without producing output, defeating the refresh timeout.
        let outputDescriptor = stdout.fileHandleForReading.fileDescriptor
        let outputFlags = fcntl(outputDescriptor, F_GETFL)
        if outputFlags >= 0 {
            _ = fcntl(outputDescriptor, F_SETFL, outputFlags | O_NONBLOCK)
        }

        let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-usage","title":"Codex Usage","version":"1.0.0"},"capabilities":{"experimentalApi":true}}}"#
        stdin.fileHandleForWriting.write(Data((initialize + "\n").utf8))

        let deadline = Date().addingTimeInterval(15)
        var buffer = Data()
        defer {
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.05)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        var didInitialize = false
        while Date() < deadline {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let byteCount = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(outputDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if byteCount > 0 {
                buffer.append(contentsOf: bytes.prefix(byteCount))
            } else if byteCount == 0 {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }

                let responseID = (object["id"] as? NSNumber)?.intValue
                if responseID == 1, !didInitialize {
                    didInitialize = true
                    let initialized = #"{"method":"initialized"}"#
                    let readLimits = #"{"id":2,"method":"account/rateLimits/read","params":null}"#
                    stdin.fileHandleForWriting.write(Data((initialized + "\n" + readLimits + "\n").utf8))
                    continue
                }

                guard responseID == 2,
                      let result = object["result"] as? [String: Any],
                      let limits = result["rateLimits"] as? [String: Any],
                      let primary = limits["primary"] as? [String: Any],
                      let percentNumber = primary["usedPercent"] as? NSNumber else { continue }

                let resetSeconds = (primary["resetsAt"] as? NSNumber)?.doubleValue
                return UsageSnapshot(
                    usedPercent: max(0, min(100, percentNumber.intValue)),
                    resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:))
                )
            }
        }

        if process.isRunning { throw UsageError.timedOut }
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw UsageError.invalidResponse(detail)
    }

    private func findCodex() throws -> String {
        let nodeVersions = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nodeVersions) {
            for version in versions.sorted().reversed() {
                let candidate = nodeVersions + "/" + version + "/bin/codex"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0, !path.isEmpty { return path }

        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex"
        ]
        guard let fallback = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UsageError.codexNotFound
        }
        return fallback
    }
}

private enum ClaudeUsageError: LocalizedError {
    case notSignedIn
    case signedOut
    case unavailable
    case invalidResponse
    case keychain(Int32)
    case rateLimited(TimeInterval?)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn, .signedOut: return "Sign in to Claude from this menu"
        case .unavailable: return "Claude usage is unavailable"
        case .invalidResponse: return "Claude returned an unreadable response"
        case .keychain(let status): return "Keychain error \(status)"
        case .rateLimited: return "Claude usage is rate-limited"
        case .server(let status): return "Claude usage returned HTTP \(status)"
        }
    }
}

private struct ClaudeUsageSnapshot: Codable {
    let fiveHour: UsageSnapshot
    let sevenDay: UsageSnapshot
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

private struct CachedClaudeUsage: Codable {
    let snapshot: ClaudeUsageSnapshot
    let fetchedAt: Date
}

private final class ClaudeUsageReader {
    // The app keeps its own OAuth session in its own Keychain item. Refresh tokens rotate on
    // every use, so sharing Claude Code's session meant the app and the CLI kept invalidating
    // each other's token, and both ended up signed out.
    fileprivate static let appService = "AI Usage-Claude OAuth"
    private static let cliService = "Claude Code-credentials"
    fileprivate static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    fileprivate static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let refreshMargin: TimeInterval = 5 * 60

    fileprivate struct Credentials {
        var root: [String: Any]
        var oauth: [String: Any]
        var accessToken: String? { oauth["accessToken"] as? String }
        var refreshToken: String? { oauth["refreshToken"] as? String }
        var expiresAt: Date? {
            (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }

        mutating func apply(tokenResponse object: [String: Any]) -> Bool {
            guard let accessToken = object["access_token"] as? String else { return false }
            oauth["accessToken"] = accessToken
            if let newRefresh = object["refresh_token"] as? String {
                oauth["refreshToken"] = newRefresh
            }
            if let expiresIn = object["expires_in"] as? NSNumber {
                let expiresAt = Date().addingTimeInterval(expiresIn.doubleValue)
                oauth["expiresAt"] = NSNumber(value: Int64(expiresAt.timeIntervalSince1970 * 1000))
            }
            if let scope = object["scope"] as? String {
                oauth["scopes"] = scope.split(separator: " ").map(String.init)
            }
            return true
        }
    }

    func fetch(completion: @escaping (Result<ClaudeUsageSnapshot, Error>) -> Void) {
        guard let credentials = try? Self.loadCredentials(service: Self.appService) else {
            fetchWithCLIToken(completion: completion)
            return
        }
        fetchWithAppSession(credentials) { [weak self] result in
            // If Claude ended the app's session, keep working off the CLI until the user signs in again.
            if case .failure(ClaudeUsageError.signedOut) = result, let self {
                self.fetchWithCLIToken { fallback in
                    if case .success = fallback { completion(fallback) } else { completion(result) }
                }
            } else {
                completion(result)
            }
        }
    }

    // Borrow a signed-in Claude Code CLI's access token read-only. Never refresh or rewrite that
    // item: spending its refresh token logs the CLI out.
    private func fetchWithCLIToken(completion: @escaping (Result<ClaudeUsageSnapshot, Error>) -> Void) {
        guard let cli = try? Self.loadCredentials(service: Self.cliService),
              let token = cli.accessToken,
              cli.expiresAt.map({ $0 > Date() }) ?? true else {
            completion(.failure(ClaudeUsageError.notSignedIn))
            return
        }
        requestUsage(token: token, completion: completion)
    }

    private func fetchWithAppSession(_ credentials: Credentials, completion: @escaping (Result<ClaudeUsageSnapshot, Error>) -> Void) {
        let needsRefresh = credentials.expiresAt.map { $0.timeIntervalSinceNow < Self.refreshMargin } ?? false
        guard !needsRefresh, let token = credentials.accessToken else {
            refreshThenRequest(credentials, completion: completion)
            return
        }
        requestUsage(token: token) { [weak self] result in
            if case .failure(ClaudeUsageError.signedOut) = result, let self {
                self.refreshThenRequest(credentials, completion: completion)
            } else {
                completion(result)
            }
        }
    }

    private func refreshThenRequest(_ credentials: Credentials, completion: @escaping (Result<ClaudeUsageSnapshot, Error>) -> Void) {
        refresh(credentials) { [weak self] result in
            switch result {
            case .success(let token): self?.requestUsage(token: token, completion: completion)
            case .failure(let error): completion(.failure(error))
            }
        }
    }

    // Items written through /usr/bin/security list that tool as their trusted app, so reading
    // them through it again never prompts, even though this app is only ad-hoc signed.
    private static let securityTool = "/usr/bin/security"
    private static let itemNotFoundExitCode: Int32 = 44

    static var hasAppSession: Bool {
        (try? loadCredentials(service: appService)) != nil
    }

    private static func loadCredentials(service: String) throws -> Credentials {
        let result = try runSecurity(arguments: ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"])
        guard result.status == 0 else {
            throw result.status == itemNotFoundExitCode ? ClaudeUsageError.notSignedIn : ClaudeUsageError.keychain(result.status)
        }
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // security prints the secret as hex when it contains non-printable bytes.
        let data = text.hasPrefix("{") ? Data(text.utf8) : (Data(hex: text) ?? Data(text.utf8))
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw ClaudeUsageError.notSignedIn
        }
        return Credentials(root: root, oauth: oauth)
    }

    fileprivate static func saveAppCredentials(_ credentials: Credentials) throws {
        var root = credentials.root
        root["claudeAiOauth"] = credentials.oauth
        let data = try JSONSerialization.data(withJSONObject: root)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        // Interactive mode reads the command from stdin so the tokens never appear in argv.
        let command = "add-generic-password -U -a \"\(NSUserName())\" -s \"\(appService)\" -X \(hex)\n"
        let result = try runSecurity(arguments: ["-i"], input: Data(command.utf8))
        guard result.status == 0 else { throw ClaudeUsageError.keychain(result.status) }
    }

    private static func runSecurity(arguments: [String], input: Data? = nil) throws -> (status: Int32, output: Data) {
        let process = Process()
        let stdout = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: securityTool)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    /// Exchanges the app's own refresh token and stores the rotated tokens in the app's item.
    private func refresh(_ credentials: Credentials, completion: @escaping (Result<String, Error>) -> Void) {
        guard let refreshToken = credentials.refreshToken else {
            completion(.failure(ClaudeUsageError.signedOut))
            return
        }
        Self.postToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ]) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let object):
                var updated = credentials
                guard updated.apply(tokenResponse: object), let token = updated.accessToken else {
                    completion(.failure(ClaudeUsageError.invalidResponse))
                    return
                }
                do {
                    try Self.saveAppCredentials(updated)
                    completion(.success(token))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    fileprivate static func postToken(_ body: [String: String], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.failure(ClaudeUsageError.unavailable))
                return
            }
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            // Only a rejected grant means the session is gone. Any other failure is treated as
            // transient so the stored tokens are kept and the refresh is retried later.
            let errorCode = (object?["error"] as? String) ?? ((object?["error"] as? [String: Any])?["type"] as? String)
            if errorCode == "invalid_grant" || response.statusCode == 401 {
                completion(.failure(ClaudeUsageError.signedOut))
                return
            }
            if response.statusCode == 429 {
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                completion(.failure(ClaudeUsageError.rateLimited(retryAfter)))
                return
            }
            guard response.statusCode == 200, let object else {
                completion(.failure(ClaudeUsageError.server(response.statusCode)))
                return
            }
            completion(.success(object))
        }.resume()
    }

    private func requestUsage(token: String, completion: @escaping (Result<ClaudeUsageSnapshot, Error>) -> Void) {
        requestUsageEndpoint(token: token) { [weak self] result in
            guard case .failure(let error) = result, let self else {
                completion(result)
                return
            }
            switch error {
            case ClaudeUsageError.signedOut, ClaudeUsageError.notSignedIn:
                completion(result)
            default:
                // The usage endpoint is undocumented and often rate-limited; the API reports the
                // same windows in its rate-limit headers, so read them from a one-token request.
                self.requestUsageFromHeaders(token: token) { fallback in
                    if case .success = fallback { completion(fallback) } else { completion(result) }
                }
            }
        }
    }

    private func requestUsageFromHeaders(token: String, completion: @escaping (Result<ClaudeUsageSnapshot, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "system": "You are Claude Code, Anthropic's official CLI for Claude.",
            "messages": [["role": "user", "content": "."]]
        ] as [String: Any])

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.failure(ClaudeUsageError.unavailable))
                return
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                completion(.failure(ClaudeUsageError.signedOut))
                return
            }
            // A 429 from an exhausted window still carries the headers.
            guard let fiveHour = Self.parseHeaderWindow(response, "5h"),
                  let sevenDay = Self.parseHeaderWindow(response, "7d") else {
                completion(.failure(ClaudeUsageError.server(response.statusCode)))
                return
            }
            completion(.success(ClaudeUsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay)))
        }.resume()
    }

    private static func parseHeaderWindow(_ response: HTTPURLResponse, _ window: String) -> UsageSnapshot? {
        let prefix = "anthropic-ratelimit-unified-\(window)-"
        guard let utilization = response.value(forHTTPHeaderField: prefix + "utilization").flatMap(Double.init) else { return nil }
        // Headers report a 0–1 fraction; the usage endpoint reports a percentage.
        let percent = utilization <= 1 ? utilization * 100 : utilization
        let reset = response.value(forHTTPHeaderField: prefix + "reset")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
        return UsageSnapshot(usedPercent: max(0, min(100, Int(percent.rounded()))), resetsAt: reset)
    }

    private func requestUsageEndpoint(token: String, completion: @escaping (Result<ClaudeUsageSnapshot, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("StevieUsage/1.1", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.failure(ClaudeUsageError.unavailable))
                return
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                completion(.failure(ClaudeUsageError.signedOut))
                return
            }
            if response.statusCode == 429 {
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                completion(.failure(ClaudeUsageError.rateLimited(retryAfter)))
                return
            }
            guard response.statusCode == 200 else {
                completion(.failure(ClaudeUsageError.server(response.statusCode)))
                return
            }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fiveHour = Self.parseWindow(object["five_hour"]),
                  let sevenDay = Self.parseWindow(object["seven_day"]) else {
                completion(.failure(ClaudeUsageError.invalidResponse))
                return
            }
            completion(.success(ClaudeUsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay)))
        }.resume()
    }

    private static func parseWindow(_ value: Any?) -> UsageSnapshot? {
        guard let window = value as? [String: Any],
              let utilization = window["utilization"] as? NSNumber else { return nil }
        let reset = (window["resets_at"] as? String).flatMap { value in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        return UsageSnapshot(
            usedPercent: max(0, min(100, Int(utilization.doubleValue.rounded()))),
            resetsAt: reset
        )
    }
}

/// Signs the app in to Claude with the same OAuth flow Claude Code uses (PKCE + localhost
/// callback), giving the app a session of its own.
private final class ClaudeSignIn {
    private static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    private static let successURL = "https://platform.claude.com/oauth/code/success?app=claude-code"
    private static let scopes = "user:profile user:inference"

    private let queue = DispatchQueue(label: "com.stevie.codexusage.signin")
    private var listener: NWListener?
    private var completion: ((Result<Void, Error>) -> Void)?

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.finish(.failure(CancellationError()))
            self.completion = completion
            do { try self.listen() } catch { self.finish(.failure(error)) }
        }
    }

    private func listen() throws {
        let verifier = Self.randomToken()
        let state = Self.randomToken()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state_ in
            guard let self else { return }
            switch state_ {
            case .ready:
                guard let port = listener.port?.rawValue else { return }
                var components = URLComponents(string: Self.authorizeURL)!
                components.queryItems = [
                    URLQueryItem(name: "code", value: "true"),
                    URLQueryItem(name: "client_id", value: ClaudeUsageReader.clientID),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "redirect_uri", value: "http://localhost:\(port)/callback"),
                    URLQueryItem(name: "scope", value: Self.scopes),
                    URLQueryItem(name: "code_challenge", value: challenge),
                    URLQueryItem(name: "code_challenge_method", value: "S256"),
                    URLQueryItem(name: "state", value: state)
                ]
                if let url = components.url {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            case .failed(let error):
                self.finish(.failure(error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, verifier: verifier, state: state)
        }
        listener.start(queue: queue)

        // Give up if the browser flow is abandoned.
        queue.asyncAfter(deadline: .now() + 10 * 60) { [weak self, weak listener] in
            guard let self, let listener, self.listener === listener else { return }
            self.finish(.failure(URLError(.timedOut)))
        }
    }

    private func handle(_ connection: NWConnection, verifier: String, state: String) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                .components(separatedBy: "\r\n").first ?? ""
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard let components = URLComponents(string: "http://localhost" + target),
                  components.path == "/callback",
                  let port = self.listener?.port?.rawValue else {
                Self.respond(connection, status: "404 Not Found", location: nil)
                return
            }
            let items = components.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                Self.respond(connection, status: "400 Bad Request", location: nil)
                self.finish(.failure(ClaudeUsageError.signedOut))
                return
            }
            Self.respond(connection, status: "302 Found", location: Self.successURL)
            ClaudeUsageReader.postToken([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": "http://localhost:\(port)/callback",
                "client_id": ClaudeUsageReader.clientID,
                "code_verifier": verifier,
                "state": state
            ]) { [weak self] result in
                self?.queue.async {
                    switch result {
                    case .failure(let error):
                        self?.finish(.failure(error))
                    case .success(let object):
                        var credentials = ClaudeUsageReader.Credentials(root: [:], oauth: [:])
                        guard credentials.apply(tokenResponse: object), credentials.refreshToken != nil else {
                            self?.finish(.failure(ClaudeUsageError.invalidResponse))
                            return
                        }
                        do {
                            try ClaudeUsageReader.saveAppCredentials(credentials)
                            self?.finish(.success(()))
                        } catch {
                            self?.finish(.failure(error))
                        }
                    }
                }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        listener?.cancel()
        listener = nil
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    private static func respond(_ connection: NWConnection, status: String, location: String?) {
        var head = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n"
        if let location { head += "Location: \(location)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class UsageModel: ObservableObject {
    @Published var codexWeekly = UsageReading.loading
    @Published var claudeFiveHour = UsageReading.loading
    @Published var claudeWeekly = UsageReading.loading
    @Published var updateDetail = "Codex 1m · Claude 5m"
    @Published var launchAtLoginEnabled = false
    @Published var claudeNeedsSignIn = false
    @Published var isSigningIn = false
    @Published var showBars = UserDefaults.standard.object(forKey: "showBars") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showBars, forKey: "showBars") }
    }

    private let codexReader = CodexUsageReader()
    private let claudeReader = ClaudeUsageReader()
    private let claudeSignIn = ClaudeSignIn()
    private let claudeCacheKey = "lastGoodClaudeUsage"
    private let claudeCacheMaxAge: TimeInterval = 60 * 60
    private var timer: Timer?
    private var isRefreshingCodex = false
    private var isRefreshingClaude = false
    private var lastClaudeSuccess: Date?
    private var nextClaudeRefreshAt = Date.distantPast

    init() {
        // A second copy would refresh the same single-use token and sign both out.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .contains(where: { $0.processIdentifier != getpid() }) {
            exit(0)
        }
        if let data = UserDefaults.standard.data(forKey: claudeCacheKey),
           let cache = try? JSONDecoder().decode(CachedClaudeUsage.self, from: data),
           Date().timeIntervalSince(cache.fetchedAt) < claudeCacheMaxAge {
            claudeFiveHour = UsageReading(cache.snapshot.fiveHour)
            claudeWeekly = UsageReading(cache.snapshot.sevenDay)
            lastClaudeSuccess = cache.fetchedAt
        }
        launchAtLoginEnabled = FileManager.default.fileExists(atPath: launchAgentURL.path)
        if !launchAtLoginEnabled {
            try? setLaunchAtLogin(true)
            launchAtLoginEnabled = true
        } else if let plist = NSDictionary(contentsOf: launchAgentURL),
                  let arguments = plist["ProgramArguments"] as? [String],
                  arguments.first != Bundle.main.executableURL?.path {
            try? setLaunchAtLogin(true)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshScheduled() }
        }
    }

    func refresh() {
        refreshCodex()
        refreshClaude(force: true)
    }

    private func refreshScheduled() {
        refreshCodex()
        refreshClaude(force: false)
    }

    private func refreshCodex() {
        guard !isRefreshingCodex else { return }
        isRefreshingCodex = true
        codexReader.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingCodex = false
                switch result {
                case .success(let snapshot):
                    self.codexWeekly = UsageReading(snapshot)
                case .failure(let error):
                    self.codexWeekly = UsageReading(remaining: nil, resetsAt: nil, error: error.localizedDescription)
                }
            }
        }
    }

    private func refreshClaude(force: Bool) {
        guard !isRefreshingClaude, (force || Date() >= nextClaudeRefreshAt) else { return }
        isRefreshingClaude = true
        claudeReader.fetch { [weak self] result in
            let hasAppSession = ClaudeUsageReader.hasAppSession
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshingClaude = false
                switch result {
                case .success(let snapshot):
                    let now = Date()
                    UserDefaults.standard.removeObject(forKey: "lastClaudeFailure")
                    self.claudeFiveHour = UsageReading(snapshot.fiveHour)
                    self.claudeWeekly = UsageReading(snapshot.sevenDay)
                    // Borrowing the CLI's token only lasts until it expires, so keep offering sign-in.
                    self.claudeNeedsSignIn = !hasAppSession
                    self.lastClaudeSuccess = now
                    self.nextClaudeRefreshAt = now.addingTimeInterval(5 * 60)
                    let cache = CachedClaudeUsage(snapshot: snapshot, fetchedAt: now)
                    if let data = try? JSONEncoder().encode(cache) {
                        UserDefaults.standard.set(data, forKey: self.claudeCacheKey)
                    }
                    self.updateDetail = "Codex 1m · Claude 5m"
                case .failure(let error):
                    let now = Date()
                    UserDefaults.standard.set(error.localizedDescription, forKey: "lastClaudeFailure")
                    switch error {
                    case ClaudeUsageError.notSignedIn, ClaudeUsageError.signedOut: self.claudeNeedsSignIn = true
                    default: self.claudeNeedsSignIn = !hasAppSession
                    }
                    let retryDelay: TimeInterval
                    if case ClaudeUsageError.rateLimited(let retryAfter) = error {
                        retryDelay = max(5 * 60, retryAfter ?? 0)
                    } else {
                        retryDelay = 2 * 60
                    }
                    self.nextClaudeRefreshAt = now.addingTimeInterval(retryDelay)
                    let cacheAge = self.lastClaudeSuccess.map { now.timeIntervalSince($0) }
                    if let cacheAge, cacheAge < self.claudeCacheMaxAge {
                        let minutes = max(1, Int(cacheAge / 60))
                        let message = "Showing last update (\(minutes)m ago) · \(error.localizedDescription)"
                        self.claudeFiveHour.error = message
                        self.claudeWeekly.error = message
                    } else {
                        let reading = UsageReading(remaining: nil, resetsAt: nil, error: error.localizedDescription)
                        self.claudeFiveHour = reading
                        self.claudeWeekly = reading
                    }
                    self.updateDetail = "Claude refresh failed · retrying"
                }
            }
        }
    }

    func signInToClaude() {
        guard !isSigningIn else { return }
        isSigningIn = true
        updateDetail = "Finish signing in in your browser"
        claudeSignIn.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSigningIn = false
                switch result {
                case .success:
                    self.updateDetail = "Signed in to Claude"
                    self.refreshClaude(force: true)
                case .failure(let error):
                    self.updateDetail = "Claude sign-in failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func toggleLaunchAtLogin() {
        do {
            try setLaunchAtLogin(!launchAtLoginEnabled)
            launchAtLoginEnabled.toggle()
        } catch {
            updateDetail = "Couldn’t change Launch at Login: \(error.localizedDescription)"
        }
    }

    func openCodex() {
        NSWorkspace.shared.open(URL(string: "codex://")!)
    }

    func openClaude() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/Claude.app"),
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.stevie.codexusage.plist")
    }

    private func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            let executable = Bundle.main.executableURL?.path ?? Bundle.main.bundlePath + "/Contents/MacOS/CodexUsage"
            let plist: [String: Any] = [
                "Label": "com.stevie.codexusage",
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "ProcessType": "Interactive"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: launchAgentURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
    }
}

@main
private struct CodexUsageApp: App {
    @StateObject private var model = UsageModel()

    private let claudeColor = Color(red: 0.78, green: 0.39, blue: 0.29)
    private let codexColor = Color(red: 0.04, green: 0.58, blue: 0.44)

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 0) {
                Text("USAGE REMAINING")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                    .padding(.bottom, 11)

                UsageRow(title: "Claude · 5 hours", reading: model.claudeFiveHour, color: claudeColor)
                UsageRow(title: "Claude · weekly", reading: model.claudeWeekly, color: claudeColor)
                    .padding(.top, 12)
                UsageRow(title: "Codex · weekly", reading: model.codexWeekly, color: codexColor)
                    .padding(.top, 12)

                if model.claudeNeedsSignIn {
                    Button(model.isSigningIn ? "Waiting for browser…" : "Sign in to Claude") {
                        model.signInToClaude()
                    }
                    .disabled(model.isSigningIn)
                    .padding(.top, 12)
                }

                Divider().padding(.vertical, 12)

                HStack {
                    Text(model.updateDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                }

                HStack {
                    Toggle("Show bars", isOn: $model.showBars)
                    Spacer()
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { _ in model.toggleLaunchAtLogin() }
                    ))
                }
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.top, 10)

                HStack(spacing: 12) {
                    Button("Open Claude") { model.openClaude() }
                    Button("Open Codex") { model.openCodex() }
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
            .padding(15)
            .frame(width: 272)
        } label: {
            Image(nsImage: StatusArtwork.image(
                claudeFiveHour: model.claudeFiveHour,
                claudeWeekly: model.claudeWeekly,
                codexWeekly: model.codexWeekly,
                showBars: model.showBars
            ))
            .resizable()
            .interpolation(.high)
            .frame(width: model.showBars ? 66 : 43, height: 27)
            .accessibilityLabel("Claude five-hour \(percentage(model.claudeFiveHour)), Claude weekly \(percentage(model.claudeWeekly)), Codex weekly \(percentage(model.codexWeekly)) remaining")
        }
        .menuBarExtraStyle(.window)
    }

    private func percentage(_ reading: UsageReading) -> String {
        guard let remaining = reading.remaining else { return "unavailable" }
        return "\(remaining) percent\(reading.error == nil ? "" : ", last refresh failed")"
    }
}

private enum StatusArtwork {
    static func image(claudeFiveHour: UsageReading, claudeWeekly: UsageReading, codexWeekly: UsageReading, showBars: Bool) -> NSImage {
        let size = NSSize(width: showBars ? 66 : 43, height: 27)
        let image = NSImage(size: size, flipped: false) { _ in
            let claude = NSColor(calibratedRed: 1, green: 0.43, blue: 0.31, alpha: 1)
            let codex = NSColor(calibratedRed: 0.31, green: 0.9, blue: 0.66, alpha: 1)

            drawLogo("ClaudeMark", in: NSRect(x: 1, y: 10.5, width: 14, height: 14), color: claude)
            drawLogo("OpenAIMark", in: NSRect(x: 2.5, y: 0, width: 10.5, height: 10.5), color: codex)
            drawRow(claudeFiveHour, bottom: 18, color: claude, showBars: showBars)
            drawRow(claudeWeekly, bottom: 9, color: claude, showBars: showBars)
            drawRow(codexWeekly, bottom: 0, color: codex, showBars: showBars)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawRow(_ reading: UsageReading, bottom: CGFloat, color: NSColor, showBars: Bool) {
        let value = reading.remaining.map { "\($0)%" } ?? "—"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: reading.error == nil ? NSColor.white : NSColor.white.withAlphaComponent(0.6)
        ]
        (value as NSString).draw(at: NSPoint(x: 17, y: bottom), withAttributes: attributes)

        guard showBars else { return }
        let track = NSBezierPath(roundedRect: NSRect(x: 46, y: bottom + 3, width: 18, height: 2), xRadius: 1, yRadius: 1)
        NSColor.white.withAlphaComponent(0.4).setFill()
        track.fill()
        if let remaining = reading.remaining {
            let filled = NSBezierPath(roundedRect: NSRect(x: 46, y: bottom + 3, width: 18 * CGFloat(remaining) / 100, height: 2), xRadius: 1, yRadius: 1)
            (reading.error == nil ? color : color.withAlphaComponent(0.5)).setFill()
            filled.fill()
        }
    }

    private static func drawLogo(_ name: String, in rect: NSRect, color: NSColor) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.setFill()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
        tinted.unlockFocus()
        tinted.draw(in: rect)
    }
}

private struct UsageRow: View {
    let title: String
    let reading: UsageReading
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(reading.remaining.map { "\($0)%" } ?? "—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let error = reading.error { return error }
        if let reset = reading.resetsAt {
            let relative = RelativeDateTimeFormatter().localizedString(for: reset, relativeTo: Date())
            return "Resets \(relative)"
        }
        return reading.remaining == nil ? "Loading…" : "Reset time unavailable"
    }
}
