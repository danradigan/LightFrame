import Foundation
import Combine
import Network

// MARK: - TVDiscovery
// Finds Samsung Frame TVs on the local network using SSDP
// (Simple Service Discovery Protocol).
//
// SSDP works by sending a UDP broadcast to 239.255.255.250:1900.
// Samsung TVs that hear it respond with their location URL,
// which we fetch to get the TV's name and model number.
@MainActor
class TVDiscovery: ObservableObject {

    // MARK: - Discovered TV
    struct DiscoveredTV: Identifiable, Equatable {
        let id = UUID()
        let name: String        // e.g. "Samsung The Frame (55)"
        let ipAddress: String   // e.g. "192.168.86.25"
        let modelName: String   // e.g. "QN55LS03B"
    }

    // MARK: - Published State
    @Published var discoveredTVs: [DiscoveredTV] = []
    @Published var isSearching: Bool = false

    // MARK: - Private
    private var connection: NWConnection?
    private var searchTask: Task<Void, Never>?

    // SSDP constants — these are part of the UPnP standard
    private let multicastAddress = "239.255.255.250"
    private let ssdpPort: UInt16 = 1900

    // The M-SEARCH message targeting Samsung remote control receivers
    private var searchMessage: String {
        "M-SEARCH * HTTP/1.1\r\n" +
        "HOST: 239.255.255.250:1900\r\n" +
        "MAN: \"ssdp:discover\"\r\n" +
        "MX: 3\r\n" +
        "ST: urn:samsung.com:device:RemoteControlReceiver:1\r\n" +
        "\r\n"
    }

    // MARK: - Start Search
    /// Broadcasts an SSDP search and collects responses for 5 seconds.
    func startSearch() async {
        guard !isSearching else { return }
        discoveredTVs = []
        isSearching = true
        print("🔍 TVDiscovery: Starting SSDP search...")

        searchTask = Task {
            sendSSDPBroadcast()
            // Wait 5 seconds for TV responses to arrive
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            isSearching = false
            print("🔍 TVDiscovery: Found \(discoveredTVs.count) TV(s)")
        }
    }

    /// Cancel an in-progress search
    func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        connection?.cancel()
        connection = nil
        isSearching = false
    }

    // MARK: - SSDP Broadcast
    private func sendSSDPBroadcast() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(multicastAddress),
            port: NWEndpoint.Port(rawValue: ssdpPort)!
        )

        connection = NWConnection(to: endpoint, using: .udp)
        connection?.start(queue: .global(qos: .userInitiated))

        guard let data = searchMessage.data(using: .utf8) else { return }

        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("🔍 TVDiscovery: Send error — \(error)")
            } else {
                print("🔍 TVDiscovery: SSDP broadcast sent")
                guard let self else { return }
                Task { @MainActor in
                    self.listenForResponses()
                }
            }
        })
    }

    // MARK: - Listen for Responses
    private func listenForResponses() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let data, let response = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self.handleResponse(response)
                }
            }

            // Keep listening until search ends
            if error == nil {
                Task { @MainActor in
                    if self.isSearching {
                        self.listenForResponses()
                    }
                }
            }
        }
    }

    // MARK: - Parse Response
    private func handleResponse(_ response: String) {
        // Pull the LOCATION header — it's a URL to the TV's description XML
        guard let locationLine = response
            .components(separatedBy: "\r\n")
            .first(where: { $0.uppercased().hasPrefix("LOCATION:") }),
              let url = URL(string: locationLine
                  .replacingOccurrences(of: "LOCATION:", with: "", options: .caseInsensitive)
                  .trimmingCharacters(in: .whitespaces)),
              let ip = url.host
        else { return }

        // Skip if we already found this TV
        guard !discoveredTVs.contains(where: { $0.ipAddress == ip }) else { return }

        // Fetch the TV's UPnP description to get its name
        Task {
            await fetchDescription(from: url, ip: ip)
        }
    }

    // MARK: - Fetch TV Description
    /// Downloads the TV's UPnP XML description to extract its friendly name
    private func fetchDescription(from url: URL, ip: String) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let xml = String(data: data, encoding: .utf8)
        else {
            addTV(name: "Samsung TV", ip: ip, model: "Unknown")
            return
        }

        let name  = xmlValue(xml, tag: "friendlyName") ?? "Samsung TV"
        let model = xmlValue(xml, tag: "modelName")    ?? "Unknown"
        addTV(name: name, ip: ip, model: model)
    }

    private func addTV(name: String, ip: String, model: String) {
        let tv = DiscoveredTV(name: name, ipAddress: ip, modelName: model)
        discoveredTVs.append(tv)
        print("📺 Found: \(name) (\(model)) at \(ip)")
    }

    /// Simple XML tag value extractor — avoids pulling in XMLParser for two tags
    private func xmlValue(_ xml: String, tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end   = xml.range(of: "</\(tag)>")
        else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}
