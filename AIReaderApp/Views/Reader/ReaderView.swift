// ReaderView.swift
// Main reader interface with three-column NavigationSplitView layout
//
// Features: TOC sidebar, chapter content, AI analysis panel

import SwiftUI
import SwiftData

struct ReaderView: View {
    let book: BookModel
    let onDismiss: () -> Void

    @Environment(SettingsManager.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: ReaderViewModel?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if let viewModel = viewModel {
                readerContent(viewModel: viewModel)
            } else {
                ProgressView("Loading...")
                    .onAppear {
                        viewModel = ReaderViewModel(book: book, modelContext: modelContext)
                    }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel?.saveProgress()
                    onDismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Library")
                    }
                }
            }

            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(1)

                    if let chapter = viewModel?.currentChapter {
                        Text(chapter.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                #if DEBUG
                // Debug button to test highlight menu
                Button {
                    if let vm = viewModel {
                        vm.selectedText = "The urge to control is everywhere, and most of us can track it back to the way we were raised."
                        vm.selectionRange = NSRange(location: 0, length: 94)
                        vm.showingContextMenu = true
                    }
                } label: {
                    Image(systemName: "highlighter")
                        .foregroundStyle(.orange)
                }
                #endif

                Button {
                    viewModel?.showingTOC.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                }

                Button {
                    viewModel?.showingAnalysisPanel.toggle()
                } label: {
                    Image(systemName: "brain")
                }
            }
        }
    }

    @ViewBuilder
    private func readerContent(viewModel: ReaderViewModel) -> some View {
        // Use simple ZStack layout for iPhone - NavigationSplitView has issues on compact devices
        // NavigationSplitView's 3-column mode doesn't work well on iPhone
        ZStack(alignment: .bottom) {
            // Main content - always visible
            ChapterContentView(viewModel: viewModel)
                .environment(settings)

            // Undo Toast - appears at screen level after highlight deletion
            // Visible even when analysis panel sheet is closed
            if viewModel.deletedHighlightForUndo != nil {
                undoToast(viewModel: viewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.deletedHighlightForUndo != nil)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showingTOC },
            set: { viewModel.showingTOC = $0 }
        )) {
            NavigationStack {
                TOCSidebarView(viewModel: viewModel)
                    .environment(settings)
                    .navigationTitle("Contents")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                viewModel.showingTOC = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showingAnalysisPanel },
            set: { viewModel.showingAnalysisPanel = $0 }
        )) {
            NavigationStack {
                AnalysisPanelView(viewModel: viewModel)
                    .environment(settings)
                    .navigationTitle("Analysis")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                viewModel.showingAnalysisPanel = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        // Save progress when app goes to background (defense-in-depth)
        // Ensures no progress loss if debounce timer hasn't fired yet
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                viewModel.saveProgress()
            }
        }
        // Save progress when view disappears (catches swipe-back gestures)
        .onDisappear {
            viewModel.saveProgress()
        }
    }

    // MARK: - Undo Toast
    /// Screen-level undo toast that appears after highlight deletion
    /// Visible regardless of panel state - follows standard iOS/Material Design pattern
    private func undoToast(viewModel: ReaderViewModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))

            Text("Highlight deleted")
                .font(.subheadline)
                .foregroundStyle(.white)

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    viewModel.undoDeleteHighlight()
                }
            } label: {
                Text("Undo")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.85))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

// MARK: - TOC Sidebar View
struct TOCSidebarView: View {
    @Bindable var viewModel: ReaderViewModel

    @Environment(SettingsManager.self) private var settings

    var body: some View {
        List {
            Section("Chapters") {
                ForEach(Array(viewModel.sortedChapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        viewModel.goToChapter(index)
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(
                                    index == viewModel.currentChapterIndex
                                    ? settings.theme.accentColor
                                    : settings.theme.textColor
                                )
                                .fontWeight(index == viewModel.currentChapterIndex ? .semibold : .regular)

                            Spacer()

                            if index == viewModel.currentChapterIndex {
                                Image(systemName: "book.fill")
                                    .foregroundStyle(settings.theme.accentColor)
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !viewModel.book.tableOfContents.isEmpty {
                Section("Table of Contents") {
                    ForEach(viewModel.book.tableOfContents.sorted(by: { $0.order < $1.order })) { entry in
                        TOCEntryRow(entry: entry, viewModel: viewModel, depth: 0)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .background(settings.theme.secondaryBackgroundColor)
    }
}

// MARK: - TOC Entry Row (Recursive for nested entries)
struct TOCEntryRow: View {
    let entry: TOCEntryModel
    @Bindable var viewModel: ReaderViewModel
    let depth: Int

    @Environment(SettingsManager.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                viewModel.goToTOCEntry(entry)
            } label: {
                HStack {
                    Text(entry.title)
                        .font(.subheadline)
                        .foregroundStyle(settings.theme.textColor)
                        .padding(.leading, CGFloat(depth * 16))

                    Spacer()
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            // Render children recursively
            ForEach(entry.children.sorted(by: { $0.order < $1.order })) { child in
                TOCEntryRow(entry: child, viewModel: viewModel, depth: depth + 1)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ReaderView(book: BookModel(title: "Sample Book", authors: ["Author"]), onDismiss: {})
    }
    .modelContainer(for: BookModel.self)
}
