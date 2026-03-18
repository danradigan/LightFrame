import Foundation
import SwiftUI

// MARK: - Matte Style
// Controls the shape and width of the border around the photo on the TV.
// These string values must match exactly what the Samsung Frame TV API expects.
enum MatteStyle: String, CaseIterable, Codable {
    case none       = "none"
    case modern     = "modern"
    case modernThin = "modernthin"
    case modernWide = "modernwide"
    case flexible   = "flexible"
    case shadowbox  = "shadowbox"
    case panoramic  = "panoramic"

    var displayName: String {
        switch self {
        case .none:       return "None"
        case .modern:     return "Modern"
        case .modernThin: return "Modern Thin"
        case .modernWide: return "Modern Wide"
        case .flexible:   return "Flexible"
        case .shadowbox:  return "Shadow Box"
        case .panoramic:  return "Panoramic"
        }
    }
}

// MARK: - Matte Color
// The color of the matte border. String values must match the Samsung API exactly.
// Note: "burgandy" is intentionally misspelled to match Samsung's own API spelling.
enum MatteColor: String, CaseIterable, Codable {
    case black     = "black"
    case neutral   = "neutral"
    case antique   = "antique"
    case warm      = "warm"
    case polar     = "polar"
    case sand      = "sand"
    case seafoam   = "seafoam"
    case sage      = "sage"
    case burgundy  = "burgandy"   // Samsung's API spells it this way
    case navy      = "navy"
    case apricot   = "apricot"
    case byzantine = "byzantine"
    case lavender  = "lavender"
    case redOrange = "redorange"

    var displayName: String {
        switch self {
        case .black:     return "Black"
        case .neutral:   return "Neutral"
        case .antique:   return "Antique"
        case .warm:      return "Warm"
        case .polar:     return "Polar"
        case .sand:      return "Sand"
        case .seafoam:   return "Seafoam"
        case .sage:      return "Sage"
        case .burgundy:  return "Burgundy"
        case .navy:      return "Navy"
        case .apricot:   return "Apricot"
        case .byzantine: return "Byzantine"
        case .lavender:  return "Lavender"
        case .redOrange: return "Red Orange"
        }
    }

    // RGB color values matched to the Samsung Frame TV swatch reference.
    var previewColor: Color {
        switch self {
        case .black:     return Color(red: 0.08, green: 0.08, blue: 0.08)
        case .neutral:   return Color(red: 0.56, green: 0.55, blue: 0.53)
        case .antique:   return Color(red: 0.84, green: 0.81, blue: 0.77)
        case .warm:      return Color(red: 0.89, green: 0.87, blue: 0.83)
        case .polar:     return Color(red: 0.89, green: 0.90, blue: 0.91)
        case .sand:      return Color(red: 0.68, green: 0.63, blue: 0.49)
        case .seafoam:   return Color(red: 0.40, green: 0.52, blue: 0.51)
        case .sage:      return Color(red: 0.62, green: 0.67, blue: 0.55)
        case .burgundy:  return Color(red: 0.38, green: 0.13, blue: 0.16)
        case .navy:      return Color(red: 0.10, green: 0.15, blue: 0.33)
        case .apricot:   return Color(red: 0.90, green: 0.70, blue: 0.32)
        case .byzantine: return Color(red: 0.50, green: 0.26, blue: 0.52)
        case .lavender:  return Color(red: 0.69, green: 0.64, blue: 0.68)
        case .redOrange: return Color(red: 0.84, green: 0.38, blue: 0.24)
        }
    }
}

// MARK: - Matte
// Combines a style and color into one value.
// The apiToken is the string sent to the Samsung TV API, e.g. "flexible_warm".
struct Matte: Codable, Equatable, Hashable {
    var style: MatteStyle
    var color: MatteColor?

    // The string the Samsung API expects, e.g. "flexible_warm" or "none"
    var apiToken: String {
        guard style != .none, let color = color else {
            return style.rawValue
        }
        return "\(style.rawValue)_\(color.rawValue)"
    }

    // Human readable label shown in the UI, e.g. "Flexible · Warm"
    var displayName: String {
        guard style != .none, let color = color else {
            return style.displayName
        }
        return "\(style.displayName) · \(color.displayName)"
    }

    // Parses a matte string from EXIF data, e.g. "flexible_warm" or "none"
    nonisolated static func parse(_ raw: String) -> Matte? {
        let parts = raw.lowercased().components(separatedBy: "_")
        guard let style = MatteStyle(rawValue: parts[0]) else { return nil }
        let color = parts.count > 1 ? MatteColor(rawValue: parts[1]) : nil
        return Matte(style: style, color: color)
    }
}

// MARK: - Photo
// Represents a single photo file on disk in a collection folder.
// This is the core model the entire app revolves around.
struct Photo: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let url: URL
    var matte: Matte?
    var tvContentID: String?
    var isOnTV: Bool
    var thumbnailData: Data?      // Compressed JPEG thumbnail generated during scan
    var width: Int?               // Pixel width of the original image
    var height: Int?              // Pixel height of the original image

    var filename: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.lowercased() }
    var isJPEG: Bool { fileExtension == "jpg" || fileExtension == "jpeg" }

    // True if the image is approximately 16:9 (within 5% tolerance)
    var is16x9: Bool {
        guard let w = width, let h = height, h > 0 else { return true } // assume OK if unknown
        let ratio = Double(w) / Double(h)
        let target = 16.0 / 9.0  // 1.778
        return abs(ratio - target) / target < 0.05
    }
}

// MARK: - TV-Only Item
// Represents a photo that exists on the TV but not in any local collection.
// This could be Samsung built-in art or something uploaded from another device.
struct TVOnlyItem: Identifiable, Codable {
    let id: String          // The TV's content ID, e.g. "SAM-F0042" or "MY-C0012"
    var matte: Matte?       // The matte currently set on the TV for this item
    var isBuiltIn: Bool     // true = Samsung built-in art, false = user uploaded
    var thumbnailData: Data? // Downloaded from TV during Scan TV
    var width: Int?
    var height: Int?

    // True if approximately 16:9 (within 5% tolerance)
    var is16x9: Bool {
        guard let w = width, let h = height, h > 0 else { return true }
        let ratio = Double(w) / Double(h)
        let target = 16.0 / 9.0
        return abs(ratio - target) / target < 0.05
    }

    // Built-in Samsung art IDs start with "SAM-", user uploads start with "MY-"
    static func isBuiltInID(_ id: String) -> Bool {
        id.hasPrefix("SAM-")
    }
}

// MARK: - Collection
// A named folder preset. Each collection points to a folder on disk.
// Collections are shared across TVs — the same folder can be sent to any TV.
struct Collection: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String        // e.g. "Landscapes", "Holiday 2024"
    var folderURL: URL      // The folder on disk containing the photos
    var bookmarkData: Data? // Security-scoped bookmark for sandbox access across launches
    var photos: [Photo]     // Photos found in this folder (populated when scanned)

    // Total number of photos currently on the TV from this collection
    func photosOnTV(count: Int) -> String {
        "\(count) of \(photos.count) on TV"
    }
}

// MARK: - TV
// Represents a Samsung Frame TV on the network.
// Each TV stores its own connection token and remembers what's been uploaded to it.
struct TV: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String            // User-given name, e.g. "Living Room"
    var ipAddress: String       // e.g. "192.168.86.25"
    var token: String?          // Pairing token saved after first connection approval
    var isReachable: Bool       // Updated when the app tries to connect

    // The WebSocket URLs used to connect to this TV.
    // Samsung Frame TVs require TWO separate WebSocket channels:
    //   - samsung.remote.control  — for pairing/token exchange (port 8002)
    //   - com.samsung.art-app     — for all art mode commands (port 8002)
    // On 2022+ models, sending art commands to the remote.control channel
    // silently hangs with no response. The dedicated art channel must be used.

    // Used during initial pairing to get our token
    var pairingURL: URL? {
        let appName = "TGlnaHRGcmFtZQ=="
        var urlString = "wss://\(ipAddress):8002/api/v2/channels/samsung.remote.control?name=\(appName)"
        if let token = token {
            urlString += "&token=\(token)"
        }
        return URL(string: urlString)
    }

    // Used for all art mode commands after pairing
    var artChannelURL: URL? {
        let appName = "TGlnaHRGcmFtZQ=="
        var urlString = "wss://\(ipAddress):8002/api/v2/channels/com.samsung.art-app?name=\(appName)"
        if let token = token {
            urlString += "&token=\(token)"
        }
        return URL(string: urlString)
    }

    // Legacy alias — points to pairing URL for backwards compatibility
    var webSocketURL: URL? { pairingURL }
}

// MARK: - Slideshow Order
// Controls whether the TV cycles through art in order or randomly.
enum SlideshowOrder: String, CaseIterable, Codable {
    case inOrder = "off"        // Samsung API uses "off" for sequential
    case random  = "on"         // Samsung API uses "on" for shuffle

    var displayName: String {
        switch self {
        case .inOrder: return "In Order"
        case .random:  return "Random"
        }
    }
}

// MARK: - Slideshow Interval
// How long each photo is displayed before the TV switches to the next one.
enum SlideshowInterval: Int, CaseIterable, Codable {
    case threeMinutes    = 3
    case fifteenMinutes  = 15
    case oneHour         = 60
    case twelveHours     = 720
    case oneDay          = 1440
    case sevenDays       = 10080

    var displayName: String {
        switch self {
        case .threeMinutes:   return "3 Minutes"
        case .fifteenMinutes: return "15 Minutes"
        case .oneHour:        return "1 Hour"
        case .twelveHours:    return "12 Hours"
        case .oneDay:         return "1 Day"
        case .sevenDays:      return "7 Days"
        }
    }
}

// MARK: - App Settings
// Global preferences stored in UserDefaults.
// @AppStorage in SwiftUI reads/writes these automatically.
struct AppSettings {
    static let defaultMatteStyle    = MatteStyle.flexible
    static let defaultMatteColor    = MatteColor.warm
    static let defaultInterval      = SlideshowInterval.fifteenMinutes
    static let defaultOrder         = SlideshowOrder.random
}
