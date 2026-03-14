import Foundation
import Combine
import Network

// MARK: - TVDiscovery
// Discovers Samsung Frame TVs on the local network by scanning
// the current subnet and querying each IP on port 8001.
// This is more reliable than SSDP for Samsung TVs.
@MainActor
class TVDiscovery: ObservableObject {

    // MARK: - Discovered TV
    struct DiscoveredTV: Identifiable, Equatable {
        let id = UUID()
        let name: String        // e.g. "Buena Vista"
        let ipAddress: String   // e.g. "192.168.86.25"
        let modelName: String   // e.g. "QN75LS03BDFXZA"
    }

    // MARK: - Published State
    @Published var discoveredTVs: [DiscoveredTV] = []
    @Published var isSearching: Bool = false
    @Published var scanProgress: Double = 0  // 0.0 to 1.0

    private var searchTask: Task<Void, Never>?

    // MARK: - Start Search
    /// Scans the local subnet for Samsung Frame TVs using the REST API on port 8001.
    func startSearch() async {
        guard !isSearching else { return }
        discoveredTVs = []
        scanProgress = 0
        isSearching = true
        print("🔍 TVDiscovery: Starting subnet scan...")

        searchTask = Task {
            await scanSubnet()
            isSearching = false
            scanProgress = 1.0
            print("🔍 TVDiscovery: Scan complete — found \(discoveredTVs.count) Frame TV(s)")
        }
    }

    /// Stop an in-progress search
    func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    // MARK: - Subnet Scan
    private func scanSubnet() async {
        // Get the device's local IP to determine the subnet
        guard let localIP = getLocalIPAddress() else {
            print("🔍 TVDiscovery: Could not determine local IP")
            return
        }

        // Extract subnet prefix e.g. "192.168.86" from "192.168.86.10"
        let parts = localIP.components(separatedBy: ".")
        guard parts.count == 4 else { return }
        let subnet = "\(parts[0]).\(parts[1]).\(parts[2])"

        print("🔍 TVDiscovery: Scanning subnet \(subnet).1-254")

        let total = 254.0
        var completed = 0

        // Scan all 254 addresses concurrently
        await withTaskGroup(of: DiscoveredTV?.self) { group in
            for i in 1...254 {
                let ip = "\(subnet).\(i)"
                group.addTask {
                    await self.checkIP(ip)
                }
            }

            for await result in group {
                completed += 1
                let progress = Double(completed) / total
                await MainActor.run {
                    self.scanProgress = progress
                    if let tv = result {
                        self.discoveredTVs.append(tv)
                        print("📺 Found Frame TV: \(tv.name) (\(tv.modelName)) at \(tv.ipAddress)")
                    }
                }
            }
        }
    }

    // MARK: - Check Single IP
    /// Queries port 8001 on a single IP to see if it's a Samsung Frame TV.
    /// Returns a DiscoveredTV if it is, nil otherwise.
    private func checkIP(_ ip: String) async -> DiscoveredTV? {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else { return nil }

        // Short timeout — we're scanning 254 addresses
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let device = json["device"] as? [String: Any] else { return nil }

            // Only match Samsung Frame TVs
            guard let frameSupport = device["FrameTVSupport"] as? String,
                  frameSupport == "true" else { return nil }

            let name = (json["name"] as? String) ?? (device["name"] as? String) ?? "Samsung Frame"
            let model = (device["modelName"] as? String) ?? "Unknown"

            return DiscoveredTV(name: name, ipAddress: ip, modelName: model)

        } catch {
            // Most IPs will fail — this is expected
            return nil
        }
    }

    // MARK: - Get Local IP
    /// Returns the device's local network IP address.
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee,
                  interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            // Only look at WiFi (en0) or Ethernet (en1) interfaces
            guard name == "en0" || name == "en1" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            address = String(cString: hostname)
        }
        return address
    }
}
