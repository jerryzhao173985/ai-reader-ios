// HighlightAnalysisManager.swift
// Standalone manager for highlight analysis operations
//
// Enables analysis features (new analysis, follow-ups, streaming) outside reader context.
// Used by HighlightDetailSheet in HighlightsView for library-based analysis.

import Foundation
import SwiftData

/// Manages AI analysis operations for a single highlight
/// Works independently of ReaderViewModel - can be used in any context (Library, Reader, etc.)
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

        let jobId = jobManager.queueAnalysis(
            type: type,
            text: highlight.selectedText,
            context: highlight.fullContext,
            chapterContext: nil,  // No chapter context in library view
            question: question
        )

        activeJobId = jobId

        // Poll for streaming updates
        pollJob(jobId: jobId, type: type, question: question)
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
        var priorAnalysisContext: (type: AnalysisType, result: String)?
        if let analysis = analysisToFollowUp {
            priorAnalysisContext = (type: analysis.analysisType, result: analysis.response)
        }

        // Build conversation history from existing thread
        var history: [(question: String, answer: String)] = []
        if let thread = analysisToFollowUp?.thread {
            history = thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex }).map {
                (question: $0.question, answer: $0.answer)
            }
        }

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
        pollFollowUpJob(jobId: jobId, question: question, analysisToFollowUp: analysisToFollowUp)
    }

    /// Select an analysis for viewing
    func selectAnalysis(_ analysis: AIAnalysisModel) {
        selectedAnalysis = analysis
        currentAnalysisType = analysis.analysisType
        analysisResult = nil
        isAnalyzing = false

        // Update highlight color to match analysis type
        highlight.colorHex = analysis.analysisType.colorHex
        try? modelContext.save()
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
        }
    }

    // MARK: - Private Helpers

    private func pollJob(jobId: UUID, type: AnalysisType, question: String?) {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 50_000_000)  // 0.05s

                guard let job = jobManager.getJob(jobId) else { break }
                guard activeJobId == jobId else { break }  // Job was superseded

                switch job.status {
                case .streaming:
                    await MainActor.run {
                        if !job.streamingResult.isEmpty {
                            analysisResult = job.streamingResult
                        }
                    }
                case .completed:
                    await MainActor.run {
                        if let result = job.result {
                            analysisResult = result
                            isAnalyzing = false
                            saveAnalysis(type: type, prompt: question ?? highlight.selectedText, response: result)
                        }
                        activeJobId = nil
                    }
                    return
                case .error:
                    await MainActor.run {
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
    }

    private func pollFollowUpJob(jobId: UUID, question: String, analysisToFollowUp: AIAnalysisModel?) {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 50_000_000)

                guard let job = jobManager.getJob(jobId) else { break }
                guard activeJobId == jobId else { break }

                switch job.status {
                case .streaming:
                    await MainActor.run {
                        if !job.streamingResult.isEmpty {
                            analysisResult = job.streamingResult
                        }
                    }
                case .completed:
                    await MainActor.run {
                        if let result = job.result {
                            analysisResult = result
                            isAnalyzing = false

                            if let analysis = analysisToFollowUp {
                                // Add turn to existing analysis thread
                                addTurnToThread(analysis: analysis, question: question, answer: result)
                                selectedAnalysis = analysis
                            } else {
                                // Create new custom question analysis
                                saveAnalysis(type: .customQuestion, prompt: question, response: result)
                            }
                        }
                        activeJobId = nil
                        currentQuestion = ""
                    }
                    return
                case .error:
                    await MainActor.run {
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
    }

    private func saveAnalysis(type: AnalysisType, prompt: String, response: String) {
        let analysis = AIAnalysisModel(
            analysisType: type,
            prompt: prompt,
            response: response
        )

        analysis.highlight = highlight
        highlight.analyses.append(analysis)
        highlight.colorHex = type.colorHex

        modelContext.insert(analysis)
        try? modelContext.save()

        selectedAnalysis = analysis

        #if DEBUG
        print("[HighlightAnalysisManager] SAVED: \(type.displayName) id=\(analysis.id.uuidString.prefix(8))")
        #endif
    }

    private func addTurnToThread(analysis: AIAnalysisModel, question: String, answer: String) {
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
