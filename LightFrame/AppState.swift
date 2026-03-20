import Foundation
import SwiftUI
import Combine

// MARK: - Sidebar Selection
enum SidebarSelection: Hashable {
    case photosOnTV
    case allPhotos
    case collection(UUID)
}

// MARK: - Sort Order
enum SortOrder: String, CaseIterable {
    case nameAsc            = "Name (A-Z)"
    case nameDesc           = "Name (Z-A)"
    case dateModifiedNewest = "Newest First"
    case dateModifiedOldest = "Oldest First"
}

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

    // MARK: - TV-Only Items (loaded from SyncStore for selected TV)
    @Published var tvOnlyItems: [TVOnlyItem] = []
    @Published var selectedTVOnlyItemIDs: Set<String> = []
    @Published var lastTappedTVOnlyItem: TVOnlyItem? = nil

    // MARK: - Sidebar Selection & Sort
    @Published var sidebarSelection: SidebarSelection = .allPhotos

    /// Call this instead of setting sidebarSelection directly from view bindings.
    /// Defers cascading mutations out of the SwiftUI view-update cycle.
    func setSidebarSelection(_ selection: SidebarSelection) {
        sidebarSelection = selection
        Task { @MainActor in
            clearSelection()
            if case .photosOnTV = selection {
                isFilterLocked = true
                gridFilter = .onTV
            } else {
                isFilterLocked = false
            }
        }
    }

    @Published var sortOrder: SortOrder = {
        let stored = UserDefaults.standard.string(forKey: "sortOrder")
        return stored.flatMap { SortOrder(rawValue: $0) } ?? .nameAsc
    }() {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder") }
    }

    @Published var isFilterLocked: Bool = false

    // MARK: - Grid Filter
    @Published var gridFilter: GridFilter = .all

    // MARK: - Aspect Ratio Filter
    @Published var aspectRatioFilter: AspectRatioFilter = .all

    // MARK: - Matte Filters
    @Published var activeStyleFilters: Set<MatteStyle> = []
    @Published var activeColorFilters: Set<MatteColor> = []

    // MARK: - Cached SyncStore Data
    // Cached data from the selected TV's SyncStore to avoid accessing SyncStore during view body.
    // Updated when: selectedTV changes, after TV scan, after upload/delete.
    @Published var syncStorePhotoCount: Int = 0
    var cachedUploadedFilenames: Set<String> = []

    func refreshSyncStoreCache() {
        guard let tv = selectedTV else {
            syncStorePhotoCount = 0
            cachedUploadedFilenames = []
            return
        }
        let store = SyncStoreManager.shared.store(for: tv)
        syncStorePhotoCount = store.records.count + store.tvOnlyItems.count
        cachedUploadedFilenames = store.uploadedFilenames
    }

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


    // MARK: - Thumbnail Size (persisted to UserDefaults)
    @Published var thumbnailSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "thumbnailSize")
        return stored > 0 ? CGFloat(stored) : 160
    }() {
        didSet { UserDefaults.standard.set(Double(thumbnailSize), forKey: "thumbnailSize") }
    }

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
        setSidebarSelection(.collection(collection.id))
        save()
        // Auto-scan immediately so photos appear without a manual Scan press
        Task { await scanSelectedCollection() }
    }

    func removeCollection(_ collection: Collection) {
        collections.removeAll { $0.id == collection.id }
        if selectedCollection?.id == collection.id {
            selectedCollection = collections.first
        }
        // If we were viewing this collection, switch to allPhotos
        if case .collection(let id) = sidebarSelection, id == collection.id {
            setSidebarSelection(.allPhotos)
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

    // MARK: - Bookmark Resolution
    /// Resolves a collection's security-scoped bookmark, regenerating it if stale.
    /// If the bookmark is broken (e.g. folder deleted & recreated), silently pops
    /// an NSOpenPanel pre-navigated to the expected folder so the user just clicks Open.
    func resolveBookmark(for collection: Collection) -> (url: URL, accessGranted: Bool) {
        var resolvedURL = collection.folderURL
        var needsNewBookmark = false

        if let bookmarkData = collection.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                resolvedURL = url
                if isStale { needsNewBookmark = true }
            } else {
                needsNewBookmark = true
            }
        }

        let accessGranted = resolvedURL.startAccessingSecurityScopedResource()

        // Stale but still accessible — silently regenerate
        if accessGranted && needsNewBookmark {
            refreshBookmark(for: collection, url: resolvedURL)
        }

        // Completely broken — ask user to re-select the folder
        if !accessGranted {
            if let newURL = promptForFolderAccess(collection: collection) {
                refreshBookmark(for: collection, url: newURL)
                let granted = newURL.startAccessingSecurityScopedResource()
                return (newURL, granted)
            }
            return (resolvedURL, false)
        }

        return (resolvedURL, accessGranted)
    }

    /// Opens a folder picker pre-navigated to the collection's expected folder.
    /// Returns the selected URL or nil if the user cancels.
    private func promptForFolderAccess(collection: Collection) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Re-select the folder for \"\(collection.name)\" to restore access"
        panel.directoryURL = collection.folderURL.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    /// Regenerates the security-scoped bookmark for a collection after the user
    /// re-selects the folder or after a stale bookmark is resolved.
    func refreshBookmark(for collection: Collection, url: URL) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[index].bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        collections[index].folderURL = url
        if selectedCollection?.id == collection.id {
            selectedCollection = collections[index]
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

        let (resolvedURL, accessGranted) = resolveBookmark(for: collection)
        guard accessGranted else { return }

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
        refreshSyncStoreCache()
        save()
    }

    // MARK: - Load TV-Only Items from SyncStore
    /// Loads tvOnlyItems from the selected TV's SyncStore into memory for display.
    func loadTVOnlyItemsFromSyncStore() {
        guard let tv = selectedTV else {
            tvOnlyItems = []
            syncStorePhotoCount = 0
            return
        }
        let syncStore = SyncStoreManager.shared.store(for: tv)
        tvOnlyItems = syncStore.tvOnlyItems
        refreshSyncStoreCache()
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
        // Also select all TV-only items when viewing Photos on TV
        if case .photosOnTV = sidebarSelection {
            selectedTVOnlyItemIDs = Set(tvOnlyItems.map { $0.id })
        } else if gridFilter == .onTV {
            selectedTVOnlyItemIDs = Set(tvOnlyItems.map { $0.id })
        }
    }

    // MARK: - Filtered Photos

    var filteredPhotos: [Photo] {
        var photos: [Photo]

        switch sidebarSelection {
        case .photosOnTV:
            // Show photos that are on the selected TV (from all collections)
            guard selectedTV != nil else { return [] }
            photos = collections.flatMap { $0.photos }
                .filter { cachedUploadedFilenames.contains($0.filename) || $0.isOnTV }
            // Deduplicate by filename (same file in multiple collections)
            var seen = Set<String>()
            photos = photos.filter { seen.insert($0.filename).inserted }

        case .allPhotos:
            // Merge all collections, deduplicate by filename
            var seen = Set<String>()
            photos = collections.flatMap { $0.photos }
                .filter { seen.insert($0.filename).inserted }

        case .collection(let id):
            guard let collection = collections.first(where: { $0.id == id }) else { return [] }
            photos = collection.photos
        }

        // Apply grid filter (unless locked)
        if !isFilterLocked {
            switch gridFilter {
            case .all: break
            case .onTV: photos = photos.filter { $0.isOnTV }
            case .notOnTV: photos = photos.filter { !$0.isOnTV }
            }
        }

        // Apply aspect ratio filter
        switch aspectRatioFilter {
        case .all: break
        case .is16x9: photos = photos.filter { $0.is16x9 }
        case .other: photos = photos.filter { !$0.is16x9 }
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

        // Apply sort order
        switch sortOrder {
        case .nameAsc:
            photos.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .nameDesc:
            photos.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
        case .dateModifiedNewest, .dateModifiedOldest:
            // Pre-fetch all mod dates in one pass to avoid repeated filesystem calls
            let dates = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, Self.modDate($0.url)) })
            let ascending = sortOrder == .dateModifiedOldest
            photos.sort {
                let d0 = dates[$0.id] ?? .distantPast
                let d1 = dates[$1.id] ?? .distantPast
                return ascending ? d0 < d1 : d0 > d1
            }
        }

        return photos
    }

    private static func modDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    var selectedPhotos: [Photo] {
        guard let collection = selectedCollection else {
            // For allPhotos/photosOnTV, search all collections
            return collections.flatMap { $0.photos }.filter { selectedPhotoIDs.contains($0.id) }
        }
        return collection.photos.filter { selectedPhotoIDs.contains($0.id) }
    }

    /// The name to display for the current sidebar selection
    var currentSelectionName: String {
        switch sidebarSelection {
        case .photosOnTV: return "Photos on TV"
        case .allPhotos: return "All Photos"
        case .collection(let id):
            return collections.first(where: { $0.id == id })?.name ?? "Collection"
        }
    }

    /// Total photo count for the current sidebar selection (before filters)
    var totalPhotoCount: Int {
        switch sidebarSelection {
        case .photosOnTV:
            return syncStorePhotoCount
        case .allPhotos:
            var seen = Set<String>()
            return collections.flatMap { $0.photos }.filter { seen.insert($0.filename).inserted }.count
        case .collection(let id):
            return collections.first(where: { $0.id == id })?.photos.count ?? 0
        }
    }

    // MARK: - Persistence

    func save() {
        let data = PersistencePayload(collections: collections, tvs: tvs)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: storageURL)
        }
        // Persist selected TV and collection IDs so we restore the right ones on launch
        UserDefaults.standard.set(selectedTV?.id.uuidString, forKey: "selectedTVID")
        UserDefaults.standard.set(selectedCollection?.id.uuidString, forKey: "selectedCollectionID")
    }

    func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }

        // Try new format first (without tvOnlyItems)
        if let decoded = try? JSONDecoder().decode(PersistencePayload.self, from: data) {
            loadCollections(decoded.collections)
            tvs = decoded.tvs
        } else if let decoded = try? JSONDecoder().decode(LegacyPersistencePayload.self, from: data) {
            // Migration: old format had tvOnlyItems in AppState
            loadCollections(decoded.collections)
            tvs = decoded.tvs
            // Migrate tvOnlyItems to SyncStore for the selected TV
            if let items = decoded.tvOnlyItems, !items.isEmpty {
                migrateTVOnlyItems(items)
            }
        } else {
            return
        }

        // Restore last selected collection by persisted ID, fallback to first
        if let savedID = UserDefaults.standard.string(forKey: "selectedCollectionID"),
           let uuid = UUID(uuidString: savedID),
           let match = collections.first(where: { $0.id == uuid }) {
            selectedCollection = match
        } else {
            selectedCollection = collections.first
        }

        // Restore selectedTV — this is one of the three allowed places to set it.
        // We try to restore by persisted ID, fallback to first.
        // We clear isReachable on load because we haven't verified connectivity yet.
        let targetTV: TV?
        if let savedID = UserDefaults.standard.string(forKey: "selectedTVID"),
           let uuid = UUID(uuidString: savedID),
           let match = tvs.first(where: { $0.id == uuid }) {
            targetTV = match
        } else {
            targetTV = tvs.first
        }
        selectedTV = targetTV.map { tv in
            var t = tv
            t.isReachable = false
            return t
        }

        // Restore sidebar selection (direct assignment OK during load — no view is rendering yet)
        if let collection = selectedCollection {
            sidebarSelection = .collection(collection.id)
        }

        // Load TV-only items from SyncStore
        loadTVOnlyItemsFromSyncStore()

        // Cache the sync store count
        refreshSyncStoreCache()

        save()
    }

    private func loadCollections(_ rawCollections: [Collection]) {
        collections = rawCollections.map { collection in
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
    }

    /// Migrate tvOnlyItems from the old PersistencePayload into the selected TV's SyncStore
    private func migrateTVOnlyItems(_ items: [TVOnlyItem]) {
        if let savedID = UserDefaults.standard.string(forKey: "selectedTVID"),
           let uuid = UUID(uuidString: savedID),
           let tv = tvs.first(where: { $0.id == uuid }) {
            let syncStore = SyncStoreManager.shared.store(for: tv)
            if syncStore.tvOnlyItems.isEmpty {
                syncStore.setTVOnlyItems(items)
                print("💾 Migrated \(items.count) tvOnlyItems to SyncStore for TV \(tv.name)")
            }
        }
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

// MARK: - Aspect Ratio Filter
enum AspectRatioFilter: String, CaseIterable {
    case all   = "All"
    case is16x9 = "16:9"
    case other  = "Other"
    var displayName: String { rawValue }
}

// MARK: - Persistence Payload
private struct PersistencePayload: Codable {
    var collections: [Collection]
    var tvs: [TV]
}

// Legacy format — used for migration only
private struct LegacyPersistencePayload: Codable {
    var collections: [Collection]
    var tvs: [TV]
    var tvOnlyItems: [TVOnlyItem]?
}
