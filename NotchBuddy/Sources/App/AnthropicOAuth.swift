import Foundation

// MARK: - Anthropic sign-in (OAuth through the official `ant` CLI)
//
// `ant auth login` opens the browser, the user signs in to the Anthropic Console,
// and the CLI stores a refreshable token under ~/.config/anthropic/ in its own
// `coucou` profile (so Claude Code's login is left alone). Each request asks
// the CLI for a fresh access token. Billed to the Console org, like an API key.

enum AnthropicAuth {
    case apiKey(String)
    case oauth(String)

    /// Sets the auth headers. `beta` is the request's own beta flag, merged with the OAuth one.
    func apply(to req: inout URLRequest, beta: String? = nil) {
        var betas = beta.map { [$0] } ?? []
        switch self {
        case .apiKey(let key):
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        case .oauth(let token):
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            betas.append("oauth-2025-04-20")
        }
        if !betas.isEmpty { req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
    }

    /// Sign-in is the default: used whenever the profile exists, the saved API key otherwise.
    static func current() async -> AnthropicAuth? {
        if AnthropicOAuth.isSignedIn, let token = await AnthropicOAuth.accessToken() {
            return .oauth(token)
        }
        if let key = KeychainStore.shared.get("anthropic-api-key"), !key.isEmpty { return .apiKey(key) }
        return nil
    }

    static var isConfigured: Bool {
        ClaudeCodeChat.isEnabled || AnthropicOAuth.isSignedIn || KeychainStore.shared.get("anthropic-api-key") != nil
    }
}

enum AnthropicOAuth {
    static let profile = "coucou"
    // ponytail: fixed port makes `ant` use a localhost callback (no code to paste).
    // If it's taken, login fails with a clear error; make it configurable if that happens.
    static let callbackPort = "53682"

    /// GUI apps don't get the shell PATH, so look where Homebrew installs it.
    static var antPath: String? {
        ["/opt/homebrew/bin/ant", "/usr/local/bin/ant"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isSignedIn: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return FileManager.default.fileExists(atPath: "\(home)/.config/anthropic/credentials/\(profile).json")
    }

    /// Opens the browser and waits (up to 5 min) for the user to finish. Returns an error message or nil.
    static func login() async -> String? {
        guard antPath != nil else { return "Install the Anthropic CLI first: brew install anthropics/tap/ant" }
        // `ant auth login` makes the profile active; put back whatever was active before,
        // so the user's own `ant`/SDK/Claude Code setup keeps its credentials.
        let active = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/anthropic/active_config")
        let previous = try? Data(contentsOf: active)
        defer {
            if let previous { try? previous.write(to: active) } else { try? FileManager.default.removeItem(at: active) }
        }
        let (code, out) = await run(["auth", "login", "--profile", profile, "--callback-port", callbackPort])
        if code == 0 && isSignedIn { return nil }
        let last = out.split(separator: "\n").last.map(String.init) ?? ""
        return last.isEmpty ? "Sign-in failed." : last
    }

    static func logout() async {
        _ = await run(["auth", "logout", "--profile", profile])
    }

    /// Short-lived token; the CLI refreshes it when needed.
    static func accessToken() async -> String? {
        let (code, out) = await run(["auth", "print-credentials", "--access-token", "--profile", profile])
        let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return code == 0 && !token.isEmpty ? token : nil
    }

    private static func run(_ args: [String]) async -> (Int32, String) {
        guard let antPath else { return (-1, "") }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: antPath)
            p.arguments = args
            // An API key in the environment would shadow the profile.
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
        }
    }
}
