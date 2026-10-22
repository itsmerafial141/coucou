import Foundation

// MARK: - Island Mode

enum IslandMode: String, CaseIterable {
    case hidden, compact, expanded
}

// MARK: - Island View

enum IslandView: String, CaseIterable {
    case overview, empty, approval, question, error, finished
    case confused, upload, uploading, choose, mail, prompt
    case searching, result, note, settings
    case menuBar, spotify, venturo, discord, clipboard, system, phonevps, loomify, superset, jiggler
}

// MARK: - Bot State

enum BotState: String, CaseIterable {
    case idle, working, thinking, searching
    case approval, question, error, finished
    case ratelimit, sleeping, dizzy
}

// MARK: - Bot Emote

enum BotEmote: String, CaseIterable {
    case love, surprised, proud, wink, yawn, happy, annoyed
}

// MARK: - Approval info (pending PermissionRequest from Claude Code)

struct ApprovalInfo: Sendable {
    var sessionId: String
    var tool: String
    var command: String
    /// tool_input serialized to JSON with sortedKeys, "" if absent — used to match PostToolUse.
    var inputKey: String
    /// Pill that owns this approval: "integration_claude", "agent_cursor", or "agent_codex".
    var pillId: String
}

// MARK: - Pill badge (shown on pill edge when non-focused task has an alert)

enum PillBadge { case approval, finished, error, news }

// MARK: - Agent Task

struct AgentTask: Identifiable, Equatable {
    var id: String
    var name: String
    var color: String          // hex
    var state: BotState
    var stepIndex: Int = 0
    var steps: [String]
    var source: AgentSource
    var isIntegration: Bool = false  // true for persistent integration pills
    var emote: BotEmote? = nil
    var pillBadge: PillBadge? = nil  // alert badge shown on pill when not focused
    var sessionCwd: String?  = nil  // last known working directory (Claude Code sessions)
    var finalLine: String?   = nil  // last assistant message shown as static text after Stop
}

enum AgentSource: Equatable {
    case claudeCode
    case n8n
    case agent   // third-party agent via coucou_agent field
}

// MARK: - Chat provider

enum ChatProvider: String, CaseIterable, Codable {
    case anthropic = "anthropic"
    case google    = "google"
    case openai    = "openai"
    case ollama    = "ollama"
    case lmstudio  = "lmstudio"

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .google:    "Google"
        case .openai:    "OpenAI"
        case .ollama:    "Ollama"
        case .lmstudio:  "LM Studio"
        }
    }

    var accentHex: String {
        switch self {
        case .anthropic: "#E07950"
        case .google:    "#4285F4"
        case .openai:    "#10A37F"
        case .ollama:    "#FACC15"
        case .lmstudio:  "#A3E635"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-sonnet-4-6"
        case .google:    "gemini-2.0-flash"
        case .openai:    "gpt-4o"
        case .ollama:    "llama3.2"
        case .lmstudio:  "local-model"
        }
    }

    var keychainKey: String {
        switch self {
        case .anthropic: "anthropic-api-key"
        case .google:    "google-api-key"
        case .openai:    "openai-api-key"
        case .ollama:    ""
        case .lmstudio:  ""
        }
    }

    var isLocal: Bool {
        self == .ollama || self == .lmstudio
    }

    var pillID: String {
        switch self {
        case .anthropic: "ai_anthropic"
        case .google:    "ai_google"
        case .openai:    "ai_openai"
        case .ollama:    "ai_ollama"
        case .lmstudio:  "ai_lmstudio"
        }
    }

    init?(pillID: String) {
        switch pillID {
        case "ai_anthropic": self = .anthropic
        case "ai_google":    self = .google
        case "ai_openai":    self = .openai
        case "ai_ollama":    self = .ollama
        case "ai_lmstudio":  self = .lmstudio
        default:             return nil
        }
    }
}

// MARK: - View dimensions (from VIEWS in prototype)

struct ViewLayout {
    let height: CGFloat
}

// MARK: - Constants (from NW, NH, EW in prototype)

enum IslandConst {
    static let notchWidth: CGFloat  = IslandScreenGeometry.fallbackNotchWidth
    static let notchHeight: CGFloat = 32
    static let expandedWidth: CGFloat = 640
    static let earRadius: CGFloat   = 14
    static let roundedCorner: CGFloat = 14    // hidden/peek/compact
    static let expandedCorner: CGFloat = 22

    static let viewLayouts: [IslandView: ViewLayout] = [
        // Home is the reference: height 150
        .overview:  ViewLayout(height: 160),
        // All non-chat views match home height (150) — law
        .empty:     ViewLayout(height: 160),
        .approval:  ViewLayout(height: 160),
        .question:  ViewLayout(height: 160),
        .error:     ViewLayout(height: 160),
        .finished:  ViewLayout(height: 160),
        .confused:  ViewLayout(height: 160),
        .upload:    ViewLayout(height: 176),
        .uploading: ViewLayout(height: 176),
        .choose:    ViewLayout(height: 176),
        .mail:      ViewLayout(height: 240),
        .prompt:    ViewLayout(height: 160),
        .searching: ViewLayout(height: 160),
        .result:    ViewLayout(height: 160),
        .note:      ViewLayout(height: 160),
        .settings:  ViewLayout(height: 160),
        .menuBar:   ViewLayout(height: 160),
        .system:    ViewLayout(height: 228),
        .clipboard: ViewLayout(height: 196),
        .jiggler:   ViewLayout(height: 180),
        .spotify:   ViewLayout(height: 196),
        .venturo:   ViewLayout(height: 244),
        // Phone VPS: the 8 service rows + stats + actions need ~212pt of card: 264 keeps the 10pt bottom margin.
        .phonevps:  ViewLayout(height: 264),
        .loomify:   ViewLayout(height: 276),
        // Superset workspaces: same frame as the Loomify board (see SupersetListView)
        .superset:  ViewLayout(height: 276),
        .discord:   ViewLayout(height: 230),
    ]

    // Project colors — keyed by lowercase display name or slug
    static let projectColors: [String: String] = [
        "korus":             "#FF5A4E",
        "sbe hub":           "#2EC4A0",
        "morning ai brief":  "#F29B38",
        "publication ig":    "#7C5CFF",
        "ig post":           "#7C5CFF",
        "louisraille.fr":    "#38BDF8",
        "louisraille":       "#38BDF8",
        "notch buddy":       "#EC4899",
        "notch-buddy":       "#EC4899",
        "notchbuddy":        "#EC4899",
    ]

    static let fallbackColors = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"]

    /// Returns the fixed project color for a display name, or a stable fallback.
    static func colorForProject(_ name: String) -> String {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let c = projectColors[key] { return c }
        // partial match (e.g. "korus-api" → "korus")
        for (k, c) in projectColors where key.hasPrefix(k) || key.contains(k) { return c }
        return fallbackColors[abs(name.hashValue) % fallbackColors.count]
    }

    // State card wash colors (radial gradient from bottom)
    static let washColors: [IslandView: String] = [
        .approval:  "rgba(245,165,36,0.42)",
        .question:  "rgba(34,211,238,0.38)",
        .error:     "rgba(244,80,94,0.55)",
        .finished:  "rgba(52,211,153,0.5)",
        .confused:  "rgba(244,114,182,0.55)",
        .searching: "rgba(99,102,241,0.5)",
        .result:    "rgba(52,211,153,0.22)",
        .prompt:    "rgba(99,102,241,0.22)",
    ]
}
