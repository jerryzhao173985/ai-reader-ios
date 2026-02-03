// SettingsView.swift
// Settings interface for customizing reader appearance and API configuration
//
// Features: theme selection, font settings, margin controls, API key entry

import SwiftUI

struct SettingsView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var showingAPIKeyInfo = false
    @State private var apiKeyInput = ""

    var body: some View {
        NavigationStack {
            ZStack {
                // Navigation container background - prevents white edges when pushing views
                settings.theme.backgroundColor
                    .ignoresSafeArea(.all)

                Form {
                // Appearance Section
                Section("Appearance") {
                    themePicker
                    fontFamilyPicker
                    fontSizeSlider
                    lineSpacingSlider
                    marginSizeSlider
                    showNoteEditorToggle
                    searchIncludesNotesToggle
                }

                // Preview Section
                Section("Preview") {
                    previewText
                }

                // AI Settings Section
                Section {
                    apiKeyField
                    aiProviderPicker
                    reasoningEffortPicker
                    webSearchToggle
                    aiAutoFallbackToggle
                } header: {
                    Text("AI Settings")
                } footer: {
                    Text("Your API key is stored locally and never shared. GPT-5.2 uses the new Responses API with advanced reasoning and optional web search. GPT-4o is the proven stable option.")
                }

                // Library Section
                Section {
                    NavigationLink {
                        ArchivedBooksView()
                            .environment(settings)
                            .background(settings.theme.backgroundColor)
                    } label: {
                        Label("Archived Books", systemImage: "archivebox")
                    }
                } header: {
                    Text("Library")
                }

                // Reset Section
                Section {
                    Button("Reset to Defaults") {
                        withAnimation {
                            settings.resetToDefaults()
                        }
                    }
                    .foregroundStyle(.red)
                }

                // About Section
                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Build", value: "1")

                    Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                        Label("Get OpenAI API Key", systemImage: "key.fill")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            } // ZStack
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(settings.theme.backgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(settings.theme == .dark ? .dark : .light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                apiKeyInput = settings.openAIAPIKey
            }
        }
    }

    // MARK: - Theme Picker
    @MainActor
    private var themePicker: some View {
        HStack {
            Text("Theme")

            Spacer()

            HStack(spacing: 12) {
                ForEach(SettingsManager.Theme.allCases) { theme in
                    Button {
                        withAnimation {
                            settings.theme = theme
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(theme.backgroundColor)
                                .overlay(
                                    Circle()
                                        .stroke(theme.textColor.opacity(0.3), lineWidth: 1)
                                )
                                .frame(width: 30, height: 30)

                            Text(theme.displayName)
                                .font(.caption2)
                                .foregroundStyle(settings.theme == theme ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .overlay {
                        if settings.theme == theme {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .offset(x: 10, y: -10)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Font Family Picker
    @MainActor
    private var fontFamilyPicker: some View {
        Picker("Font", selection: Binding(
            get: { settings.fontFamily },
            set: { settings.fontFamily = $0 }
        )) {
            ForEach(SettingsManager.FontFamily.allCases) { font in
                Text(font.displayName)
                    .font(font.font(size: 14))
                    .tag(font)
            }
        }
    }

    // MARK: - Font Size Slider
    @MainActor
    private var fontSizeSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Font Size")
                Spacer()
                Text("\(Int(settings.fontSize))pt")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Image(systemName: "textformat.size.smaller")
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { settings.fontSize },
                        set: { settings.fontSize = $0 }
                    ),
                    in: 12...32,
                    step: 1
                )

                Image(systemName: "textformat.size.larger")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Line Spacing Slider
    @MainActor
    private var lineSpacingSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Line Spacing")
                Spacer()
                Text("\(Int(settings.lineSpacing))pt")
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { settings.lineSpacing },
                    set: { settings.lineSpacing = $0 }
                ),
                in: 0...20,
                step: 2
            )
        }
    }

    // MARK: - Margin Size Slider
    @MainActor
    private var marginSizeSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Margins")
                Spacer()
                Text("\(Int(settings.marginSize))pt")
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { settings.marginSize },
                    set: { settings.marginSize = $0 }
                ),
                in: 8...48,
                step: 4
            )
        }
    }

    // MARK: - Preview Text
    @MainActor
    private var previewText: some View {
        VStack(alignment: .leading, spacing: settings.lineSpacing) {
            Text("The quick brown fox jumps over the lazy dog.")
                .font(settings.readerFont)
                .foregroundStyle(settings.theme.textColor)

            Text("This is how your book will look with the current settings.")
                .font(settings.readerFont)
                .foregroundStyle(settings.theme.textColor.opacity(0.8))
        }
        .padding(settings.marginSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.theme.backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(settings.theme.textColor.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - API Key Field
    @MainActor
    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SecureField("OpenAI API Key", text: $apiKeyInput)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    settings.openAIAPIKey = apiKeyInput
                } label: {
                    Text("Save")
                        .font(.subheadline)
                }
                .disabled(apiKeyInput == settings.openAIAPIKey)
            }

            if !settings.openAIAPIKey.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("API Key configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - AI Provider Picker
    @MainActor
    private var aiProviderPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("AI Model", selection: Binding(
                get: { settings.aiProvider },
                set: { settings.aiProvider = $0 }
            )) {
                ForEach(SettingsManager.AIProvider.allCases) { provider in
                    VStack(alignment: .leading) {
                        Text(provider.displayName)
                    }
                    .tag(provider)
                }
            }

            Text(settings.aiProvider.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Web Search Toggle
    @MainActor
    private var webSearchToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { settings.webSearchEnabled },
                set: { settings.webSearchEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web Search")
                    Text("Search for relevant current information")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.webSearchEnabled && settings.aiProvider != .gpt5_2 {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                    Text("Web search only available with GPT-5.2")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Auto Fallback Toggle
    @MainActor
    private var aiAutoFallbackToggle: some View {
        Toggle(isOn: Binding(
            get: { settings.aiAutoFallback },
            set: { settings.aiAutoFallback = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-Fallback")
                Text("Use GPT-4o if selected model fails")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Show Note Editor Toggle
    @MainActor
    private var showNoteEditorToggle: some View {
        Toggle(isOn: Binding(
            get: { settings.showNoteEditor },
            set: { settings.showNoteEditor = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Note Editor")
                Text("Show note box for personal annotations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Search Includes Notes Toggle
    @MainActor
    private var searchIncludesNotesToggle: some View {
        Toggle(isOn: Binding(
            get: { settings.searchIncludesNotes },
            set: { settings.searchIncludesNotes = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Search Notes")
                Text("Include note content when searching highlights")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Reasoning Effort Picker
    @MainActor
    private var reasoningEffortPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Reasoning Effort", selection: Binding(
                get: { settings.reasoningEffort },
                set: { settings.reasoningEffort = $0 }
            )) {
                ForEach(SettingsManager.ReasoningEffort.allCases) { effort in
                    Text(effort.displayName)
                        .tag(effort)
                }
            }

            Text(settings.reasoningEffort.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !settings.aiProvider.supportsReasoningEffort {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                    Text("Reasoning effort only applies to GPT-5.2")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(SettingsManager())
}
