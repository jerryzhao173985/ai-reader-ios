// SettingsManager.swift
// Manager for app-wide settings and preferences
//
// Handles theme, font, and display settings with UserDefaults persistence

import SwiftUI

@Observable
final class SettingsManager {
    // MARK: - Theme
    enum Theme: String, CaseIterable, Identifiable {
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
    enum FontFamily: String, CaseIterable, Identifiable {
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

    // MARK: - Keys
    private enum Keys {
        static let theme = "settings.theme"
        static let fontFamily = "settings.fontFamily"
        static let fontSize = "settings.fontSize"
        static let lineSpacing = "settings.lineSpacing"
        static let marginSize = "settings.marginSize"
        static let apiKey = "settings.apiKey"
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
    }

    // MARK: - Reset
    func resetToDefaults() {
        theme = .light
        fontFamily = .serif
        fontSize = 18
        lineSpacing = 8
        marginSize = 20
    }
}

// MARK: - Environment Key
extension EnvironmentValues {
    @Entry var settingsManager: SettingsManager = SettingsManager()
}
