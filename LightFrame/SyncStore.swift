import Foundation

// MARK: - SyncStore
// A lightweight local database that tracks which photos have been uploaded
// to which TV, and what content ID the TV assigned them.
//
// Stored as a JSON file at:
//   ~/Library/Application Support/LightFrame/sync-{tvID}.json
//
// This is the source of truth for "is this photo on the TV?" — we don't
// query the TV on every launch because that's slow. Instead we trust this
// local record and offer a "Reconcile with TV" option to resync if needed.
class SyncStore {

    // MARK: - Source
    enum Source: String, Codable {
        case lightframe       // Uploaded from LightFrame
        case tvOriginated     // Already on TV (Samsung art, other app, etc.)
    }

    // MARK: - Record
    // One record per uploaded photo, per TV
    struct Record: Codable {
        let filename: String        // e.g. "sunset.jpg"
        let tvContentID: String     // e.g. "MY-C0042" — assigned by the TV on upload
        let uploadedAt: Date        // When it was uploaded
        var matte: Matte?           // The matte that was set when uploaded
        var source: Source?         // Where this photo came from
        var lastSyncedAt: Date?     // When this record was last verified against the TV
    }

    // MARK: - Persistence Wrapper
    // On-disk format wraps records + tvOnlyItems + metadata
    private struct StoragePayload: Codable {
        var records: [String: Record]
        var tvOnlyItems: [TVOnlyItem]
        var lastFullSyncDate: Date?
    }

    // MARK: - Properties
    private let tvID: UUID
    private let storageURL: URL
    private(set) var records: [String: Record] = [:]   // Keyed by filename
    private(set) var tvOnlyItems: [TVOnlyItem] = []
    var lastFullSyncDate: Date?

    // MARK: - Init
    /// Create a SyncStore for a specific TV.
    /// Each TV gets its own JSON file so they don't interfere.
    init(tvID: UUID) {
        self.tvID = tvID

        // Build the path: ~/Library/Application Support/LightFrame/sync-{uuid}.json
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("LightFrame")
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        self.storageURL = dir.appendingPathComponent("sync-\(tvID.uuidString).json")

        load()
    }

    // MARK: - Read

    /// Returns the TV content ID for a filename, or nil if not uploaded
    func contentID(for filename: String) -> String? {
        records[filename]?.tvContentID
    }

    /// Returns true if a photo with this filename has been uploaded to this TV
    func isUploaded(filename: String) -> Bool {
        records[filename] != nil
    }

    /// Returns all filenames that have been uploaded to this TV
    var uploadedFilenames: Set<String> {
        Set(records.keys)
    }

    /// Returns all records as an array, sorted by upload date
    var allRecords: [Record] {
        records.values.sorted { $0.uploadedAt < $1.uploadedAt }
    }

    // MARK: - Write

    /// Record a successful upload
    func recordUpload(filename: String, tvContentID: String, matte: Matte?) {
        let record = Record(
            filename: filename,
            tvContentID: tvContentID,
            uploadedAt: Date(),
            matte: matte,
            source: .lightframe,
            lastSyncedAt: Date()
        )
        records[filename] = record
        save()
        print("💾 SyncStore: Recorded upload of \(filename) as \(tvContentID)")
    }

    /// Remove the record for a photo that was deleted from the TV
    func recordDeletion(filename: String) {
        records.removeValue(forKey: filename)
        save()
        print("💾 SyncStore: Removed record for \(filename)")
    }

    /// Remove the record for a TV content ID (used when we only know the ID, not filename)
    func recordDeletion(tvContentID: String) {
        records = records.filter { $0.value.tvContentID != tvContentID }
        tvOnlyItems.removeAll { $0.id == tvContentID }
        save()
    }

    /// Clear all records — used when doing a full reset
    func clearAll() {
        records = [:]
        tvOnlyItems = []
        lastFullSyncDate = nil
        save()
        print("💾 SyncStore: Cleared all records")
    }

    /// Rebuild records from a fresh TV query — used by Reconcile feature
    func reconcile(with tvItems: [(filename: String, contentID: String, matte: Matte?)]) {
        records = [:]
        for item in tvItems {
            records[item.filename] = Record(
                filename: item.filename,
                tvContentID: item.contentID,
                uploadedAt: Date(),
                matte: item.matte,
                source: .lightframe,
                lastSyncedAt: Date()
            )
        }
        save()
        print("💾 SyncStore: Reconciled with \(tvItems.count) TV items")
    }

    /// Update the matte for a specific filename in the cache
    func updateMatte(_ matte: Matte, for filename: String) {
        guard records[filename] != nil else { return }
        records[filename]?.matte = matte
        records[filename]?.lastSyncedAt = Date()
        save()
    }

    /// Update tvOnlyItems from a TV scan
    func setTVOnlyItems(_ items: [TVOnlyItem]) {
        tvOnlyItems = items
        save()
    }

    /// Remove a TV-only item by content ID
    func removeTVOnlyItem(contentID: String) {
        tvOnlyItems.removeAll { $0.id == contentID }
        save()
    }

    /// Mark a full sync as complete
    func markFullSync() {
        lastFullSyncDate = Date()
        // Update lastSyncedAt on all records
        for key in records.keys {
            records[key]?.lastSyncedAt = Date()
        }
        save()
    }

    // MARK: - Persistence

    private func save() {
        let payload = StoragePayload(
            records: records,
            tvOnlyItems: tvOnlyItems,
            lastFullSyncDate: lastFullSyncDate
        )
        if let encoded = try? JSONEncoder().encode(payload) {
            try? encoded.write(to: storageURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }

        // Try new format first
        if let decoded = try? JSONDecoder().decode(StoragePayload.self, from: data) {
            records = decoded.records
            tvOnlyItems = decoded.tvOnlyItems
            lastFullSyncDate = decoded.lastFullSyncDate
            print("💾 SyncStore: Loaded \(records.count) records, \(tvOnlyItems.count) TV-only items for TV \(tvID)")
            return
        }

        // Migration: old format was bare [String: Record]
        if let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
            tvOnlyItems = []
            lastFullSyncDate = nil
            print("💾 SyncStore: Migrated \(records.count) records from old format for TV \(tvID)")
            save() // Re-save in new format
            return
        }
    }
}

// MARK: - SyncStoreManager
// Manages one SyncStore per TV so we don't create duplicates.
// Access via SyncStoreManager.shared.store(for: tv)
class SyncStoreManager {
    static let shared = SyncStoreManager()
    private var stores: [UUID: SyncStore] = [:]

    private init() {}

    /// Get or create a SyncStore for a given TV
    func store(for tv: TV) -> SyncStore {
        if let existing = stores[tv.id] {
            return existing
        }
        let store = SyncStore(tvID: tv.id)
        stores[tv.id] = store
        return store
    }

    /// Remove the store and delete its file — called when a TV is removed
    func removeStore(for tv: TV) {
        stores.removeValue(forKey: tv.id)
    }
}
