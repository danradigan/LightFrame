import Foundation
import Network

// MARK: - ArtConnectionProtocol
//
// Abstraction over SamsungConnection for testability.
// SamsungArtService uses this protocol for command-based operations.
// Both SamsungConnection and MockArtConnection (in tests) conform.
//
protocol ArtConnectionProtocol: Actor {
    func connect() async throws
    func disconnect()

    func sendCommand(
        _ innerParams: [String: Any],
        waitForEvent: String?,
        timeout: TimeInterval
    ) async throws -> SamsungArtParser.InnerMessage

    func waitForEvent(
        _ eventName: String,
        timeout: TimeInterval
    ) async throws -> SamsungArtParser.InnerMessage

    func setLogHandler(_ handler: ((String) -> Void)?)

    var isConnected: Bool { get }
    var currentToken: String? { get }

    // TCP operations — used by upload and thumbnail methods.
    func openTCPSocket(connInfo: ConnInfo) async throws -> NWConnection
    func tcpSend(connection: NWConnection, data: Data, isComplete: Bool) async throws
    func tcpReceive(connection: NWConnection, length: Int) async throws -> Data
}

