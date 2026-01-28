// ReaderViewModel.swift
// ViewModel for the Reader view managing book reading state
//
// Handles chapter navigation, highlights, AI analysis, and reading progress

import SwiftUI
import SwiftData
import UIKit

/// Input mode for the follow-up input box in AnalysisPanelView
/// Controls placeholder text and submit behavior
enum FollowUpInputMode: Equatable {
    case followUp       // Normal follow-up to existing analysis
    case askQuestion    // New custom question (no existing analysis selected)
    case addComment     // Adding a comment (no AI call, just user text)
}

@Observable
final class ReaderViewModel {
    // MARK: - Properties
    private let modelContext: ModelContext

    // Book State
    let book: BookModel
    var currentChapterIndex: Int = 0
    var scrollOffset: CGFloat = 0

    // UI State
    var showingTOC = false  // Start with TOC hidden on iPhone for better UX
    var showingAnalysisPanel = false
    var selectedText: String = ""
    var selectionRange: NSRange?

    /// Current mode for the follow-up input box
    /// Changes placeholder text and submit behavior
    var followUpInputMode: FollowUpInputMode = .followUp

    // Highlights
    var currentChapterHighlights: [HighlightModel] = []
    var selectedHighlight: HighlightModel?
    /// Request to scroll reader to a specific highlight (used by AnalysisPanelView)
    var scrollToHighlightId: UUID?

    // Undo Delete
    /// Stores deleted highlight data for undo functionality
    var deletedHighlightForUndo: DeletedHighlightData?
    /// Timer to auto-clear undo state after timeout
    private var undoTimer: Timer?

    /// Data structure to store deleted highlight for undo
    struct DeletedHighlightData {
        let chapterIndex: Int
        let selectedText: String
        let contextBefore: String
        let contextAfter: String
        let startOffset: Int
        let endOffset: Int
        let colorHex: String
        let markerIndex: Int  // 1-based marker number for undo restoration
        let analyses: [DeletedAnalysisData]

        struct DeletedAnalysisData {
            let type: AnalysisType
            let prompt: String
            let response: String
            let createdAt: Date
            let turns: [(question: String, answer: String, turnIndex: Int)]
        }
    }

    /// Pending undo restore data for JS injection (avoids HTML reload flicker)
    var pendingUndoRestore: (highlightId: UUID, startOffset: Int, endOffset: Int, markerIndex: Int, analysisCount: Int, colorHex: String)?

    // AI Analysis
    let analysisJobManager = AnalysisJobManager()
    var currentAnalysisType: AnalysisType?
    var isAnalyzing = false
    var analysisResult: String?
    var customQuestion: String = ""
    /// Currently selected analysis for conversation display (especially custom questions)
    var selectedAnalysis: AIAnalysisModel?

    // Context Menu
    var showingContextMenu = false
    var contextMenuPosition: CGPoint = .zero

    /// Pending marker update for JS injection (avoids full HTML reload)
    /// Set when analysis completes to update marker without page flicker
    /// Includes colorHex to update highlight background color when analysis completes
    var pendingMarkerUpdate: (highlightId: UUID, analysisCount: Int, colorHex: String)?

    /// Maps highlight ID to its active job ID for proper streaming display
    /// When user clicks a highlight, we show streaming from ITS job, not any random job
    private var highlightToJobMap: [UUID: UUID] = [:]

    /// Queue of pending marker updates to apply when no text selection is active
    /// This prevents marker refresh from disrupting user's text selection
    private var pendingMarkerUpdatesQueue: [(highlightId: UUID, analysisCount: Int, colorHex: String)] = []

    /// Flag to indicate there's an active text selection that shouldn't be interrupted
    var hasActiveTextSelection: Bool = false

    // MARK: - Cached Chapters (ensures SwiftData relationship is loaded)
    private var _cachedChapters: [ChapterModel]?

    private var cachedChapters: [ChapterModel] {
        if let cached = _cachedChapters {
            return cached
        }
        // Force SwiftData to load the relationship by accessing it
        let chapters = book.chapters.sorted(by: { $0.order < $1.order })
        _cachedChapters = chapters
        return chapters
    }

    // MARK: - Computed Properties
    var currentChapter: ChapterModel? {
        let chapters = cachedChapters
        guard currentChapterIndex >= 0 && currentChapterIndex < chapters.count else {
            return nil
        }
        return chapters[currentChapterIndex]
    }

    var chapterCount: Int {
        cachedChapters.count
    }

    var hasNextChapter: Bool {
        currentChapterIndex < chapterCount - 1
    }

    var hasPreviousChapter: Bool {
        currentChapterIndex > 0
    }

    var sortedChapters: [ChapterModel] {
        cachedChapters
    }

    // MARK: - Initialization
    init(book: BookModel, modelContext: ModelContext) {
        self.book = book
        self.modelContext = modelContext

        // Restore last reading position or find first content chapter
        if let progress = book.readingProgress {
            self.currentChapterIndex = progress.chapterIndex
            self.scrollOffset = progress.scrollOffset
        } else {
            // First time opening - skip front matter (cover, titlepage, etc.)
            // Find the first chapter with substantial content (>500 chars of plain text)
            self.currentChapterIndex = findFirstContentChapter()
        }

        loadHighlightsForCurrentChapter()
    }

    // MARK: - Content Detection
    /// Finds the first chapter with substantial content, skipping front matter
    private func findFirstContentChapter() -> Int {
        let chapters = cachedChapters

        // Look for first chapter with substantial content (>500 chars of plain text)
        // This skips cover pages, title pages, copyright pages, etc.
        for (index, chapter) in chapters.enumerated() {
            if chapter.plainText.count > 500 {
                return index
            }
        }

        // Fallback to first chapter if none found with substantial content
        return 0
    }

    // MARK: - Navigation
    func goToChapter(_ index: Int) {
        guard index >= 0 && index < chapterCount else { return }

        #if DEBUG
        print("[GoToChapter] Navigating from chapter \(currentChapterIndex) to \(index)")
        print("[GoToChapter] hasActiveTextSelection=\(hasActiveTextSelection), pendingQueue=\(pendingMarkerUpdatesQueue.count)")
        #endif

        // Clear active selection flag FIRST - chapter change ends any selection
        // This ensures applyDeferredMarkerUpdates() and analysis completions
        // use the immediate update path (not deferred queue)
        hasActiveTextSelection = false

        // Apply any deferred updates for current chapter before leaving
        // This ensures colorHex is saved even if user had active selection
        if !pendingMarkerUpdatesQueue.isEmpty {
            #if DEBUG
            print("[GoToChapter] Applying \(pendingMarkerUpdatesQueue.count) deferred updates before leaving")
            #endif
            applyDeferredMarkerUpdates()
        }

        // Clear highlight selection state (belongs to old chapter, now out of context)
        // Matches X button pattern: both are "deselection" operations
        // Panel stays open but will show new chapter's highlights list
        scrollToHighlightId = nil
        selectedHighlight = nil
        selectedText = ""
        analysisResult = nil
        currentAnalysisType = nil
        selectedAnalysis = nil
        isAnalyzing = false  // Prevent stale loading state in new chapter
        customQuestion = ""  // Clear stale follow-up question
        followUpInputMode = .followUp  // Reset input mode

        currentChapterIndex = index
        scrollOffset = 0
        _cachedChapters = nil  // Invalidate cache to refresh from SwiftData
        loadHighlightsForCurrentChapter()
        saveProgress()
    }

    func goToNextChapter() {
        if hasNextChapter {
            goToChapter(currentChapterIndex + 1)
        }
    }

    func goToPreviousChapter() {
        if hasPreviousChapter {
            goToChapter(currentChapterIndex - 1)
        }
    }

    func goToTOCEntry(_ entry: TOCEntryModel) {
        // Find chapter matching the TOC entry's href
        if let index = sortedChapters.firstIndex(where: { $0.href.contains(entry.href) || entry.href.contains($0.href) }) {
            goToChapter(index)
        }
    }

    // MARK: - Progress Tracking
    func saveProgress() {
        if book.readingProgress == nil {
            let progress = ReadingProgressModel(
                chapterIndex: currentChapterIndex,
                scrollPosition: Double(scrollOffset),
                scrollOffset: scrollOffset
            )
            progress.book = book
            book.readingProgress = progress
            modelContext.insert(progress)
        } else {
            book.readingProgress?.update(
                chapterIndex: currentChapterIndex,
                scrollPosition: Double(scrollOffset),
                scrollOffset: scrollOffset
            )
        }

        try? modelContext.save()
    }

    func updateScrollPosition(_ offset: CGFloat) {
        scrollOffset = offset
        // Debounce save - in production, use Combine debounce
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
            await MainActor.run {
                saveProgress()
            }
        }
    }

    // MARK: - Highlights
    func loadHighlightsForCurrentChapter() {
        let chapterIdx = currentChapterIndex
        let descriptor = FetchDescriptor<HighlightModel>(
            predicate: #Predicate { highlight in
                highlight.chapterIndex == chapterIdx
            },
            sortBy: [SortDescriptor(\.startOffset)]
        )

        do {
            currentChapterHighlights = try modelContext.fetch(descriptor)
                .filter { $0.book?.id == book.id }
            #if DEBUG
            print("[LoadHighlights] Chapter \(chapterIdx): Loaded \(currentChapterHighlights.count) highlights")
            for h in currentChapterHighlights {
                print("[LoadHighlights]   - \(h.id.uuidString.prefix(8)): colorHex=\(h.colorHex), analyses=\(h.analyses.count)")
            }
            #endif
        } catch {
            currentChapterHighlights = []
            #if DEBUG
            print("[LoadHighlights] ERROR loading highlights for chapter \(chapterIdx): \(error)")
            #endif
        }
    }

    func createHighlight(
        text: String,
        contextBefore: String,
        contextAfter: String,
        startOffset: Int,
        endOffset: Int
    ) -> HighlightModel {
        let highlight = HighlightModel(
            chapterIndex: currentChapterIndex,
            selectedText: text,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            startOffset: startOffset,
            endOffset: endOffset
        )

        highlight.book = book
        modelContext.insert(highlight)
        try? modelContext.save()

        loadHighlightsForCurrentChapter()
        return highlight
    }

    func deleteHighlight(_ highlight: HighlightModel) {
        let highlightId = highlight.id

        // Haptic feedback for tactile confirmation
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()

        // Calculate marker index (1-based position in sorted highlight list) BEFORE deletion
        let sortedHighlights = currentChapterHighlights.sorted { $0.startOffset < $1.startOffset }
        let markerIndex = (sortedHighlights.firstIndex(where: { $0.id == highlight.id }) ?? 0) + 1

        // Capture data for undo BEFORE deletion
        let analysesData = highlight.analyses.map { analysis -> DeletedHighlightData.DeletedAnalysisData in
            let turns = analysis.thread?.turns.sorted(by: { $0.turnIndex < $1.turnIndex }).map {
                (question: $0.question, answer: $0.answer, turnIndex: $0.turnIndex)
            } ?? []
            return DeletedHighlightData.DeletedAnalysisData(
                type: analysis.analysisType,
                prompt: analysis.prompt,
                response: analysis.response,
                createdAt: analysis.createdAt,
                turns: turns
            )
        }

        deletedHighlightForUndo = DeletedHighlightData(
            chapterIndex: highlight.chapterIndex,
            selectedText: highlight.selectedText,
            contextBefore: highlight.contextBefore,
            contextAfter: highlight.contextAfter,
            startOffset: highlight.startOffset,
            endOffset: highlight.endOffset,
            colorHex: highlight.colorHex,
            markerIndex: markerIndex,
            analyses: analysesData
        )

        // Start undo timer (5 seconds to undo)
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.deletedHighlightForUndo = nil
        }

        // Delete from database
        modelContext.delete(highlight)
        try? modelContext.save()
        loadHighlightsForCurrentChapter()

        // Clear ALL selection-related state if this highlight was selected
        // Must clear selectedText too - it was set by selectHighlight() and without clearing,
        // reopening panel shows pendingSelectionSection instead of chapter highlights
        if selectedHighlight?.id == highlightId {
            selectedHighlight = nil
            selectedText = ""
            analysisResult = nil
            currentAnalysisType = nil
            selectedAnalysis = nil  // Clear stale analysis reference
            isAnalyzing = false
            customQuestion = ""  // Clear stale follow-up question
            followUpInputMode = .followUp  // Reset input mode
            showingAnalysisPanel = false
        }
    }

    /// Undo the last deleted highlight
    func undoDeleteHighlight() {
        guard let data = deletedHighlightForUndo else { return }

        // Cancel undo timer
        undoTimer?.invalidate()
        undoTimer = nil

        // Ensure no scroll-to-highlight behavior during undo
        // User is reading at their current position, not at the highlight location
        scrollToHighlightId = nil

        // Recreate the highlight
        let highlight = HighlightModel(
            chapterIndex: data.chapterIndex,
            selectedText: data.selectedText,
            contextBefore: data.contextBefore,
            contextAfter: data.contextAfter,
            startOffset: data.startOffset,
            endOffset: data.endOffset
        )
        highlight.colorHex = data.colorHex
        highlight.book = book
        modelContext.insert(highlight)

        // Recreate analyses
        for analysisData in data.analyses {
            let analysis = AIAnalysisModel(
                analysisType: analysisData.type,
                prompt: analysisData.prompt,
                response: analysisData.response
            )
            // Preserve original creation date
            analysis.createdAt = analysisData.createdAt
            analysis.highlight = highlight
            highlight.analyses.append(analysis)
            modelContext.insert(analysis)

            // Recreate conversation thread if exists
            if !analysisData.turns.isEmpty {
                let thread = AnalysisThreadModel()
                thread.analysis = analysis
                analysis.thread = thread
                modelContext.insert(thread)

                for turnData in analysisData.turns {
                    let turn = AnalysisTurnModel(
                        question: turnData.question,
                        answer: turnData.answer,
                        turnIndex: turnData.turnIndex
                    )
                    turn.thread = thread
                    thread.turns.append(turn)
                    modelContext.insert(turn)
                }
            }
        }

        try? modelContext.save()

        // Set pending undo restore for JS injection (avoids HTML reload flicker)
        // ChapterWebView will inject the highlight via JS instead of reloading entire page
        pendingUndoRestore = (
            highlightId: highlight.id,
            startOffset: data.startOffset,
            endOffset: data.endOffset,
            markerIndex: data.markerIndex,
            analysisCount: data.analyses.count,
            colorHex: data.colorHex
        )

        loadHighlightsForCurrentChapter()

        // Clear undo state
        deletedHighlightForUndo = nil

        // Haptic feedback for undo confirmation
        let notificationFeedback = UINotificationFeedbackGenerator()
        notificationFeedback.notificationOccurred(.success)
    }

    // MARK: - Analysis Management

    /// Delete a specific analysis from a highlight
    /// Unlike deleteHighlight(), this only removes one analysis thread, not the entire highlight
    func deleteAnalysis(_ analysis: AIAnalysisModel) {
        guard let highlight = analysis.highlight else { return }

        // Haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()

        // Track if we need to auto-select another analysis after deletion
        let wasSelected = selectedAnalysis?.id == analysis.id

        // If this analysis is currently selected, clear selection state first
        // Full state set per State Symmetry principle (documented in project_memory)
        if wasSelected {
            selectedAnalysis = nil
            currentAnalysisType = nil
            analysisResult = nil
            isAnalyzing = false
            customQuestion = ""  // Clear any pending follow-up text
        }

        // Remove from highlight's analyses array
        highlight.analyses.removeAll { $0.id == analysis.id }

        // Delete from database (cascade will delete thread and turns)
        modelContext.delete(analysis)
        try? modelContext.save()

        // Determine new color based on the guideline: Color = Currently Selected Analysis
        // Only recalculate color when selection changes (wasSelected=true means we need new selection)
        // If deleting non-selected analysis, keep current color (it still matches selectedAnalysis)
        let newColorHex: String
        if wasSelected {
            // Deleted the selected analysis - need to auto-select next and update color
            if let mostRecentAnalysis = highlight.analyses.sorted(by: { $0.createdAt > $1.createdAt }).first {
                // Auto-select the most recent remaining analysis
                // Provides smooth UX - no jarring "empty" state after deletion
                selectedAnalysis = mostRecentAnalysis
                currentAnalysisType = mostRecentAnalysis.analysisType
                analysisResult = mostRecentAnalysis.response
                newColorHex = mostRecentAnalysis.analysisType.colorHex
                #if DEBUG
                print("[DeleteAnalysis] Auto-selected next analysis: \(mostRecentAnalysis.analysisType.displayName)")
                #endif
            } else {
                // No analyses remain - color reverts to default yellow
                newColorHex = "#FFEB3B"
            }
        } else {
            // Deleted a non-selected analysis - keep current color (still matches selectedAnalysis)
            newColorHex = highlight.colorHex
            #if DEBUG
            print("[DeleteAnalysis] Keeping current color: \(newColorHex) (deleted non-selected analysis)")
            #endif
        }

        // Trigger WKWebView marker update (color and count) via JS injection
        // This updates the inline marker [1][2] count and background color without reload
        let markerUpdate = (highlightId: highlight.id, analysisCount: highlight.analyses.count, colorHex: newColorHex)

        // Match saveAnalysis() pattern: defer colorHex update if user has active text selection
        // This prevents hash change → HTML reload which would disrupt selection
        if hasActiveTextSelection {
            // Queue the update - applyDeferredMarkerUpdates() will handle colorHex later
            pendingMarkerUpdatesQueue.append(markerUpdate)
            #if DEBUG
            print("[DeleteAnalysis] DEFERRED marker update - hasActiveTextSelection=true")
            #endif
        } else {
            // Safe to update colorHex now - no active selection to disrupt
            let oldColorHex = highlight.colorHex
            highlight.colorHex = newColorHex
            do {
                try modelContext.save()
                #if DEBUG
                print("[DeleteAnalysis] IMMEDIATE colorHex update: \(oldColorHex) → \(newColorHex)")
                #endif
            } catch {
                #if DEBUG
                print("[DeleteAnalysis] ERROR saving colorHex: \(error)")
                #endif
            }
            pendingMarkerUpdate = markerUpdate
        }

        #if DEBUG
        print("[Analysis] Deleted analysis id=\(analysis.id.uuidString.prefix(8)) type=\(analysis.analysisType.displayName), remaining: \(highlight.analyses.count)")
        #endif
    }

    /// Select an existing analysis to view (from Previous Analyses cards)
    /// Updates highlight color to match the selected analysis type - color represents user's current focus
    func selectAnalysis(_ analysis: AIAnalysisModel) {
        guard let highlight = analysis.highlight else { return }

        #if DEBUG
        let prevType = selectedAnalysis?.analysisType.displayName ?? "nil"
        print("[SelectAnalysis] Switching: \(prevType) → \(analysis.analysisType.displayName) id=\(analysis.id.uuidString.prefix(8))")
        #endif

        // Set UI state - all variables together per State Symmetry
        currentAnalysisType = analysis.analysisType
        analysisResult = analysis.response
        selectedAnalysis = analysis
        isAnalyzing = false

        // Update highlight color to match selected analysis type
        // Color represents "what user is currently viewing" not "what was created most recently"
        let newColorHex = analysis.analysisType.colorHex

        // Only update if color actually changed
        guard highlight.colorHex != newColorHex else {
            #if DEBUG
            print("[SelectAnalysis] Color unchanged: \(newColorHex)")
            #endif
            return
        }

        // Trigger WKWebView marker update (same pattern as saveAnalysis/deleteAnalysis)
        let markerUpdate = (highlightId: highlight.id, analysisCount: highlight.analyses.count, colorHex: newColorHex)

        if hasActiveTextSelection {
            pendingMarkerUpdatesQueue.append(markerUpdate)
            #if DEBUG
            print("[SelectAnalysis] DEFERRED color update - hasActiveTextSelection=true")
            #endif
        } else {
            let oldColorHex = highlight.colorHex
            highlight.colorHex = newColorHex
            do {
                try modelContext.save()
                #if DEBUG
                print("[SelectAnalysis] Color updated: \(oldColorHex) → \(newColorHex)")
                #endif
            } catch {
                #if DEBUG
                print("[SelectAnalysis] ERROR saving colorHex: \(error)")
                #endif
            }
            pendingMarkerUpdate = markerUpdate
        }
    }

    // MARK: - AI Analysis
    func performAnalysis(type: AnalysisType, text: String, context: String, question: String? = nil) {
        guard let highlight = selectedHighlight else { return }

        #if DEBUG
        print("[Analysis] START: type=\(type.displayName) highlight=\(highlight.id.uuidString.prefix(8)) prevSelected=\(selectedAnalysis?.analysisType.displayName ?? "nil")")
        #endif

        isAnalyzing = true
        currentAnalysisType = type
        analysisResult = nil
        // Clear selectedAnalysis so UI shows loading state (not streaming under old thread)
        // When user clicks "Key Points" while viewing "Discussion", we want a clean loading view
        // for Key Points - not Key Points streaming under Discussion's "Follow-ups" section
        selectedAnalysis = nil

        let jobId = analysisJobManager.queueAnalysis(
            type: type,
            text: text,
            context: context,
            chapterContext: currentChapter?.plainText,
            question: question
        )

        // Track which job belongs to which highlight for proper streaming display
        let highlightId = highlight.id
        highlightToJobMap[highlightId] = jobId

        // Poll for streaming updates and completion
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 50_000_000)  // 0.05 second for smoother streaming

                guard let job = analysisJobManager.getJob(jobId) else { break }

                switch job.status {
                case .streaming:
                    await MainActor.run {
                        // Only update analysisResult if:
                        // 1. This is the currently selected highlight
                        // 2. This is the active job for this highlight (prevents parallel job flickering)
                        if !job.streamingResult.isEmpty,
                           selectedHighlight?.id == highlightId,
                           highlightToJobMap[highlightId] == jobId {
                            analysisResult = job.streamingResult
                        }
                    }
                case .completed:
                    await MainActor.run {
                        if let result = job.result {
                            // Only update UI state if this is still the active job for this highlight
                            // Prevents older job from overwriting newer job's streaming state
                            let isActiveJob = highlightToJobMap[highlightId] == jobId
                            if selectedHighlight?.id == highlightId && isActiveJob {
                                analysisResult = result
                                isAnalyzing = false
                            }
                            // Only save if highlight wasn't deleted while analysis was running
                            // Use book.highlights (not currentChapterHighlights) so analysis saves
                            // even when user switches chapters during background processing
                            // Fetch fresh highlight from context (not captured reference) for Sendable safety
                            if let freshHighlight = book.highlights.first(where: { $0.id == highlightId }) {
                                saveAnalysis(
                                    to: freshHighlight,
                                    type: type,
                                    prompt: question ?? text,
                                    response: result,
                                    isActiveJob: isActiveJob
                                )
                            }
                        }
                        // Clean up job mapping only if this job is still the tracked one
                        // Prevents earlier job from removing a later job's entry
                        if highlightToJobMap[highlightId] == jobId {
                            highlightToJobMap.removeValue(forKey: highlightId)
                        }
                    }
                    return
                case .error:
                    await MainActor.run {
                        if selectedHighlight?.id == highlightId {
                            analysisResult = "Error: \(job.error?.localizedDescription ?? "Unknown error")"
                            isAnalyzing = false
                        }
                        // Only remove if this job is still the tracked one
                        if highlightToJobMap[highlightId] == jobId {
                            highlightToJobMap.removeValue(forKey: highlightId)
                        }
                    }
                    return
                case .queued, .running:
                    continue
                }
            }
        }
    }

    func saveAnalysis(to highlight: HighlightModel, type: AnalysisType, prompt: String, response: String, isActiveJob: Bool = true) {
        let analysis = AIAnalysisModel(
            analysisType: type,
            prompt: prompt,
            response: response
        )

        analysis.highlight = highlight
        highlight.analyses.append(analysis)
        // NOTE: Don't update colorHex here yet - it would change the hash and trigger HTML reload
        // Color update is deferred along with marker update to preserve user's text selection

        modelContext.insert(analysis)
        try? modelContext.save()

        // Only update selectedAnalysis if:
        // 1. This highlight is still selected
        // 2. This is the active job (no newer job has taken over)
        // 3. User hasn't explicitly selected a different analysis while waiting
        //    (performAnalysis sets selectedAnalysis=nil, so non-nil means user tapped a card)
        // Prevents older job from overwriting newer job's streaming UI state
        // AND prevents overwriting explicit user selection
        let userHasNotExplicitlySelectedAnother = selectedAnalysis == nil
        #if DEBUG
        print("[SaveAnalysis] type=\(type.displayName) id=\(analysis.id.uuidString.prefix(8)) isActiveJob=\(isActiveJob) userHasNotSelected=\(userHasNotExplicitlySelectedAnother)")
        #endif
        if selectedHighlight?.id == highlight.id && isActiveJob && userHasNotExplicitlySelectedAnother {
            #if DEBUG
            print("[SaveAnalysis] → Setting selectedAnalysis to \(type.displayName)")
            #endif
            selectedAnalysis = analysis
        }

        // Update marker via JS injection (no page reload, preserves scroll & selection)
        // The highlight.analyses array is already updated in memory (reference type)
        // Include colorHex so the highlight background updates to analysis type color
        let markerUpdate = (highlightId: highlight.id, analysisCount: highlight.analyses.count, colorHex: type.colorHex)

        // If user has active text selection, defer EVERYTHING to avoid disrupting selection
        // This includes not updating colorHex in SwiftData (which would change hash → reload)
        if hasActiveTextSelection {
            pendingMarkerUpdatesQueue.append(markerUpdate)
            #if DEBUG
            print("[SaveAnalysis] DEFERRED colorHex update for highlight \(highlight.id.uuidString.prefix(8)) - hasActiveTextSelection=true")
            #endif
        } else {
            // Safe to update colorHex now - no active selection to disrupt
            let oldColor = highlight.colorHex
            highlight.colorHex = type.colorHex
            do {
                try modelContext.save()
                #if DEBUG
                print("[SaveAnalysis] IMMEDIATE colorHex update for highlight \(highlight.id.uuidString.prefix(8)): \(oldColor) → \(type.colorHex)")
                #endif
            } catch {
                #if DEBUG
                print("[SaveAnalysis] ERROR saving colorHex for highlight \(highlight.id.uuidString.prefix(8)): \(error)")
                #endif
            }
            pendingMarkerUpdate = markerUpdate
        }
    }

    /// Apply any deferred marker updates after text selection is cleared
    func applyDeferredMarkerUpdates() {
        guard !pendingMarkerUpdatesQueue.isEmpty else { return }

        // Apply the last update for each highlight (most recent analysis count and color)
        var lastUpdates: [UUID: (highlightId: UUID, analysisCount: Int, colorHex: String)] = [:]
        for update in pendingMarkerUpdatesQueue {
            lastUpdates[update.highlightId] = update
        }
        pendingMarkerUpdatesQueue.removeAll()

        // First, update colorHex in SwiftData for all deferred highlights
        // This was deferred to avoid changing the hash while user had active selection
        // Use book.highlights to ensure we always find the highlight, even if
        // currentChapterHighlights is stale or being modified during chapter transition
        #if DEBUG
        print("[ApplyDeferred] Processing \(lastUpdates.count) deferred updates")
        #endif
        for update in lastUpdates.values {
            if let highlight = book.highlights.first(where: { $0.id == update.highlightId }) {
                let oldColor = highlight.colorHex
                highlight.colorHex = update.colorHex
                #if DEBUG
                print("[ApplyDeferred] Updated highlight \(update.highlightId.uuidString.prefix(8)): \(oldColor) → \(update.colorHex)")
                #endif
            } else {
                #if DEBUG
                print("[ApplyDeferred] WARNING: Highlight \(update.highlightId.uuidString.prefix(8)) NOT FOUND in book.highlights!")
                #endif
            }
        }
        do {
            try modelContext.save()
            #if DEBUG
            print("[ApplyDeferred] SwiftData save succeeded")
            #endif
        } catch {
            #if DEBUG
            print("[ApplyDeferred] ERROR saving: \(error)")
            #endif
        }

        // Now trigger the marker updates via JS injection
        // NOTE: Setting pendingMarkerUpdate multiple times in a loop only keeps the last one
        // This is acceptable because the HTML reload (triggered by colorHex change) will
        // render all highlights with correct markers anyway
        if let lastUpdate = lastUpdates.values.first {
            pendingMarkerUpdate = lastUpdate
        }
    }

    func askFollowUpQuestion(highlight: HighlightModel, question: String) {
        // Use the currently viewed analysis for follow-up
        // Each analysis type (Fact Check, Discussion, etc.) has its OWN conversation thread
        // If no analysis is selected, we're starting a fresh custom question
        let analysisToFollowUp = selectedAnalysis

        #if DEBUG
        print("[FollowUp] START: question='\(question.prefix(20))...' analysisToFollowUp=\(analysisToFollowUp?.analysisType.displayName ?? "nil") id=\(analysisToFollowUp?.id.uuidString.prefix(8) ?? "nil")")
        #endif

        isAnalyzing = true
        analysisResult = nil
        customQuestion = question  // Track current question for streaming display

        // Keep the current analysis type (don't switch to .customQuestion)
        // This way the UI knows to show the appropriate conversation view for this analysis
        if let analysis = analysisToFollowUp {
            currentAnalysisType = analysis.analysisType
        } else {
            currentAnalysisType = .customQuestion
        }

        // Build priorAnalysisContext from the analysis being followed up
        // This includes the initial analysis result so AI knows the context
        // For comments: use prompt (user's comment text) since response is empty
        var priorAnalysisContext: (type: AnalysisType, result: String)?
        if let analysis = analysisToFollowUp {
            if analysis.analysisType == .comment {
                // Comments store user's text in prompt, response is empty
                // Pass the comment as context so AI knows what user wrote
                priorAnalysisContext = (type: analysis.analysisType, result: analysis.prompt)
            } else {
                priorAnalysisContext = (type: analysis.analysisType, result: analysis.response)
            }
        }

        // Build conversation history from existing thread turns
        // The initial analysis result is already in priorAnalysisContext
        var history: [(question: String, answer: String)] = []
        if let thread = analysisToFollowUp?.thread {
            history = thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex }).map {
                (question: $0.question, answer: $0.answer)
            }
        }

        let jobId = analysisJobManager.queueAnalysis(
            type: .customQuestion,  // API call type (it's always a question to the AI)
            text: highlight.selectedText,
            context: highlight.fullContext,
            chapterContext: currentChapter?.plainText,
            question: question,
            history: history,
            priorAnalysisContext: priorAnalysisContext
        )

        // Track which job belongs to which highlight for proper streaming display
        // This ensures parallel follow-ups don't interfere with each other
        let highlightId = highlight.id
        let analysisToFollowUpId = analysisToFollowUp?.id  // Capture ID for Sendable safety
        highlightToJobMap[highlightId] = jobId

        // Poll for streaming updates and completion
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 50_000_000)  // 0.05 second for smoother streaming

                guard let job = analysisJobManager.getJob(jobId) else { break }

                switch job.status {
                case .streaming:
                    // Update with streaming result for real-time display
                    // Only update if:
                    // 1. This is the currently selected highlight
                    // 2. This is the active job for this highlight (prevents parallel job flickering)
                    await MainActor.run {
                        if !job.streamingResult.isEmpty,
                           selectedHighlight?.id == highlightId,
                           highlightToJobMap[highlightId] == jobId {
                            analysisResult = job.streamingResult
                        }
                    }
                case .completed:
                    await MainActor.run {
                        // Check if this is the active job for this highlight BEFORE any state changes
                        // This prevents parallel job interference (e.g., job A completing shouldn't reset
                        // input mode while job B is still running)
                        let isActiveJob = highlightToJobMap[highlightId] == jobId

                        if let result = job.result {
                            // Only update UI state if this is still the active job
                            if selectedHighlight?.id == highlightId && isActiveJob {
                                analysisResult = result
                                isAnalyzing = false
                            }

                            // Only save if highlight wasn't deleted while analysis was running
                            // Use book.highlights (not currentChapterHighlights) so analysis saves
                            // even when user switches chapters during background processing
                            if let freshHighlight = book.highlights.first(where: { $0.id == highlightId }) {
                                // Look up fresh analysis using captured ID (Sendable safe)
                                if let analysisId = analysisToFollowUpId {
                                    // Analysis was selected - try to find it (might have been deleted)
                                    guard let analysis = freshHighlight.analyses.first(where: { $0.id == analysisId }) else {
                                        // Analysis was deleted during streaming
                                        #if DEBUG
                                        print("[FollowUp] ABORTED: Analysis \(analysisId.uuidString.prefix(8)) was deleted during streaming")
                                        #endif
                                        // Clean up: reset UI state if this was the active job
                                        if highlightToJobMap[highlightId] == jobId {
                                            highlightToJobMap.removeValue(forKey: highlightId)
                                            if selectedHighlight?.id == highlightId {
                                                isAnalyzing = false
                                                analysisResult = nil
                                            }
                                        }
                                        return
                                    }
                                    // Add turn to the analysis thread
                                    // Note: addTurnToThread has built-in duplicate detection to prevent
                                    // double-tap from creating duplicate turns
                                    addTurnToThread(analysis: analysis, question: question, answer: result)
                                    #if DEBUG
                                    print("[FollowUp] COMPLETE: Added turn to \(analysis.analysisType.displayName) id=\(analysis.id.uuidString.prefix(8))")
                                    #endif
                                    // Only update selectedAnalysis if:
                                    // 1. Highlight is still selected
                                    // 2. This is the active job (no newer job has taken over)
                                    // 3. User hasn't switched to a different analysis (respect explicit user choice)
                                    let userStillViewingSameAnalysis = selectedAnalysis?.id == analysis.id || selectedAnalysis == nil
                                    #if DEBUG
                                    print("[FollowUp] Check: isActiveJob=\(isActiveJob) userStillViewingSame=\(userStillViewingSameAnalysis) currentSelected=\(selectedAnalysis?.analysisType.displayName ?? "nil")")
                                    #endif
                                    if selectedHighlight?.id == highlightId && isActiveJob && userStillViewingSameAnalysis {
                                        selectedAnalysis = analysis
                                    }
                                } else {
                                    // No analysis was selected (analysisToFollowUpId == nil) - create new custom question analysis
                                    // Check if an identical custom question already exists (double-tap protection)
                                    let isDuplicate = freshHighlight.analyses.contains { existing in
                                        existing.analysisType == .customQuestion &&
                                        existing.prompt == question &&
                                        existing.response == result
                                    }

                                    if isDuplicate {
                                        #if DEBUG
                                        print("[FollowUp] SKIPPED: Duplicate custom question already exists")
                                        #endif
                                    } else {
                                        let analysis = AIAnalysisModel(
                                            analysisType: .customQuestion,
                                            prompt: question,
                                            response: result
                                        )
                                        analysis.highlight = freshHighlight
                                        freshHighlight.analyses.append(analysis)
                                        // NOTE: Don't update colorHex immediately - use deferral logic like saveAnalysis()
                                        modelContext.insert(analysis)
                                        try? modelContext.save()

                                        #if DEBUG
                                        print("[FollowUp] COMPLETE: Created new custom question id=\(analysis.id.uuidString.prefix(8))")
                                        #endif

                                        // Only update selectedAnalysis if:
                                        // 1. Highlight is still selected
                                        // 2. This is the active job (no newer job has taken over)
                                        // 3. User hasn't selected a different analysis since starting this question
                                        //    (respect explicit user choice - they started with nil, if now non-nil they tapped something)
                                        let userStillHasNoAnalysisSelected = selectedAnalysis == nil
                                        if selectedHighlight?.id == highlightId && isActiveJob && userStillHasNoAnalysisSelected {
                                            selectedAnalysis = analysis
                                        }

                                        // Use same deferral logic as saveAnalysis() for colorHex and marker updates
                                        let markerUpdate = (highlightId: freshHighlight.id, analysisCount: freshHighlight.analyses.count, colorHex: AnalysisType.customQuestion.colorHex)
                                        if hasActiveTextSelection {
                                            pendingMarkerUpdatesQueue.append(markerUpdate)
                                            #if DEBUG
                                            print("[FollowUp] DEFERRED colorHex update for highlight \(freshHighlight.id.uuidString.prefix(8)) - hasActiveTextSelection=true")
                                            #endif
                                        } else {
                                            let oldColor = freshHighlight.colorHex
                                            freshHighlight.colorHex = AnalysisType.customQuestion.colorHex
                                            do {
                                                try modelContext.save()
                                                #if DEBUG
                                                print("[FollowUp] IMMEDIATE colorHex update for highlight \(freshHighlight.id.uuidString.prefix(8)): \(oldColor) → \(AnalysisType.customQuestion.colorHex)")
                                                #endif
                                            } catch {
                                                #if DEBUG
                                                print("[FollowUp] ERROR saving colorHex for highlight \(freshHighlight.id.uuidString.prefix(8)): \(error)")
                                                #endif
                                            }
                                            pendingMarkerUpdate = markerUpdate
                                        }
                                        // Initial Q&A stored in prompt/response - no turn needed
                                        // Turns are for FOLLOW-UP questions only
                                    }
                                }
                            }
                        }
                        // Clean up job mapping only if this job is still the tracked one
                        // Prevents earlier job from removing a later job's entry
                        if highlightToJobMap[highlightId] == jobId {
                            highlightToJobMap.removeValue(forKey: highlightId)
                        }
                        // Reset input mode only if:
                        // 1. This highlight is still selected
                        // 2. This was the active job (prevents parallel job A from resetting mode while B is active)
                        if selectedHighlight?.id == highlightId && isActiveJob {
                            followUpInputMode = .followUp
                        }
                    }
                    return
                case .error:
                    await MainActor.run {
                        // Check if this is the active job for this highlight
                        // Prevents parallel job's error from disrupting newer job's state
                        let isActiveJob = highlightToJobMap[highlightId] == jobId
                        if selectedHighlight?.id == highlightId && isActiveJob {
                            analysisResult = "Error: \(job.error?.localizedDescription ?? "Unknown error")"
                            isAnalyzing = false
                            followUpInputMode = .followUp
                        }
                        // Only remove if this job is still the tracked one
                        if highlightToJobMap[highlightId] == jobId {
                            highlightToJobMap.removeValue(forKey: highlightId)
                        }
                    }
                    return
                case .queued, .running:
                    continue
                }
            }
        }
    }

    private func addTurnToThread(analysis: AIAnalysisModel, question: String, answer: String) {
        // Check for duplicate turn (same question AND same answer already exists)
        // This prevents double-tap from creating duplicate turns
        // Note: We check both question AND answer because the same question asked twice
        // at different times could legitimately have different answers
        if let existingTurns = analysis.thread?.turns,
           existingTurns.contains(where: { $0.question == question && $0.answer == answer }) {
            #if DEBUG
            print("[AddTurn] SKIPPED: Duplicate turn already exists (question='\(question.prefix(20))...')")
            #endif
            return
        }

        if analysis.thread == nil {
            let thread = AnalysisThreadModel()
            thread.analysis = analysis
            analysis.thread = thread
            modelContext.insert(thread)
        }

        let turnIndex = analysis.thread?.turns.count ?? 0
        let turn = AnalysisTurnModel(
            question: question,
            answer: answer,
            turnIndex: turnIndex
        )

        turn.thread = analysis.thread
        analysis.thread?.turns.append(turn)
        modelContext.insert(turn)

        try? modelContext.save()

        // Refresh highlights to ensure conversation data is loaded for marker taps
        loadHighlightsForCurrentChapter()
    }

    // MARK: - Custom Question Preparation

    /// Prepares UI state for a new custom question thread
    /// Called when user clicks "Ask Question" button to start a fresh question
    ///
    /// Key behaviors:
    /// 1. Clears current analysis display (so streaming from other jobs doesn't show)
    /// 2. Clears job mapping for current highlight (stops ongoing job from updating UI)
    /// 3. Sets input mode to .askQuestion (changes placeholder and submit behavior)
    ///
    /// This conceptually "reserves" the panel for the new custom question,
    /// even before the user types and submits. Any ongoing jobs will still
    /// complete and save in the background, but won't affect the UI.
    func prepareForNewCustomQuestion() {
        guard let highlight = selectedHighlight else { return }

        // Clear analysis state so UI shows empty/ready state
        selectedAnalysis = nil
        currentAnalysisType = .customQuestion
        analysisResult = nil

        // Set input mode for custom question placeholder
        followUpInputMode = .askQuestion

        // KEY: Clear job mapping for this highlight
        // This prevents ongoing jobs from:
        // - Updating analysisResult with their streaming content
        // - Setting selectedAnalysis when they complete
        // - Resetting followUpInputMode to .followUp
        // The jobs still save to database - only UI updates are blocked
        highlightToJobMap.removeValue(forKey: highlight.id)

        #if DEBUG
        print("[PrepareForNewCustomQuestion] Cleared state for highlight \(highlight.id.uuidString.prefix(8)) - ready for new custom question")
        #endif
    }

    // MARK: - Highlight Selection
    /// Selects a highlight and loads its most recent analysis for display
    func selectHighlight(_ highlight: HighlightModel) {
        // Look up the highlight from currentChapterHighlights to get fresh data with analyses loaded
        // The passed highlight from WebView may have stale/unloaded relationships
        let targetId = highlight.id
        let freshHighlight = currentChapterHighlights.first(where: { $0.id == targetId }) ?? highlight

        selectedHighlight = freshHighlight
        selectedText = freshHighlight.selectedText

        // Check if this highlight has an ongoing analysis (streaming)
        if let activeJobId = highlightToJobMap[targetId],
           let job = analysisJobManager.getJob(activeJobId) {
            // Show streaming result for this highlight's active job
            isAnalyzing = (job.status == .streaming || job.status == .queued || job.status == .running)
            if !job.streamingResult.isEmpty {
                analysisResult = job.streamingResult
            } else if let result = job.result {
                analysisResult = result
            } else {
                analysisResult = nil
            }
            // Clear stale selectedAnalysis from previous highlight
            // During active streaming, UI shows streaming view (not conversation view)
            // When job completes, saveAnalysis() will set selectedAnalysis appropriately
            selectedAnalysis = nil
            currentAnalysisType = nil
        } else {
            // No active job - load the analysis matching the highlight's current color
            // Color represents "what user last viewed" - persist their selection across taps
            // Fallback to most recent if no match (e.g., fresh highlight or color mismatch)
            let sortedAnalyses = freshHighlight.analyses.sorted(by: { $0.createdAt > $1.createdAt })

            // Find analysis matching current highlight color (user's last selection)
            let analysisMatchingColor = sortedAnalyses.first { $0.analysisType.colorHex == freshHighlight.colorHex }

            if let analysisToShow = analysisMatchingColor ?? sortedAnalyses.first {
                currentAnalysisType = analysisToShow.analysisType
                analysisResult = analysisToShow.response
                selectedAnalysis = analysisToShow
                isAnalyzing = false
                #if DEBUG
                let source = analysisMatchingColor != nil ? "color-matched" : "fallback-to-recent"
                print("[SelectHighlight] Showing \(analysisToShow.analysisType.displayName) (\(source))")
                #endif
            } else {
                // No analyses yet - clear result
                currentAnalysisType = nil
                analysisResult = nil
                selectedAnalysis = nil
                isAnalyzing = false
            }
        }

        // Reset input mode to follow-up (fresh highlight context)
        followUpInputMode = .followUp

        showingAnalysisPanel = true
    }

    // MARK: - Comment Management

    /// Add a comment to a highlight (no AI call, just stores user's text)
    /// Comment is stored as: prompt = user's comment, response = "" (empty)
    /// This allows follow-up questions on comments to work like normal Q&A threads
    func addComment(to highlight: HighlightModel, text: String) {
        #if DEBUG
        print("[Comment] Adding comment to highlight \(highlight.id.uuidString.prefix(8)): '\(text.prefix(30))...'")
        #endif

        let analysis = AIAnalysisModel(
            analysisType: .comment,
            prompt: text,      // User's comment text
            response: ""       // No initial AI response for comments
        )

        analysis.highlight = highlight
        highlight.analyses.append(analysis)
        modelContext.insert(analysis)

        // Update colorHex to comment color
        let markerUpdate = (highlightId: highlight.id, analysisCount: highlight.analyses.count, colorHex: AnalysisType.comment.colorHex)

        if hasActiveTextSelection {
            pendingMarkerUpdatesQueue.append(markerUpdate)
            #if DEBUG
            print("[Comment] DEFERRED colorHex update - hasActiveTextSelection=true")
            #endif
        } else {
            highlight.colorHex = AnalysisType.comment.colorHex
            pendingMarkerUpdate = markerUpdate
        }

        try? modelContext.save()

        // Set selected analysis to the new comment
        selectedAnalysis = analysis
        currentAnalysisType = .comment
        analysisResult = nil  // No AI result for comments
        isAnalyzing = false

        // Reset input mode back to follow-up for future questions
        followUpInputMode = .followUp

        #if DEBUG
        print("[Comment] COMPLETE: Created comment id=\(analysis.id.uuidString.prefix(8))")
        #endif
    }

    // MARK: - Text Selection
    func handleTextSelection(_ text: String, range: NSRange) {
        let wasActive = hasActiveTextSelection
        selectedText = text
        selectionRange = range
        showingContextMenu = !text.isEmpty
        // Track active selection to defer marker updates
        hasActiveTextSelection = !text.isEmpty

        // If selection was just cleared (user tapped elsewhere), apply deferred updates
        if wasActive && !hasActiveTextSelection {
            applyDeferredMarkerUpdates()
        }
    }

    func clearSelection() {
        selectedText = ""
        selectionRange = nil
        hasActiveTextSelection = false
        // Apply any deferred marker updates now that selection is cleared
        applyDeferredMarkerUpdates()
        showingContextMenu = false
    }
}
