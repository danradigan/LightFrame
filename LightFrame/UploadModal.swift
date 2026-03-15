import SwiftUI

// MARK: - UploadModal
// The sheet shown during an upload or delete operation.
// Displays a progress bar, current file name, time remaining, and a Cancel button.
// After completion, shows a summary and a Done button.
//
// This view is purely a display layer — all logic lives in UploadEngine.
// It observes the engine's @Published properties and reacts to changes.
struct UploadModal: View {
    @ObservedObject var engine: UploadEngine

    // Called when the user taps Done after completion, or after cancel winds down
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Header
            HStack {
                Text(headerTitle)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // MARK: Body
            VStack(spacing: 20) {

                if engine.isComplete {
                    // ── Summary after completion ──────────────────────────
                    CompletionSummaryView(engine: engine)

                } else {
                    // ── Active upload progress ────────────────────────────

                    // Current file name
                    HStack {
                        if engine.isCancelled {
                            Label("Cancelling…", systemImage: "xmark.circle")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Uploading")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(engine.currentPhotoName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        // Photo count — e.g. "12 of 273"
                        Text("\(engine.currentIndex + 1) of \(engine.totalCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    // Progress bar
                    VStack(spacing: 6) {
                        ProgressView(value: engine.progress)
                            .progressViewStyle(.linear)

                        HStack {
                            // Time remaining estimate
                            Text(engine.timeRemainingString)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            // Percentage
                            Text("\(Int(engine.progress * 100))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }

                    // Per-item scroll list — shows each photo's status
                    // Capped height so the modal doesn't grow taller than the screen
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(engine.items) { item in
                                    UploadItemRow(item: item)
                                        .id(item.id)
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        // Auto-scroll to keep the current item visible
                        .onChange(of: engine.currentIndex) {
                            let id = engine.items[safe: engine.currentIndex]?.id
                            if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                        }
                    }
                }
            }
            .padding(24)

            Divider()

            // MARK: Footer Buttons
            HStack {
                if engine.isComplete {
                    // Show "Retry Failed" if there were failures
                    if engine.failedCount > 0 && !engine.isCancelled {
                        Button("Retry Failed (\(engine.failedCount))") {
                            Task { await engine.retryFailed() }
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("Done") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                    Button(engine.isCancelled ? "Cancelling…" : "Cancel") {
                        engine.cancel()
                    }
                    .disabled(engine.isCancelled)
                    .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 460)
        // Sheet for duplicate prompt — appears over this modal
        .sheet(item: $engine.pendingDuplicate) { duplicate in
            DuplicatePromptSheet(
                item: duplicate,
                onResolve: { resolution, applyToAll in
                    engine.resolveDuplicate(resolution, applyToAll: applyToAll)
                }
            )
        }
    }

    // MARK: - Header Title
    private var headerTitle: String {
        if engine.isComplete {
            if engine.isCancelled { return "Upload Cancelled" }
            return "Upload Complete"
        }
        return "Uploading \(engine.totalCount) Photo\(engine.totalCount == 1 ? "" : "s")"
    }
}

// MARK: - Completion Summary
// Shown after the upload finishes (success or cancelled).
// Gives a quick breakdown of what happened.
struct CompletionSummaryView: View {
    @ObservedObject var engine: UploadEngine

    var body: some View {
        VStack(spacing: 16) {

            // Big icon — checkmark or xmark
            Image(systemName: engine.isCancelled ? "xmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(engine.isCancelled ? .secondary : .green)

            // Summary counts
            VStack(spacing: 8) {
                SummaryRow(
                    icon: "arrow.up.circle.fill",
                    color: .green,
                    label: "Uploaded",
                    count: engine.doneCount
                )
                if engine.skippedCount > 0 {
                    SummaryRow(
                        icon: "forward.fill",
                        color: .secondary,
                        label: "Skipped (already on TV)",
                        count: engine.skippedCount
                    )
                }
                if engine.failedCount > 0 {
                    SummaryRow(
                        icon: "exclamationmark.circle.fill",
                        color: .red,
                        label: "Failed",
                        count: engine.failedCount
                    )
                }
                if engine.pendingCount > 0 && engine.isCancelled {
                    SummaryRow(
                        icon: "minus.circle",
                        color: .orange,
                        label: "Not uploaded (cancelled)",
                        count: engine.pendingCount
                    )
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
    }
}

// MARK: - Summary Row
struct SummaryRow: View {
    let icon: String
    let color: Color
    let label: String
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text("\(count)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }
}

// MARK: - Upload Item Row
// One row in the scrollable item list inside the modal.
// Shows an icon representing the current state + file name.
struct UploadItemRow: View {
    let item: UploadItem

    var body: some View {
        HStack(spacing: 10) {
            stateIcon
                .frame(width: 16)
            Text(item.photo.filename)
                .font(.caption)
                .foregroundColor(labelColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            stateLabel
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var isActive: Bool {
        if case .uploading = item.state { return true }
        return false
    }

    private var labelColor: Color {
        switch item.state {
        case .failed: return .red
        case .skipped: return .secondary
        default: return .primary
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch item.state {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.secondary)
                .font(.caption)
        case .uploading:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        case .skipped:
            Image(systemName: "forward.fill")
                .foregroundColor(.secondary)
                .font(.caption)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch item.state {
        case .pending:   Text("")
        case .uploading: Text("Uploading…")
        case .done:      Text("Done")
        case .skipped:   Text("Skipped")
        case .failed(let msg): Text(msg).lineLimit(1)
        }
    }
}

// MARK: - Array Safe Subscript
// Prevents crashes when accessing items[engine.currentIndex] near the end of the array
extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
