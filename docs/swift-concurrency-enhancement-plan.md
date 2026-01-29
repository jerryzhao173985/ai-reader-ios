# Swift Concurrency Enhancement Plan

## Executive Summary

With `@MainActor` migration complete, the codebase is now positioned to leverage Swift Concurrency features that were previously unsafe or impossible. This plan outlines **practical, user-facing improvements** grounded in the core reading and AI analysis experience.

---

## Current State (Completed)

| Component | Status | Benefit |
|-----------|--------|---------|
| `@MainActor` on ViewModels | Done | Compiler-enforced thread safety |
| Timer callback fix | Done | Eliminated latent data race |
| Memory leak fix (`defer`) | Done | Proper job cleanup |
| Synchronous call sites | Done | Cleaner code, no `await` from UI |

---

## Enhancement Tiers

### Tier 1: Essential (High User Value, Low Effort)

#### 1.1 Task Cancellation on Navigation

**Problem:** When user closes book or navigates away during streaming analysis, the API call continues wastefully.

**Solution:** Use `Task` handles with cancellation.

```swift
// Current: Fire and forget
Task {
    defer { analysisJobManager.clearJob(jobId) }
    // ... polling loop
}

// Enhanced: Cancellable
private var activePollingTasks: [UUID: Task<Void, Never>] = [:]

let task = Task {
    defer { analysisJobManager.clearJob(jobId) }
    while !Task.isCancelled {
        // ... polling loop
    }
}
activePollingTasks[jobId] = task

// On cleanup (book close, highlight delete):
func cancelAnalysis(for highlightId: UUID) {
    if let jobId = highlightToJobMap[highlightId],
       let task = activePollingTasks[jobId] {
        task.cancel()
        activePollingTasks.removeValue(forKey: jobId)
    }
}
```

**User Benefit:**
- Saves API costs when user abandons analysis
- Faster cleanup when navigating away
- More responsive app behavior

**Effort:** Low (add task tracking + cancellation checks)

---

#### 1.2 Graceful Streaming Interruption

**Problem:** When user starts new analysis on same highlight, old streaming continues until completion.

**Solution:** Cancel previous task before starting new one.

```swift
func performAnalysis(type: AnalysisType, ...) {
    // Cancel any existing analysis for this highlight
    if let existingJobId = highlightToJobMap[highlightId] {
        activePollingTasks[existingJobId]?.cancel()
        analysisJobManager.clearJob(existingJobId)
    }

    // Start new analysis
    let jobId = analysisJobManager.queueAnalysis(...)
    // ...
}
```

**User Benefit:**
- Cleaner UX when changing analysis type mid-stream
- No "ghost" streaming from abandoned analyses
- Predictable behavior

**Effort:** Low (leverage existing infrastructure)

---

### Tier 2: Enhanced (Medium User Value, Medium Effort)

#### 2.1 Batch Analysis with TaskGroup

**Problem:** User wants to run multiple analysis types on same highlight simultaneously.

**Solution:** Use `TaskGroup` for parallel execution with proper coordination.

```swift
func performBatchAnalysis(types: [AnalysisType], on highlight: HighlightModel) async {
    await withTaskGroup(of: (AnalysisType, String?).self) { group in
        for type in types {
            group.addTask {
                let result = await self.runSingleAnalysis(type: type, highlight: highlight)
                return (type, result)
            }
        }

        for await (type, result) in group {
            if let result = result {
                await MainActor.run {
                    saveAnalysis(to: highlight, type: type, result: result)
                }
            }
        }
    }
}
```

**User Benefit:**
- "Analyze All" button: Run Fact Check + Key Points + Discussion at once
- Time savings: 3 analyses in ~1.5x time of 1 (parallel API calls)
- Comprehensive highlight understanding in one action

**Effort:** Medium (new UI + batch coordination)

---

#### 2.2 Background Analysis Continuation

**Problem:** When user switches chapters during analysis, job completes but UI doesn't show result until user returns.

**Current Behavior:** Job saves to SwiftData, but user doesn't know it completed.

**Solution:** Add notification system for background completions.

```swift
// In polling loop completion
if !isActiveJob {
    // Job completed in background
    NotificationCenter.default.post(
        name: .analysisCompletedInBackground,
        object: nil,
        userInfo: ["highlightId": highlightId, "type": type]
    )
}

// In UI: Show subtle indicator
.onReceive(NotificationCenter.default.publisher(for: .analysisCompletedInBackground)) { notification in
    showBackgroundCompletionBadge = true
}
```

**User Benefit:**
- User knows analysis completed while reading elsewhere
- No lost work feeling
- Seamless multi-tasking experience

**Effort:** Medium (notification infrastructure + UI indicators)

---

#### 2.3 Streaming Progress Indicators

**Problem:** During long analyses, user only sees streaming text. No indication of progress.

**Solution:** Track streaming metrics for progress estimation.

```swift
struct Job {
    // Existing fields...

    // Progress tracking
    var streamingStartTime: Date?
    var chunksReceived: Int = 0
    var estimatedProgress: Double {
        // Heuristic: Average analysis is ~500 tokens, ~100 chunks
        min(Double(chunksReceived) / 100.0, 0.95)
    }
}
```

**User Benefit:**
- Visual progress bar during analysis
- Estimated time remaining
- Less uncertainty during long analyses

**Effort:** Medium (tracking + UI component)

---

### Tier 3: Advanced (High User Value, Higher Effort)

#### 3.1 Smart Pre-fetching

**Problem:** User selects highlight, waits for analysis to start, then waits for streaming.

**Solution:** Pre-fetch likely analyses when highlight is selected.

```swift
func onHighlightSelected(_ highlight: HighlightModel) {
    selectedHighlight = highlight

    // If no analyses exist, pre-warm with most common type
    if highlight.analyses.isEmpty {
        Task(priority: .background) {
            // Pre-generate context, don't call API yet
            let _ = buildPrompt(type: .factCheck, text: highlight.selectedText, ...)
        }
    }
}
```

**User Benefit:**
- Faster perceived response time
- Context ready when user taps analysis type
- Smoother experience

**Effort:** Medium-High (careful resource management)

---

#### 3.2 Offline Queue with Retry

**Problem:** If network fails mid-analysis, job errors out and user must retry manually.

**Solution:** Add retry logic with exponential backoff.

```swift
private func runJobWithRetry(id: UUID, maxAttempts: Int = 3) async {
    var attempt = 0
    while attempt < maxAttempts {
        do {
            try await runJobStreaming(id: id)
            return // Success
        } catch {
            attempt += 1
            if attempt < maxAttempts {
                // Exponential backoff: 1s, 2s, 4s
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000)
            }
        }
    }
    // Mark as failed after all retries
    jobs[id]?.status = .error
    jobs[id]?.error = NetworkError.maxRetriesExceeded
}
```

**User Benefit:**
- Resilient to transient network issues
- Automatic recovery without user intervention
- Better experience on unstable connections

**Effort:** High (error handling, retry logic, state management)

---

#### 3.3 Concurrent Multi-Highlight Analysis

**Problem:** User wants to analyze multiple highlights across the book at once.

**Solution:** Extend batch analysis to work across highlights.

```swift
func analyzeMultipleHighlights(_ highlights: [HighlightModel], type: AnalysisType) async {
    // Rate limit: max 3 concurrent API calls
    await withTaskGroup(of: Void.self) { group in
        let semaphore = AsyncSemaphore(value: 3)

        for highlight in highlights {
            group.addTask {
                await semaphore.wait()
                defer { semaphore.signal() }

                await self.runSingleAnalysis(type: type, highlight: highlight)
            }
        }
    }
}
```

**User Benefit:**
- "Fact Check All Highlights" in chapter
- Bulk analysis for research workflows
- Significant time savings for heavy users

**Effort:** High (UI for selection, progress tracking, rate limiting)

---

## Implementation Priority Matrix

| Enhancement | User Value | Effort | Priority |
|-------------|------------|--------|----------|
| 1.1 Task Cancellation | High | Low | **P0** |
| 1.2 Graceful Interruption | High | Low | **P0** |
| 2.1 Batch Analysis | High | Medium | **P1** |
| 2.2 Background Notifications | Medium | Medium | **P1** |
| 2.3 Progress Indicators | Medium | Medium | **P2** |
| 3.1 Smart Pre-fetching | Medium | Medium-High | **P2** |
| 3.2 Retry Logic | Medium | High | **P3** |
| 3.3 Multi-Highlight Batch | High | High | **P3** |

---

## Recommended Implementation Order

### Phase 1: Foundation (This Week)
- [x] @MainActor migration (DONE)
- [x] Memory leak fix (DONE)
- [x] Timer fix (DONE)
- [ ] 1.1 Task Cancellation
- [ ] 1.2 Graceful Interruption

### Phase 2: Enhanced UX (Next Sprint)
- [ ] 2.1 Batch Analysis ("Analyze All" button)
- [ ] 2.2 Background Completion Notifications
- [ ] 2.3 Streaming Progress Indicators

### Phase 3: Power Features (Future)
- [ ] 3.1 Smart Pre-fetching
- [ ] 3.2 Retry Logic
- [ ] 3.3 Multi-Highlight Batch Analysis

---

## Technical Prerequisites

All enhancements leverage the `@MainActor` foundation:

```
@MainActor ReaderViewModel
    ├── Task handles (cancellable)
    ├── TaskGroup (batch operations)
    ├── AsyncSequence (streaming)
    └── Structured concurrency (lifecycle management)
```

Without explicit `@MainActor`, these patterns would require complex manual thread management and be error-prone.

---

## Success Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Analysis cancellation on nav | 0% (runs to completion) | 100% (cancelled) |
| API cost on abandoned analyses | ~$X/month wasted | Near zero |
| Multi-analysis time | 3x single | 1.5x single |
| Network failure recovery | Manual retry | Automatic |
| User-perceived responsiveness | Good | Excellent |

---

## Conclusion

The `@MainActor` migration is not the end goal - it's the **foundation** that enables these practical improvements. Each enhancement builds on the explicit concurrency model to deliver tangible user value:

1. **Faster**: Parallel execution, cancellation
2. **Smoother**: Progress indicators, graceful interruption
3. **Smarter**: Pre-fetching, background notifications
4. **Resilient**: Retry logic, offline queue

The investment in proper concurrency architecture pays dividends in every subsequent feature.
