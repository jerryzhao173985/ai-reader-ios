// ChapterContentView.swift
// Displays chapter content with text selection and highlighting
//
// Features: HTML rendering, text selection, highlight overlays, gestures

import SwiftUI
import SwiftData
import WebKit

struct ChapterContentView: View {
    @Bindable var viewModel: ReaderViewModel

    @Environment(SettingsManager.self) private var settings

    @State private var selectionContext: (before: String, after: String) = ("", "")
    @State private var selectionOffsets: (start: Int, end: Int) = (0, 0)

    // Custom question input
    @State private var showingCustomQuestionInput = false
    @State private var customQuestionText = ""
    @State private var pendingSelectedText = ""
    @State private var pendingContext = ""

    // Scroll to highlight tracking
    @State private var scrollToHighlightId: String?

    var body: some View {
        ZStack {
            settings.theme.backgroundColor
                .ignoresSafeArea()

            if let chapter = viewModel.currentChapter {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Chapter Title
                            Text(chapter.title)
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundStyle(settings.theme.textColor)
                                .id("chapter-top")

                            // WKWebView for HTML content with text selection
                            ChapterWebView(
                                htmlContent: chapter.htmlContent,
                                settings: settings,
                                highlights: viewModel.currentChapterHighlights,
                                initialScrollOffset: viewModel.scrollOffset,
                                onTextSelected: { text, range, context, offsets in
                                    let wasActive = viewModel.hasActiveTextSelection
                                    viewModel.selectedText = text
                                    viewModel.selectionRange = range
                                    selectionContext = context
                                    selectionOffsets = offsets
                                    viewModel.showingContextMenu = !text.isEmpty
                                    // Track active selection to defer updates
                                    viewModel.hasActiveTextSelection = !text.isEmpty

                                    // If selection was just cleared (user tapped elsewhere), apply deferred updates
                                    if wasActive && !viewModel.hasActiveTextSelection {
                                        viewModel.applyDeferredMarkerUpdates()
                                    }
                                },
                                onHighlightTapped: { highlight in
                                    // Scroll to the highlight and open panel
                                    scrollToHighlightId = highlight.id.uuidString
                                    viewModel.selectHighlight(highlight)

                                    // Clear scroll ID after a short delay to allow re-scrolling
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        scrollToHighlightId = nil
                                    }
                                },
                                onScrollChanged: { offset in
                                    viewModel.updateScrollPosition(offset)
                                },
                                onMarkerUpdateHandled: {
                                    viewModel.pendingMarkerUpdate = nil
                                },
                                scrollToHighlightId: scrollToHighlightId,
                                pendingMarkerUpdate: viewModel.pendingMarkerUpdate,
                                hasActiveTextSelection: viewModel.hasActiveTextSelection
                            )
                            .frame(minHeight: UIScreen.main.bounds.height - 200)
                        }
                        .padding(.horizontal, settings.marginSize)
                        .padding(.vertical, 20)
                    }
                    .onChange(of: viewModel.currentChapterIndex) { _, _ in
                        withAnimation {
                            scrollProxy.scrollTo("chapter-top", anchor: .top)
                        }
                    }
                }

                // Navigation Overlay
                chapterNavigationOverlay

                // Highlight Menu
                if viewModel.showingContextMenu {
                    highlightMenuOverlay
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading chapter...")
                        .foregroundStyle(settings.theme.textColor.opacity(0.5))
                }
            }
        }
        .alert("Ask a Question", isPresented: $showingCustomQuestionInput) {
            TextField("What would you like to know?", text: $customQuestionText)
            Button("Cancel", role: .cancel) {
                showingCustomQuestionInput = false
                customQuestionText = ""
            }
            Button("Ask") {
                submitCustomQuestion()
            }
        } message: {
            Text("Enter your question about the selected text")
        }
    }

    // MARK: - Chapter Navigation Overlay
    private var chapterNavigationOverlay: some View {
        HStack {
            // Previous Chapter Button
            if viewModel.hasPreviousChapter {
                Button {
                    viewModel.goToPreviousChapter()
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.title)
                        .foregroundStyle(settings.theme.accentColor)
                        .background(Circle().fill(settings.theme.backgroundColor))
                }
                .padding(.leading, 8)
            }

            Spacer()

            // Next Chapter Button
            if viewModel.hasNextChapter {
                Button {
                    viewModel.goToNextChapter()
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.title)
                        .foregroundStyle(settings.theme.accentColor)
                        .background(Circle().fill(settings.theme.backgroundColor))
                }
                .padding(.trailing, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Highlight Menu Overlay
    private var highlightMenuOverlay: some View {
        VStack {
            Spacer()

            VStack(spacing: 12) {
                Text("Selected Text")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(viewModel.selectedText.prefix(100) + (viewModel.selectedText.count > 100 ? "..." : ""))
                    .font(.subheadline)
                    .foregroundStyle(settings.theme.textColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Divider()

                HStack(spacing: 20) {
                    highlightButton(type: .factCheck, icon: "checkmark.seal", label: "Fact Check")
                    highlightButton(type: .keyPoints, icon: "list.bullet", label: "Key Points")
                    highlightButton(type: .discussion, icon: "bubble.left.and.bubble.right", label: "Discussion")
                    // Ask button opens custom question input
                    Button {
                        showCustomQuestionInput()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                                .font(.title2)
                            Text("Ask")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color(hex: AnalysisType.customQuestion.colorHex) ?? settings.theme.accentColor)
                    }
                }
                .padding(.vertical, 8)

                HStack(spacing: 20) {
                    highlightButton(type: .argumentMap, icon: "chart.bar.doc.horizontal", label: "Arguments")
                    highlightButton(type: .counterpoints, icon: "arrow.left.arrow.right", label: "Counter")
                    highlightButton(type: .comment, icon: "text.bubble", label: "Comment")

                    // Just highlight without analysis
                    Button {
                        createHighlightOnly()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "highlighter")
                                .font(.title2)
                            Text("Highlight")
                                .font(.caption2)
                        }
                        .foregroundStyle(settings.theme.textColor)
                    }
                }
                .padding(.vertical, 8)

                Button("Cancel") {
                    viewModel.showingContextMenu = false
                }
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding()
            .shadow(radius: 10)
        }
    }

    private func highlightButton(type: AnalysisType, icon: String, label: String) -> some View {
        Button {
            createHighlightAndAnalyze(type: type)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(Color(hex: type.colorHex) ?? settings.theme.accentColor)
        }
    }

    private func createHighlightOnly() {
        let highlight = viewModel.createHighlight(
            text: viewModel.selectedText,
            contextBefore: selectionContext.before,
            contextAfter: selectionContext.after,
            startOffset: selectionOffsets.start,
            endOffset: selectionOffsets.end
        )
        viewModel.selectedHighlight = highlight
        viewModel.showingContextMenu = false
        // Clear selection state so deferred marker updates can be processed
        viewModel.clearSelection()
    }

    private func createHighlightAndAnalyze(type: AnalysisType) {
        let highlight = viewModel.createHighlight(
            text: viewModel.selectedText,
            contextBefore: selectionContext.before,
            contextAfter: selectionContext.after,
            startOffset: selectionOffsets.start,
            endOffset: selectionOffsets.end
        )
        viewModel.selectedHighlight = highlight
        // Panel opens only when user taps inline side note marker [1] [2] etc.
        viewModel.performAnalysis(
            type: type,
            text: viewModel.selectedText,
            context: "\(selectionContext.before)\(viewModel.selectedText)\(selectionContext.after)"
        )
        viewModel.showingContextMenu = false
        // Clear selection state so deferred marker updates can be processed
        viewModel.clearSelection()
    }

    private func showCustomQuestionInput() {
        // Store current selection state before dismissing the menu
        pendingSelectedText = viewModel.selectedText
        pendingContext = "\(selectionContext.before)\(viewModel.selectedText)\(selectionContext.after)"
        customQuestionText = ""
        showingCustomQuestionInput = true
        viewModel.showingContextMenu = false
    }

    private func submitCustomQuestion() {
        guard !customQuestionText.isEmpty else { return }

        let highlight = viewModel.createHighlight(
            text: pendingSelectedText,
            contextBefore: selectionContext.before,
            contextAfter: selectionContext.after,
            startOffset: selectionOffsets.start,
            endOffset: selectionOffsets.end
        )
        viewModel.selectedHighlight = highlight
        // Panel opens only when user taps inline side note marker [1] [2] etc.
        viewModel.performAnalysis(
            type: .customQuestion,
            text: pendingSelectedText,
            context: pendingContext,
            question: customQuestionText
        )

        showingCustomQuestionInput = false
        customQuestionText = ""
        // Clear selection state so deferred marker updates can be processed
        viewModel.clearSelection()
    }
}

// MARK: - Chapter WebView (WKWebView wrapped for SwiftUI)
struct ChapterWebView: UIViewRepresentable {
    let htmlContent: String
    let settings: SettingsManager
    let highlights: [HighlightModel]
    let initialScrollOffset: CGFloat
    let onTextSelected: (String, NSRange, (before: String, after: String), (start: Int, end: Int)) -> Void
    let onHighlightTapped: (HighlightModel) -> Void
    let onScrollChanged: (CGFloat) -> Void
    /// Callback to clear pending marker update after it's been handled
    let onMarkerUpdateHandled: () -> Void

    /// Highlight ID to scroll to (when marker is tapped externally)
    var scrollToHighlightId: String?

    /// Pending marker update - inject via JS instead of HTML reload to avoid flicker
    /// Includes colorHex to update highlight background color when analysis completes
    var pendingMarkerUpdate: (highlightId: UUID, analysisCount: Int, colorHex: String)?

    /// When true, skip HTML reloads to preserve user's text selection
    /// Any pending updates will be applied when this becomes false
    var hasActiveTextSelection: Bool = false

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "textSelection")
        configuration.userContentController.add(context.coordinator, name: "highlightTapped")

        // Enable text selection
        configuration.preferences.javaScriptEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator

        // Set scroll delegate for position tracking
        webView.scrollView.delegate = context.coordinator
        context.coordinator.webView = webView

        // Disable link preview to prevent interference with text selection
        webView.allowsLinkPreview = false

        // Ensure user interaction is enabled
        webView.isUserInteractionEnabled = true
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = false

        // Important: Allow text selection to work properly
        webView.scrollView.delaysContentTouches = false
        webView.scrollView.canCancelContentTouches = false

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Update coordinator's parent reference so it has fresh highlights data
        context.coordinator.parent = self

        // Compute hashes early to detect changes
        let baseContentHash = htmlContent.hashValue
        let styledHTML = generateStyledHTML()
        let styledContentHash = styledHTML.hashValue

        let isChapterChange = baseContentHash != context.coordinator.lastBaseContentHash
        let isHighlightUpdate = !isChapterChange && styledContentHash != context.coordinator.lastStyledContentHash

        // CRITICAL: If user has active text selection, skip ALL reloads to preserve selection
        // Any changes (colorHex, analyses.count, etc.) will be applied when selection is cleared
        // We DON'T update lastStyledContentHash so the next update after selection clear will reload
        if hasActiveTextSelection && !isChapterChange {
            #if DEBUG
            if isHighlightUpdate {
                print("[WebView] Skipping reload - active text selection, deferring update")
            }
            #endif
            return
        }

        // Handle pending marker update via JS injection (no reload, no flicker)
        // This is triggered when analysis completes - update marker text AND highlight color
        // IMPORTANT: Only skip reload if no new highlights were added (checked via isHighlightUpdate)
        if let update = pendingMarkerUpdate,
           update.highlightId != context.coordinator.lastHandledMarkerId {
            context.coordinator.lastHandledMarkerId = update.highlightId
            context.coordinator.injectMarkerUpdate(
                webView: webView,
                highlightId: update.highlightId,
                analysisCount: update.analysisCount,
                colorHex: update.colorHex
            )

            // Notify that we handled the update
            DispatchQueue.main.async {
                self.onMarkerUpdateHandled()
            }

            // If no other changes (no new highlights), we can skip HTML reload
            // The marker was updated via JS, and the hash will be updated below
            if !isChapterChange && !isHighlightUpdate {
                // Update hash to prevent future reload for this same state
                context.coordinator.lastStyledContentHash = styledContentHash
                return
            }
            // Otherwise, continue to reload HTML for the new highlight
        }

        if isChapterChange {
            // Chapter changed - reset scroll to initialScrollOffset
            context.coordinator.lastBaseContentHash = baseContentHash
            context.coordinator.lastStyledContentHash = styledContentHash
            context.coordinator.resetScrollRestoration()
            context.coordinator.lastHandledMarkerId = nil  // Reset for new chapter

            #if DEBUG
            print("[WebView] Chapter change - loading new content, length: \(styledHTML.count)")
            #endif

            webView.loadHTMLString(styledHTML, baseURL: nil)
        } else if isHighlightUpdate {
            // Same chapter, highlights changed (new highlight created) - preserve scroll position
            context.coordinator.lastStyledContentHash = styledContentHash
            context.coordinator.saveScrollPositionForReload()

            #if DEBUG
            print("[WebView] Highlight update - preserving scroll position")
            #endif

            webView.loadHTMLString(styledHTML, baseURL: nil)
        }

        // Scroll to highlight if requested
        if let highlightId = scrollToHighlightId {
            let cleanId = highlightId.replacingOccurrences(of: "-", with: "")
            let js = """
            (function() {
                const el = document.querySelector('.highlight-\(cleanId)');
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    return true;
                }
                return false;
            })();
            """
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("[WebView] Scroll to highlight error: \(error.localizedDescription)")
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func generateStyledHTML() -> String {
        let theme = settings.theme
        let bgColor = theme.backgroundColor.hexString ?? "#ffffff"
        let textColor = theme.textColor.hexString ?? "#000000"
        let accentColor = theme.accentColor.hexString ?? "#0066cc"

        let fontFamily: String
        switch settings.fontFamily {
        case .serif: fontFamily = "Georgia, serif"
        case .sansSerif: fontFamily = "-apple-system, sans-serif"
        case .monospace: fontFamily = "Menlo, monospace"
        }

        // Generate highlight CSS
        var highlightStyles = ""
        for (index, highlight) in highlights.enumerated() {
            let color = highlight.colorHex ?? "#ffff00"
            highlightStyles += """
            .highlight-\(highlight.id.uuidString.replacingOccurrences(of: "-", with: "")) {
                background-color: \(color)40;
                border-bottom: 2px solid \(color);
                cursor: pointer;
                position: relative;
            }
            .highlight-marker-\(index + 1) {
                font-size: 0.7em;
                vertical-align: super;
                color: \(color);
                font-weight: bold;
                margin-left: 2px;
            }
            """
        }

        // Generate highlight data as JSON for JavaScript
        // Include analysis count to show multiple analysis indicators
        let highlightData = highlights.enumerated().map { index, highlight -> String in
            let analysisCount = highlight.analyses.count
            return """
            {"id":"\(highlight.id.uuidString.replacingOccurrences(of: "-", with: ""))","start":\(highlight.startOffset),"end":\(highlight.endOffset),"marker":\(index + 1),"analysisCount":\(analysisCount)}
            """
        }.joined(separator: ",")
        let highlightsJSON = "[\(highlightData)]"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes">
            <style>
                * {
                    -webkit-user-select: text;
                    user-select: text;
                }
                body {
                    font-family: \(fontFamily);
                    font-size: \(settings.fontSize)px;
                    line-height: \(1.0 + settings.lineSpacing / 10);
                    color: \(textColor);
                    background-color: \(bgColor);
                    padding: 0;
                    margin: 0;
                    word-wrap: break-word;
                }
                a {
                    color: \(accentColor);
                }
                img {
                    max-width: 100%;
                    height: auto;
                }
                p {
                    margin-bottom: 1em;
                }
                h1, h2, h3, h4, h5, h6 {
                    color: \(textColor);
                    margin-top: 1.5em;
                    margin-bottom: 0.5em;
                }
                blockquote {
                    border-left: 3px solid \(accentColor);
                    padding-left: 1em;
                    margin-left: 0;
                    color: \(textColor)cc;
                }
                \(highlightStyles)
                ::selection {
                    background-color: \(accentColor)40;
                }
            </style>
        </head>
        <body>
            \(htmlContent)
            <script>
                // Debounce selection to handle iOS text selection properly
                let selectionTimeout = null;
                let lastSelection = '';
                let selectionCheckInterval = null;
                let isSelecting = false;

                function sendSelection() {
                    try {
                        const selection = window.getSelection();
                        if (selection && selection.rangeCount > 0) {
                            const text = selection.toString();

                            // Skip if empty/whitespace-only
                            if (!text || text.trim().length === 0) return;

                            const range = selection.getRangeAt(0);

                            // Get clean text (excludes marker text like [1], [2], [3])
                            const textContent = getCleanTextContent();

                            // Calculate offsets in clean text, snapping if boundary is inside a marker
                            // Example: "emotion[11][9]" selected → snaps to "emotion"
                            const startOffset = getTextOffset(range.startContainer, range.startOffset, 'start');
                            const endOffset = getTextOffset(range.endContainer, range.endOffset, 'end');

                            // Validate: if offsets are invalid (e.g., selection was entirely markers), skip
                            if (startOffset >= endOffset) {
                                console.log('[Selection] Invalid range after snapping (marker-only selection), skipping');
                                return;
                            }

                            // Use snapped text from clean content for consistency with offsets
                            // This ensures "emotion[11]" selection sends "emotion" with matching offsets
                            const snappedText = textContent.substring(startOffset, endOffset);

                            // Skip if snapped text is unchanged (prevent redundant messages)
                            // Compare snappedText, not raw text - "emotion[11]" and "emotion[11][9]" both snap to "emotion"
                            if (snappedText === lastSelection) return;
                            lastSelection = snappedText;

                            const contextBefore = textContent.substring(Math.max(0, startOffset - 100), startOffset);
                            const contextAfter = textContent.substring(endOffset, Math.min(textContent.length, endOffset + 100));

                            // Log for debugging
                            console.log('[Selection] snapped text:', snappedText.substring(0, 50), 'length:', snappedText.length, 'offsets:', startOffset, '-', endOffset);

                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.textSelection) {
                                window.webkit.messageHandlers.textSelection.postMessage({
                                    text: snappedText,
                                    startOffset: startOffset,
                                    endOffset: endOffset,
                                    contextBefore: contextBefore,
                                    contextAfter: contextAfter
                                });
                            }
                        }
                    } catch (e) {
                        console.log('[Selection] Error:', e.message);
                    }
                }

                // Listen for selection changes with debounce
                document.addEventListener('selectionchange', function() {
                    clearTimeout(selectionTimeout);
                    selectionTimeout = setTimeout(sendSelection, 200);
                });

                // Multiple attempts on touchend for iOS reliability
                document.addEventListener('touchend', function(e) {
                    // Multiple delays to catch iOS selection timing
                    setTimeout(sendSelection, 100);
                    setTimeout(sendSelection, 250);
                    setTimeout(sendSelection, 500);
                    setTimeout(sendSelection, 800);
                });

                // Long press handling for iOS
                let longPressTimer = null;
                document.addEventListener('touchstart', function(e) {
                    isSelecting = true;

                    // Start polling during touch
                    if (selectionCheckInterval) clearInterval(selectionCheckInterval);
                    selectionCheckInterval = setInterval(sendSelection, 300);

                    // Also set a long press check
                    longPressTimer = setTimeout(function() {
                        sendSelection();
                    }, 600);
                }, { passive: true });

                document.addEventListener('touchmove', function(e) {
                    // Keep checking selection during move (drag select)
                    if (isSelecting) {
                        clearTimeout(selectionTimeout);
                        selectionTimeout = setTimeout(sendSelection, 100);
                    }
                }, { passive: true });

                document.addEventListener('touchend', function() {
                    isSelecting = false;
                    clearTimeout(longPressTimer);

                    // Continue checking for a bit after touch ends
                    setTimeout(function() {
                        if (selectionCheckInterval) {
                            clearInterval(selectionCheckInterval);
                            selectionCheckInterval = null;
                        }
                    }, 1500);
                }, { passive: true });

                document.addEventListener('touchcancel', function() {
                    isSelecting = false;
                    clearTimeout(longPressTimer);

                    if (selectionCheckInterval) {
                        clearInterval(selectionCheckInterval);
                        selectionCheckInterval = null;
                    }
                }, { passive: true });

                // Helper: Check if a text node is inside a marker element (should be excluded from offset calculations)
                // Markers are <sup> elements with classes like "highlight-marker-5" or "analysis-marker"
                function isMarkerTextNode(textNode) {
                    let el = textNode.parentElement;
                    while (el && el !== document.body) {
                        // Only match our specific marker patterns (not arbitrary classes containing these strings)
                        if (el.tagName === 'SUP' && el.className) {
                            // Match: highlight-marker-N (where N is a number) or analysis-marker
                            if (/^highlight-marker-\\d+$/.test(el.className) ||
                                el.className === 'analysis-marker') {
                                return true;
                            }
                        }
                        el = el.parentElement;
                    }
                    return false;
                }

                // Get clean text content excluding marker text (for context extraction)
                // This ensures context offsets match getTextOffset() calculations
                function getCleanTextContent() {
                    let text = '';
                    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
                    while (walker.nextNode()) {
                        if (!isMarkerTextNode(walker.currentNode)) {
                            text += walker.currentNode.textContent;
                        }
                    }
                    return text;
                }

                // Get text offset in clean text (excluding markers)
                //
                // When selection boundary lands inside a marker like [11], we must snap to real text:
                //   - boundary='start': snap FORWARD to next real text (for selection START)
                //   - boundary='end': snap BACKWARD to previous real text (for selection END)
                //
                // Example: "emotion[11][9][7] more" - user selects "emotion[11][9"
                //   - END boundary is inside "[9]" marker
                //   - Snap backward → returns position at end of "emotion" (offset 7)
                //   - Result: selection = "emotion" (correct!)
                //
                // This prevents the bug where target node is skipped (markers are skipped)
                // and the function would return total document length → entire chapter highlighted
                function getTextOffset(node, offset, boundary) {
                    boundary = boundary || 'end';  // Default: snap backward (safe for end boundaries)

                    let totalOffset = 0;
                    let lastRealTextEnd = 0;  // Position at end of last real (non-marker) text
                    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);

                    while (walker.nextNode()) {
                        const currentNode = walker.currentNode;

                        if (isMarkerTextNode(currentNode)) {
                            // Target is inside a marker - must snap to real text boundary
                            if (currentNode === node) {
                                if (boundary === 'start') {
                                    // START boundary: snap forward to next real text
                                    while (walker.nextNode()) {
                                        if (!isMarkerTextNode(walker.currentNode)) {
                                            return totalOffset;  // Start of next real text
                                        }
                                    }
                                    return totalOffset;  // No more real text, return current position
                                } else {
                                    // END boundary: snap backward to end of previous real text
                                    return lastRealTextEnd;
                                }
                            }
                            continue;  // Skip marker text in offset counting
                        }

                        // Normal text node
                        if (currentNode === node) {
                            return totalOffset + offset;
                        }

                        totalOffset += currentNode.textContent.length;
                        lastRealTextEnd = totalOffset;
                    }
                    return totalOffset;
                }

                // Highlight data from Swift
                const highlightsData = \(highlightsJSON);

                // Apply highlights to DOM after page loads
                function applyHighlights() {
                    console.log('[Highlights] Applying', highlightsData.length, 'highlights');

                    highlightsData.forEach(function(highlight) {
                        try {
                            applyHighlight(highlight.id, highlight.start, highlight.end, highlight.marker, highlight.analysisCount || 0);
                        } catch (e) {
                            console.log('[Highlights] Error applying highlight', highlight.id, ':', e.message);
                        }
                    });

                    // Attach click handlers after highlights are applied
                    attachHighlightClickHandlers();
                }

                function applyHighlight(id, startOffset, endOffset, markerNum, analysisCount) {
                    // Find text nodes and their positions
                    // IMPORTANT: Skip marker text nodes to prevent "offset drift" when multiple highlights are applied
                    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
                    const textNodes = [];
                    let totalOffset = 0;

                    while (walker.nextNode()) {
                        const node = walker.currentNode;

                        // Skip marker text nodes - they shouldn't affect offset calculation
                        // This prevents drift when applying multiple highlights in sequence
                        if (isMarkerTextNode(node)) {
                            continue;
                        }

                        const nodeStart = totalOffset;
                        const nodeEnd = totalOffset + node.textContent.length;

                        // Check if this node overlaps with our highlight range
                        if (nodeEnd > startOffset && nodeStart < endOffset) {
                            textNodes.push({
                                node: node,
                                nodeStart: nodeStart,
                                nodeEnd: nodeEnd
                            });
                        }
                        totalOffset = nodeEnd;
                    }

                    if (textNodes.length === 0) {
                        console.log('[Highlights] No text nodes found for offsets', startOffset, '-', endOffset);
                        return;
                    }

                    // Process nodes in reverse order to avoid offset issues
                    for (let i = textNodes.length - 1; i >= 0; i--) {
                        const info = textNodes[i];
                        const node = info.node;
                        const text = node.textContent;

                        // Calculate local offsets within this text node
                        const localStart = Math.max(0, startOffset - info.nodeStart);
                        const localEnd = Math.min(text.length, endOffset - info.nodeStart);

                        if (localStart >= localEnd) continue;

                        // Split text into: before, highlighted, after
                        const beforeText = text.substring(0, localStart);
                        const highlightedText = text.substring(localStart, localEnd);
                        const afterText = text.substring(localEnd);

                        // Create highlight span
                        const span = document.createElement('span');
                        span.className = 'highlight-' + id;
                        span.textContent = highlightedText;

                        // Add marker to the last segment (first in reverse order)
                        if (i === textNodes.length - 1 && markerNum) {
                            const marker = document.createElement('sup');
                            marker.className = 'highlight-marker-' + markerNum;
                            // Show analysis count if > 1 (e.g., [1·3] for marker 1 with 3 analyses)
                            if (analysisCount > 1) {
                                marker.textContent = '[' + markerNum + '·' + analysisCount + ']';
                            } else {
                                marker.textContent = '[' + markerNum + ']';
                            }
                            span.appendChild(marker);
                        }

                        // Create a document fragment with the split content
                        const fragment = document.createDocumentFragment();
                        if (beforeText) fragment.appendChild(document.createTextNode(beforeText));
                        fragment.appendChild(span);
                        if (afterText) fragment.appendChild(document.createTextNode(afterText));

                        // Replace the original text node
                        node.parentNode.replaceChild(fragment, node);
                    }

                    console.log('[Highlights] Applied highlight', id, 'with marker [' + markerNum + '], analysisCount:', analysisCount);
                }

                function attachHighlightClickHandlers() {
                    document.querySelectorAll('[class^="highlight-"]').forEach(el => {
                        el.addEventListener('click', function(e) {
                            let highlightId = null;

                            // Check if this is a marker (class contains 'marker')
                            if (this.className.includes('marker')) {
                                // It's a marker - find parent highlight span
                                let parent = this.parentElement;
                                while (parent && parent !== document.body) {
                                    const parentClasses = parent.className ? parent.className.split(' ') : [];
                                    const highlightClass = parentClasses.find(c => c.startsWith('highlight-') && !c.includes('marker'));
                                    if (highlightClass) {
                                        highlightId = highlightClass.replace('highlight-', '');
                                        break;
                                    }
                                    parent = parent.parentElement;
                                }
                            } else {
                                // It's a highlight span - extract ID directly
                                const classes = this.className.split(' ');
                                const highlightClass = classes.find(c => c.startsWith('highlight-') && !c.includes('marker'));
                                if (highlightClass) {
                                    highlightId = highlightClass.replace('highlight-', '');
                                }
                            }

                            if (highlightId && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.highlightTapped) {
                                window.webkit.messageHandlers.highlightTapped.postMessage({
                                    id: highlightId
                                });
                            }
                            e.stopPropagation();
                        });
                    });
                }

                // Apply highlights after a short delay to ensure DOM is ready
                setTimeout(applyHighlights, 100);

                // Debug: Log when page loads
                console.log('[ChapterWebView] JavaScript initialized, text selection enabled');
            </script>
        </body>
        </html>
        """
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        var parent: ChapterWebView  // var to allow updates when highlights change
        /// Hash of base HTML content (without highlight styling) - detects chapter changes
        var lastBaseContentHash: Int = 0
        /// Hash of full styled HTML (with highlights) - detects highlight updates
        var lastStyledContentHash: Int = 0
        weak var webView: WKWebView?
        private var hasRestoredScroll = false
        /// Scroll position to restore after HTML reload (preserves position during highlight updates)
        /// NOT cleared after restoration - kept for subsequent rapid loads until user manually scrolls
        private var pendingScrollPosition: CGFloat?
        /// Last handled marker update ID to prevent duplicate handling
        var lastHandledMarkerId: UUID?

        init(_ parent: ChapterWebView) {
            self.parent = parent
        }

        func resetScrollRestoration() {
            hasRestoredScroll = false
            pendingScrollPosition = nil
        }

        /// Save current scroll position before reloading HTML
        /// Uses pendingScrollPosition which is NOT cleared after restoration - keeps valid position
        /// for subsequent rapid loads. Only cleared when user manually scrolls.
        func saveScrollPositionForReload() {
            // If we already have a valid pending position, keep it
            // This handles rapid updates where multiple saves occur before first didFinish
            if let existing = pendingScrollPosition, existing > 0 {
                #if DEBUG
                print("[WebView] Scroll save skipped - valid pending position exists: \(existing)")
                #endif
                return
            }

            let currentY = webView?.scrollView.contentOffset.y ?? 0

            // Only save if we have a real position (page is loaded, user has scrolled)
            if let webView = webView, webView.scrollView.contentSize.height > 0, currentY > 0 {
                pendingScrollPosition = currentY
                #if DEBUG
                print("[WebView] Scroll position saved: \(currentY)")
                #endif
            }
            // If currentY is 0, either user is at top or page is loading - don't save
            // If user was genuinely at top, they stay at top anyway (no harm)
        }

        /// Inject JavaScript to update marker and highlight color without reloading HTML
        /// This preserves scroll position and text selection (no flicker)
        func injectMarkerUpdate(webView: WKWebView, highlightId: UUID, analysisCount: Int, colorHex: String) {
            let cleanId = highlightId.uuidString.replacingOccurrences(of: "-", with: "")
            let js = """
            (function() {
                // Find all spans with this highlight class (may be split across text nodes)
                const highlights = document.querySelectorAll('.highlight-\(cleanId)');
                if (highlights.length === 0) {
                    console.log('[Marker] Highlight not found: \(cleanId)');
                    return false;
                }

                // Update background color on ALL highlight spans
                highlights.forEach(function(highlight) {
                    highlight.style.backgroundColor = '\(colorHex)40';
                    highlight.style.borderBottomColor = '\(colorHex)';
                });

                // Find or create marker container (only on the last highlight span)
                const lastHighlight = highlights[highlights.length - 1];
                let marker = lastHighlight.querySelector('.analysis-marker');
                if (!marker) {
                    marker = document.createElement('sup');
                    marker.className = 'analysis-marker';
                    marker.style.cssText = 'font-weight: bold; cursor: pointer; margin-left: 2px; font-size: 0.75em;';
                    // Add click handler for the marker
                    marker.addEventListener('click', function(e) {
                        e.stopPropagation();
                        window.webkit.messageHandlers.highlightTapped.postMessage({id: '\(cleanId)'});
                    });
                    lastHighlight.appendChild(marker);
                }

                // Update marker text and color to match highlight
                marker.textContent = '[\(analysisCount)]';
                marker.style.color = '\(colorHex)';
                console.log('[Marker] Updated marker for \(cleanId) to [\(analysisCount)] with color \(colorHex)');
                return true;
            })();
            """

            webView.evaluateJavaScript(js) { result, error in
                #if DEBUG
                if let error = error {
                    print("[WebView] Marker injection error: \(error.localizedDescription)")
                } else {
                    print("[WebView] Marker injected successfully for highlight \(cleanId) with color \(colorHex)")
                }
                #endif
            }
        }

        // MARK: - Scroll Position Management
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Report scroll changes back to ViewModel
            parent.onScrollChanged(scrollView.contentOffset.y)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Restore scroll position after content loads
            // Priority: pendingScrollPosition (from reload) > initialScrollOffset (from chapter open)
            // IMPORTANT: pendingScrollPosition is NOT cleared - kept for rapid subsequent loads
            // Only cleared when user manually scrolls (see scrollViewWillBeginDragging)
            let targetOffset: CGFloat
            let source: String
            if let pending = pendingScrollPosition {
                targetOffset = pending
                // DON'T clear pendingScrollPosition - keep for subsequent rapid loads
                source = "pending"
            } else if !hasRestoredScroll && parent.initialScrollOffset > 0 {
                targetOffset = parent.initialScrollOffset
                // Set pendingScrollPosition so the asyncAfter guard passes
                // Also enables rapid-load protection if highlights are created immediately after chapter open
                pendingScrollPosition = targetOffset
                hasRestoredScroll = true
                source = "initial"
            } else {
                #if DEBUG
                print("[WebView] didFinish - no scroll restoration needed")
                #endif
                return  // No scroll restoration needed
            }

            #if DEBUG
            print("[WebView] Scroll restoration: \(targetOffset) (source: \(source))")
            #endif

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                // If user started scrolling during the delay, pendingScrollPosition was cleared
                // Respect user's scroll intent by skipping restoration
                guard self?.pendingScrollPosition != nil else {
                    #if DEBUG
                    print("[WebView] Scroll restoration skipped - user scrolled during delay")
                    #endif
                    return
                }
                webView.scrollView.setContentOffset(
                    CGPoint(x: 0, y: targetOffset),
                    animated: false
                )
            }
        }

        /// Clear pendingScrollPosition when user manually scrolls
        /// This allows the next save to capture the user's new position
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if pendingScrollPosition != nil {
                #if DEBUG
                print("[WebView] User scrolling - clearing pending position")
                #endif
                pendingScrollPosition = nil
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "textSelection", let body = message.body as? [String: Any] {
                let text = body["text"] as? String ?? ""
                let startOffset = body["startOffset"] as? Int ?? 0
                let endOffset = body["endOffset"] as? Int ?? 0
                let contextBefore = body["contextBefore"] as? String ?? ""
                let contextAfter = body["contextAfter"] as? String ?? ""

                DispatchQueue.main.async {
                    self.parent.onTextSelected(
                        text,
                        NSRange(location: startOffset, length: endOffset - startOffset),
                        (before: contextBefore, after: contextAfter),
                        (start: startOffset, end: endOffset)
                    )
                }
            } else if message.name == "highlightTapped", let body = message.body as? [String: Any] {
                if let idString = body["id"] as? String {
                    let cleanId = idString.replacingOccurrences(of: "-", with: "")
                    if let highlight = parent.highlights.first(where: {
                        $0.id.uuidString.replacingOccurrences(of: "-", with: "") == cleanId
                    }) {
                        DispatchQueue.main.async {
                            self.parent.onHighlightTapped(highlight)
                        }
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow local content, block external navigation
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                // Could open in Safari if needed
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

// MARK: - Color Extension for Hex
extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count
        if length == 6 {
            self.init(
                red: Double((rgb & 0xFF0000) >> 16) / 255.0,
                green: Double((rgb & 0x00FF00) >> 8) / 255.0,
                blue: Double(rgb & 0x0000FF) / 255.0
            )
        } else if length == 8 {
            self.init(
                red: Double((rgb & 0xFF000000) >> 24) / 255.0,
                green: Double((rgb & 0x00FF0000) >> 16) / 255.0,
                blue: Double((rgb & 0x0000FF00) >> 8) / 255.0,
                opacity: Double(rgb & 0x000000FF) / 255.0
            )
        } else {
            return nil
        }
    }

    var hexString: String? {
        guard let components = UIColor(self).cgColor.components else { return nil }

        let r = Int(components[0] * 255)
        let g = Int(components.count > 1 ? components[1] * 255 : components[0] * 255)
        let b = Int(components.count > 2 ? components[2] * 255 : components[0] * 255)

        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

#Preview {
    ChapterContentView(
        viewModel: ReaderViewModel(
            book: BookModel(title: "Sample", authors: ["Author"]),
            modelContext: try! ModelContainer(for: BookModel.self).mainContext
        )
    )
}
