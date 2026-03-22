import Foundation
import Network
@testable import LightFrame

// MARK: - MockArtConnection
//
// A fake SamsungConnection that can be injected into SamsungArtService for testing.
// Scripted responses are keyed by the "request" field in the inner payload.
//
// Usage:
//   let mock = MockArtConnection()
//   mock.scriptResponse(for: "get_content_list", response: ...)
//   let service = SamsungArtService(testConnection: mock)
//   let items = try await service.fetchArtList()
//
actor MockArtConnection: ArtConnectionProtocol {

    // MARK: - State

    private(set) var state: SamsungConnection.State = .disconnected
    var token: String? = "mock-token-abc"

    // MARK: - Response Scripting

    /// Scripted responses keyed by request name (e.g., "get_content_list")
    private var scriptedResponses: [String: ScriptedResponse] = [:]

    /// Ordered list of all commands sent (for assertion)
    private(set) var sentCommands: [SentCommand] = []

    /// Number of times connect() was called
    private(set) var connectCount: Int = 0

    /// Number of times disconnect() was called
    private(set) var disconnectCount: Int = 0

    /// If set, connect() will throw this error
    var connectError: Error?

    /// If set, all sendCommand calls will throw this (simulates connection death)
    var globalError: Error?

    /// Artificial delay before returning responses (seconds)
    var responseDelay: TimeInterval = 0

    /// Log handler (mirrors SamsungConnection)
    var logHandler: ((String) -> Void)?

    struct SentCommand: Sendable {
        let request: String
        let params: [String: String]  // Simplified — string values only
        let waitForEvent: String?
        let timeout: TimeInterval
    }

    struct ScriptedResponse {
        let inner: SamsungArtParser.InnerMessage
        var callCount: Int = 0
        /// If set, throw this error instead of returning the response
        var error: Error?
        /// If set, throw on the Nth call (1-indexed), return response otherwise
        var failOnCall: Int?
    }

    // MARK: - Scripting API

    /// Script a successful response for a given request type.
    func scriptResponse(for request: String, inner: SamsungArtParser.InnerMessage) {
        scriptedResponses[request] = ScriptedResponse(inner: inner)
    }

    /// Script an error for a given request type.
    func scriptError(for request: String, error: Error) {
        scriptedResponses[request] = ScriptedResponse(
            inner: makeInner(event: "error"),
            error: error
        )
    }

    /// Script a response that fails on a specific call number then succeeds.
    func scriptFailThenSucceed(for request: String, failOnCall: Int, error: Error, inner: SamsungArtParser.InnerMessage) {
        scriptedResponses[request] = ScriptedResponse(inner: inner, error: error, failOnCall: failOnCall)
    }

    /// Script a TV error response (event="error" with error_code).
    func scriptTVError(for request: String, errorCode: String) {
        let requestDataStr = "{\"request\":\"\(request)\"}"
        let inner = makeInner(event: "error", fields: [
            "error_code": errorCode,
            "request_data": requestDataStr
        ])
        scriptedResponses[request] = ScriptedResponse(inner: inner)
    }

    /// Clear all scripted responses and sent commands.
    func reset() {
        scriptedResponses.removeAll()
        sentCommands.removeAll()
        connectCount = 0
        disconnectCount = 0
        connectError = nil
        globalError = nil
        responseDelay = 0
        state = .disconnected
    }

    // MARK: - Connection Interface (mirrors SamsungConnection)

    func connect() async throws {
        connectCount += 1
        if let err = connectError {
            state = .error(err.localizedDescription)
            throw err
        }
        state = .connected
    }

    func disconnect() {
        disconnectCount += 1
        state = .disconnected
    }

    var isConnected: Bool { state == .connected }

    var currentToken: String? { token }

    func clearEarlyEvents() {}

    func setLogHandler(_ handler: ((String) -> Void)?) {
        logHandler = handler
    }

    func sendCommand(
        _ innerParams: [String: Any],
        waitForEvent: String? = nil,
        timeout: TimeInterval = 5
    ) async throws -> SamsungArtParser.InnerMessage {
        if let err = globalError { throw err }

        let requestType = innerParams["request"] as? String ?? "unknown"

        // Record the command
        var stringParams: [String: String] = [:]
        for (key, value) in innerParams {
            stringParams[key] = "\(value)"
        }
        sentCommands.append(SentCommand(
            request: requestType,
            params: stringParams,
            waitForEvent: waitForEvent,
            timeout: timeout
        ))

        logHandler?("MockArtConnection: sendCommand(\(requestType))")

        // Apply delay
        if responseDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        }

        // Find scripted response
        guard var response = scriptedResponses[requestType] else {
            throw SamsungArtError.timeout("\(requestType) — no scripted response")
        }

        // Track call count
        response.callCount += 1
        scriptedResponses[requestType] = response

        // Check if this call should fail
        if let failOn = response.failOnCall, response.callCount == failOn {
            throw response.error!
        } else if response.failOnCall == nil, let err = response.error {
            throw err
        }

        // Check for TV error
        let inner = response.inner
        if inner.isError {
            let reqName = inner.errorRequestName ?? requestType
            let code = inner.errorCode ?? "unknown"
            throw SamsungArtError.tvError(request: reqName, errorCode: code)
        }

        return inner
    }

    func waitForEvent(_ eventName: String, timeout: TimeInterval) async throws -> SamsungArtParser.InnerMessage {
        if let err = globalError { throw err }

        logHandler?("MockArtConnection: waitForEvent(\(eventName))")

        // Look for scripted response keyed by event name
        if let response = scriptedResponses[eventName] {
            if let err = response.error { throw err }
            return response.inner
        }

        throw SamsungArtError.timeout("waitForEvent(\(eventName)) — no scripted response")
    }

    // MARK: - TCP Stubs (not used in non-TCP tests)

    func openTCPSocket(connInfo: ConnInfo) async throws -> NWConnection {
        // For service-level tests that don't reach TCP, this should never be called.
        // If it is, fail loudly so we know the test needs TCP mocking.
        fatalError("MockArtConnection.openTCPSocket called — TCP mocking not implemented for this test")
    }

    func tcpSend(connection: NWConnection, data: Data, isComplete: Bool) async throws {
        fatalError("MockArtConnection.tcpSend called — TCP mocking not implemented for this test")
    }

    func tcpReceive(connection: NWConnection, length: Int) async throws -> Data {
        fatalError("MockArtConnection.tcpReceive called — TCP mocking not implemented for this test")
    }

    // MARK: - Helpers

    /// Build an InnerMessage for scripting responses.
    nonisolated func makeInner(
        event: String,
        requestID: String? = nil,
        fields: [String: Any] = [:]
    ) -> SamsungArtParser.InnerMessage {
        var raw: [String: Any] = ["event": event]
        if let rid = requestID { raw["request_id"] = rid }
        for (k, v) in fields { raw[k] = v }
        return SamsungArtParser.InnerMessage(
            event: event,
            requestID: requestID,
            raw: raw
        )
    }

    /// Build a content list response inner message.
    nonisolated func makeContentListResponse(items: [[String: Any]], requestID: String? = nil) -> SamsungArtParser.InnerMessage {
        let listData = try! JSONSerialization.data(withJSONObject: items)
        let listString = String(data: listData, encoding: .utf8)!
        return makeInner(event: "get_content_list", requestID: requestID, fields: [
            "content_list": listString
        ])
    }

    /// Build a slideshow status response.
    nonisolated func makeSlideshowResponse(value: String, type: String, categoryID: String? = nil) -> SamsungArtParser.InnerMessage {
        var fields: [String: Any] = ["value": value, "type": type]
        if let cat = categoryID { fields["category_id"] = cat }
        return makeInner(event: "get_slideshow_status", fields: fields)
    }
}
