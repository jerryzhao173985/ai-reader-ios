# Swift 6.2 Concurrency Usage & Migration Guide

## Date: 2026-01-30
## Status: Investigation Complete

---

## Executive Summary

This document captures a comprehensive analysis of Swift Concurrency patterns in the AIReaderApp codebase, reconciling findings from multiple expert reviews. The codebase demonstrates **sophisticated understanding of Swift Concurrency** with some areas requiring attention for Swift 6 strict concurrency compliance.

| Category | Status | Summary |
|----------|--------|---------|
| @MainActor Usage | ✅ Excellent | Correct annotation, proper Task inheritance |
| Sendable Conformance | ⚠️ Needs Work | Some types need explicit conformance |
| Task Cancellation | ⚠️ Partial | Signal-based works, but network not cancelled |
| AsyncThrowingStream | ⚠️ Missing Handler | No `onTermination` for consumer cancellation |
| DispatchQueue Legacy | ⚠️ 9 Instances | Need migration to Task pattern |
| Memory Management | ⚠️ Cleanup Needed | URLSession/Timer deinit missing |

---

## Part 1: Correct Patterns (No Changes Needed)

### 1.1 @MainActor for UI-Bound Classes

All ViewModels correctly use `@MainActor` before `@Observable`:

```swift
// ReaderViewModel.swift:18-20
@MainActor
@Observable
final class ReaderViewModel { ... }

// HighlightAnalysisManager.swift:12-14
@MainActor
@Observable
final class HighlightAnalysisManager { ... }

// LibraryViewModel.swift:10-12
@MainActor
@Observable
final class LibraryViewModel { ... }

// AIService.swift:1014-1015
@MainActor
final class AnalysisJobManager { ... }
```

**Why this is correct:**
- `@MainActor` ensures compiler-enforced thread safety
- Follows Apple's guidance: "Use @MainActor for SwiftUI data models, not actors"
- `final class` prevents subclassing that could break isolation guarantees

### 1.2 Task Inheritance from @MainActor

Tasks created inside @MainActor classes correctly inherit MainActor context:

```swift
// AIService.swift:1071-1098
@MainActor
func queueAnalysis(...) -> UUID {
    let jobId = UUID()
    jobs[jobId] = Job(...)  // Safe - synchronous on MainActor

    Task {
        // Task inherits @MainActor context automatically
        await runJobStreaming(id: jobId, ...)  // Safe state access
    }

    return jobId  // Returns immediately - no race condition
}
```

**Key insight:** The synchronous `queueAnalysis()` call eliminates the race window between job creation and tracking that would exist with an async call.

### 1.3 Sendable Types for Stream Communication

Types crossing isolation boundaries are correctly marked Sendable:

```swift
// AIService.swift:88-91
enum StreamEvent: Sendable {
    case content(String)
    case fallbackOccurred(modelId: String, webSearchEnabled: Bool)
}

// AIService.swift:96-100
struct NonStreamingResult: Sendable {
    let content: String
    let modelId: String
    let usedWebSearch: Bool
}

// EPUBParserService.swift:173-196
struct EPUBMetadata: Sendable { ... }
struct ManifestItem: Sendable { ... }
struct SpineItem: Sendable { ... }
```

### 1.4 Three-Layer Job Tracking Architecture

The job management system demonstrates excellent separation of concerns:

```swift
// ReaderViewModel.swift:107-117

/// UI layer: Maps highlight ID to its LATEST job ID for streaming display
private var highlightToJobMap: [UUID: UUID] = [:]

/// Ownership layer: Maps highlight ID to ALL its job IDs
private var highlightToJobIds: [UUID: Set<UUID>] = [:]

/// Cancellation layer: Set of job IDs that should stop processing
private var cancelledJobs: Set<UUID> = []
```

**Benefits:**
- Precise job-level cancellation (cancel one job, others continue)
- Parallel job support per highlight
- Clean separation: UI concerns vs ownership vs cancellation signals

### 1.5 defer-Based Job Cleanup

All exit paths are handled via defer:

```swift
// ReaderViewModel.swift:729-795
Task {
    defer { cleanupJob(jobId, forHighlight: highlightId) }

    while !cancelledJobs.contains(jobId) {
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard let job = analysisJobManager.getJob(jobId) else { break }

        switch job.status {
        case .completed:
            return  // defer runs
        case .error:
            return  // defer runs
        // ...
        }
    }
    // Loop exits → defer runs
}
```

**Verified exit paths:**
1. `.completed` → return → defer runs ✓
2. `.error` → return → defer runs ✓
3. Job not found (guard fails) → break → defer runs ✓
4. Cancellation signal (loop exits) → defer runs ✓

### 1.6 Timer Callback Pattern

Timer correctly hops to MainActor:

```swift
// ReaderViewModel.swift:390-394
undoTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
    Task { @MainActor in
        self?.deletedHighlightForUndo = nil
    }
}
```

**Why `Task { @MainActor in }` is required:**
- Timer callbacks run on RunLoop thread, NOT MainActor
- Even though class is @MainActor, timer closures don't inherit that context
- Explicit `@MainActor` annotation hops back to MainActor for state mutation

---

## Part 2: Issues Requiring Attention

### 2.1 [CRITICAL] AsyncThrowingStream Missing onTermination Handler

**Location:** `AIService.swift:395-597`

**Current Code:**
```swift
private func callResponsesAPIStreaming(prompt: String) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            // ... network operations ...
            for try await line in bytes.lines {
                continuation.yield(.content(delta))
            }
            continuation.finish()
        }
        // ← NO onTermination handler!
    }
}
```

**Problem:**
When consumer stops iterating (e.g., job cancelled), the internal Task continues running:
```swift
// In AnalysisJobManager
for try await event in aiService.callOpenAIStreaming(prompt: prompt) {
    if cancelledJobs.contains(jobId) { break }  // Consumer stops
}
// But network request continues! Wastes API costs.
```

**Impact:**
- API calls continue after cancellation (wasted cost)
- Network connections held open unnecessarily
- Battery drain on mobile device

**Fix Required:**
```swift
AsyncThrowingStream { continuation in
    let task = Task {
        defer { continuation.finish() }  // Guarantee finish

        for try await line in bytes.lines {
            guard !Task.isCancelled else { break }  // Check cancellation
            continuation.yield(.content(delta))
        }
    }

    continuation.onTermination = { @Sendable _ in
        task.cancel()  // Cancel network task when consumer stops
    }
}
```

---

### 2.2 [CRITICAL] DispatchQueue Legacy Usage (9 Instances)

**Locations:**

| File | Line | Usage |
|------|------|-------|
| ChapterContentView.swift | 63 | `asyncAfter` in onHighlightTapped |
| ChapterContentView.swift | 422 | `async` in onMarkerUpdateHandled |
| ChapterContentView.swift | 448 | `async` in onUndoRestoreHandled |
| ChapterContentView.swift | 455 | `async` in onMarkerUpdateHandled |
| ChapterContentView.swift | 482 | `async` in onUndoRestoreHandled |
| ChapterContentView.swift | 1224 | `asyncAfter` in scroll restoration |
| ChapterContentView.swift | 1259 | `async` in WKScriptMessage handler |
| ChapterContentView.swift | 1273 | `async` in WKScriptMessage handler |
| AnalysisPanelView.swift | 870 | `asyncAfter` in Button action |

**Why Migration Required:**
WKWebView delegate callbacks run on main **thread** but NOT in MainActor-isolated context. Swift 6 strict concurrency requires explicit isolation.

**Current Pattern (Legacy):**
```swift
DispatchQueue.main.async {
    self.parent.onHighlightTapped(highlight)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    viewModel.scrollToHighlightId = nil
}
```

**Swift 6 Pattern:**
```swift
// Immediate execution
Task { @MainActor in
    self.parent.onHighlightTapped(highlight)
}

// Delayed execution
Task { @MainActor in
    try? await Task.sleep(for: .milliseconds(500))
    viewModel.scrollToHighlightId = nil
}
```

---

### 2.3 [HIGH] AIService Non-Sendable Self Capture

**Location:** `AIService.swift:395-597`

**Problem:**
```swift
@Observable
final class AIService {  // NOT @MainActor, NOT Sendable
    private let config: AIConfiguration
    private let session: URLSession  // NOT Sendable

    func callResponsesAPIStreaming(...) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {  // @Sendable closure
                guard !config.apiKey.isEmpty else { ... }  // Captures self.config
                let (bytes, response) = try await session.bytes(for: request)  // Uses self.session
            }
        }
    }
}
```

**Swift 6 Impact:**
```
warning: capture of 'self' with non-sendable type 'AIService' in a `@Sendable` closure
```

**Fix Options:**

**Option A: Extract Sendable configuration before Task**
```swift
func callResponsesAPIStreaming(prompt: String) -> AsyncThrowingStream<StreamEvent, Error> {
    // Capture Sendable values BEFORE the @Sendable closure
    let apiKey = config.apiKey
    let endpoint = config.endpoint
    let model = config.model
    let maxInputChars = config.maxInputChars
    let sessionCopy = session  // URLSession is thread-safe for use

    return AsyncThrowingStream { continuation in
        Task {
            // Use captured values, not self
            guard !apiKey.isEmpty else {
                continuation.finish(throwing: AIError.noAPIKey)
                return
            }
            // ...
        }
    }
}
```

**Option B: Use @unchecked Sendable (if you accept responsibility)**
```swift
@Observable
final class AIService: @unchecked Sendable {
    // Developer takes responsibility for thread safety
    // Acceptable because config and session are effectively immutable after init
}
```

---

### 2.4 [HIGH] AIError Contains Non-Sendable Error

**Location:** `AIService.swift:110-130`

**Current Code:**
```swift
enum AIError: LocalizedError {
    case noAPIKey
    case networkError(Error)  // Error protocol is NOT Sendable
    case invalidResponse
    case apiError(String)
    case timeout
}
```

**Problem:**
`Error` protocol is not `Sendable`, making `AIError` itself non-Sendable.

**Fix:**
```swift
enum AIError: LocalizedError, Sendable {
    case noAPIKey
    case networkError(String)  // Store message, not Error
    case invalidResponse
    case apiError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        // ...
        }
    }
}

// When creating:
catch {
    throw AIError.networkError(error.localizedDescription)
}
```

---

### 2.5 [MEDIUM] Missing Explicit Sendable on Enums

**Locations:**
- `AnalysisType` in AIAnalysisModel.swift
- `AIProvider` in SettingsManager.swift
- `ReasoningEffort` in SettingsManager.swift
- `Theme` in SettingsManager.swift
- `FontFamily` in SettingsManager.swift

**Current:**
```swift
enum AnalysisType: String, Codable, CaseIterable, Identifiable {
    case factCheck = "fact_check"
    // ...
}
```

**Fix:**
```swift
enum AnalysisType: String, Codable, CaseIterable, Identifiable, Sendable {
    case factCheck = "fact_check"
    // ...
}
```

**Note:** These enums are implicitly Sendable (raw value enums with no associated values), but Swift 6 may require explicit conformance.

---

### 2.6 [MEDIUM] URLSession Not Invalidated

**Location:** `AIService.swift:134-141`

**Current Code:**
```swift
init(configuration: AIConfiguration = .default) {
    self.config = configuration

    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = configuration.timeoutSeconds
    self.session = URLSession(configuration: sessionConfig)
    // ← No invalidation in deinit
}
```

**Problem:**
- URLSession holds strong references to delegates
- Resources not released until `invalidateAndCancel()` called
- Fallback creates new AIService instances (lines 491, 582) accumulating sessions

**Fix:**
```swift
deinit {
    session.invalidateAndCancel()
}
```

---

### 2.7 [MEDIUM] Timer Not Invalidated in deinit

**Location:** `ReaderViewModel.swift`

**Current:** No `deinit` method

**Fix:**
```swift
deinit {
    undoTimer?.invalidate()
}
```

---

### 2.8 [MEDIUM] No Cleanup on View Disappear

**Location:** `ReaderView.swift`

**Problem:** When user exits reader, active Tasks continue running.

**Fix:**
```swift
// In ReaderView
.onDisappear {
    viewModel?.cancelAllActiveJobs()
}

// In ReaderViewModel
func cancelAllActiveJobs() {
    for highlightId in highlightToJobIds.keys {
        cancelAllAnalysesForHighlight(highlightId)
    }
}
```

---

### 2.9 [LOW] Redundant MainActor.run

**Location:** `ReaderViewModel.swift:286-292`

**Current:**
```swift
func updateScrollPosition(_ offset: CGFloat) {
    scrollOffset = offset
    Task {
        try? await Task.sleep(nanoseconds: 500_000_000)
        await MainActor.run {  // ← Redundant!
            saveProgress()
        }
    }
}
```

**Fix:**
```swift
func updateScrollPosition(_ offset: CGFloat) {
    scrollOffset = offset
    Task {
        try? await Task.sleep(nanoseconds: 500_000_000)
        saveProgress()  // Already on MainActor - Task inherited context
    }
}
```

---

### 2.10 [LOW] Missing Task.isCancelled in ReaderViewModel

**Location:** `ReaderViewModel.swift:732`

**Current:**
```swift
while !cancelledJobs.contains(jobId) {  // Only checks job-level signal
```

**Recommendation:** Add defense-in-depth:
```swift
while !Task.isCancelled && !cancelledJobs.contains(jobId) {
```

---

## Part 3: Prioritized Action Items

### Phase 1: Critical Fixes (Do Now)

| # | Issue | File | Line(s) | Effort |
|---|-------|------|---------|--------|
| 1 | Add `onTermination` to AsyncThrowingStream | AIService.swift | 395-597, 602-676 | Medium |
| 2 | Fix `AIError.networkError(Error)` → `networkError(String)` | AIService.swift | 113 | Low |
| 3 | Migrate DispatchQueue usages (9 instances) | ChapterContentView.swift, AnalysisPanelView.swift | See table above | Medium |

### Phase 2: Swift 6 Readiness (Before Migration)

| # | Issue | File | Line(s) | Effort |
|---|-------|------|---------|--------|
| 4 | Fix AIService self-capture in @Sendable closures | AIService.swift | 395-597 | Medium |
| 5 | Add explicit `Sendable` to all enums | Multiple | - | Low |
| 6 | Add `deinit` to AIService (URLSession) | AIService.swift | - | Low |
| 7 | Add `deinit` to ReaderViewModel (Timer) | ReaderViewModel.swift | - | Low |

### Phase 3: Enhancements (Nice to Have)

| # | Issue | File | Line(s) | Effort |
|---|-------|------|---------|--------|
| 8 | Add cleanup on view disappear | ReaderView.swift | - | Low |
| 9 | Remove redundant `MainActor.run` | ReaderViewModel.swift | 288-291 | Low |
| 10 | Add `Task.isCancelled` check to ReaderViewModel | ReaderViewModel.swift | 732 | Low |
| 11 | Store Task handles for explicit cancellation | ReaderViewModel.swift | - | Medium |

---

## Part 4: Code Patterns Reference

### Pattern: AsyncThrowingStream with Proper Cancellation

```swift
func streamingOperation() -> AsyncThrowingStream<Result, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            defer { continuation.finish() }

            do {
                for try await item in someAsyncSequence {
                    guard !Task.isCancelled else { break }
                    continuation.yield(item)
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { @Sendable termination in
            task.cancel()
        }
    }
}
```

### Pattern: DispatchQueue to Task Migration

```swift
// BEFORE (Legacy)
DispatchQueue.main.async {
    self.updateUI()
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    self.delayedUpdate()
}

// AFTER (Swift Concurrency)
Task { @MainActor in
    self.updateUI()
}

Task { @MainActor in
    try? await Task.sleep(for: .milliseconds(500))
    self.delayedUpdate()
}
```

### Pattern: Sendable Value Extraction

```swift
// BEFORE (Captures non-Sendable self)
func asyncOperation() async {
    Task {
        let result = self.config.process()  // Captures self
    }
}

// AFTER (Captures Sendable values)
func asyncOperation() async {
    let configValue = config.value  // Extract before Task
    Task {
        let result = configValue.process()  // Uses Sendable value
    }
}
```

### Pattern: @MainActor Class with Task

```swift
@MainActor
@Observable
final class ViewModel {
    var state: State = .initial

    func performWork() {
        // Synchronous setup - no race condition
        state = .loading

        Task {
            // Task inherits @MainActor - state access is safe
            let result = await service.fetch()
            state = .loaded(result)  // Direct assignment, no MainActor.run needed
        }
    }
}
```

---

## Part 5: Swift 6 Readiness Checklist

| Requirement | Current Status | Action |
|-------------|----------------|--------|
| Explicit @MainActor on ViewModels | ✅ Complete | None |
| Sendable types for boundary crossing | ⚠️ Partial | Fix AIError, add to enums |
| No implicit captures of non-Sendable | ⚠️ Issues | Fix AIService |
| AsyncThrowingStream cancellation | ❌ Missing | Add onTermination |
| DispatchQueue eliminated | ❌ 9 instances | Migrate to Task |
| Resource cleanup in deinit | ❌ Missing | Add to AIService, ReaderViewModel |

---

## Part 6: Architecture Decisions (Rationale)

### Why @MainActor Over Actor for AnalysisJobManager

Per Apple's guidance and Swift Concurrency best practices:

| Factor | `actor` | `@MainActor class` | Our Choice |
|--------|---------|-------------------|------------|
| Call from SwiftUI | Requires `await` | Synchronous | @MainActor ✓ |
| Race condition risk | At call sites | None | @MainActor ✓ |
| Sendable constraints | Required | Not needed | @MainActor ✓ |
| Mental model | Complex | Simple | @MainActor ✓ |

**Key quote from docs:** "Do not use actors for SwiftUI data models. Use @MainActor instead."

### Why Signal-Based Cancellation Over Task.isCancelled

The three-layer job tracking uses `cancelledJobs.contains(jobId)` instead of pure `Task.isCancelled`:

1. **Granularity**: Can cancel specific job while others continue
2. **Semantics**: Job-level cancellation is more meaningful than Task-level
3. **Parallel Jobs**: Multiple jobs per highlight, each independently cancellable
4. **UI Control**: Only latest job updates UI via `highlightToJobMap`

However, `Task.isCancelled` should ALSO be checked for defense-in-depth.

### Why Polling Over AsyncSequence for Job Status

The 50ms polling pattern was chosen over AsyncSequence because:

1. **Simplicity**: Polling is straightforward to understand
2. **Batching**: 50ms interval naturally batches UI updates
3. **@Observable**: SwiftUI observation handles reactivity anyway
4. **CPU overhead**: Negligible (50ms = 20 checks/sec, O(1) dictionary lookup)

Future consideration: Replace with proper observation if polling becomes a bottleneck.

---

## Appendix: File Reference

| File | @MainActor | Key Patterns |
|------|------------|--------------|
| ReaderViewModel.swift | ✅ Yes | Three-layer tracking, defer cleanup, Timer |
| HighlightAnalysisManager.swift | ✅ Yes | Task.isCancelled polling |
| LibraryViewModel.swift | ✅ Yes | async/await for import |
| AIService.swift | ❌ No (intentional) | AsyncThrowingStream, fallback |
| AnalysisJobManager (in AIService.swift) | ✅ Yes | Job state, synchronous queue |
| EPUBParserService.swift | ❌ No | Sendable structs |
| ChapterContentView.swift | N/A (View) | WKWebView delegates, DispatchQueue |
| AnalysisPanelView.swift | N/A (View) | DispatchQueue |

---

*Document generated from comprehensive Swift Concurrency analysis on 2026-01-30*
