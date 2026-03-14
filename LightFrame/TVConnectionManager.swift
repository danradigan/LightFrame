//
//  TVConnectionManager.swift
//  LightFrame
//
//  Created by Dan Radigan on 3/14/26.
//


import Foundation
import SwiftUI
import Combine

// MARK: - TVConnectionManager
// Manages the active WebSocket connection to the selected TV.
// Automatically connects when the selected TV changes.
// Updates AppState reachability so the green dot reflects real connection state.
@MainActor
class TVConnectionManager: ObservableObject {

    @Published var connection: TVConnection?
    @Published var statusMessage: String = ""

    private var appState: AppState
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState
        observeSelectedTV()
    }

    // MARK: - Observe Selected TV
    // Whenever the user switches TVs, disconnect from the old one
    // and connect to the new one automatically.
    private func observeSelectedTV() {
        appState.$selectedTV
            .removeDuplicates()
            .sink { [weak self] tv in
                Task { @MainActor in
                    await self?.switchTo(tv: tv)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Switch TV
    private func switchTo(tv: TV?) async {
        // Disconnect from current connection
        connection?.disconnect()
        connection = nil

        guard let tv = tv else {
            appState.updateReachability(false, for: appState.tvs.first ?? TV(
                id: UUID(), name: "", ipAddress: "", token: nil, isReachable: false
            ))
            return
        }

        // Create a new connection for the selected TV
        let newConnection = TVConnection(tv: tv)
        connection = newConnection

        // Observe connection state changes to update the green dot
        newConnection.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                let reachable = state == .connected
                self.appState.updateReachability(reachable, for: tv)
                if case .error(let msg) = state {
                    self.statusMessage = msg
                } else if state == .connected {
                    self.statusMessage = "Connected to \(tv.name)"
                }
            }
            .store(in: &cancellables)

        // Attempt connection
        statusMessage = "Connecting to \(tv.name)..."
        await newConnection.connect()
    }

    // MARK: - Reconnect
    func reconnect() async {
        if let tv = appState.selectedTV {
            await switchTo(tv: tv)
        }
    }

    // MARK: - Send Slideshow Order
    func setSlideshowOrder(_ order: SlideshowOrder) async -> Bool {
        guard let conn = connection, conn.state == .connected else { return false }
        do {
            try await conn.setSlideshowOrder(order)
            return true
        } catch {
            statusMessage = "Failed to set order: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Send Slideshow Interval
    func setSlideshowInterval(_ interval: SlideshowInterval) async -> Bool {
        guard let conn = connection, conn.state == .connected else { return false }
        do {
            try await conn.setSlideshowInterval(interval)
            return true
        } catch {
            statusMessage = "Failed to set interval: \(error.localizedDescription)"
            return false
        }
    }
}