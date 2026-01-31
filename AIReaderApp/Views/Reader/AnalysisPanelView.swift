// AnalysisPanelView.swift
// Right panel displaying AI analysis results and conversation threads
//
// Features: analysis types, streaming results, follow-up questions, history

import SwiftUI
import SwiftData

struct AnalysisPanelView: View {
    @Bindable var viewModel: ReaderViewModel

    @Environment(SettingsManager.self) private var settings

    @State private var followUpQuestion = ""
    @State private var highlightSearchText = ""
    @FocusState private var isQuestionFocused: Bool

    /// Tracks the highlight ID to scroll to when returning from analysis view to chapter highlights list
    /// Set before clearing selectedHighlight, then consumed after UI transition to scroll to that card
    @State private var scrollToHighlightOnReturn: UUID? = nil

    /// Tracks when to scroll to a specific analysis position after switching analyses
    /// For simple analysis: scrolls to top. For conversation: scrolls to last turn
    @State private var scrollToAnalysisId: UUID? = nil

    // MARK: - Markdown Text Helper
    /// Renders markdown text with fallback to plain text if parsing fails
    private func markdownText(_ string: String) -> Text {
        if let attributed = try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        } else {
            return Text(string)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let highlight = viewModel.selectedHighlight {
                            selectedTextSection(highlight)
                            analysisSection(highlight)
                        } else if !viewModel.selectedText.isEmpty {
                            pendingSelectionSection
                        } else {
                            emptyStateSection
                        }
                    }
                    .padding()
                }
                .onChange(of: scrollToHighlightOnReturn) { _, highlightId in
                    // When returning from analysis view to chapter highlights list,
                    // position at the previously viewed highlight's card (centered)
                    // NO animation - user should see the list already at the right position
                    if let highlightId, viewModel.selectedHighlight == nil {
                        // Disable all animations for instant positioning
                        // This makes the panel appear already centered at the card
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(highlightId, anchor: .center)
                        }
                        scrollToHighlightOnReturn = nil
                    }
                }
                .onChange(of: scrollToAnalysisId) { _, analysisId in
                    // When switching between analyses (card tap), scroll to appropriate position:
                    // - Simple analysis (no follow-ups): scroll to top of analysis
                    // - Conversation analysis (has follow-ups): scroll to last turn (most recent Q&A)
                    guard let analysisId,
                          let analysis = viewModel.selectedAnalysis,
                          analysis.id == analysisId else {
                        scrollToAnalysisId = nil
                        return
                    }

                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if let thread = analysis.thread,
                           !thread.turns.isEmpty,
                           let lastTurn = thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex }).last {
                            // Conversation with follow-ups: scroll to last turn
                            proxy.scrollTo(lastTurn.id, anchor: .top)
                        } else {
                            // Simple analysis or no turns yet: scroll to top
                            proxy.scrollTo("analysis-content-top", anchor: .top)
                        }
                    }
                    scrollToAnalysisId = nil
                }
                .onChange(of: viewModel.isAnalyzing) { wasAnalyzing, isAnalyzing in
                    // When starting a NEW analysis (not follow-up), scroll to top
                    // This handles: user selects analysis type from menu while viewing another analysis
                    // selectedAnalysis == nil means it's a new analysis, not a follow-up
                    if isAnalyzing && !wasAnalyzing && viewModel.selectedAnalysis == nil {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo("analysis-content-top", anchor: .top)
                        }
                    }
                }
            }

            // Follow-up Question Input
            if viewModel.selectedHighlight != nil {
                followUpInputSection
            }
        }
        .background(settings.theme.secondaryBackgroundColor)
    }

    // MARK: - Header
    private var header: some View {
        HStack {
            Text("AI Analysis")
                .font(.headline)
                .foregroundStyle(settings.theme.textColor)

            Spacer()

            if viewModel.selectedHighlight != nil {
                Button {
                    // Remember which highlight to scroll to when returning to chapter highlights list
                    // This creates a fluid UX: user sees the card they just closed in the middle of the list
                    scrollToHighlightOnReturn = viewModel.selectedHighlight?.id

                    // Clear ALL selection-related state to return to chapter highlights view
                    // selectedText must be cleared because selectHighlight() sets it,
                    // and non-empty selectedText shows pendingSelectionSection instead of emptyStateSection
                    viewModel.selectedHighlight = nil
                    viewModel.selectedText = ""
                    viewModel.analysisResult = nil
                    viewModel.currentAnalysisType = nil
                    viewModel.selectedAnalysis = nil
                    viewModel.isAnalyzing = false  // Prevent stale loading state
                    viewModel.customQuestion = ""  // Clear stale follow-up question
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(settings.theme.backgroundColor)
    }

    // MARK: - Selected Text Section
    private func selectedTextSection(_ highlight: HighlightModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected Text")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                // Quick analysis menu (excluding types that need user input) + Delete option
                Menu {
                    ForEach(AnalysisType.quickAnalysisTypes, id: \.self) { type in
                        Button {
                            viewModel.performAnalysis(
                                type: type,
                                text: highlight.selectedText,
                                context: highlight.fullContext
                            )
                        } label: {
                            Label(type.displayName, systemImage: type.iconName)
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            viewModel.deleteHighlight(highlight)
                        }
                    } label: {
                        Label("Delete Highlight", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(settings.theme.accentColor)
                }
            }

            // Selected text box - styled with colored bar + border to match HighlightsView pattern
            quoteBlock(highlight: highlight)

            // Quick Analysis Buttons + Ask Question + Delete
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // All quick analysis types (Fact Check, Discussion, Key Points, Argument Map, Counterpoints)
                    ForEach(AnalysisType.quickAnalysisTypes, id: \.self) { type in
                        analysisTypeButton(type, highlight: highlight)
                    }

                    // Custom Question button - creates NEW custom question thread
                    // Prepares UI for fresh question and blocks ongoing jobs from updating display
                    Button {
                        viewModel.prepareForNewCustomQuestion()
                        isQuestionFocused = true
                    } label: {
                        Label("Ask Question", systemImage: AnalysisType.customQuestion.iconName)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color(hex: AnalysisType.customQuestion.colorHex)?.opacity(0.2) ?? settings.theme.accentColor.opacity(0.2))
                            )
                            .foregroundStyle(Color(hex: AnalysisType.customQuestion.colorHex) ?? settings.theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    // NO .disabled - allow starting new custom question even during streaming
                    // This enables parallel job workflow: user can initiate new question anytime

                    // Delete button (same style as analysis buttons)
                    Button {
                        viewModel.deleteHighlight(highlight)
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.red.opacity(0.15))
                            )
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Quote block styled with colored bar + border - aligned with HighlightsView pattern
    private func quoteBlock(highlight: HighlightModel) -> some View {
        let quoteColor = Color(hex: highlight.colorHex) ?? .yellow
        return HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(quoteColor)
                .frame(width: 4)

            Text(highlight.selectedText)
                .font(.subheadline)
                .foregroundStyle(settings.theme.textColor)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(quoteColor.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(quoteColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func analysisTypeButton(_ type: AnalysisType, highlight: HighlightModel) -> some View {
        Button {
            viewModel.performAnalysis(
                type: type,
                text: highlight.selectedText,
                context: highlight.fullContext
            )
        } label: {
            Label(type.displayName, systemImage: type.iconName)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color(hex: type.colorHex)?.opacity(0.2) ?? settings.theme.accentColor.opacity(0.2))
                )
                .foregroundStyle(Color(hex: type.colorHex) ?? settings.theme.accentColor)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Analysis Section
    private func analysisSection(_ highlight: HighlightModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Current Analysis Area (loading or result)
            currentAnalysisView
                .id("analysis-content-top")  // Enable ScrollViewReader scroll target
                .animation(.easeInOut(duration: 0.2), value: viewModel.isAnalyzing)
                .animation(.easeInOut(duration: 0.2), value: viewModel.analysisResult != nil)

            // Previous Analyses (sorted by most recent first)
            // Filter out the currently selected analysis to avoid duplicate display
            // (it's already shown in currentAnalysisView above)
            let otherAnalyses = highlight.analyses
                .filter { $0.id != viewModel.selectedAnalysis?.id }
                .sorted(by: { $0.createdAt > $1.createdAt })

            if !otherAnalyses.isEmpty {
                Text("Previous Analyses")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                ForEach(otherAnalyses) { analysis in
                    previousAnalysisCard(analysis)
                }
            }
        }
    }

    // MARK: - Current Analysis View (loading or result)
    @ViewBuilder
    private var currentAnalysisView: some View {
        // Any analysis with a thread OR streaming OR custom question OR comment shows conversation view
        // Custom questions and comments ALWAYS need conversation view to display the content
        // (comments store user's text in .prompt, not .response)
        // This allows follow-ups on Fact Check, Discussion, etc. - not just custom questions
        if let analysis = viewModel.selectedAnalysis {
            if analysis.analysisType == .customQuestion || analysis.analysisType == .comment || analysis.thread != nil || viewModel.isAnalyzing {
                // Custom question OR comment OR has follow-ups OR actively streaming - show conversation view
                analysisConversationView(analysis)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // No thread, not analyzing, not custom question, not comment - just show the result
                resultView(analysis.response)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } else if viewModel.isAnalyzing {
            // New analysis starting (no selectedAnalysis yet) - show loading/streaming
            VStack(alignment: .leading, spacing: 12) {
                // Show the analysis type being created
                if let type = viewModel.currentAnalysisType {
                    Label(type.displayName, systemImage: type.iconName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(hex: type.colorHex) ?? settings.theme.accentColor)
                }

                // Show streaming result if available, otherwise show loading indicator
                if let result = viewModel.analysisResult, !result.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        markdownText(result)
                            .font(.subheadline)
                            .foregroundStyle(settings.theme.textColor)
                            .textSelection(.enabled)

                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Analyzing...")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(settings.theme.secondaryBackgroundColor.opacity(0.5))
                    )
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.8)

                        Text("Analyzing...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(settings.theme.backgroundColor.opacity(0.5))
                    )
                }
            }
            .transition(.opacity)
        } else if let result = viewModel.analysisResult {
            resultView(result)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private func resultView(_ result: String) -> some View {
        if result.hasPrefix("Error:") {
            // Error display with styled container
            VStack(alignment: .leading, spacing: 8) {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)

                Text(result.replacingOccurrences(of: "Error: ", with: ""))
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.textColor.opacity(0.8))
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )
        } else {
            // Normal result display
            VStack(alignment: .leading, spacing: 8) {
                if let type = viewModel.currentAnalysisType {
                    Label(type.displayName, systemImage: type.iconName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(hex: type.colorHex) ?? settings.theme.accentColor)
                }

                markdownText(result)
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.textColor)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(settings.theme.backgroundColor)
            )
        }
    }

    // MARK: - Analysis Conversation View (for any analysis type with follow-ups)
    /// Displays an analysis with its conversation thread
    /// Works for all analysis types: Fact Check, Discussion, Custom Question, etc.
    /// Each analysis type can have its own independent conversation thread
    @ViewBuilder
    private func analysisConversationView(_ analysis: AIAnalysisModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with analysis type
            Label(analysis.analysisType.displayName, systemImage: analysis.analysisType.iconName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color(hex: analysis.analysisType.colorHex) ?? settings.theme.accentColor)

            // Initial content depends on analysis type
            if analysis.analysisType == .customQuestion {
                // Custom questions: show initial Q&A as chat bubbles
                userMessageBubble(analysis.prompt)
                aiMessageBubble(analysis.response)
            } else if analysis.analysisType == .comment {
                // Comments: show user's comment as a bubble (no AI response initially)
                commentBubble(analysis.prompt)
                // If response is not empty (shouldn't happen for new comments), show it
                if !analysis.response.isEmpty {
                    aiMessageBubble(analysis.response)
                }
            } else {
                // Other types (Fact Check, Discussion, etc.): show the analysis result
                markdownText(analysis.response)
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.textColor)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(settings.theme.secondaryBackgroundColor.opacity(0.5))
                    )
            }

            // Follow-up turns (if any)
            if let thread = analysis.thread, !thread.turns.isEmpty {
                // Visual separator for non-bubble analyses (not custom question or comment)
                if analysis.analysisType != .customQuestion && analysis.analysisType != .comment {
                    HStack {
                        VStack { Divider() }
                        Text("Follow-ups")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        VStack { Divider() }
                    }
                    .padding(.vertical, 4)
                }

                ForEach(thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex })) { turn in
                    VStack(alignment: .leading, spacing: 8) {
                        userMessageBubble(turn.question)
                        aiMessageBubble(turn.answer)
                    }
                    .id(turn.id)  // Enable ScrollViewReader targeting for conversation scroll
                }
            }

            // Current question being asked (if actively analyzing)
            if viewModel.isAnalyzing {
                // Show separator if this is the first follow-up on a non-bubble analysis
                if analysis.analysisType != .customQuestion && analysis.analysisType != .comment && (analysis.thread?.turns.isEmpty ?? true) {
                    HStack {
                        VStack { Divider() }
                        Text("Follow-ups")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        VStack { Divider() }
                    }
                    .padding(.vertical, 4)
                }

                userMessageBubble(viewModel.customQuestion.isEmpty ? "..." : viewModel.customQuestion)

                // Show streaming response or "thinking" indicator
                if let streaming = viewModel.analysisResult, !streaming.isEmpty {
                    aiMessageBubble(streaming, isStreaming: true)
                } else {
                    // AI is starting to think - show loading bubble
                    thinkingBubble
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(settings.theme.backgroundColor)
        )
    }

    // MARK: - Chat Bubble Components
    /// User message bubble - right-aligned with accent color
    private func userMessageBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(settings.theme.accentColor)
                )
        }
    }

    /// AI message bubble - left-aligned with secondary background
    private func aiMessageBubble(_ text: String, isStreaming: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                markdownText(text)
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.textColor)
                    .textSelection(.enabled)

                if isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Thinking...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(settings.theme.secondaryBackgroundColor)
            )
            Spacer(minLength: 40)
        }
    }

    /// Thinking indicator bubble - shown when AI is processing but no output yet
    private var thinkingBubble: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Thinking...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(settings.theme.secondaryBackgroundColor)
            )
            Spacer(minLength: 40)
        }
    }

    /// Comment bubble - right-aligned with comment color (distinct from user questions)
    /// Shows the user's personal note/comment on the highlighted text
    private func commentBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: AnalysisType.comment.colorHex) ?? settings.theme.accentColor)
            )
        }
    }

    /// Previous analysis card with tap to open and X button to delete
    private func previousAnalysisCard(_ analysis: AIAnalysisModel) -> some View {
        ZStack(alignment: .topTrailing) {
            // Main card content (tappable to open analysis)
            Button {
                // Use centralized method - handles state + colorHex update + marker injection
                viewModel.selectAnalysis(analysis)

                // Trigger scroll to appropriate position for this analysis
                scrollToAnalysisId = analysis.id
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(analysis.analysisType.displayName, systemImage: analysis.analysisType.iconName)
                            .font(.caption)
                            .foregroundStyle(Color(hex: analysis.analysisType.colorHex) ?? .secondary)

                        Spacer()

                        // Model, web search, and timestamp
                        HStack(spacing: 4) {
                            if let modelName = analysis.modelDisplayName {
                                Text(modelName)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                if analysis.usedWebSearch {
                                    Image(systemName: "globe")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Text("•")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Text(analysis.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        // Indicate tappable (leave space for X button)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 16)  // Space for X button
                    }

                    // Show the question asked for custom questions
                    if analysis.analysisType == .customQuestion {
                        Text("Q: \(analysis.prompt)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .italic()
                    }

                    // Content preview: comments store text in prompt (response is empty), others use response
                    markdownText(analysis.analysisType == .comment ? analysis.prompt : analysis.response)
                        .font(.caption)
                        .foregroundStyle(settings.theme.textColor)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)

                    // Conversation Thread
                    if let thread = analysis.thread, !thread.turns.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex })) { turn in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Q: \(turn.question)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    (Text("A: ") + markdownText(turn.answer))
                                        .font(.caption2)
                                        .foregroundStyle(settings.theme.textColor)
                                }
                                .padding(.leading, 8)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill((Color(hex: analysis.analysisType.colorHex) ?? .blue).opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke((Color(hex: analysis.analysisType.colorHex) ?? .blue).opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            // Delete button (X in top-right corner)
            Button {
                viewModel.deleteAnalysis(analysis)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(settings.theme.secondaryBackgroundColor)
                    )
            }
            .buttonStyle(.plain)
            .offset(x: -6, y: 6)
        }
    }

    // MARK: - Pending Selection Section
    private var pendingSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text Selected")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Text(viewModel.selectedText)
                .font(.subheadline)
                .foregroundStyle(settings.theme.textColor)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.2))
                )

            Text("Create a highlight to analyze this text")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty State Section
    private var emptyStateSection: some View {
        VStack(spacing: 16) {
            // Show current chapter highlights if any exist
            if !viewModel.currentChapterHighlights.isEmpty {
                chapterHighlightsSection
            } else {
                // Show intro when no highlights in chapter
                introSection
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Chapter Highlights Section
    /// Filtered highlights based on search text
    private var filteredChapterHighlights: [HighlightModel] {
        let sorted = viewModel.currentChapterHighlights.sorted(by: { $0.startOffset < $1.startOffset })
        if highlightSearchText.isEmpty {
            return sorted
        }
        return sorted.filter { $0.selectedText.localizedCaseInsensitiveContains(highlightSearchText) }
    }

    private var chapterHighlightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Chapter Highlights", systemImage: "highlighter")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(viewModel.currentChapterHighlights.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(settings.theme.accentColor.opacity(0.2)))
            }

            // Search box for filtering highlights
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Search highlights", text: $highlightSearchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)

                if !highlightSearchText.isEmpty {
                    Button {
                        highlightSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(settings.theme.backgroundColor)
            )

            // Show filtered results or empty search state
            if filteredChapterHighlights.isEmpty && !highlightSearchText.isEmpty {
                Text("No highlights matching \"\(highlightSearchText)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(filteredChapterHighlights) { highlight in
                    chapterHighlightRow(highlight)
                        .id(highlight.id)  // Enable ScrollViewReader.scrollTo() targeting
                }
            }

            // Hint to create more
            HStack {
                Image(systemName: "plus.circle")
                    .font(.caption)
                    .foregroundStyle(settings.theme.accentColor.opacity(0.6))

                Text("Select text in the chapter to add more highlights")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private func chapterHighlightRow(_ highlight: HighlightModel) -> some View {
        Button {
            // Select and scroll to highlight (scrollTo defaults to true)
            viewModel.selectHighlight(highlight)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(highlight.selectedText)
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.textColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    // Analysis type icons + count badge
                    if !highlight.analyses.isEmpty {
                        HStack(spacing: 6) {
                            // Type icons (unique types only)
                            HStack(spacing: 4) {
                                ForEach(Array(Set(highlight.analyses.map(\.analysisType))), id: \.self) { type in
                                    Image(systemName: type.iconName)
                                        .font(.caption2)
                                        .foregroundStyle(Color(hex: type.colorHex) ?? .secondary)
                                }
                            }

                            // Analysis count badge - shows total number of analysis threads
                            // This tells readers: "N threads of analysis on this selection"
                            Text("\(highlight.analyses.count)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(Color(hex: highlight.colorHex) ?? .yellow)
                                )
                        }
                    } else {
                        Text("No analysis yet")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: highlight.colorHex)?.opacity(0.15) ?? Color.yellow.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: highlight.colorHex)?.opacity(0.3) ?? Color.yellow.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Intro Section (when no highlights)
    private var introSection: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [settings.theme.accentColor.opacity(0.6), settings.theme.accentColor.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 8) {
                Text("AI Reading Assistant")
                    .font(.headline)
                    .foregroundStyle(settings.theme.textColor.opacity(0.7))

                Text("Select text in the chapter to unlock powerful AI analysis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "checkmark.seal", text: "Fact-check claims", color: .green)
                featureRow(icon: "list.bullet", text: "Extract key points", color: .blue)
                featureRow(icon: "bubble.left.and.bubble.right", text: "Start discussions", color: .purple)
                featureRow(icon: "questionmark.circle", text: "Ask custom questions", color: .orange)
            }
            .padding(.top, 8)
        }
        .padding(24)
    }

    private func featureRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
                .frame(width: 24)

            Text(text)
                .font(.caption)
                .foregroundStyle(settings.theme.textColor.opacity(0.6))

            Spacer()
        }
    }

    // MARK: - Follow-up Input Section
    /// Mode-aware input section that handles follow-up, ask question, and add comment modes
    private var followUpInputSection: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                TextField(inputPlaceholder, text: $followUpQuestion, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($isQuestionFocused)
                    .lineLimit(1...4)
                    .onAppear {
                        // Auto-focus when opening in ask/comment mode
                        if viewModel.followUpInputMode != .followUp {
                            isQuestionFocused = true
                        }
                    }

                Button {
                    submitInput()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            followUpQuestion.isEmpty
                            ? settings.theme.textColor.opacity(0.3)
                            : inputAccentColor
                        )
                }
                // Only disable when empty - allow parallel jobs during streaming
                // .askQuestion: start NEW custom question thread in parallel
                // .addComment: add comment (no AI call needed)
                // .followUp: add turn to existing thread (works during streaming)
                .disabled(followUpQuestion.isEmpty)
            }
            .padding(12)
            .background(settings.theme.backgroundColor)
        }
    }

    /// Placeholder text based on current input mode
    private var inputPlaceholder: String {
        switch viewModel.followUpInputMode {
        case .followUp:
            return "Ask a follow-up question..."
        case .askQuestion:
            return "What would you like to know about this text?"
        case .addComment:
            return "Add your comment..."
        }
    }

    /// Accent color for the input based on mode
    private var inputAccentColor: Color {
        switch viewModel.followUpInputMode {
        case .addComment:
            return Color(hex: AnalysisType.comment.colorHex) ?? settings.theme.accentColor
        case .askQuestion:
            return Color(hex: AnalysisType.customQuestion.colorHex) ?? settings.theme.accentColor
        case .followUp:
            return settings.theme.accentColor
        }
    }

    /// Handle input submission based on current mode
    private func submitInput() {
        guard !followUpQuestion.isEmpty, let highlight = viewModel.selectedHighlight else { return }

        switch viewModel.followUpInputMode {
        case .followUp:
            viewModel.askFollowUpQuestion(highlight: highlight, question: followUpQuestion)
        case .askQuestion:
            // Ask as new custom question
            viewModel.askFollowUpQuestion(highlight: highlight, question: followUpQuestion)
        case .addComment:
            // Add comment without AI call
            viewModel.addComment(to: highlight, text: followUpQuestion)
        }

        followUpQuestion = ""
        isQuestionFocused = false
    }
}

// MARK: - Analysis Type Extensions
extension AnalysisType {
    var iconName: String {
        switch self {
        case .factCheck: return "checkmark.seal"
        case .discussion: return "bubble.left.and.bubble.right"
        case .keyPoints: return "list.bullet"
        case .argumentMap: return "chart.bar.doc.horizontal"
        case .counterpoints: return "arrow.left.arrow.right"
        case .customQuestion: return "questionmark.circle"
        case .comment: return "text.bubble"
        }
    }
}

#Preview {
    @Previewable @State var container = try! ModelContainer(for: BookModel.self)
    let book = BookModel(title: "Sample", authors: ["Author"])
    AnalysisPanelView(
        viewModel: ReaderViewModel(
            book: book,
            modelContext: container.mainContext
        )
    )
    .frame(width: 350)
}
