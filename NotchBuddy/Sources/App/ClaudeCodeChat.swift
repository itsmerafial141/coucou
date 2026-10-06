import Foundation

// MARK: - Notch chat backed by the Claude Code CLI
//
// Each message runs `claude -p` (headless Claude Code, the user's own subscription)
// in the home folder, streams its JSON events into the chat bubble, and resumes the
// same session on the next message. "+" (new conversation) starts a fresh session.

@MainActor
final class ClaudeCodeChat {
    static let shared = ClaudeCodeChat()

    /// "claudeCode" (default) or "api" (Anthropic API: browser sign-in / API key).
    nonisolated static var isEnabled: Bool {
        (UserDefaults.standard.string(forKey: "anthropicBackend") ?? "claudeCode") == "claudeCode"
            && claudePath != nil
    }

    nonisolated static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Sessions started from the notch; HookServer skips them so they don't show up as terminal pills.
    private(set) static var ownSessions: Set<String> = []

    private var sessionId: String?
    private var process: Process?

    func reset() {
        process?.terminate()
        process = nil
        sessionId = nil
    }

    func chat(query: String, context: PromptContext?, state: AppState) async {
        guard let claude = Self.claudePath else { return }

        var prompt = query
        if sessionId == nil, let context {
            switch context {
            case .window(let app, let title, let url):
                prompt = "Context — App: \(app), Window: \(title)\(url.map { ", URL: \($0)" } ?? "")\n\n\(query)"
            case .file(let name, let fileURL):
                let paths = state.contextFiles(fileURL).map(\.path)
                prompt = (paths.isEmpty ? "File: \(name)" : paths.map { "File: \($0)" }.joined(separator: "\n"))
                    + "\n\n\(query)"
            }
        }

        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--dangerously-skip-permissions",
                    "--append-system-prompt", Self.systemPrompt]
        if let sessionId {
            args += ["--resume", sessionId]
        } else {
            let id = UUID().uuidString.lowercased()
            args += ["--session-id", id]
            sessionId = id
            Self.ownSessions.insert(id)
        }
        let model = state.claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        // ponytail: the app's built-in default means "not picked" → Claude Code's own default model.
        if !model.isEmpty && model != AppState.defaultClaudeModel { args += ["--model", model] }

        let p = Process()
        // Login shell so Claude Code's Bash tool gets the user's PATH (brew, fvm, …).
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec \"$0\" \"$@\"", claude] + args
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "ANTHROPIC_API_KEY"] { env.removeValue(forKey: k) }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        let bubble = ChatMessage(role: .assistant, content: "")
        state.chatHistory.append(bubble)
        state.stateOverride = .thinking
        func show(_ text: String) {
            if let i = state.chatHistory.firstIndex(where: { $0.id == bubble.id }) {
                state.chatHistory[i].content = text
            }
        }

        do { try p.run() } catch {
            state.chatHistory.removeAll { $0.id == bubble.id }
            await fail("Couldn't start Claude Code: \(error.localizedDescription)", state: state)
            return
        }
        process = p

        var streamed = ""
        var final: String?
        var errorText: String?
        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                switch e["type"] as? String {
                case "stream_event":
                    if let ev = e["event"] as? [String: Any],
                       let delta = ev["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let t = delta["text"] as? String {
                        streamed += t
                        if state.stateOverride == .thinking { state.stateOverride = nil }
                        show(streamed)
                    }
                case "assistant":
                    // Tool step: show what Claude Code is doing until text arrives.
                    let blocks = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    if let tool = blocks.first(where: { $0["type"] as? String == "tool_use" }) {
                        let step = Self.describe(tool)
                        if !streamed.isEmpty { streamed += "\n\n" }
                        show(streamed + "_\(step)…_")
                    }
                case "result":
                    if e["is_error"] as? Bool == true || e["subtype"] as? String != "success" {
                        errorText = e["result"] as? String ?? "Claude Code stopped with an error."
                    } else {
                        final = e["result"] as? String
                    }
                default: break
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
        p.waitUntilExit()
        if process === p { process = nil }

        state.stateOverride = nil
        if let final, !final.isEmpty {
            show(final.trimmingCharacters(in: .whitespacesAndNewlines))
            state.view = .prompt
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } else if p.terminationReason == .uncaughtSignal {
            state.chatHistory.removeAll { $0.id == bubble.id }   // cancelled by "+"
        } else {
            state.chatHistory.removeAll { $0.id == bubble.id }
            await fail(errorText ?? "Claude Code returned no answer (exit \(p.terminationStatus)).", state: state)
        }
    }

    private func fail(_ message: String, state: AppState) async {
        state.stateOverride = .error
        state.noteMessage = message
        state.view = .note
    }

    static func describe(_ tool: [String: Any]) -> String {
        let name = tool["name"] as? String ?? "Tool"
        let input = tool["input"] as? [String: Any] ?? [:]
        let detail = (input["description"] ?? input["file_path"] ?? input["pattern"]
                      ?? input["query"] ?? input["url"] ?? input["command"]) as? String
        guard let detail, !detail.isEmpty else { return name }
        return "\(name): \(detail.count > 60 ? String(detail.prefix(60)) + "…" : detail)"
    }

    private static let systemPrompt = """
    You are replying inside Coucou, a small chat window in the notch of the user's Mac. \
    Keep answers short and direct. Use light Markdown: short paragraphs, bullet lists, **bold**, \
    `inline code` and fenced code blocks. Avoid tables and big headings: the window is small.
    """
}
