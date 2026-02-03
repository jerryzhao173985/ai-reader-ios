// SettingsManager.swift
// Manager for app-wide settings and preferences
//
// Handles theme, font, and display settings with UserDefaults persistence

import SwiftUI

@Observable
final class SettingsManager {
    // MARK: - AI Provider
    /// AI model provider selection
    /// GPT-5.2 uses the new Responses API, GPT-4o uses Chat Completions API
    enum AIProvider: String, CaseIterable, Identifiable, Sendable {
        case gpt5_2 = "gpt-5.2"
        case gpt4o = "gpt-4o"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gpt5_2: return "GPT-5.2 (Latest)"
            case .gpt4o: return "GPT-4o (Stable)"
            }
        }

        var modelId: String { rawValue }

        /// Which API endpoint to use
        var apiEndpoint: String {
            switch self {
            case .gpt5_2: return "/responses"
            case .gpt4o: return "/chat/completions"
            }
        }

        var description: String {
            switch self {
            case .gpt5_2: return "Newest model with Responses API, advanced reasoning"
            case .gpt4o: return "Proven model with Chat Completions API"
            }
        }

        /// Whether this provider supports reasoning effort configuration
        var supportsReasoningEffort: Bool {
            switch self {
            case .gpt5_2: return true
            case .gpt4o: return false
            }
        }
    }

    // MARK: - Reasoning Effort
    /// Controls how much reasoning the model performs before responding
    /// Only applicable to GPT-5.2 (Responses API)
    enum ReasoningEffort: String, CaseIterable, Identifiable, Sendable {
        case none = "none"
        case low = "low"
        case medium = "medium"
        case high = "high"
        case xhigh = "xhigh"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: return "None (Fastest)"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .xhigh: return "Extra High (Best)"
            }
        }

        var description: String {
            switch self {
            case .none: return "Minimal reasoning, fastest responses"
            case .low: return "Light reasoning for simple tasks"
            case .medium: return "Balanced speed and reasoning depth"
            case .high: return "Thorough reasoning for complex tasks"
            case .xhigh: return "Maximum reasoning depth, best quality"
            }
        }
    }

    // MARK: - Theme
    enum Theme: String, CaseIterable, Identifiable, Sendable {
        case light
        case dark
        case sepia

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .light: return "Light"
            case .dark: return "Dark"
            case .sepia: return "Sepia"
            }
        }

        var backgroundColor: Color {
            switch self {
            case .light: return Color(white: 0.98)
            case .dark: return Color(white: 0.1)
            case .sepia: return Color(red: 0.96, green: 0.94, blue: 0.88)
            }
        }

        var textColor: Color {
            switch self {
            case .light: return Color(white: 0.1)
            case .dark: return Color(white: 0.9)
            case .sepia: return Color(red: 0.35, green: 0.25, blue: 0.15)
            }
        }

        var secondaryBackgroundColor: Color {
            switch self {
            case .light: return Color(white: 0.95)
            case .dark: return Color(white: 0.15)
            case .sepia: return Color(red: 0.92, green: 0.90, blue: 0.84)
            }
        }

        var accentColor: Color {
            switch self {
            case .light: return .blue
            case .dark: return .cyan
            case .sepia: return Color(red: 0.6, green: 0.4, blue: 0.2)
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .light, .sepia: return .light
            case .dark: return .dark
            }
        }
    }

    // MARK: - Font Family
    enum FontFamily: String, CaseIterable, Identifiable, Sendable {
        case serif = "Georgia"
        case sansSerif = "System"
        case monospace = "Menlo"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .serif: return "Serif"
            case .sansSerif: return "Sans Serif"
            case .monospace: return "Monospace"
            }
        }

        var font: Font {
            switch self {
            case .serif: return .custom("Georgia", size: 16)
            case .sansSerif: return .system(size: 16)
            case .monospace: return .system(size: 16, design: .monospaced)
            }
        }

        func font(size: CGFloat) -> Font {
            switch self {
            case .serif: return .custom("Georgia", size: size)
            case .sansSerif: return .system(size: size)
            case .monospace: return .system(size: size, design: .monospaced)
            }
        }
    }

    // MARK: - Persisted Properties
    var theme: Theme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme)
        }
    }

    var fontFamily: FontFamily {
        didSet {
            UserDefaults.standard.set(fontFamily.rawValue, forKey: Keys.fontFamily)
        }
    }

    var fontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: Keys.fontSize)
        }
    }

    var lineSpacing: CGFloat {
        didSet {
            UserDefaults.standard.set(lineSpacing, forKey: Keys.lineSpacing)
        }
    }

    var marginSize: CGFloat {
        didSet {
            UserDefaults.standard.set(marginSize, forKey: Keys.marginSize)
        }
    }

    var openAIAPIKey: String {
        didSet {
            // Store securely in Keychain in production
            UserDefaults.standard.set(openAIAPIKey, forKey: Keys.apiKey)
        }
    }

    var aiProvider: AIProvider {
        didSet {
            UserDefaults.standard.set(aiProvider.rawValue, forKey: Keys.aiProvider)
        }
    }

    /// When true, automatically falls back to GPT-4o if GPT-5.2 fails
    var aiAutoFallback: Bool {
        didSet {
            UserDefaults.standard.set(aiAutoFallback, forKey: Keys.aiAutoFallback)
        }
    }

    /// Reasoning effort for GPT-5.2 (controls reasoning depth)
    /// Default: xhigh for best quality analysis
    var reasoningEffort: ReasoningEffort {
        didSet {
            UserDefaults.standard.set(reasoningEffort.rawValue, forKey: Keys.reasoningEffort)
        }
    }

    /// When true, enables web search tool for GPT-5.2 Responses API
    /// Allows the model to search the web for current information relevant to the selected text
    var webSearchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(webSearchEnabled, forKey: Keys.webSearchEnabled)
        }
    }

    /// When true, shows the note editor box in the analysis panel
    /// Allows users to add personal notes to highlights (distinct from AI analysis)
    /// Default: false for minimal design - users can enable if they want note-taking
    var showNoteEditor: Bool {
        didSet {
            UserDefaults.standard.set(showNoteEditor, forKey: Keys.showNoteEditor)
        }
    }

    /// When true, search in HighlightsView also searches note content
    /// Default: false - only search highlight text (original behavior)
    var searchIncludesNotes: Bool {
        didSet {
            UserDefaults.standard.set(searchIncludesNotes, forKey: Keys.searchIncludesNotes)
        }
    }

    // MARK: - Keys
    private enum Keys {
        static let theme = "settings.theme"
        static let fontFamily = "settings.fontFamily"
        static let fontSize = "settings.fontSize"
        static let lineSpacing = "settings.lineSpacing"
        static let marginSize = "settings.marginSize"
        static let apiKey = "settings.apiKey"
        static let aiProvider = "settings.aiProvider"
        static let aiAutoFallback = "settings.aiAutoFallback"
        static let reasoningEffort = "settings.reasoningEffort"
        static let webSearchEnabled = "settings.webSearchEnabled"
        static let showNoteEditor = "settings.showNoteEditor"
        static let searchIncludesNotes = "settings.searchIncludesNotes"
    }

    // MARK: - Computed Properties
    var readerFont: Font {
        fontFamily.font(size: fontSize)
    }

    // MARK: - Initialization
    init() {
        // Load saved settings or use defaults
        let defaults = UserDefaults.standard

        if let themeValue = defaults.string(forKey: Keys.theme),
           let savedTheme = Theme(rawValue: themeValue) {
            self.theme = savedTheme
        } else {
            self.theme = .light
        }

        if let fontValue = defaults.string(forKey: Keys.fontFamily),
           let savedFont = FontFamily(rawValue: fontValue) {
            self.fontFamily = savedFont
        } else {
            self.fontFamily = .serif
        }

        let savedFontSize = defaults.double(forKey: Keys.fontSize)
        self.fontSize = savedFontSize > 0 ? savedFontSize : 18

        let savedLineSpacing = defaults.double(forKey: Keys.lineSpacing)
        self.lineSpacing = savedLineSpacing > 0 ? savedLineSpacing : 8

        let savedMarginSize = defaults.double(forKey: Keys.marginSize)
        self.marginSize = savedMarginSize > 0 ? savedMarginSize : 20

        self.openAIAPIKey = defaults.string(forKey: Keys.apiKey) ?? ""

        // Load AI provider (default to GPT-4o for stability during development)
        if let providerValue = defaults.string(forKey: Keys.aiProvider),
           let savedProvider = AIProvider(rawValue: providerValue) {
            self.aiProvider = savedProvider
        } else {
            self.aiProvider = .gpt4o  // Safe default
        }

        // Load auto-fallback setting (default true for resilience)
        if defaults.object(forKey: Keys.aiAutoFallback) != nil {
            self.aiAutoFallback = defaults.bool(forKey: Keys.aiAutoFallback)
        } else {
            self.aiAutoFallback = true
        }

        // Load reasoning effort (default to xhigh for best quality)
        if let effortValue = defaults.string(forKey: Keys.reasoningEffort),
           let savedEffort = ReasoningEffort(rawValue: effortValue) {
            self.reasoningEffort = savedEffort
        } else {
            self.reasoningEffort = .xhigh  // Best quality default
        }

        // Load web search setting (default false - opt-in feature)
        if defaults.object(forKey: Keys.webSearchEnabled) != nil {
            self.webSearchEnabled = defaults.bool(forKey: Keys.webSearchEnabled)
        } else {
            self.webSearchEnabled = false  // Off by default
        }

        // Load note editor setting (default false - minimal design, opt-in feature)
        if defaults.object(forKey: Keys.showNoteEditor) != nil {
            self.showNoteEditor = defaults.bool(forKey: Keys.showNoteEditor)
        } else {
            self.showNoteEditor = false  // Off by default for minimal design
        }

        // Load search includes notes setting (default false - original behavior)
        if defaults.object(forKey: Keys.searchIncludesNotes) != nil {
            self.searchIncludesNotes = defaults.bool(forKey: Keys.searchIncludesNotes)
        } else {
            self.searchIncludesNotes = false  // Off by default for original behavior
        }
    }

    // MARK: - Reset
    func resetToDefaults() {
        theme = .light
        fontFamily = .serif
        fontSize = 18
        lineSpacing = 8
        marginSize = 20
        showNoteEditor = false  // Default to minimal design
        searchIncludesNotes = false  // Default to original behavior
    }
}

// MARK: - Environment Key
extension EnvironmentValues {
    @Entry var settingsManager: SettingsManager = SettingsManager()
}
