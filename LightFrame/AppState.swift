import Foundation
import SwiftUI
import Combine

// MARK: - AppState
// The single source of truth for the entire app.
// Every view reads from and writes to this object.
// @MainActor ensures all UI updates happen on the main thread.
@MainActor
class AppState: ObservableObject {

    // MARK: - Collections
    // The list of named folder presets the user has set up
    @Published var collections: [Collection] = []

    // The currently selected collection in the sidebar
    @Published var selectedCollection: Collection?

    // MARK: - TVs
    // All TVs the user has added
    @Published var tvs: [TV] = []

    // The currently active TV
    @Published var selectedTV: TV?

    // MARK: - Photo Selection
    // The set of photo IDs currently selected in the grid
    // Using a Set means we can quickly check if a photo is selected
    @Published var selectedPhotoIDs: Set<UUID> = []

    // The last photo tapped — drives the right panel detail view
    @Published var lastTappedPhoto: Photo?

    // MARK: - TV-Only Items
    // Photos on the TV that don't exist in any local collection
    @Published var tvOnlyItems: [TVOnlyItem] = []

    // MARK: - Grid Filter
    // Controls which tab is active in the photo grid
    @Published var gridFilter: GridFilter = .all

    // MARK: - Matte Filters
    // Active filters in the sidebar — empty set means "show all"
    @Published var activeStyleFilters: Set<MatteStyle> = []
    @Published var activeColorFilters: Set<MatteColor> = []

    // MARK: - Upload State
    @Published var isUploading: Bool = false
    @Published var uploadProgress: Double = 0       // 0.0 to 1.0
    @Published var uploadCurrent: Int = 0           // e.g. 12
    @Published var uploadTotal: Int = 0             // e.g. 47
    @Published var uploadTimeRemaining: String = "" // e.g. "2 min remaining"
    @Published var uploadError: String?             // Non-nil if something went wrong

    // MARK: - Thumbnail Size
    // Controls the grid thumbnail size via the bottom-right slider
    // Range: 100 (small) to 300 (large), default 160
    @Published var thumbnailSize: CGFloat = 160

    // MARK: - Persistence
    // Path to the JSON file that stores collections and TVs between launches
    private let storageURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("LightFrame")
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("appstate.json")
    }()

    // MARK: - Init
    init() {
        load()
    }

    // MARK: - Collection Management

    /// Add a new collection pointing to a folder on disk
    func addCollection(name: String, folderURL: URL) {
        let collection = Collection(
            id: UUID(),
            name: name,
            folderURL: folderURL,
            photos: []
        )
        collections.append(collection)
        selectedCollection = collection
        save()
    }

    /// Remove a collection by ID
    func removeCollection(_ collection: Collection) {
        collections.removeAll { $0.id == collection.id }
        if selectedCollection?.id == collection.id {
            selectedCollection = collections.first
        }
        save()
    }

    /// Rename a collection
    func renameCollection(_ collection: Collection, to name: String) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[index].name = name
        if selectedCollection?.id == collection.id {
            selectedCollection = collections[index]
        }
        save()
    }

    /// Update the photos inside a collection after a scan
    func updatePhotos(_ photos: [Photo], in collection: Collection) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[index].photos = photos
        if selectedCollection?.id == collection.id {
            selectedCollection = collections[index]
        }
        save()
    }

    // MARK: - TV Management

    /// Add a new TV
    func addTV(name: String, ipAddress: String) {
        let tv = TV(
            id: UUID(),
            name: name,
            ipAddress: ipAddress,
            token: nil,
            isReachable: false
        )
        tvs.append(tv)
        if selectedTV == nil {
            selectedTV = tv
        }
        save()
    }

    /// Remove a TV by ID
    func removeTV(_ tv: TV) {
        tvs.removeAll { $0.id == tv.id }
        if selectedTV?.id == tv.id {
            selectedTV = tvs.first
        }
        save()
    }

    /// Update a TV's token after successful pairing
    func updateToken(_ token: String, for tv: TV) {
        guard let index = tvs.firstIndex(where: { $0.id == tv.id }) else { return }
        tvs[index].token = token
        if selectedTV?.id == tv.id {
            selectedTV = tvs[index]
        }
        save()
    }

    /// Update a TV's reachability status
    func updateReachability(_ reachable: Bool, for tv: TV) {
        guard let index = tvs.firstIndex(where: { $0.id == tv.id }) else { return }
        tvs[index].isReachable = reachable
        if selectedTV?.id == tv.id {
            selectedTV = tvs[index]
        }
        // Don't save here — reachability is transient, not persisted
    }

    /// Update a TV's content ID for a photo after upload
    func setContentID(_ contentID: String, for photo: Photo, in collection: Collection) {
        guard let colIndex = collections.firstIndex(where: { $0.id == collection.id }),
              let photoIndex = collections[colIndex].photos.firstIndex(where: { $0.id == photo.id })
        else { return }
        collections[colIndex].photos[photoIndex].tvContentID = contentID
        collections[colIndex].photos[photoIndex].isOnTV = true
        if selectedCollection?.id == collection.id {
            selectedCollection = collections[colIndex]
        }
        save()
    }

    // MARK: - Photo Selection

    /// Select a single photo (clears previous selection)
    func selectPhoto(_ photo: Photo) {
        selectedPhotoIDs = [photo.id]
        lastTappedPhoto = photo
    }

    /// Toggle a photo in/out of the selection (for Cmd+click)
    func togglePhotoSelection(_ photo: Photo) {
        if selectedPhotoIDs.contains(photo.id) {
            selectedPhotoIDs.remove(photo.id)
            if lastTappedPhoto?.id == photo.id {
                lastTappedPhoto = nil
            }
        } else {
            selectedPhotoIDs.insert(photo.id)
            lastTappedPhoto = photo
        }
    }

    /// Select a contiguous range of photos (for Shift+click)
    func selectRange(to photo: Photo, in photos: [Photo]) {
        guard let endIndex = photos.firstIndex(where: { $0.id == photo.id }) else { return }

        // Find the anchor — the last tapped photo, or default to first
        let startIndex: Int
        if let anchor = lastTappedPhoto,
           let anchorIndex = photos.firstIndex(where: { $0.id == anchor.id }) {
            startIndex = anchorIndex
        } else {
            startIndex = 0
        }

        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        let rangeIDs = photos[range].map { $0.id }
        selectedPhotoIDs.formUnion(rangeIDs)
        lastTappedPhoto = photo
    }

    /// Clear all selected photos
    func clearSelection() {
        selectedPhotoIDs = []
        lastTappedPhoto = nil
    }

    /// Select all photos in the current filtered view
    func selectAll(photos: [Photo]) {
        selectedPhotoIDs = Set(photos.map { $0.id })
    }

    // MARK: - Filtered Photos
    // Returns the photos to show in the grid based on active tab and filters

    var filteredPhotos: [Photo] {
        guard let collection = selectedCollection else { return [] }

        // Start with all photos in the collection
        var photos = collection.photos

        // Apply grid tab filter
        switch gridFilter {
        case .all:
            break // Show everything
        case .onTV:
            photos = photos.filter { $0.isOnTV }
        case .notOnTV:
            photos = photos.filter { !$0.isOnTV }
        }

        // Apply matte style filter
        if !activeStyleFilters.isEmpty {
            photos = photos.filter { photo in
                guard let matte = photo.matte else { return false }
                return activeStyleFilters.contains(matte.style)
            }
        }

        // Apply matte color filter
        if !activeColorFilters.isEmpty {
            photos = photos.filter { photo in
                guard let color = photo.matte?.color else { return false }
                return activeColorFilters.contains(color)
            }
        }

        return photos
    }

    // MARK: - Selected Photos for Upload/Delete
    // The actual Photo objects that are currently selected
    var selectedPhotos: [Photo] {
        guard let collection = selectedCollection else { return [] }
        return collection.photos.filter { selectedPhotoIDs.contains($0.id) }
    }

    // MARK: - Persistence

    /// Save collections and TVs to disk as JSON
    func save() {
        // We save a simplified version — just the data, not the computed properties
        let data = PersistencePayload(collections: collections, tvs: tvs)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: storageURL)
        }
    }

    /// Load collections and TVs from disk on launch
    func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(PersistencePayload.self, from: data)
        else { return }

        collections = decoded.collections
        tvs = decoded.tvs
        selectedCollection = collections.first
        selectedTV = tvs.first
    }
}

// MARK: - Grid Filter
// The three tabs above the photo grid
enum GridFilter: String, CaseIterable {
    case all      = "All"
    case onTV     = "On TV"
    case notOnTV  = "Not on TV"

    var displayName: String { rawValue }
}

// MARK: - Persistence Payload
// A simple wrapper so we can encode/decode AppState to JSON
private struct PersistencePayload: Codable {
    var collections: [Collection]
    var tvs: [TV]
}
