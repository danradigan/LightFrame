import SwiftUI
import Foundation
import Combine

// MARK: - ConnectionDiagnosticSheet
//
// Standalone diagnostic tool that probes a TV's connection step by step.
// Works even when the TV won't connect — that's the whole point.
//
// Probes in order:
//   1. REST API (port 8001) — is the TV on the network?
//   2. WebSocket remote control (port 8002) — can we handshake?
//   3. Token exchange — does the TV issue a pairing token?
//   4. Art channel open — does ms.channel.connect arrive?
//   5. Art channel ready — does ms.channel.ready arrive?
//   6. Art command — can we send get_artmode_status?
//
// Each step reports success/failure with raw response data.
// The full report can be copied as JSON for sharing.
//
struct ConnectionDiagnosticSheet: View {
    @State var ipAddress: String
    @Environment(\.dismiss) private var dismiss

    @StateObject private var runner = DiagnosticRunner()

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Diagnostics")
                        .font(.headline)
                    Text("Step-by-step connection probe")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()

                if runner.isRunning {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 4)
                }

                Button(runner.isRunning ? "Running…" : (runner.hasRun ? "Run Again" : "Run")) {
                    runner.run(ip: ipAddress)
                }
                .disabled(runner.isRunning || ipAddress.isEmpty)

                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.jsonReport, forType: .string)
                }
                .disabled(!runner.hasRun || runner.isRunning)

                Button("Close") { dismiss() }
            }
            .padding()

            // ── IP Input ────────────────────────────────────────────
            HStack {
                Text("TV IP:")
                    .font(.caption)
                TextField("192.168.1.100", text: $ipAddress)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit {
                        if !runner.isRunning && !ipAddress.isEmpty {
                            runner.run(ip: ipAddress)
                        }
                    }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // ── Results ─────────────────────────────────────────────
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(runner.steps) { step in
                        DiagnosticStepRow(step: step)
                    }
                }
                .padding()
            }
            .frame(minHeight: 200)

            Divider()

            // ── Raw Log ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Text("Raw Log")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(runner.logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: runner.logLines.count) {
                        if let last = runner.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .frame(minHeight: 100, maxHeight: 160)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .cornerRadius(4)
            }
            .padding()
        }
        .frame(width: 650, height: 520)
    }
}

// MARK: - DiagnosticStepRow

private struct DiagnosticStepRow: View {
    let step: DiagnosticStep

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch step.state {
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

            Text(step.name)
                .frame(width: 180, alignment: .leading)

            if let duration = step.duration {
                Text(String(format: "%.1fs", duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 45, alignment: .trailing)
            } else {
                Text("")
                    .frame(width: 45)
            }

            Text(step.detail)
                .font(.caption)
                .foregroundColor(step.state == .failed ? .red : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - DiagnosticStep

struct DiagnosticStep: Identifiable {
    let id: String
    let name: String
    var state: TestState = .pending
    var duration: TimeInterval?
    var detail: String = ""
    var rawData: [String: Any] = [:]
}

// MARK: - DiagnosticRunner

@MainActor
class DiagnosticRunner: ObservableObject {
    @Published var steps: [DiagnosticStep] = defaultSteps()
    @Published var isRunning = false
    @Published var hasRun = false
    @Published var logLines: [String] = []
    @Published var jsonReport: String = ""

    private var runTask: Task<Void, Never>?

    static func defaultSteps() -> [DiagnosticStep] {
        [
            DiagnosticStep(id: "rest_api", name: "1. REST API (port 8001)"),
            DiagnosticStep(id: "ws_remote", name: "2. WebSocket Remote Control"),
            DiagnosticStep(id: "token", name: "3. Token Exchange"),
            DiagnosticStep(id: "ws_art_connect", name: "4. Art Channel Connect"),
            DiagnosticStep(id: "ws_art_ready", name: "5. Art Channel Ready"),
            DiagnosticStep(id: "art_command", name: "6. Art Command Test"),
        ]
    }

    func run(ip: String) {
        steps = Self.defaultSteps()
        logLines = []
        isRunning = true
        hasRun = true

        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runProbe(ip: ip)
            self.isRunning = false
        }
    }

    private func log(_ msg: String) {
        logLines.append(msg)
    }

    private func update(_ id: String, state: TestState, detail: String, duration: TimeInterval? = nil, rawData: [String: Any] = [:]) {
        if let idx = steps.firstIndex(where: { $0.id == id }) {
            steps[idx].state = state
            steps[idx].detail = detail
            steps[idx].duration = duration
            steps[idx].rawData = rawData
        }
    }

    private func skipRemaining(after id: String, reason: String) {
        var found = false
        for i in steps.indices {
            if steps[i].id == id { found = true; continue }
            if found && steps[i].state == .pending {
                steps[i].state = .skipped
                steps[i].detail = reason
            }
        }
    }

    // MARK: - Probe Sequence

    private func runProbe(ip: String) async {
        var report: [String: Any] = [
            "probe_version": 1,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "target_ip": ip
        ]

        // ── Step 1: REST API ────────────────────────────────────
        update("rest_api", state: .running, detail: "Querying...")
        let restStart = Date()
        log("── Step 1: REST API at http://\(ip):8001/api/v2/ ──")

        let restResult = await probeRESTAPI(ip: ip)
        let restDuration = Date().timeIntervalSince(restStart)

        if let info = restResult {
            update("rest_api", state: .passed,
                   detail: "\(info["name"] ?? "Unknown") (\(info["model"] ?? "?"))",
                   duration: restDuration, rawData: info)
            report["rest_api"] = ["status": "pass", "data": info, "time_ms": Int(restDuration * 1000)]
            log("  Name: \(info["name"] ?? "?")")
            log("  Model: \(info["model"] ?? "?")")
            log("  FrameTVSupport: \(info["FrameTVSupport"] ?? "?")")
        } else {
            update("rest_api", state: .failed,
                   detail: "No response — TV may be off, wrong IP, or not a Samsung TV",
                   duration: restDuration)
            report["rest_api"] = ["status": "fail", "time_ms": Int(restDuration * 1000)]
            log("  FAILED — no response")
            skipRemaining(after: "rest_api", reason: "REST API unreachable")
            buildReport(report)
            return
        }

        // ── Step 2: WebSocket Remote Control ────────────────────
        update("ws_remote", state: .running, detail: "Connecting WSS...")
        let wsStart = Date()
        log("── Step 2: WebSocket to samsung.remote.control (port 8002) ──")

        let (wsSuccess, wsEvent, wsRawData, wsToken) = await probeRemoteControl(ip: ip)
        let wsDuration = Date().timeIntervalSince(wsStart)

        if wsSuccess {
            update("ws_remote", state: .passed,
                   detail: "Got \(wsEvent ?? "connect")",
                   duration: wsDuration)
            report["ws_remote"] = ["status": "pass", "event": wsEvent ?? "", "time_ms": Int(wsDuration * 1000)]
            log("  Event: \(wsEvent ?? "?")")
        } else {
            update("ws_remote", state: .failed,
                   detail: wsEvent ?? "Connection failed",
                   duration: wsDuration)
            report["ws_remote"] = ["status": "fail", "detail": wsEvent ?? "unknown", "time_ms": Int(wsDuration * 1000)]
            log("  FAILED: \(wsEvent ?? "unknown")")
            skipRemaining(after: "ws_remote", reason: "WebSocket handshake failed")
            buildReport(report)
            return
        }

        // ── Step 3: Token ───────────────────────────────────────
        if let token = wsToken {
            update("token", state: .passed, detail: "Token: \(token.prefix(12))...")
            report["token"] = ["status": "pass", "token_prefix": String(token.prefix(12))]
            log("  Token: \(token.prefix(20))...")
        } else {
            update("token", state: .passed, detail: "No token (TV may not require pairing)")
            report["token"] = ["status": "pass", "note": "no token returned"]
            log("  No token in response (may not require pairing)")
        }

        // ── Step 4 & 5: Art Channel ─────────────────────────────
        update("ws_art_connect", state: .running, detail: "Opening art channel...")
        let artStart = Date()
        log("── Step 4-5: Art channel (com.samsung.art-app) ──")

        let (artConnected, artReady, artError) = await probeArtChannel(ip: ip, token: wsToken)
        let artDuration = Date().timeIntervalSince(artStart)

        if artConnected {
            update("ws_art_connect", state: .passed,
                   detail: "ms.channel.connect received",
                   duration: artDuration)
            report["ws_art_connect"] = ["status": "pass", "time_ms": Int(artDuration * 1000)]
            log("  ms.channel.connect: OK")
        } else {
            update("ws_art_connect", state: .failed,
                   detail: artError ?? "No connect event",
                   duration: artDuration)
            report["ws_art_connect"] = ["status": "fail", "detail": artError ?? "unknown"]
            log("  FAILED: \(artError ?? "no connect event")")
            update("ws_art_ready", state: .skipped, detail: "Connect failed")
            skipRemaining(after: "ws_art_ready", reason: "Art channel connect failed")
            buildReport(report)
            return
        }

        if artReady {
            update("ws_art_ready", state: .passed, detail: "ms.channel.ready received")
            report["ws_art_ready"] = ["status": "pass"]
            log("  ms.channel.ready: OK")
        } else {
            update("ws_art_ready", state: .failed,
                   detail: artError ?? "No ready event",
                   duration: artDuration)
            report["ws_art_ready"] = ["status": "fail", "detail": artError ?? "unknown"]
            log("  FAILED: \(artError ?? "no ready event")")
            skipRemaining(after: "ws_art_ready", reason: "Art channel not ready")
            buildReport(report)
            return
        }

        // ── Step 6: Art Command ─────────────────────────────────
        update("art_command", state: .running, detail: "Sending get_artmode_status...")
        let cmdStart = Date()
        log("── Step 6: Art command (get_artmode_status) ──")

        let (cmdSuccess, cmdDetail, cmdRaw) = await probeArtCommand(ip: ip, token: wsToken)
        let cmdDuration = Date().timeIntervalSince(cmdStart)

        if cmdSuccess {
            update("art_command", state: .passed, detail: cmdDetail, duration: cmdDuration)
            report["art_command"] = ["status": "pass", "detail": cmdDetail, "time_ms": Int(cmdDuration * 1000), "response_keys": Array((cmdRaw ?? [:]).keys)]
            log("  Response: \(cmdDetail)")
        } else {
            update("art_command", state: .failed, detail: cmdDetail, duration: cmdDuration)
            report["art_command"] = ["status": "fail", "detail": cmdDetail, "time_ms": Int(cmdDuration * 1000)]
            log("  FAILED: \(cmdDetail)")
        }

        log("── Diagnostics complete ──")
        buildReport(report)
    }

    // MARK: - Probe: REST API

    private nonisolated func probeRESTAPI(ip: String) async -> [String: String]? {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else { return nil }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let device = json["device"] as? [String: Any] else { return nil }

            var info: [String: String] = [:]
            info["name"] = (json["name"] as? String) ?? (device["name"] as? String)
            info["model"] = device["modelName"] as? String
            info["FrameTVSupport"] = device["FrameTVSupport"] as? String
            info["TokenAuthSupport"] = device["TokenAuthSupport"] as? String
            info["id"] = device["id"] as? String

            // Capture all device keys for diagnostic purposes
            info["all_device_keys"] = device.keys.sorted().joined(separator: ", ")

            return info
        } catch {
            return nil
        }
    }

    // MARK: - Probe: Remote Control WebSocket

    private nonisolated func probeRemoteControl(ip: String) async -> (success: Bool, event: String?, rawData: [String: Any]?, token: String?) {
        guard let url = SamsungArtProtocol.remoteControlURL(host: ip, port: 8002) else {
            return (false, "Invalid URL", nil, nil)
        }

        let sslDelegate = SSLBypassDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: sslDelegate, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        task.resume()

        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        let deadline = Date().addingTimeInterval(15)

        while Date() < deadline {
            do {
                let msg = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        let result = try await task.receive()
                        guard case .string(let text) = result else {
                            throw SamsungArtError.decodingFailed("Binary message")
                        }
                        return text
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(deadline.timeIntervalSinceNow * 1_000_000_000))
                        throw SamsungArtError.timeout("Handshake timeout")
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }

                guard let outer = SamsungArtParser.parseOuter(msg) else { continue }

                // Skip startup noise
                if SamsungArtParser.ignoreEventsAtStartup.contains(outer.event) { continue }

                if outer.event == SamsungArtParser.channelUnauthorized {
                    return (false, "ms.channel.unauthorized — TV rejected connection", nil, nil)
                }
                if outer.event == SamsungArtParser.channelTimeout {
                    return (false, "ms.channel.timeOut — token may be missing", nil, nil)
                }
                if outer.event == SamsungArtParser.errorEvent {
                    let errMsg = outer.data?["message"] as? String ?? "unknown"
                    return (false, "ms.error: \(errMsg)", nil, nil)
                }
                if outer.event == SamsungArtParser.channelConnect {
                    let token = SamsungArtParser.extractToken(from: outer)
                    return (true, "ms.channel.connect", outer.raw, token)
                }

                // Unexpected event — keep reading
                continue

            } catch {
                return (false, error.localizedDescription, nil, nil)
            }
        }

        return (false, "Timed out waiting for ms.channel.connect", nil, nil)
    }

    // MARK: - Probe: Art Channel

    private nonisolated func probeArtChannel(ip: String, token: String?) async -> (connected: Bool, ready: Bool, error: String?) {
        guard let url = SamsungArtProtocol.artChannelURL(host: ip, port: 8002, token: token) else {
            return (false, false, "Invalid art channel URL")
        }

        let sslDelegate = SSLBypassDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: sslDelegate, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        task.resume()

        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        // Phase 1: Wait for ms.channel.connect
        let connectDeadline = Date().addingTimeInterval(15)
        var gotConnect = false

        while Date() < connectDeadline {
            do {
                let text = try await receiveWithTimeout(task: task, timeout: connectDeadline.timeIntervalSinceNow)
                guard let outer = SamsungArtParser.parseOuter(text) else { continue }
                if SamsungArtParser.ignoreEventsAtStartup.contains(outer.event) { continue }

                if outer.event == SamsungArtParser.channelUnauthorized {
                    return (false, false, "ms.channel.unauthorized")
                }
                if outer.event == SamsungArtParser.channelTimeout {
                    return (false, false, "ms.channel.timeOut")
                }
                if outer.event == SamsungArtParser.channelConnect {
                    gotConnect = true
                    break
                }
            } catch {
                return (false, false, error.localizedDescription)
            }
        }

        if !gotConnect {
            return (false, false, "Timed out waiting for ms.channel.connect")
        }

        // Phase 2: Wait for ms.channel.ready
        do {
            let text = try await receiveWithTimeout(task: task, timeout: 10)
            guard let outer = SamsungArtParser.parseOuter(text) else {
                return (true, false, "Unparseable response after connect")
            }
            if outer.event == SamsungArtParser.channelReady {
                return (true, true, nil)
            }
            return (true, false, "Expected ms.channel.ready, got \(outer.event)")
        } catch {
            return (true, false, "Timeout waiting for ms.channel.ready: \(error.localizedDescription)")
        }
    }

    // MARK: - Probe: Art Command

    private nonisolated func probeArtCommand(ip: String, token: String?) async -> (success: Bool, detail: String, raw: [String: Any]?) {
        // Use a full SamsungConnection for this — it handles the full lifecycle
        let conn = SamsungConnection(host: ip, port: 8002, token: token, name: "LightFrame")
        do {
            try await conn.connect()
            let params = SamsungArtProtocol.getArtmodeStatus()
            let inner = try await conn.sendCommand(params, waitForEvent: nil, timeout: 10)
            let value = inner.raw["value"] as? String ?? "unknown"
            await conn.disconnect()
            return (true, "Art mode: \(value)", inner.raw)
        } catch {
            await conn.disconnect()
            return (false, error.localizedDescription, nil)
        }
    }

    // MARK: - Helpers

    private nonisolated func receiveWithTimeout(task: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let msg = try await task.receive()
                guard case .string(let text) = msg else {
                    throw SamsungArtError.decodingFailed("Binary message")
                }
                return text
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                throw SamsungArtError.timeout("Receive timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func buildReport(_ report: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            jsonReport = str
        }
    }

    deinit {
        runTask?.cancel()
    }
}
