import SwiftUI
import Combine

// MARK: - ProtocolTestSheet
//
// Runs SamsungArtService protocol tests against a TV and displays results.
// Opened from the TV context menu in TVRowView.
//
// Uses the LIVE artService from TVConnectionManager rather than creating
// a competing connection. The Samsung TV only handles one art channel
// client reliably — a second concurrent connection causes hangs.
//
struct ProtocolTestSheet: View {
    let tv: TV
    let artService: SamsungArtService
    @Environment(\.dismiss) private var dismiss

    @StateObject private var runner = TestRunner()

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ───────────────────────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Protocol Tests")
                        .font(.headline)
                    Text("\(tv.name) — \(tv.ipAddress)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()

                if runner.isRunning {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 4)
                }

                Button(runner.isRunning ? "Running…" : (runner.hasRun ? "Run Again" : "Run All")) {
                    runner.runAll(artService: artService, tv: tv)
                }
                .disabled(runner.isRunning)

                Button("Close") { dismiss() }
            }
            .padding()

            Divider()

            // ── Results Table ─────────────────────────────────────────────────
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(runner.results) { result in
                        TestResultRow(result: result)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .frame(minHeight: 200)

            Divider()

            // ── Protocol Log ──────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Protocol Log")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(runner.logLines.joined(separator: "\n"), forType: .string)
                    }
                    .font(.caption)
                    .disabled(runner.logLines.isEmpty)

                    Button("Clear") {
                        runner.logLines.removeAll()
                    }
                    .font(.caption)
                    .disabled(runner.logLines.isEmpty)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(runner.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(logColor(for: line))
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: runner.logLines.count) { _ in
                        if let last = runner.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .cornerRadius(4)
            }
            .padding()
        }
        .frame(width: 600, height: 560)
    }

    private func logColor(for line: String) -> Color {
        if line.contains("❌") || line.contains("Error") { return .red }
        if line.contains("✅") { return .green }
        if line.contains("⚠️") { return .orange }
        if line.contains("📤") || line.contains("📩") { return .secondary }
        return .primary
    }
}

// MARK: - TestResultRow

private struct TestResultRow: View {
    let result: TestResultItem

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch result.state {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                case .running:
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                case .passed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                case .skipped:
                    Image(systemName: "minus.circle")
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 16)

            Text(result.displayName)
                .frame(width: 120, alignment: .leading)

            if let duration = result.duration {
                Text(String(format: "%.1fs", duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 45, alignment: .trailing)
            } else {
                Text("")
                    .frame(width: 45)
            }

            Text(result.detail)
                .font(.caption)
                .foregroundColor(result.state == .failed ? .red : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(result.state == .running ? Color.accentColor.opacity(0.05) : Color.clear)
        .cornerRadius(4)
    }
}

// MARK: - TestResultItem

enum TestState {
    case pending, running, passed, failed, skipped
}

struct TestResultItem: Identifiable {
    let id: String
    var state: TestState = .pending
    var duration: TimeInterval?
    var detail: String = ""

    var displayName: String {
        id.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - TestRunner
//
// Uses the LIVE artService from TVConnectionManager.
// The "connect" test verifies the existing connection rather than
// creating a competing one that would hang.
//
@MainActor
class TestRunner: ObservableObject {
    @Published var results: [TestResultItem] = SamsungArtService.availableTests.map { TestResultItem(id: $0) }
    @Published var isRunning = false
    @Published var hasRun = false
    @Published var logLines: [String] = []

    private var runTask: Task<Void, Never>?
    private var originalLogHandler: ((String) -> Void)?

    func runAll(artService: SamsungArtService, tv: TV) {
        // Reset
        results = SamsungArtService.availableTests.map { TestResultItem(id: $0) }
        logLines.removeAll()
        isRunning = true
        hasRun = true

        // Intercept log handler to capture protocol log in the sheet
        originalLogHandler = artService.logHandler
        artService.logHandler = { [weak self] line in
            Task { @MainActor [weak self] in
                self?.logLines.append(line)
            }
            // Also forward to original handler (console)
            self?.originalLogHandler?(line)
        }

        runTask = Task { [weak self] in
            guard let self else { return }

            var connectPassed = false

            for i in self.results.indices {
                guard !Task.isCancelled else { break }

                let testName = self.results[i].id

                // Skip everything after connect if connect failed
                if testName != "connect" && !connectPassed {
                    self.results[i].state = .skipped
                    self.results[i].detail = "Skipped (connect failed)"
                    continue
                }

                self.results[i].state = .running
                self.logLines.append("── Running: \(testName) ──")

                let result = await artService.runTest(testName)

                self.results[i].state = result.success ? .passed : .failed
                self.results[i].duration = result.duration
                self.results[i].detail = result.detail

                if testName == "connect" {
                    connectPassed = result.success
                }

                self.logLines.append("\(result.success ? "✅" : "❌") \(testName): \(result.detail) (\(String(format: "%.1fs", result.duration)))")
            }

            // Restore original log handler
            artService.logHandler = self.originalLogHandler

            self.isRunning = false
            self.logLines.append("── Tests complete ──")
        }
    }

    deinit {
        runTask?.cancel()
    }
}
