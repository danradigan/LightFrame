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
    @Published var collections: [Collection] = []
    @Published var selectedCollection: Collection?

    // MARK: - TVs
    @Published var tvs: [TV] = []

    // selectedTV is the TV the user has chosen in the sidebar.
    //
    // CRITICAL: TVConnectionManager observes $selectedTV to know when to switch
    // connections. We must ONLY write to selectedTV when the user actually picks
    // a different TV. Writing it for any other reason (e.g. reachability updates)
    // causes TVConnectionManager to disconnect and reconnect — the reconnect loop.
    //
    // Rule: only these three places should ever assign selectedTV:
    //   1. load() — restoring saved state on launch
    //   2. addTV() — after adding a new TV with no existing selection
    //   3. removeTV() — after removing the currently selected TV
    //   4. TVRowView.onTapGesture — user picks a different TV
    //
    // updateReachability() deliberately does NOT touch selectedTV. See that method.
    @Published var selectedTV: TV?

    // MARK: - Photo Selection
    @Published var selectedPhotoIDs: Set<UUID> = []
    @Published var lastTappedPhoto: Photo?

    // MARK: - TV-Only Items
    @Published var tvOnlyItems: [TVOnlyItem] = []
    @Published var selectedTVOnlyItemIDs: Set<String> = []
    @Published var lastTappedTVOnlyItem: TVOnlyItem? = nil

    // MARK: - Grid Filter
    @Published var gridFilter: GridFilter = .all

    // MARK: - Matte Filters
    @Published var activeStyleFilters: Set<MatteStyle> = []
    @Published var activeColorFilters: Set<MatteColor> = []

    // MARK: - Upload State
    @Published var isUploading: Bool = false
    @Published var uploadProgress: Double = 0
    @Published var uploadCurrent: Int = 0
    @Published var uploadTotal: Int = 0
    @Published var uploadTimeRemaining: String = ""
    @Published var uploadError: String?

    // MARK: - Scan State
    @Published var isScanning: Bool = false
    @Published var scanningCollectionID: UUID? = nil

    // MARK: - Thumbnail Size
    @Published var thumbnailSize: CGFloat = 160

    // Zoom: 6-point scale matching ZoomLevel enum.
    // Cmd+< shrinks, Cmd+> grows, Cmd+0 resets to actual size (level 3).
    func zoomIn() {
        guard let current = ZoomLevel.closest(to: thumbnailSize),
              let next = ZoomLevel(rawValue: current.rawValue + 1) else { return }
        thumbnailSize = next.cgFloatValue
    }

    func zoomOut() {
        guard let current = ZoomLevel.closest(to: thumbnailSize),
              let next = ZoomLevel(rawValue: current.rawValue - 1) else { return }
        thumbnailSize = next.cgFloatValue
    }

    func zoomActualSize() {
        thumbnailSize = ZoomLevel.level3.cgFloatValue
    }

    // MARK: - Menu Triggers
    // Flags set by menu commands, observed by views that own the corresponding sheets.
    @Published var triggerScanTV: Bool = false
    @Published var triggerDeleteSelected: Bool = false

    // MARK: - Persistence URL
    private let storageURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("LightFrame")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("appstate.json")
    }()

    // MARK: - Init
    init() { load() }

    // MARK: - Collection Management

    /// Add a new collection and immediately auto-scan it
    func addCollection(name: String, folderURL: URL) {
        let bookmark = try? folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let collection = Collection(
            id: UUID(), name: name,
            folderURL: folderURL, bookmarkData: bookmark, photos: []
        )
        collections.append(collection)
        selectedCollection = collection
        save()
        // Auto-scan immediately so photos appear without a manual Scan press
        Task { await scanSelectedCollection() }
    }

    func removeCollection(_ collection: Collection) {
        collections.removeAll { $0.id == collection.id }
        if selectedCollection?.id == collection.id {
            selectedCollection = collections.first
        }
        save()
    }

    func renameCollection(_ collection: Collection, to name: String) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[index].name = name
        if selectedCollection?.id == collection.id { selectedCollection = collections[index] }
        save()
    }

    func updatePhotos(_ photos: [Photo], in collection: Collection) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[index].photos = photos
        if selectedCollection?.id == collection.id { selectedCollection = collections[index] }
        save()
    }

    // MARK: - Smart Single-Photo Matte Update
    /// Updates just one photo's matte and thumbnail in memory.
    /// Much faster than re-scanning the entire collection for a single change.
    func updateMatte(_ matte: Matte, for photo: Photo, newData: Data? = nil) {
        guard let colIndex = collections.firstIndex(where: { col in
                  col.photos.contains(where: { $0.id == photo.id })
              }),
              let photoIndex = collections[colIndex].photos.firstIndex(where: { $0.id == photo.id })
        else { return }

        collections[colIndex].photos[photoIndex].matte = matte

        if let data = newData {
            collections[colIndex].photos[photoIndex].thumbnailData = data
        }

        if selectedCollection?.id == collections[colIndex].id {
            selectedCollection = collections[colIndex]
        }

        if lastTappedPhoto?.id == photo.id {
            lastTappedPhoto = collections[colIndex].photos[photoIndex]
        }

        save()
    }

    // MARK: - Scan Collection
    /// Scans the selected collection's folder and updates its photos.
    func scanSelectedCollection() async {
        guard let collection = selectedCollection else { return }

        isScanning = true
        scanningCollectionID = collection.id
        defer {
            isScanning = false
            scanningCollectionID = nil
        }

        var resolvedURL = collection.folderURL
        if let bookmarkData = collection.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) { resolvedURL = url }
        }

        let accessGranted = resolvedURL.startAccessingSecurityScopedResource()

        let syncStore: SyncStore
        if let tv = selectedTV {
            syncStore = SyncStoreManager.shared.store(for: tv)
        } else {
            syncStore = SyncStore(tvID: UUID())
        }

        let photos = await PhotoScanner.scan(
            folderURL: resolvedURL,
            existingPhotos: collection.photos,
            syncStore: syncStore
        )

        if accessGranted { resolvedURL.stopAccessingSecurityScopedResource() }
        updatePhotos(photos, in: collection)
    }

    // MARK: - TV Management

    func addTV(name: String, ipAddress: String) {
        let tv = TV(id: UUID(), name: name, ipAddress: ipAddress, token: nil, isReachable: false)
        tvs.append(tv)
        // Only set selectedTV if nothing is selected yet.
        // Never change selectedTV as a side effect of adding a non-first TV.
        if selectedTV == nil { selectedTV = tv }
        save()
    }

    func removeTV(_ tv: TV) {
        tvs.removeAll { $0.id == tv.id }
        // Only update selectedTV when we remove the currently selected one
        if selectedTV?.id == tv.id { selectedTV = tvs.first }
        save()
    }

    func updateToken(_ token: String, for tv: TV) {
        guard let index = tvs.firstIndex(where: { $0.id == tv.id }) else { return }
        tvs[index].token = token
        // DO NOT touch selectedTV here — it would trigger TVConnectionManager to reconnect.
        // The token is stored in tvs[]; TVConnection reads it via tv.webSocketURL on next connect.
        save()
    }

    // MARK: - updateReachability
    // Updates the green/grey dot for a TV.
    //
    // THE LOOP-FREE RULE:
    // This method ONLY writes to tvs[]. It never touches selectedTV.
    //
    // Why this matters: TVConnectionManager observes $selectedTV. If we wrote
    // selectedTV here, it would re-fire that publisher, causing TVConnectionManager
    // to call switchTo() → disconnect() → connect() → updateReachability() → repeat.
    //
    // The sidebar dot reads tv.isReachable from tvs[], not from selectedTV, so
    // updating tvs[] is sufficient to refresh the UI.
    func updateReachability(_ reachable: Bool, for tv: TV) {
        guard let index = tvs.firstIndex(where: { $0.id == tv.id }) else { return }
        // Only write if the value actually changed — avoids unnecessary publishes
        guard tvs[index].isReachable != reachable else { return }
        tvs[index].isReachable = reachable
        // Intentionally NOT updating selectedTV — see comment above
    }

    func setContentID(_ contentID: String, for photo: Photo, in collection: Collection) {
        guard let colIndex = collections.firstIndex(where: { $0.id == collection.id }),
              let photoIndex = collections[colIndex].photos.firstIndex(where: { $0.id == photo.id })
        else { return }
        collections[colIndex].photos[photoIndex].tvContentID = contentID
        collections[colIndex].photos[photoIndex].isOnTV = true
        if selectedCollection?.id == collection.id { selectedCollection = collections[colIndex] }
        save()
    }

    // MARK: - Photo Selection

    func selectPhoto(_ photo: Photo) {
        selectedPhotoIDs = [photo.id]
        lastTappedPhoto = photo
        selectedTVOnlyItemIDs = []
        lastTappedTVOnlyItem = nil
    }

    func togglePhotoSelection(_ photo: Photo) {
        selectedTVOnlyItemIDs = []
        lastTappedTVOnlyItem = nil
        if selectedPhotoIDs.contains(photo.id) {
            selectedPhotoIDs.remove(photo.id)
            if lastTappedPhoto?.id == photo.id { lastTappedPhoto = nil }
        } else {
            selectedPhotoIDs.insert(photo.id)
            lastTappedPhoto = photo
        }
    }

    func selectRange(to photo: Photo, in photos: [Photo]) {
        selectedTVOnlyItemIDs = []
        lastTappedTVOnlyItem = nil
        guard let endIndex = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        let startIndex: Int
        if let anchor = lastTappedPhoto,
           let anchorIndex = photos.firstIndex(where: { $0.id == anchor.id }) {
            startIndex = anchorIndex
        } else {
            startIndex = 0
        }
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        selectedPhotoIDs.formUnion(photos[range].map { $0.id })
        lastTappedPhoto = photo
    }

    func clearSelection() {
        selectedPhotoIDs = []
        lastTappedPhoto = nil
        selectedTVOnlyItemIDs = []
        lastTappedTVOnlyItem = nil
    }

    // MARK: - TV-Only Selection

    func selectTVOnlyItem(_ item: TVOnlyItem) {
        selectedTVOnlyItemIDs = [item.id]
        lastTappedTVOnlyItem = item
        selectedPhotoIDs = []
        lastTappedPhoto = nil
    }

    func toggleTVOnlyItemSelection(_ item: TVOnlyItem) {
        selectedPhotoIDs = []
        lastTappedPhoto = nil
        if selectedTVOnlyItemIDs.contains(item.id) {
            selectedTVOnlyItemIDs.remove(item.id)
            if lastTappedTVOnlyItem?.id == item.id { lastTappedTVOnlyItem = nil }
        } else {
            selectedTVOnlyItemIDs.insert(item.id)
            lastTappedTVOnlyItem = item
        }
    }

    func selectTVOnlyRange(to item: TVOnlyItem) {
        selectedPhotoIDs = []
        lastTappedPhoto = nil
        guard let endIndex = tvOnlyItems.firstIndex(where: { $0.id == item.id }) else { return }
        let startIndex: Int
        if let anchor = lastTappedTVOnlyItem,
           let anchorIndex = tvOnlyItems.firstIndex(where: { $0.id == anchor.id }) {
            startIndex = anchorIndex
        } else {
            startIndex = 0
        }
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        selectedTVOnlyItemIDs.formUnion(tvOnlyItems[range].map { $0.id })
        lastTappedTVOnlyItem = item
    }

    var selectedTVOnlyItems: [TVOnlyItem] {
        tvOnlyItems.filter { selectedTVOnlyItemIDs.contains($0.id) }
    }

    func selectAll(photos: [Photo]) {
        selectedPhotoIDs = Set(photos.map { $0.id })
        // Also select all TV-only items if on the On TV tab
        if gridFilter == .onTV {
            selectedTVOnlyItemIDs = Set(tvOnlyItems.map { $0.id })
        }
    }

    // MARK: - Filtered Photos

    var filteredPhotos: [Photo] {
        guard let collection = selectedCollection else { return [] }
        var photos = collection.photos

        switch gridFilter {
        case .all: break
        case .onTV: photos = photos.filter { $0.isOnTV }
        case .notOnTV: photos = photos.filter { !$0.isOnTV }
        }

        if !activeStyleFilters.isEmpty {
            photos = photos.filter { photo in
                guard let matte = photo.matte else { return false }
                return activeStyleFilters.contains(matte.style)
            }
        }

        if !activeColorFilters.isEmpty {
            photos = photos.filter { photo in
                guard let color = photo.matte?.color else { return false }
                return activeColorFilters.contains(color)
            }
        }

        return photos
    }

    var selectedPhotos: [Photo] {
        guard let collection = selectedCollection else { return [] }
        return collection.photos.filter { selectedPhotoIDs.contains($0.id) }
    }

    // MARK: - Persistence

    func save() {
        let data = PersistencePayload(collections: collections, tvs: tvs, tvOnlyItems: tvOnlyItems)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: storageURL)
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(PersistencePayload.self, from: data)
        else { return }

        collections = decoded.collections.map { collection in
            var resolved = collection
            if let bookmarkData = collection.bookmarkData {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    resolved.folderURL = url
                    if isStale {
                        resolved.bookmarkData = try? url.bookmarkData(
                            options: .withSecurityScope,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                    }
                }
            }
            return resolved
        }

        tvs = decoded.tvs
        tvOnlyItems = decoded.tvOnlyItems ?? []
        selectedCollection = collections.first

        // Restore selectedTV — this is one of the three allowed places to set it.
        // We clear isReachable on load because we haven't verified connectivity yet.
        selectedTV = tvs.first.map { tv in
            var t = tv
            t.isReachable = false
            return t
        }

        save()
    }
}

// MARK: - Zoom Levels
// 6-point scale for thumbnail sizes. Cmd+< / Cmd+> step through these.
enum ZoomLevel: Int, CaseIterable {
    case level1 = 1, level2, level3, level4, level5, level6

    var cgFloatValue: CGFloat {
        switch self {
        case .level1: return 80
        case .level2: return 120
        case .level3: return 160
        case .level4: return 200
        case .level5: return 240
        case .level6: return 280
        }
    }

    static func closest(to value: CGFloat) -> ZoomLevel? {
        allCases.min(by: { abs($0.cgFloatValue - value) < abs($1.cgFloatValue - value) })
    }
}

// MARK: - Grid Filter
enum GridFilter: String, CaseIterable {
    case all     = "All"
    case onTV    = "On TV"
    case notOnTV = "Not on TV"
    var displayName: String { rawValue }
}

// MARK: - Persistence Payload
private struct PersistencePayload: Codable {
    var collections: [Collection]
    var tvs: [TV]
    var tvOnlyItems: [TVOnlyItem]?  // Optional for backwards compatibility with existing files
}
