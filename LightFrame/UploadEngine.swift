import Foundation
import SwiftUI
import Combine

// MARK: - Duplicate Resolution
// When a photo is already on the TV, the user can choose to skip or overwrite it.
// They can also apply their choice to all remaining duplicates in this batch.
enum DuplicateResolution {
    case skip
    case overwrite
}

// MARK: - Upload Item State
// Tracks the result of a single photo in the upload queue.
enum UploadItemState {
    case pending        // Not started yet
    case uploading      // In progress
    case done           // Successfully uploaded
    case skipped        // Already on TV, user chose to skip
    case failed(String) // Error message
}

// MARK: - Upload Item
// One entry in the upload queue — one photo and its outcome.
struct UploadItem: Identifiable {
    let id: UUID
    let photo: Photo
    let collection: Collection
    var state: UploadItemState = .pending
}

// MARK: - UploadEngine
// Drives the upload queue sequentially.
//
// Sequential (not concurrent) because:
// - The Samsung TV WebSocket only handles one command at a time
// - A pending continuation is stored in TVConnection — sending two uploads
//   simultaneously would corrupt the response routing
//
// Cancellation:
// - isCancelled flag is checked before each photo
// - The current photo finishes cleanly before the engine stops
//   (we don't yank the WebSocket mid-transfer)
@MainActor
class UploadEngine: ObservableObject, Identifiable {

    // Stable identity for sheet(item:) — each upload session is a unique engine
    let id = UUID()

    // MARK: - Published State
    // These drive the modal UI

    @Published var items: [UploadItem] = []

    // Index into items[] for the photo currently being uploaded
    @Published var currentIndex: Int = 0

    // Whether the engine is actively running
    @Published var isRunning: Bool = false

    // Whether the full batch is finished (success or cancelled)
    @Published var isComplete: Bool = false

    // Set to true when the user taps Cancel — engine stops after current photo
    @Published var isCancelled: Bool = false

    // Elapsed seconds — drives time-remaining estimate
    @Published var elapsedSeconds: Double = 0

    // MARK: - Duplicate Handling
    // When a duplicate is detected the engine pauses here and waits for
    // the UI to call resolveDuplicate() with the user's choice.
    @Published var pendingDuplicate: UploadItem? = nil

    // If the user checked "apply to all", this holds their blanket choice
    // for all subsequent duplicates in this batch.
    private var bulkDuplicateResolution: DuplicateResolution? = nil

    // The continuation that the engine is suspended on while waiting
    // for the user to respond to a duplicate prompt.
    private var duplicateContinuation: CheckedContinuation<DuplicateResolution, Never>?

    // MARK: - Dependencies
    private var tvManager: TVConnectionManager
    private var appState: AppState
    private var syncStore: SyncStore

    // The currently running upload task — cancelled when user taps Cancel
    private var currentUploadTask: Task<Void, Never>?

    // MARK: - Init
    init(tvManager: TVConnectionManager, appState: AppState, syncStore: SyncStore) {
        self.tvManager = tvManager
        self.appState = appState
        self.syncStore = syncStore
    }

    // MARK: - Computed Properties

    var totalCount: Int { items.count }
    var doneCount: Int { items.filter { if case .done = $0.state { return true }; return false }.count }
    var skippedCount: Int { items.filter { if case .skipped = $0.state { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed(_) = $0.state { return true }; return false }.count }
    var pendingCount: Int { items.filter { if case .pending = $0.state { return true }; return false }.count }

    // Progress 0.0 → 1.0 based on non-pending items
    var progress: Double {
        guard totalCount > 0 else { return 0 }
        let processed = totalCount - pendingCount
        return Double(processed) / Double(totalCount)
    }

    // Estimated seconds remaining based on average time per photo so far
    var estimatedSecondsRemaining: Double? {
        let processed = totalCount - pendingCount
        guard processed > 0, elapsedSeconds > 0 else { return nil }
        let avgPerPhoto = elapsedSeconds / Double(processed)
        return avgPerPhoto * Double(pendingCount)
    }

    // Human-readable time remaining string shown in the modal
    var timeRemainingString: String {
        guard let secs = estimatedSecondsRemaining, secs > 0 else {
            return pendingCount > 0 ? "Estimating..." : ""
        }
        if secs < 60 { return "About \(Int(secs))s remaining" }
        let mins = Int(secs / 60)
        return "About \(mins)m remaining"
    }

    // Name of the photo currently being processed
    var currentPhotoName: String {
        guard currentIndex < items.count else { return "" }
        return items[currentIndex].photo.filename
    }

    // MARK: - Start Upload
    /// Builds the queue from the given photos and starts processing.
    func start(photos: [Photo], collection: Collection) async {
        // Build the item queue
        items = photos.map { UploadItem(id: UUID(), photo: $0, collection: collection) }
        currentIndex = 0
        isRunning = true
        isComplete = false
        isCancelled = false
        elapsedSeconds = 0
        bulkDuplicateResolution = nil

        // Start the elapsed-time ticker
        startTimer()

        // Process each item in order
        for index in items.indices {
            guard !isCancelled else { break }

            currentIndex = index

            // Wrap in a Task so cancel() can interrupt it mid-upload
            await withTaskCancellationHandler {
                let task = Task { await self.processItem(at: index) }
                currentUploadTask = task
                await task.value
                currentUploadTask = nil
            } onCancel: {
                // Task.cancel() is called by the withTaskCancellationHandler
            }

            if isCancelled { break }
        }

        // Wrap up
        stopTimer()
        isRunning = false
        isComplete = true
    }

    // MARK: - Cancel
    /// Signals the engine to stop. Cancels the current upload task immediately.
    func cancel() {
        isCancelled = true
        currentUploadTask?.cancel()
        currentUploadTask = nil
        // If paused on a duplicate prompt, auto-skip
        duplicateContinuation?.resume(returning: .skip)
        duplicateContinuation = nil
        pendingDuplicate = nil
    }

    // MARK: - Retry Failed
    /// Re-queues all failed items and processes them again.
    /// Called from the completion screen's "Retry Failed" button.
    func retryFailed() async {
        // Reset failed items back to pending
        for index in items.indices {
            if case .failed = items[index].state {
                items[index].state = .pending
            }
        }

        isComplete = false
        isCancelled = false
        isRunning = true
        bulkDuplicateResolution = nil

        startTimer()

        // Process only the items that are pending (the retried ones)
        for index in items.indices {
            guard !isCancelled else { break }
            guard case .pending = items[index].state else { continue }

            currentIndex = index

            await withTaskCancellationHandler {
                let task = Task { await self.processItem(at: index) }
                currentUploadTask = task
                await task.value
                currentUploadTask = nil
            } onCancel: {}

            if isCancelled { break }
        }

        stopTimer()
        isRunning = false
        isComplete = true
    }

    // MARK: - Resolve Duplicate
    /// Called by the UI when the user responds to the duplicate prompt.
    /// applyToAll: if true, stores their choice for all future duplicates this session.
    func resolveDuplicate(_ resolution: DuplicateResolution, applyToAll: Bool) {
        if applyToAll {
            bulkDuplicateResolution = resolution
        }
        pendingDuplicate = nil
        duplicateContinuation?.resume(returning: resolution)
        duplicateContinuation = nil
    }

    // MARK: - Process Single Item
    private func processItem(at index: Int) async {
        var item = items[index]
        item.state = .uploading
        items[index] = item

        let photo = item.photo

        // Check if already on TV
        if photo.isOnTV {
            let resolution = await resolutionForDuplicate(item: item)
            switch resolution {
            case .skip:
                items[index].state = .skipped
                return
            case .overwrite:
                // Delete the old version first, then re-upload below
                if let contentID = photo.tvContentID {
                    try? await tvManager.deletePhotos(contentIDs: [contentID])
                    syncStore.recordDeletion(filename: photo.filename)
                    var updated = photo
                    updated.isOnTV = false
                    updated.tvContentID = nil
                    appState.updatePhotoInPlace(updated, in: item.collection)
                }
            }
        }

        // Load image data (security scope is handled by the collection bookmark)
        guard let imageData = loadImageData(for: photo, collection: item.collection) else {
            items[index].state = .failed("Could not read file")
            return
        }

        // Determine file type
        let fileType = photo.fileExtension.uppercased() == "PNG" ? "PNG" : "JPEG"
        print("📦 Uploading \(photo.filename): \(imageData.count / 1024)KB as \(fileType)")

        // Upload to TV — TVConnectionManager handles matte fallback automatically.
        // No automatic retry: if upload fails after TCP transfer, the image may already
        // be on the TV. Retrying would create duplicates. This matches Nick's Python
        // where upload() is called once with no retry wrapper.
        do {
            let (contentID, confirmedMatte) = try await tvManager.uploadPhoto(
                imageData: imageData,
                fileType: fileType,
                matte: photo.matte
            )

            // Record the upload in SyncStore so future scans know it's on the TV
            syncStore.recordUpload(
                filename: photo.filename,
                tvContentID: contentID,
                matte: confirmedMatte
            )

            // Update the photo in AppState so the grid dot turns green immediately
            appState.setContentID(contentID, for: photo, in: item.collection)

            // If the matte fell back, update model to match what the TV actually got
            if confirmedMatte != photo.matte {
                if let confirmed = confirmedMatte {
                    appState.updateMatte(confirmed, for: photo, newData: nil)
                }
            }

            items[index].state = .done

        } catch {
            print("❌ FAILED \(photo.filename): \(error)")
            items[index].state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Duplicate Resolution Logic
    // If a bulk resolution has been set (user checked "apply to all"), use that.
    // Otherwise, pause the engine and wait for the UI to call resolveDuplicate().
    private func resolutionForDuplicate(item: UploadItem) async -> DuplicateResolution {
        // Bulk resolution already set — use it without prompting
        if let bulk = bulkDuplicateResolution { return bulk }

        // Pause and wait for user input
        return await withCheckedContinuation { continuation in
            self.duplicateContinuation = continuation
            self.pendingDuplicate = item
        }
    }

    // MARK: - Load Image Data
    // Opens the collection's security-scoped bookmark to read the file.
    private func loadImageData(for photo: Photo, collection: Collection) -> Data? {
        var resolvedURL = collection.folderURL
        var accessGranted = false

        if let bookmarkData = collection.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                resolvedURL = url
                // Silently regenerate stale bookmarks without showing UI
                if isStale {
                    appState.refreshBookmark(for: collection, url: url)
                }
            }
        }

        accessGranted = resolvedURL.startAccessingSecurityScopedResource()
        defer { if accessGranted { resolvedURL.stopAccessingSecurityScopedResource() } }

        return try? Data(contentsOf: photo.url)
    }

    // MARK: - Timer
    // Uses a Swift async Task loop instead of Timer to avoid Swift 6
    // concurrency issues with captured self in a Timer callback.
    // The loop runs every second while isRunning is true.
    private func startTimer() {
        Task { @MainActor [weak self] in
            while let self, self.isRunning && !self.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if self.isRunning && !self.isCancelled {
                    self.elapsedSeconds += 1
                }
            }
        }
    }

    private func stopTimer() {
        // No-op — the task loop exits naturally when isRunning becomes false
    }
}

// MARK: - AppState extension
// Adds updatePhotoInPlace which surgically updates one photo without a full rescan.
// Used by UploadEngine to clear isOnTV when overwriting a duplicate.
extension AppState {
    func updatePhotoInPlace(_ photo: Photo, in collection: Collection) {
        guard let colIndex = collections.firstIndex(where: { $0.id == collection.id }),
              let photoIndex = collections[colIndex].photos.firstIndex(where: { $0.id == photo.id })
        else { return }
        collections[colIndex].photos[photoIndex] = photo
        if selectedCollection?.id == collection.id {
            selectedCollection = collections[colIndex]
        }
        save()
    }
}
