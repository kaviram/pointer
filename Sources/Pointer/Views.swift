import AppKit
import SwiftUI

// MARK: - Root

struct RootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 420, height: 520)
    }

    @ViewBuilder
    private var header: some View {
        if state.phase == .confirming {
            HStack {
                Text("Confirm capture")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            Picker("", selection: $state.tab) {
                ForEach(PopoverTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .confirming:
            ConfirmView(state: state)
        case .idle:
            HistoryView(state: state, history: state.history, settings: state.settings)
        case .analyzing, .result, .failed:
            if state.tab == .result {
                AnalysisView(state: state)
            } else {
                HistoryView(state: state, history: state.history, settings: state.settings)
            }
        }
    }
}

// MARK: - Confirm

struct ConfirmView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let capture = state.capture {
                CapturePreview(image: capture.image)
                    .frame(maxWidth: .infinity)
                    .frame(height: 210)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $state.selectedPromptId) {
                    ForEach(state.settings.settings.prompts) { prompt in
                        Text(prompt.name).tag(prompt.id)
                    }
                }
                .labelsHidden()
            }

            if let capture = state.capture {
                Text(CostEstimate.describe(settings: state.settings.settings, image: capture.image))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button("Cancel") { state.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Analyze") { state.analyze() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }
}

struct CapturePreview: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: NSScreen.main?.backingScaleFactor ?? 2)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Analysis

struct AnalysisView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metaLine
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error = state.errorMessage {
                        errorBox(error)
                    }

                    if state.responseText.isEmpty, state.phase == .analyzing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(state.isThinking ? "Thinking…" : "Sending…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !state.responseText.isEmpty {
                        Text(renderMarkdown(state.responseText))
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }

            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(state.activePromptName)
                .font(.caption.weight(.medium))
            Text("·")
                .foregroundStyle(.tertiary)
            Text(state.settings.settings.activeModel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if state.elapsed > 0 {
                Text(String(format: "%.1fs", state.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Button("Retry") { state.retry() }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                state.copyResponse()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(state.responseText.isEmpty)

            Menu("Re-run") {
                ForEach(state.settings.settings.prompts) { prompt in
                    Button(prompt.name) { state.rerun(promptId: prompt.id) }
                }
            }
            .disabled(state.capture == nil || state.phase == .analyzing)
            .fixedSize()

            Spacer()

            Button("Close") { state.cancel() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var state: AppState
    /// Observed explicitly: AppState holds `history` as a plain `let`, so
    /// without this a freshly analyzed snippet wouldn't appear until the
    /// popover was reopened.
    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: SettingsStore
    @State private var query: String = ""
    @State private var selected: HistoryEntry?

    var body: some View {
        if let entry = selected {
            HistoryDetailView(history: history, entry: entry) { selected = nil }
        } else {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Search explanations", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            let results = history.search(query)

            if results.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text(history.entries.isEmpty ? "No snippets analyzed yet." : "No matches.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    if history.entries.isEmpty {
                        Text("Press \(settings.settings.hotkey.displayString) to capture one.")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 11))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { entry in
                            HistoryRow(history: history, entry: entry)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = entry }
                                .contextMenu {
                                    Button("Copy Explanation") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(entry.response, forType: .string)
                                    }
                                    Button("Delete", role: .destructive) {
                                        history.delete(entry)
                                    }
                                }
                            Divider()
                        }
                    }
                }

                Divider()
                HStack {
                    Text("\(history.entries.count) saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear All") { history.clearAll() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }
}

struct HistoryRow: View {
    @ObservedObject var history: HistoryStore
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let image = history.image(for: entry) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 56, height: 34)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.promptName)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(relativeTime(entry.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text(entry.firstLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct HistoryDetailView: View {
    @ObservedObject var history: HistoryStore
    let entry: HistoryEntry
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                Spacer()
                Text(entry.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let image = history.image(for: entry) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                    }

                    Text(entry.promptName)
                        .font(.system(size: 12, weight: .semibold))

                    Text(renderMarkdown(entry.response))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }

            Divider()
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.response, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("Delete", role: .destructive) {
                    history.delete(entry)
                    onBack()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

func relativeTime(_ date: Date) -> String {
    relativeFormatter.localizedString(for: date, relativeTo: Date())
}
