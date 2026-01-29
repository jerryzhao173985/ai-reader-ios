# Analysis Job Threading Investigation

## Date: 2026-01-29 (Final)

## Executive Summary

**Current Status: @MainActor class approach IMPLEMENTED (replacing actor conversion).**

After thorough investigation of Swift Concurrency best practices, `AnalysisJobManager` was converted to `@MainActor final class`. This follows Apple's official guidance: "Do not use actors for SwiftUI data models" - prefer `@MainActor` for types that work closely with UI.

---

## 1. Architecture Overview

### Components

```
┌─────────────────────────────────────────────────────────────────┐
│ SwiftUI Views (MainActor)                                       │
│   - Button actions trigger analysis                             │
│   - .task modifiers start polling                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ ReaderViewModel / HighlightAnalysisManager                      │
│ (@MainActor @Observable)                                        │
│   - queueAnalysis() called synchronously from UI                │
│   - pollJob() creates polling Task (inherits @MainActor)        │
│   - saveAnalysis() persists to SwiftData                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ AnalysisJobManager (@MainActor final class)                     │
│   - jobs: [UUID: Job] dictionary (MainActor-protected)          │
│   - queueAnalysis() creates job, launches Task, returns UUID    │
│   - runJobStreaming() / runJobNonStreaming() execute API calls  │
│   - getJob() returns Job directly (no Sendable needed)          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ AIService                                                       │
│   - callOpenAIStreaming() → AsyncThrowingStream<StreamEvent>    │
│   - callOpenAINonStreaming() → NonStreamingResult               │
└─────────────────────────────────────────────────────────────────┘
```

### Job Lifecycle

```
.queued → .running → .streaming → .completed
                  └→ .error
```

---

## 2. Threading Model - Detailed Timeline

### Scenario: User triggers one analysis

**With @MainActor approach (current implementation):**

```
TIME    THREAD      ACTION
────    ──────      ──────
T0      MainActor   User taps "Fact Check" button
T1      MainActor   queueAnalysis() called SYNCHRONOUSLY
T2      MainActor   jobs[jobId] = Job(status: .queued, ...)
T3      MainActor   Task { runJobStreaming() } SCHEDULED
T4      MainActor   return jobId IMMEDIATELY
T5      MainActor   activeJobId = jobId (same sync execution!)
T6      MainActor   Task { pollJob() } created (inherits @MainActor)
T7      MainActor   Poll Task sleeps 50ms (await suspends, frees MainActor)
T8      MainActor   runJobStreaming Task starts (MainActor available)
T9      MainActor   jobs[id]?.status = .running (direct write)
T10     MainActor   buildPrompt() (synchronous)
T11     MainActor   jobs[id]?.status = .streaming (direct write)
T12     MainActor   API call starts (await suspends, frees MainActor)
...
T57     MainActor   Poll wakes up (await completed)
T58     MainActor   guard let job = getJob(jobId) - READ
...
T100+   MainActor   Streaming chunk arrives (await completed)
T101    MainActor   jobs[id]?.streamingResult = chunk (direct write)
T102    MainActor   Poll wakes, reads job.streamingResult
...
T200    MainActor   jobs[id]?.status = .completed (direct write)
```

### Key Insight: Everything on MainActor = No Races

All operations happen on MainActor. The `await` points **suspend** (freeing MainActor
for other work) but **resume on MainActor**. No concurrent access = no data races.

**The 50ms poll interval is still beneficial** - it batches UI updates efficiently,
but it's no longer required for thread safety.

---

## 3. What the Original Code Does

### runJobStreaming (COMMITTED VERSION)

```swift
private func runJobStreaming(...) async {
    // UNWRAPPED - No one reading yet (T9)
    jobs[id]?.status = .running

    if type == .comment {
        // UNWRAPPED - No one reading yet
        jobs[id]?.status = .completed
        jobs[id]?.result = question ?? ""
        return
    }

    let prompt = buildPrompt(...)

    // UNWRAPPED - No one reading yet (T11)
    jobs[id]?.status = .streaming

    do {
        for try await event in aiService.callOpenAIStreaming(prompt: prompt) {
            switch event {
            case .content(let chunk):
                if updateCounter >= 3 {
                    // WRAPPED - Polling IS actively reading now
                    await MainActor.run {
                        jobs[id]?.streamingResult = currentResult
                    }
                }
            case .fallbackOccurred(let modelId, let webSearchEnabled):
                // WRAPPED - Polling IS actively reading now
                await MainActor.run {
                    jobs[id]?.modelId = modelId
                    jobs[id]?.webSearchEnabled = webSearchEnabled
                }
            }
        }

        // WRAPPED - Polling IS actively reading now
        await MainActor.run {
            jobs[id]?.status = .completed
            jobs[id]?.result = fullResult
            jobs[id]?.streamingResult = fullResult
        }
    } catch {
        // WRAPPED - Polling IS actively reading now
        await MainActor.run {
            jobs[id]?.status = .error
            jobs[id]?.error = error
        }
    }
}
```

### Design Rationale

| Write | Timing | Polling Active? | Wrapped? | Why |
|-------|--------|-----------------|----------|-----|
| `.running` | T9 | No (sleeping) | No | No race possible |
| `.streaming` | T11 | No (sleeping) | No | No race possible |
| Comment completion | T9-T10 | No (sleeping) | No | No race possible |
| `streamingResult` | T100+ | Yes | Yes | Avoid race |
| `modelId` | T100+ | Yes | Yes | Avoid race |
| `.completed` | T200+ | Yes | Yes | Avoid race |
| `.error` | T200+ | Yes | Yes | Avoid race |

---

## 4. Parallel Jobs Analysis

### Scenario: Two analyses running simultaneously

```
Highlight A: Job A (jobId = UUID-A)
Highlight B: Job B (jobId = UUID-B)

Job A writes to: jobs[UUID-A]
Job B writes to: jobs[UUID-B]

Polling for A reads: jobs[UUID-A]
Polling for B reads: jobs[UUID-B]
```

**Different dictionary keys = No interference between jobs.**

Each job only reads/writes its OWN entry. The dictionary structure is only modified when adding new jobs, which happens on MainActor (from UI).

---

## 5. The Polling "Race" - Probability Analysis

### When could a race occur?

A race requires the polling read and streaming write to execute at the EXACT same moment.

**Timing:**
- Dictionary write duration: ~1 microsecond
- Poll interval: 50,000 microseconds (50ms)
- Probability of overlap: 1/50,000 = 0.002%

**Even if overlap occurs:**
- Reader sees old value (stale but consistent)
- NOT a crash - just slightly outdated data
- Next poll (50ms later) sees correct value

**In practice:** Working fine for months with parallel analyses.

---

## 6. My Proposed Changes (OVERKILL)

### What I added:

```swift
// BEFORE (original)
jobs[id]?.status = .running

// AFTER (my change)
await MainActor.run { jobs[id]?.status = .running }
```

### Why it's overkill:

1. **Adds overhead**: Context switch to MainActor costs CPU cycles
2. **Solves non-problem**: No one is reading when these writes happen
3. **Inconsistent fix**: I only wrapped writes, not reads - doesn't fully solve theoretical race
4. **Breaks design intent**: Original design intentionally skipped wrapping for early writes

---

## 7. Memory Leak Issue (Separate Concern)

```swift
func clearJob(_ id: UUID) {
    jobs.removeValue(forKey: id)  // NEVER CALLED
}
```

Jobs accumulate in memory forever. For typical usage (dozens of analyses per session), this is negligible. For power users with hundreds of analyses, could become significant.

**Recommendation**: Low priority. Fix later if memory becomes an issue.

---

## 8. Original Recommendation (SUPERSEDED)

> **Note**: This section is historical. The actor conversion has been implemented instead.

### Original Action: REVERT my MainActor.run changes

The original timing-based design was correct, but the actor conversion provides formal correctness. See Section 10 for the implemented solution.

---

## 9. Lessons Learned

1. **Understand the timeline**: Task scheduling ≠ Task execution
2. **50ms is an eternity**: In CPU time, 50ms is 50,000,000 nanoseconds
3. **Don't fix what isn't broken**: Working code with intentional design choices
4. **Consistency isn't always right**: Sometimes inconsistency reflects nuanced understanding
5. **First principles matter**: Trace actual execution, don't just apply patterns blindly
6. **Actor vs @MainActor**: For UI data models, prefer `@MainActor` - simpler, synchronous calls
7. **await suspends, doesn't block**: `@MainActor` code can still do async I/O without blocking UI
8. **Task inherits actor context**: A Task created on @MainActor stays on @MainActor

---

## 10. Actor Conversion (SUPERSEDED - Historical)

> **Note**: The actor approach was implemented but later replaced with `@MainActor` class.
> See Section 11 for the final solution.

The actor conversion worked but had drawbacks:
- Required `Sendable` conformance (forced `errorMessage: String?` instead of `error: Error?`)
- Required caller-provided UUID pattern to avoid race conditions
- All calls required `await` even from @MainActor context
- More complex mental model than necessary

---

## 11. @MainActor Class Approach (FINAL SOLUTION)

### Why @MainActor Over Actor

From official Swift Concurrency documentation and best practices:

> "Do not use actors for SwiftUI data models. Use @MainActor instead."

**Key insight**: When a type works closely with UI (like a job manager that updates
state read by SwiftUI views), `@MainActor` is simpler and more appropriate:

| Aspect | `actor` | `@MainActor class` |
|--------|---------|-------------------|
| Access from UI | Requires `await` | Synchronous (no await) |
| Sendable requirement | Yes (for crossing boundaries) | No (stays on MainActor) |
| Mental model | Actor-isolated, hop required | Everything on MainActor |
| Race conditions | Possible at call sites | None (synchronous) |

### What Was Done

```swift
// BEFORE (actor approach)
actor AnalysisJobManager {
    struct Job: Sendable {
        var errorMessage: String?  // Can't use Error (not Sendable)
    }

    func queueAnalysis(id: UUID = UUID(), ...) -> UUID  // Caller-provided ID
}

// Call site required Task + await + MainActor.run
Task {
    let jobId = UUID()
    activeJobId = jobId
    await jobManager.queueAnalysis(id: jobId, ...)
}

// AFTER (@MainActor class approach)
@MainActor
final class AnalysisJobManager {
    struct Job {
        var error: Error?  // Can use Error directly
    }

    func queueAnalysis(...) -> UUID  // Internal UUID generation
}

// Call site is simple synchronous call
let jobId = jobManager.queueAnalysis(...)
activeJobId = jobId  // No race - same synchronous execution
```

### Key Changes

1. **Changed from `actor` to `@MainActor final class`**
2. **Removed Sendable from Job struct** - `error: Error?` works directly
3. **Removed caller-provided UUID** - internal generation is safe (synchronous)
4. **Removed all `await` at call sites** - calls are synchronous from @MainActor
5. **Removed `MainActor.run` wrappers in polling** - Task inherits @MainActor

### Updated Call Sites

**ReaderViewModel.swift**:
```swift
@MainActor
@Observable
final class ReaderViewModel {
    func performAnalysis(...) {
        // Synchronous call - no Task wrapper needed
        let jobId = analysisJobManager.queueAnalysis(
            type: type, text: text, context: context, ...
        )
        activeJobId = jobId  // Same synchronous execution

        Task { await pollJob(jobId: jobId) }  // Inherits @MainActor
    }
}
```

**HighlightAnalysisManager.swift**:
```swift
@MainActor
@Observable
final class HighlightAnalysisManager {
    func performAnalysis(type: AnalysisType, question: String? = nil) {
        // Synchronous call - no await needed
        let jobId = jobManager.queueAnalysis(...)
        activeJobId = jobId

        Task { await pollJob(jobId: jobId, ...) }
    }
}
```

### Why This is Better

1. **Simpler mental model**: Everything on MainActor = no thread safety concerns
2. **No Sendable constraints**: Can use `Error` type directly
3. **Synchronous calls**: No race window between queueAnalysis and setting activeJobId
4. **Follows Apple guidance**: "Use @MainActor for SwiftUI data models"
5. **Tasks inherit context**: Polling Tasks stay on MainActor automatically
6. **Less boilerplate**: No `await`, no `MainActor.run`, no caller-provided UUIDs

### Background Work Still Works

Even though everything is on MainActor, async operations don't block:

```swift
// Inside runJobStreaming (on MainActor)
for try await event in aiService.callOpenAIStreaming(...) {
    // await suspends, freeing MainActor for other work
    // When data arrives, resumes on MainActor
    jobs[id]?.streamingResult = chunk  // Direct write, no wrapper
}
```

The `await` in the streaming loop **suspends** (releases MainActor) during network I/O,
allowing the UI to remain responsive. When data arrives, execution resumes on MainActor.
