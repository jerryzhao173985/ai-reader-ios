# Bug Investigation: Stale `selectedAnalysis` in `selectHighlight()` Active Job Branch

**Date:** 2026-01-23
**Severity:** High (UI/UX corruption, data context mismatch)
**Status:** Fixed and Verified

---

## Executive Summary

The `selectHighlight()` function's active job branch updated only 2 of 4 related state variables, violating the atomic state transition principle documented in `thread-per-analysis-architecture.md`. This caused stale `selectedAnalysis` from a previously viewed highlight to persist, resulting in the UI displaying the wrong analysis conversation context mixed with the current highlight's streaming content.

---

## Bug Description

### Location
`ReaderViewModel.swift:911-927` — `selectHighlight()` active job branch

### Symptom
When user navigates: Highlight A (streaming) → Highlight B → back to Highlight A, the UI shows:
- Highlight A selected (correct)
- Highlight A's streaming content (correct)
- **Highlight B's conversation context** (WRONG)

### Root Cause
Incomplete state transition in the active job branch:

```swift
// BEFORE FIX (lines 911-922)
if let activeJobId = highlightToJobMap[targetId],
   let job = analysisJobManager.getJob(activeJobId) {
    isAnalyzing = (job.status == .streaming || job.status == .queued || job.status == .running)
    if !job.streamingResult.isEmpty {
        analysisResult = job.streamingResult
    } else if let result = job.result {
        analysisResult = result
    } else {
        analysisResult = nil
    }
    // MISSING: selectedAnalysis = nil
    // MISSING: currentAnalysisType = nil
}
```

---

## State Machine Analysis

### Key State Variables

| Variable | Purpose |
|----------|---------|
| `selectedHighlight` | Currently selected highlight in WKWebView |
| `selectedAnalysis` | Analysis being viewed for conversation display |
| `currentAnalysisType` | Type label for streaming/display |
| `isAnalyzing` | Whether an API call is in progress |
| `analysisResult` | Streaming/completed response text |

### Logical States

| State | selectedAnalysis | currentAnalysisType | isAnalyzing |
|-------|-----------------|---------------------|-------------|
| IDLE | nil | nil | false |
| ANALYZING_NEW | nil | type | true |
| VIEWING_ANALYSIS | analysis | type | false |
| FOLLOW_UP_STREAMING | analysis | type | true |

### The Bug: Invalid State Combination

```
User action: Tap Highlight A (with active streaming job)
Expected state: ANALYZING_NEW (nil, nil, true)
Actual state: (B's analysis, B's type, true) ← INVALID
```

---

## UI Impact Analysis

### AnalysisPanelView Decision Tree (`AnalysisPanelView.swift:215-279`)

```swift
if let analysis = viewModel.selectedAnalysis {        // ← Branch 1
    if analysis.thread != nil || viewModel.isAnalyzing {
        analysisConversationView(analysis)            // Shows analysis's conversation
    } else {
        resultView(analysis.response)
    }
} else if viewModel.isAnalyzing {                     // ← Branch 2
    streamingLoadingView                              // Shows streaming content
}
```

### Bug Behavior

| State | Branch Taken | UI Shows |
|-------|--------------|----------|
| Without fix: `selectedAnalysis=B, isAnalyzing=true` | Branch 1 | B's conversation + A's streaming at bottom |
| With fix: `selectedAnalysis=nil, isAnalyzing=true` | Branch 2 | A's streaming content only |

### Visual Corruption Example

Without fix, `analysisConversationView(B's analysis)` renders:
```
[Fact Check]                    ← B's type header
B's initial response            ← WRONG
--- Follow-ups ---
B's follow-up Q1               ← WRONG
B's follow-up A1               ← WRONG
[User's streaming question]     ← Confusing context
[A's streaming response...]     ← Correct but misplaced
```

---

## Investigation Methodology

### 1. State Variable Audit

Grep for all modification points:
```bash
grep -n "selectedAnalysis\|currentAnalysisType\|isAnalyzing" ReaderViewModel.swift
```

Identified 16 modification points across 6 functions.

### 2. Modification Point Verification

| Location | Variables Updated | Complete? |
|----------|------------------|-----------|
| goToChapter() L194-196 | all 3 | ✅ |
| deselectCurrentHighlight() L364-366 | all 3 | ✅ |
| X button (AnalysisPanelView) L74-76 | all 3 | ✅ |
| performAnalysis() START L461-467 | all 3 | ✅ |
| askFollowUpQuestion() START L673-682 | 2 (keeps selectedAnalysis intentionally) | ✅ |
| Card tap L487-490 | all 3 | ✅ |
| selectHighlight() no job L932-941 | all 3 | ✅ |
| **selectHighlight() active job L911-922** | **2 of 4** | **❌ BUG** |

### 3. highlightToJobMap Usage Audit

Verified all 11 usages of `highlightToJobMap`:
- 2 insertions (job start)
- 4 guard conditions (within polling loops)
- 4 cleanup operations (job completion/error)
- 1 branch condition (`selectHighlight()` — the bug location)

Only `selectHighlight()` uses the map to branch into different behavior. No similar bugs exist.

### 4. Documentation Cross-Reference

`thread-per-analysis-architecture.md` Section 4.4 "Incomplete State Cleanup" (L531-549) explicitly warns:
```swift
// ❌ WRONG - Missing states
func goToChapter() {
    selectedHighlight = nil
    // Missing: selectedAnalysis, isAnalyzing, customQuestion
}
```

The bug is a direct violation of this documented principle.

---

## The Fix

### Code Change (`ReaderViewModel.swift:923-927`)

```swift
if let activeJobId = highlightToJobMap[targetId],
   let job = analysisJobManager.getJob(activeJobId) {
    isAnalyzing = (job.status == .streaming || job.status == .queued || job.status == .running)
    if !job.streamingResult.isEmpty {
        analysisResult = job.streamingResult
    } else if let result = job.result {
        analysisResult = result
    } else {
        analysisResult = nil
    }
    // ADDED: Clear stale selectedAnalysis from previous highlight
    // During active streaming, UI shows streaming view (not conversation view)
    // When job completes, saveAnalysis() will set selectedAnalysis appropriately
    selectedAnalysis = nil
    currentAnalysisType = nil
}
```

### Why `currentAnalysisType = nil`?

The `Job` struct doesn't store analysis type. During the brief streaming period after navigation, no type label shows. This is acceptable because:
1. Streaming content IS visible
2. "Analyzing..." indicator shows progress
3. On completion, `saveAnalysis()` sets `selectedAnalysis` with correct type
4. No incorrect/stale information displayed

### Completion Flow Verification

When job completes, `saveAnalysis()` at L571-579:
```swift
let userHasNotExplicitlySelectedAnother = selectedAnalysis == nil  // TRUE (cleared by fix)
if selectedHighlight?.id == highlight.id &&    // TRUE (A selected)
   isActiveJob &&                               // TRUE (this job)
   userHasNotExplicitlySelectedAnother {        // TRUE
    selectedAnalysis = analysis                 // Sets to A's new analysis ✅
}
```

---

## Why This Bug Was Missed

### 1. Missing Test Scenario

`thread-per-analysis-architecture.md` Testing Scenarios (L593-628) covers 5 scenarios but not:

**Scenario 6: Highlight Switch During Streaming**
1. Create Highlight A, start Fact Check → streaming
2. Tap on existing Highlight B → view B's analysis
3. Tap back on Highlight A (still streaming)
4. Verify: UI shows A's streaming, not B's conversation

### 2. Rare Edge Case

The active job branch only executes when:
- User taps a highlight
- That highlight has an entry in `highlightToJobMap`
- The job is still running/streaming

This requires: start analysis → navigate away → return before completion.

### 3. Partial Correctness Masked the Bug

The branch correctly set `isAnalyzing` and `analysisResult`, so streaming appeared to work. The conversation context corruption was subtle and required specific navigation patterns.

---

## Lessons Learned

### 1. Atomic State Transitions

When multiple state variables represent a "logical state", update them together:

```swift
// Pattern: Entering ANALYZING_NEW state
isAnalyzing = true
currentAnalysisType = type  // or nil if unknown
analysisResult = streamingContent
selectedAnalysis = nil      // ← Don't forget!
```

### 2. Branch Coverage for State Machines

Every branch that changes behavior must be audited for complete state updates:

```swift
if condition {
    // Branch A: Must set ALL related state variables
} else {
    // Branch B: Must set ALL related state variables
}
```

### 3. Documentation as Verification Tool

The architecture doc's "Common Pitfalls" section caught this bug pattern. Always cross-reference implementation against documented principles.

---

## Prevention Strategies

### 1. State Transition Functions

Consider centralizing state transitions:

```swift
private func enterAnalyzingNewState(streamingResult: String?) {
    isAnalyzing = true
    analysisResult = streamingResult
    selectedAnalysis = nil
    currentAnalysisType = nil
}

private func enterViewingAnalysisState(_ analysis: AIAnalysisModel) {
    isAnalyzing = false
    analysisResult = analysis.response
    selectedAnalysis = analysis
    currentAnalysisType = analysis.analysisType
}
```

### 2. Add Missing Test Scenario

Add to testing matrix:

```swift
// Test: Highlight Switch During Streaming
func testHighlightSwitchDuringStreaming() {
    // 1. Create highlight A, start analysis
    // 2. While streaming, tap highlight B
    // 3. Verify selectedAnalysis = B's analysis
    // 4. Tap back to highlight A (still streaming)
    // 5. Verify selectedAnalysis = nil (not B's stale value)
    // 6. Verify UI shows streaming view, not conversation view
}
```

### 3. State Consistency Assertions

In DEBUG builds, assert state consistency:

```swift
#if DEBUG
func assertStateConsistency() {
    if isAnalyzing && selectedAnalysis != nil {
        // Valid only during follow-up streaming
        assert(selectedHighlight?.analyses.contains(where: { $0.id == selectedAnalysis?.id }) == true,
               "selectedAnalysis must belong to selectedHighlight during streaming")
    }
}
#endif
```

---

## Files Reference

| File | Relevant Lines | Purpose |
|------|---------------|---------|
| `ReaderViewModel.swift` | 911-946 | `selectHighlight()` — bug location |
| `ReaderViewModel.swift` | 454-546 | `performAnalysis()` — reference implementation |
| `ReaderViewModel.swift` | 663-861 | `askFollowUpQuestion()` — follow-up flow |
| `AnalysisPanelView.swift` | 215-279 | UI decision tree |
| `AnalysisPanelView.swift` | 336-413 | `analysisConversationView()` |
| `thread-per-analysis-architecture.md` | 277-296 | State cleanup symmetry principle |
| `thread-per-analysis-architecture.md` | 531-549 | Incomplete cleanup pitfall warning |

---

## Verification Checklist

- [x] Bug reproduced and understood
- [x] Root cause identified (incomplete state transition)
- [x] All 16 state modification points audited
- [x] No similar bugs in other code paths
- [x] Fix aligns with documented architecture principles
- [x] Completion flow verified (saveAnalysis sets correct state)
- [x] Build succeeds
- [x] UI decision tree paths verified
