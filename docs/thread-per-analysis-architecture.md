# Thread-Per-Analysis Architecture

## Overview

Each AI analysis type (Fact Check, Discussion, Key Points, Custom Question, etc.) maintains its own independent conversation thread. Follow-up questions append to the thread of the analysis being viewed, not to a global queue.

```
Highlight
├── Analysis: Fact Check
│   ├── Initial: prompt="selected text", response="fact check result"
│   └── Thread
│       ├── Turn 0: "What sources support this?" → "According to..."
│       └── Turn 1: "Any counterarguments?" → "Critics argue..."
├── Analysis: Discussion
│   ├── Initial: prompt="selected text", response="discussion points"
│   └── Thread
│       └── Turn 0: "Expand on point 2" → "Point 2 relates to..."
└── Analysis: Custom Question
    ├── Initial: prompt="What does X mean?", response="X refers to..."
    └── Thread (empty - no follow-ups yet)
```

---

## Data Model

### SwiftData Entities

```swift
// HighlightModel.swift
@Model class HighlightModel {
    var selectedText: String
    var fullContext: String
    var chapterIndex: Int
    @Relationship(deleteRule: .cascade) var analyses: [AIAnalysisModel]
    // ...
}

// AIAnalysisModel.swift
@Model class AIAnalysisModel {
    var analysisType: AnalysisType      // .factCheck, .discussion, .customQuestion, etc.
    var prompt: String                   // Initial question or selected text
    var response: String                 // Initial AI response
    @Relationship(deleteRule: .cascade) var thread: AnalysisThreadModel?
    var highlight: HighlightModel?
    // ...
}

// AnalysisThreadModel.swift
@Model class AnalysisThreadModel {
    @Relationship(deleteRule: .cascade) var turns: [ConversationTurnModel]
    var analysis: AIAnalysisModel?
}

// ConversationTurnModel.swift
@Model class ConversationTurnModel {
    var turnIndex: Int
    var question: String
    var answer: String
    var thread: AnalysisThreadModel?
}
```

### Key Distinction

| Field | Purpose | Example |
|-------|---------|---------|
| `analysis.prompt` | Initial question/text | "The market crashed in 2008" |
| `analysis.response` | Initial AI response | "This refers to the financial crisis..." |
| `thread.turns` | Follow-up Q&A pairs | [("Why?", "Because..."), ("What then?", "Subsequently...")] |

---

## State Management

### ReaderViewModel Properties

```swift
// Selection State
var selectedHighlight: HighlightModel?    // Currently tapped highlight
var selectedText: String = ""             // Text being analyzed
var currentAnalysisType: AnalysisType?    // Type being displayed/streamed

// Analysis State
var isAnalyzing = false                   // API call in progress
var analysisResult: String?               // Current/streaming result
var selectedAnalysis: AIAnalysisModel?    // Analysis being viewed for conversation
var customQuestion: String = ""           // Current follow-up question text

// Job Tracking
var highlightToJobMap: [UUID: UUID] = [:] // highlightId → active jobId
```

### Two Distinct Actions

#### 1. `performAnalysis()` - New Analysis

```swift
func performAnalysis(type: AnalysisType, text: String, context: String, question: String? = nil) {
    guard let highlight = selectedHighlight else { return }

    isAnalyzing = true
    currentAnalysisType = type
    analysisResult = nil
    selectedAnalysis = nil  // ← CLEAR: Shows clean loading view

    let jobId = analysisJobManager.queueAnalysis(...)
    highlightToJobMap[highlight.id] = jobId
    // ... polling loop
}
```

**Why clear `selectedAnalysis`?** When user clicks "Key Points" while viewing "Discussion", we want a fresh loading view for Key Points—not Key Points streaming under Discussion's "Follow-ups" section.

#### 2. `askFollowUpQuestion()` - Follow-up on Existing Analysis

```swift
func askFollowUpQuestion(highlight: HighlightModel, question: String) {
    // CAPTURE at function START before any async work
    let analysisToFollowUp = selectedAnalysis

    isAnalyzing = true
    analysisResult = nil
    customQuestion = question  // Track for streaming display

    // DON'T clear selectedAnalysis - we're continuing a conversation

    // Build context from the analysis being followed up
    var priorAnalysisContext: (type: AnalysisType, result: String)?
    if let analysis = analysisToFollowUp {
        priorAnalysisContext = (type: analysis.analysisType, result: analysis.response)
    }

    let jobId = analysisJobManager.queueAnalysis(
        type: .customQuestion,
        // ...
        priorAnalysisContext: priorAnalysisContext
    )
    // ... polling loop
}
```

**Why capture `analysisToFollowUp` at START?** During async polling, user might tap a different analysis card. We must add the turn to the analysis that was viewed when they submitted the question, not whatever is selected when the API returns.

---

## Race Condition Guards

### The Problem

```
Timeline:
0ms   - User asks follow-up on Fact Check, Job A starts
100ms - User taps Discussion card (selectedAnalysis = Discussion)
500ms - User asks follow-up on Discussion, Job B starts
800ms - Job A completes → Should NOT overwrite Discussion's streaming state
1200ms - Job B completes → Should update Discussion
```

### The Solution: `highlightToJobMap`

```swift
var highlightToJobMap: [UUID: UUID] = [:]  // highlightId → jobId
```

**Critical insight:** This tracks ONE active job per HIGHLIGHT, not per analysis. When Job B starts on the same highlight, it overwrites Job A's entry.

```swift
// Job start
highlightToJobMap[highlight.id] = jobId

// Job completion - check if still active
let isActiveJob = highlightToJobMap[highlightId] == jobId
```

### Guard Hierarchy

```swift
case .completed:
    if let result = job.result {
        let isActiveJob = highlightToJobMap[highlightId] == jobId

        // 1. UI UPDATES: Guard with isActiveJob
        if selectedHighlight?.id == highlightId && isActiveJob {
            analysisResult = result
            isAnalyzing = false
        }

        // 2. DATA PERSISTENCE: ALWAYS happens (user data is sacred)
        if book.highlights.contains(where: { $0.id == highlightId }) {
            addTurnToThread(analysis: analysisToFollowUp, question: question, answer: result)

            // 3. selectedAnalysis UPDATE: Guard with isActiveJob AND user intent
            let userStillViewingSameAnalysis = selectedAnalysis?.id == analysis.id || selectedAnalysis == nil
            if selectedHighlight?.id == highlightId && isActiveJob && userStillViewingSameAnalysis {
                selectedAnalysis = analysis
            }
        }
    }

    // 4. JOB CLEANUP: Only if still the tracked job
    if highlightToJobMap[highlightId] == jobId {
        highlightToJobMap.removeValue(forKey: highlightId)
    }
```

### Why This Order Matters

| Step | Guarded By | Reason |
|------|------------|--------|
| UI updates | `isActiveJob` | Prevent older job from overwriting newer job's streaming |
| Data persistence | None | User data must ALWAYS save |
| `selectedAnalysis` | `isActiveJob` + `userStillViewing` | Respect explicit user card taps |
| Job cleanup | `map[id] == jobId` | Prevent earlier job from orphaning later job's entry |

---

## Duplicate Prevention

### The Problem

Double-tap on "Send" button could fire `askFollowUpQuestion()` twice with identical parameters, creating duplicate turns.

### Wrong Approach (What We Initially Tried)

```swift
// ❌ WRONG: Guarding addTurnToThread with isActiveJob
if isActiveJob {
    addTurnToThread(analysis: analysis, question: question, answer: result)
}
```

**Why wrong?** If user rapidly asks follow-ups on DIFFERENT analyses of the same highlight:
- Job A for Fact Check starts
- Job B for Discussion starts, overwrites `highlightToJobMap`
- Job A completes with `isActiveJob = false`
- Turn is NOT added → **Legitimate user data dropped!**

### Correct Approach: Content-Based Detection

```swift
private func addTurnToThread(analysis: AIAnalysisModel, question: String, answer: String) {
    // Check for duplicate turn (same question AND same answer already exists)
    if let existingTurns = analysis.thread?.turns,
       existingTurns.contains(where: { $0.question == question && $0.answer == answer }) {
        #if DEBUG
        print("[AddTurn] SKIPPED: Duplicate turn already exists")
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
    let turn = ConversationTurnModel(
        turnIndex: analysis.thread?.turns.count ?? 0,
        question: question,
        answer: answer
    )
    turn.thread = analysis.thread
    analysis.thread?.turns.append(turn)
    modelContext.insert(turn)
    try? modelContext.save()
}
```

**Why check both question AND answer?** The same question asked at different times could legitimately have different answers (updated information, different context).

---

## State Cleanup Symmetry

All deselection paths must clear the same state set:

```swift
// Pattern used in: X button, goToChapter(), deleteHighlight(), selectHighlight(nil)
selectedHighlight = nil
selectedText = ""
analysisResult = nil
currentAnalysisType = nil
selectedAnalysis = nil
isAnalyzing = false
customQuestion = ""
showingAnalysisPanel = false
```

**Why symmetric?** Inconsistent cleanup leads to stale state bugs:
- `isAnalyzing = true` with no job running → infinite loading spinner
- `selectedAnalysis` pointing to deleted analysis → crash on access
- `customQuestion` from previous highlight → confusing UI

---

## UI Components

### AnalysisPanelView Decision Tree

```swift
@ViewBuilder
private var currentAnalysisView: some View {
    if let analysis = viewModel.selectedAnalysis {
        if analysis.thread != nil || viewModel.isAnalyzing {
            // Has follow-ups or actively streaming
            analysisConversationView(analysis)
        } else {
            // No thread, not analyzing - just show result
            resultView(analysis.response)
        }
    } else if viewModel.isAnalyzing {
        // New analysis starting (no selectedAnalysis yet)
        streamingLoadingView
    } else if let result = viewModel.analysisResult {
        // Legacy path - plain result
        resultView(result)
    }
}
```

### Conversation View Structure

```swift
private func analysisConversationView(_ analysis: AIAnalysisModel) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        // Header
        Label(analysis.analysisType.displayName, systemImage: analysis.analysisType.iconName)

        // Initial content (differs by type)
        if analysis.analysisType == .customQuestion {
            userMessageBubble(analysis.prompt)   // "What does X mean?"
            aiMessageBubble(analysis.response)   // "X refers to..."
        } else {
            markdownText(analysis.response)      // Fact check / discussion result
        }

        // Follow-up turns
        if let thread = analysis.thread, !thread.turns.isEmpty {
            if analysis.analysisType != .customQuestion {
                followUpsDivider  // Visual separator for non-custom
            }
            ForEach(thread.turns.sorted(by: { $0.turnIndex < $1.turnIndex })) { turn in
                userMessageBubble(turn.question)
                aiMessageBubble(turn.answer)
            }
        }

        // Active streaming
        if viewModel.isAnalyzing {
            userMessageBubble(viewModel.customQuestion)
            if let streaming = viewModel.analysisResult, !streaming.isEmpty {
                aiMessageBubble(streaming, isStreaming: true)
            } else {
                thinkingBubble
            }
        }
    }
}
```

### Card Tap Handler

```swift
private func previousAnalysisCard(_ analysis: AIAnalysisModel) -> some View {
    Button {
        viewModel.currentAnalysisType = analysis.analysisType
        viewModel.analysisResult = analysis.response
        viewModel.selectedAnalysis = analysis  // ← Enables conversation view
        viewModel.isAnalyzing = false
    } label: {
        // Card content
    }
}
```

---

## API Context Flow

### AIService Integration

```swift
// ReaderViewModel.askFollowUpQuestion()
let jobId = analysisJobManager.queueAnalysis(
    type: .customQuestion,
    text: highlight.selectedText,
    context: highlight.fullContext,
    chapterContext: currentChapter?.plainText,
    question: question,
    history: history,                    // Previous turns in this thread
    priorAnalysisContext: priorAnalysisContext  // The analysis being followed up
)

// AnalysisJobManager.buildPrompt()
if let prior = priorAnalysisContext {
    prompt += """

    **Previous AI Analysis (\(prior.type.displayName)):**
    The user was viewing this analysis when they asked their question:
    \(prior.result)
    """
}
```

**Enables:** "The fact check mentioned regulatory changes—what were they specifically?"

---

## Component Interaction Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           ChapterContentView                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐     │
│  │  Text Selection │───▶│ Context Menu    │───▶│ Analysis Button │     │
│  └─────────────────┘    └─────────────────┘    └────────┬────────┘     │
│                                                          │              │
│  ┌─────────────────┐                                     │              │
│  │ Inline Marker   │◀────────────────────────────────────┘              │
│  │ [1] [2] [3]     │                                                    │
│  └────────┬────────┘                                                    │
│           │ onHighlightTapped                                           │
└───────────┼─────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           ReaderViewModel                                │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ State                                                            │   │
│  │ - selectedHighlight: HighlightModel?                             │   │
│  │ - selectedAnalysis: AIAnalysisModel?                             │   │
│  │ - highlightToJobMap: [UUID: UUID]                                │   │
│  │ - isAnalyzing, analysisResult, customQuestion                    │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐     │
│  │ performAnalysis │    │askFollowUpQuestion│   │ addTurnToThread │     │
│  │ clears          │    │ captures          │    │ duplicate check │     │
│  │ selectedAnalysis│    │ analysisToFollowUp│    │ content-based   │     │
│  └────────┬────────┘    └────────┬────────┘    └────────┬────────┘     │
│           │                       │                       │             │
│           └───────────────────────┼───────────────────────┘             │
│                                   │                                     │
│                                   ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ AnalysisJobManager                                               │   │
│  │ - queueAnalysis(priorAnalysisContext:)                           │   │
│  │ - Job polling with isActiveJob checks                            │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          AnalysisPanelView                               │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐     │
│  │ Analysis Cards  │───▶│ Card Tap        │───▶│ selectedAnalysis│     │
│  │ (horizontal     │    │ sets            │    │ = tapped card   │     │
│  │  scroll)        │    │ selectedAnalysis│    │                 │     │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘     │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ currentAnalysisView                                              │   │
│  │ - if selectedAnalysis.thread → analysisConversationView          │   │
│  │ - else if isAnalyzing → streamingLoadingView                     │   │
│  │ - else → resultView                                              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ followUpInputArea                                                │   │
│  │ - TextField → askFollowUpQuestion(highlight, question)           │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Common Pitfalls

### 1. Guarding Data Writes with Job Status

```swift
// ❌ WRONG
if isActiveJob {
    addTurnToThread(...)
}

// ✅ CORRECT
addTurnToThread(...)  // Always save
if isActiveJob && userStillViewing {
    selectedAnalysis = analysis  // Guard UI only
}
```

### 2. Capturing Context After Async

```swift
// ❌ WRONG
func askFollowUpQuestion() {
    Task {
        let result = await api.call()
        // selectedAnalysis may have changed during await!
        addTurnToThread(analysis: selectedAnalysis!, ...)
    }
}

// ✅ CORRECT
func askFollowUpQuestion() {
    let analysisToFollowUp = selectedAnalysis  // Capture at START
    Task {
        let result = await api.call()
        addTurnToThread(analysis: analysisToFollowUp!, ...)
    }
}
```

### 3. Conflating Highlight Jobs with Analysis Jobs

```swift
// The map tracks per-HIGHLIGHT, not per-analysis
highlightToJobMap[highlight.id] = jobId

// This means: rapid follow-ups on DIFFERENT analyses of the SAME highlight
// will have isActiveJob=false for earlier jobs
// Solution: isActiveJob guards UI, not data
```

### 4. Incomplete State Cleanup

```swift
// ❌ WRONG - Missing states
func goToChapter() {
    selectedHighlight = nil
    // Missing: selectedAnalysis, isAnalyzing, customQuestion
}

// ✅ CORRECT - Full cleanup
func goToChapter() {
    selectedHighlight = nil
    selectedText = ""
    analysisResult = nil
    currentAnalysisType = nil
    selectedAnalysis = nil
    isAnalyzing = false
    customQuestion = ""
}
```

---

## Debug Logging

Enable in DEBUG builds:

```swift
#if DEBUG
print("[Analysis] START: type=\(type.displayName) highlight=\(highlight.id.uuidString.prefix(8))")
print("[FollowUp] START: question='\(question.prefix(20))...' analysisToFollowUp=\(analysisToFollowUp?.analysisType.displayName ?? "nil")")
print("[SaveAnalysis] type=\(type.displayName) isActiveJob=\(isActiveJob) userHasNotSelected=\(userHasNotExplicitlySelectedAnother)")
print("[AddTurn] SKIPPED: Duplicate turn already exists")
print("[CardTap] Tapped \(analysis.analysisType.displayName) id=\(analysis.id.uuidString.prefix(8))")
#endif
```

### Log Interpretation

| Pattern | Meaning |
|---------|---------|
| `[Analysis] START` | New analysis type requested |
| `[FollowUp] START` | Follow-up question submitted |
| `isActiveJob=false` | Older job completed after newer job started |
| `userHasNotSelected=false` | User explicitly tapped a different card |
| `SKIPPED: Duplicate` | Double-tap protection triggered |

---

## File Reference

| File | Responsibility |
|------|----------------|
| `ReaderViewModel.swift:454-546` | `performAnalysis()` - new analysis flow |
| `ReaderViewModel.swift:661-861` | `askFollowUpQuestion()` - follow-up flow |
| `ReaderViewModel.swift:863-892` | `addTurnToThread()` - duplicate detection |
| `AnalysisPanelView.swift:210-280` | `currentAnalysisView` - display decision tree |
| `AnalysisPanelView.swift:330-425` | `analysisConversationView()` - thread display |
| `AIService.swift:758-792` | `priorAnalysisContext` prompt building |

---

## Testing Scenarios

### 1. Parallel Analysis Race

1. Select text, tap "Fact Check"
2. While streaming, tap "Discussion"
3. **Verify:** Discussion streams correctly, Fact Check saves to data

### 2. Rapid Follow-ups on Different Analyses

1. Create highlight with Fact Check and Discussion
2. View Fact Check, ask "Tell me more"
3. Immediately tap Discussion card
4. Ask "Expand on this"
5. **Verify:** Both turns save to correct threads

### 3. Double-tap Prevention

1. Create highlight with analysis
2. Type follow-up question
3. Rapidly double-tap Send
4. **Verify:** Only one turn created

### 4. Chapter Change Cleanup

1. Create highlight with ongoing analysis
2. Switch to different chapter
3. Return to original chapter
4. **Verify:** No stale loading states, analysis saved correctly

### 5. Card Tap During Streaming

1. Start new Fact Check analysis
2. While streaming, tap existing Discussion card
3. **Verify:** UI shows Discussion, Fact Check continues in background and saves
