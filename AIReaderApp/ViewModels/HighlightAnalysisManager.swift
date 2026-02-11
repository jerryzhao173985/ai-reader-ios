// HighlightAnalysisManager.swift
// Standalone manager for highlight analysis operations
//
// Enables analysis features (new analysis, follow-ups, streaming) outside reader context.
// Used by HighlightDetailSheet in HighlightsView for library-based analysis.

import Foundation
import SwiftData

/// Manages AI analysis operations for a single highlight
/// Works independently of ReaderViewModel - can be used in any context (Library, Reader, etc.)
@MainActor
@Observable
final class HighlightAnalysisManager {
    // MARK: - Dependencies
    let highlight: HighlightModel
    private let modelContext: ModelContext
    private let jobManager: AnalysisJobManager

    // MARK: - State
    /// Currently selected analysis for viewing/follow-up
    var selectedAnalysis: AIAnalysisModel?

    /// Current analysis type being performed
    var currentAnalysisType: AnalysisType?

    /// Whether an analysis is in progress
    var isAnalyzing = false

    /// Current analysis result (streaming or complete)
    var analysisResult: String?

    /// Current follow-up question being asked (for streaming display)
    var currentQuestion: String = ""

    /// Tracks active job ID for this highlight
    private var activeJobId: UUID?

    // MARK: - Initialization
    init(highlight: HighlightModel, modelContext: ModelContext) {
        self.highlight = highlight
        self.modelContext = modelContext
        self.jobManager = AnalysisJobManager()

        // Auto-select most recent analysis if any exist
        if let mostRecent = highlight.analyses.sorted(by: { $0.createdAt > $1.createdAt }).first {
            self.selectedAnalysis = mostRecent
            self.currentAnalysisType = mostRecent.analysisType
        }
    }

    // MARK: - Public API

    /// Start a new analysis of the specified type
    func performAnalysis(type: AnalysisType, question: String? = nil) {
        #if DEBUG
        print("[HighlightAnalysisManager] START: type=\(type.displayName)")
        #endif

        isAnalyzing = true
        currentAnalysisType = type
        analysisResult = nil
        selectedAnalysis = nil  // Clear to show loading state
        currentQuestion = ""    // Clear stale follow-up question (streamingAnalysisView always renders this)

        // Queue job synchronously - @MainActor class allows direct call without await
        // Job ID is returned immediately, no race condition with UI state
        let jobId = jobManager.queueAnalysis(
            type: type,
            text: highlight.selectedText,
            context: highlight.fullContext,
            chapterContext: nil,  // No chapter context in library view
            question: question
        )
        activeJobId = jobId

        // Poll for streaming updates
        // Task inherits @MainActor context - state updates are automatic
        // Named task for Instruments debugging (matches ReaderViewModel pattern)
        // NOTE: Don't cancel previous Tasks - they must run to completion to save results
        // The activeJobId check inside pollJob() handles UI isolation without losing data
        Task(name: "LibraryAnalysis: \(type.displayName) [\(highlight.id.uuidString.prefix(8))]") {
            await pollJob(jobId: jobId, type: type, question: question)
        }
    }

    /// Ask a follow-up question on the current analysis
    func askFollowUpQuestion(_ question: String) {
        let analysisToFollowUp = selectedAnalysis

        #if DEBUG
        print("[HighlightAnalysisManager] FOLLOW-UP: '\(question.prefix(30))...' on \(analysisToFollowUp?.analysisType.displayName ?? "new")")
        #endif

        isAnalyzing = true
        analysisResult = nil
        currentQuestion = question

        // Keep current analysis type for UI
        if let analysis = analysisToFollowUp {
            currentAnalysisType = analysis.analysisType
        } else {
            currentAnalysisType = .customQuestion
        }

        // Build prior context from existing analysis
        // For comments: use prompt (user's comment text) since response is empty
        var priorAnalysisContext: (type: AnalysisType, result: String)?
        if let analysis = analysisToFollowUp {
            if analysis.analysisType == .comment {
                // Comments store user's text in prompt, response is empty
                priorAnalysisContext = (type: analysis.analysisType, result: analysis.prompt)
            } else {
                priorAnalysisContext = (type: analysis.analysisType, result: analysis.response)
            }
        }

        // Build conversation history from existing thread
        var history: [(question: String, answer: String)] = []
        if let thread = analysisToFollowUp?.thread {
            history = thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex }).map {
                (question: $0.question, answer: $0.answer)
            }
        }

        // Queue job synchronously - @MainActor class allows direct call without await
        // Job ID is returned immediately, no race condition with UI state
        let analysisToFollowUpId = analysisToFollowUp?.id
        let jobId = jobManager.queueAnalysis(
            type: .customQuestion,
            text: highlight.selectedText,
            context: highlight.fullContext,
            chapterContext: nil,
            question: question,
            history: history,
            priorAnalysisContext: priorAnalysisContext
        )
        activeJobId = jobId

        // Poll for streaming updates
        // Task inherits @MainActor context - state updates are automatic
        // Named task for Instruments debugging (matches ReaderViewModel pattern)
        // NOTE: Don't cancel previous Tasks - they must run to completion to save results
        Task(name: "LibraryFollowUp: [\(highlight.id.uuidString.prefix(8))]") {
            await pollFollowUpJob(jobId: jobId, question: question, analysisToFollowUpId: analysisToFollowUpId)
        }
    }

    /// Select an analysis for viewing
    func selectAnalysis(_ analysis: AIAnalysisModel) {
        selectedAnalysis = analysis
        currentAnalysisType = analysis.analysisType
        analysisResult = nil
        isAnalyzing = false

        // Update highlight color to match analysis type (only save if changed)
        if highlight.colorHex != analysis.analysisType.colorHex {
            highlight.colorHex = analysis.analysisType.colorHex
            try? modelContext.save()
        }
    }

    /// Delete an analysis
    func deleteAnalysis(_ analysis: AIAnalysisModel) {
        // Clear selection if deleting the selected one
        if selectedAnalysis?.id == analysis.id {
            selectedAnalysis = nil
            analysisResult = nil
        }

        // Remove from highlight
        highlight.analyses.removeAll { $0.id == analysis.id }
        modelContext.delete(analysis)
        try? modelContext.save()

        // If analyses remain, select most recent
        if let mostRecent = highlight.analyses.sorted(by: { $0.createdAt > $1.createdAt }).first {
            selectAnalysis(mostRecent)
        } else {
            // No analyses remain - reset to default yellow (matches ReaderViewModel behavior)
            highlight.colorHex = "#FFEB3B"
            try? modelContext.save()
        }
    }

    /// Returns to the analysis cards list from expanded analysis or streaming view.
    /// Called when user presses the Back button in HighlightDetailSheet.
    ///
    /// Unlike Reader's X button (protected by two-level gate: selectedHighlight + highlightToJobMap),
    /// Library has only one gate (activeJobId). Must clear it so background jobs
    /// save data but don't flip the UI back to analysis view.
    func returnToAnalysisList() {
        selectedAnalysis = nil
        currentAnalysisType = nil
        analysisResult = nil
        isAnalyzing = false
        currentQuestion = ""
        activeJobId = nil

        #if DEBUG
        print("[HighlightAnalysisManager] Returned to analysis list")
        #endif
    }

    /// Prepares UI state for a new custom question thread
    /// Called when user clicks "Ask Question" button to start a fresh question
    ///
    /// Key behaviors:
    /// 1. Clears current analysis display (so streaming from other jobs doesn't show)
    /// 2. Clears activeJobId (stops ongoing job from updating UI)
    /// 3. Sets currentAnalysisType to .customQuestion (for UI indicators)
    ///
    /// The ongoing job will still complete and save in the background,
    /// but won't affect the UI (user is focused on new question).
    /// This enables parallel job support matching ReaderViewModel's behavior.
    func prepareForNewCustomQuestion() {
        selectedAnalysis = nil
        currentAnalysisType = .customQuestion
        analysisResult = nil
        isAnalyzing = false
        currentQuestion = ""

        // Clear active job so ongoing job doesn't update UI
        // Job will still complete and save in background
        activeJobId = nil

        #if DEBUG
        print("[HighlightAnalysisManager] Prepared for new custom question")
        #endif
    }

    // MARK: - Private Helpers

    private func pollJob(jobId: UUID, type: AnalysisType, question: String?) async {
        // Single cleanup point: defer ensures job memory is freed on ANY exit path
        defer { jobManager.clearJob(jobId) }

        // Poll until job reaches terminal state (.completed / .error)
        // WARNING: Do NOT cancel polling tasks - the save guarantee below MUST execute.
        // Cancelling would exit the loop → defer { clearJob } removes the job → API result lost.
        // The activeJobId check handles UI isolation without cancellation.
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))  // Smoother streaming updates

            // Synchronous call - no await needed (both are @MainActor)
            guard let job = jobManager.getJob(jobId) else { break }

            // NOTE: Don't break if not active - job should still complete and save
            // Only skip UI updates for non-active jobs

            switch job.status {
            case .streaming:
                // Only update UI if this is the active job
                if activeJobId == jobId && !job.streamingResult.isEmpty {
                    analysisResult = job.streamingResult
                }
            case .completed:
                let isActiveJob = activeJobId == jobId

                if let result = job.result {
                    // Only update UI if this is the active job
                    if isActiveJob {
                        analysisResult = result
                        isAnalyzing = false
                    }

                    // ALWAYS save, regardless of active status - API tokens were spent
                    saveAnalysis(type: type, prompt: question ?? highlight.selectedText, response: result, isActiveJob: isActiveJob, modelId: job.modelId, usedWebSearch: job.webSearchEnabled)
                }

                // Only clear activeJobId if this is still the tracked job
                if isActiveJob {
                    activeJobId = nil
                }
                return
            case .error:
                let isActiveJob = activeJobId == jobId
                // Only show error if this is the active job
                if isActiveJob {
                    analysisResult = "Error: \(job.error?.localizedDescription ?? "Unknown error")"
                    isAnalyzing = false
                    activeJobId = nil
                }
                return
            case .queued, .running:
                continue
            }
        }
    }

    private func pollFollowUpJob(jobId: UUID, question: String, analysisToFollowUpId: UUID?) async {
        // Single cleanup point: defer ensures job memory is freed on ANY exit path
        defer { jobManager.clearJob(jobId) }

        // Poll until job reaches terminal state (.completed / .error)
        // WARNING: Do NOT cancel polling tasks - the save guarantee below MUST execute.
        // Cancelling would exit the loop → defer { clearJob } removes the job → API result lost.
        // The activeJobId check handles UI isolation without cancellation.
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))  // Smoother streaming updates

            // Synchronous call - no await needed (both are @MainActor)
            guard let job = jobManager.getJob(jobId) else { break }

            // NOTE: Don't break if not active - job should still complete and save
            // Only skip UI updates for non-active jobs

            switch job.status {
            case .streaming:
                // Only update UI if this is the active job
                if activeJobId == jobId && !job.streamingResult.isEmpty {
                    analysisResult = job.streamingResult
                }
            case .completed:
                let isActiveJob = activeJobId == jobId

                if let result = job.result {
                    // Only update UI if this is the active job
                    if isActiveJob {
                        analysisResult = result
                        isAnalyzing = false
                        currentQuestion = ""
                    }

                    // ALWAYS save, regardless of active status - API tokens were spent
                    // Look up fresh analysis using captured ID
                    if let analysisId = analysisToFollowUpId {
                        // Analysis was selected - try to find it (might have been deleted)
                        if let analysis = highlight.analyses.first(where: { $0.id == analysisId }) {
                            // Add turn to existing analysis thread
                            addTurnToThread(analysis: analysis, question: question, answer: result)
                            // Only update selectedAnalysis if active
                            if isActiveJob {
                                selectedAnalysis = analysis
                            }
                        }
                        // If analysis was deleted during streaming, silently ignore
                    } else {
                        // No analysis was selected - create new custom question analysis
                        saveAnalysis(type: .customQuestion, prompt: question, response: result, isActiveJob: isActiveJob, modelId: job.modelId, usedWebSearch: job.webSearchEnabled)
                    }
                }

                // Only clear activeJobId if this is still the tracked job
                if isActiveJob {
                    activeJobId = nil
                }
                return
            case .error:
                let isActiveJob = activeJobId == jobId
                // Only show error if this is the active job
                if isActiveJob {
                    analysisResult = "Error: \(job.error?.localizedDescription ?? "Unknown error")"
                    isAnalyzing = false
                    activeJobId = nil
                    currentQuestion = ""
                }
                return
            case .queued, .running:
                continue
            }
        }
    }

    private func saveAnalysis(type: AnalysisType, prompt: String, response: String, isActiveJob: Bool = true, modelId: String, usedWebSearch: Bool) {
        let analysis = AIAnalysisModel(
            analysisType: type,
            prompt: prompt,
            response: response,
            modelUsed: modelId,
            usedWebSearch: usedWebSearch
        )

        analysis.highlight = highlight
        highlight.analyses.append(analysis)

        // Only update highlight color for the active job (user's current intent)
        // A background Fact Check completing should not overwrite Discussion's color
        if isActiveJob {
            highlight.colorHex = type.colorHex
        }

        modelContext.insert(analysis)
        try? modelContext.save()

        // Set selectedAnalysis after save - only for active job
        if isActiveJob {
            selectedAnalysis = analysis
        }

        #if DEBUG
        print("[HighlightAnalysisManager] SAVED: \(type.displayName) id=\(analysis.id.uuidString.prefix(8)) isActiveJob=\(isActiveJob)")
        #endif
    }

    private func addTurnToThread(analysis: AIAnalysisModel, question: String, answer: String) {
        // Safety check: verify analysis still exists in highlight's analyses
        // It might have been deleted via X button while job was running
        guard highlight.analyses.contains(where: { $0.id == analysis.id }) else {
            #if DEBUG
            print("[HighlightAnalysisManager] SKIPPED: Analysis was deleted during job")
            #endif
            return
        }

        // Check for duplicate
        if let existingTurns = analysis.thread?.turns,
           existingTurns.contains(where: { $0.question == question && $0.answer == answer }) {
            #if DEBUG
            print("[HighlightAnalysisManager] SKIPPED: Duplicate turn")
            #endif
            return
        }

        // Create thread if needed
        if analysis.thread == nil {
            let thread = AnalysisThreadModel()
            thread.analysis = analysis
            analysis.thread = thread
            modelContext.insert(thread)
        }

        // Add turn
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

        #if DEBUG
        print("[HighlightAnalysisManager] ADDED TURN: index=\(turnIndex)")
        #endif
    }
}
