import SwiftUI
import Combine

// MARK: - PhotoGridView
// The center column — a scrollable grid of photo thumbnails.
// Every cell is forced to 16:9 aspect ratio.
// Photos without a matte show aspect-fit on black background.
struct PhotoGridView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tvManager: TVConnectionManager

    // The UploadEngine driving the current upload session.
    // Non-nil while an upload is active — used as the sheet item trigger.
    // Recreated each time an upload starts so state is always fresh.
    @State private var uploadEngine: UploadEngine? = nil

    // Delete confirmation and progress
    @State private var showDeleteConfirmation = false
    @State private var photosToDelete: [Photo] = []
    @State private var tvOnlyItemsToDelete: [TVOnlyItem] = []
    @State private var deleteEngine: DeleteEngine? = nil

    // Scan TV progress
    @State private var scanTVEngine: ScanTVEngine? = nil

    var columns: [GridItem] {
        [GridItem(.adaptive(
            minimum: appState.thumbnailSize,
            maximum: appState.thumbnailSize + 20
        ))]
    }

    /// Whether to show TV-only items inline in the grid
    private var showTVOnlyItems: Bool {
        if case .photosOnTV = appState.sidebarSelection { return true }
        if appState.gridFilter == .onTV { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {

            if appState.isScanning {
                PulsingDivider()
            }

            // MARK: Empty State
            if appState.filteredPhotos.isEmpty && (!showTVOnlyItems || appState.tvOnlyItems.isEmpty) && !appState.isScanning {
                EmptyGridView()
            } else {
                // MARK: Photo Grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(appState.filteredPhotos) { photo in
                            PhotoThumbnailView(photo: photo)
                                .onTapGesture { handleTap(photo: photo) }
                                .contextMenu { photoContextMenu(for: photo) }
                        }

                        // Show TV-only items inline when appropriate
                        if showTVOnlyItems {
                            ForEach(appState.tvOnlyItems) { item in
                                TVOnlyThumbnailView(item: item, size: appState.thumbnailSize)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(appState.selectedTVOnlyItemIDs.contains(item.id) ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                    .scaleEffect(appState.selectedTVOnlyItemIDs.contains(item.id) ? 0.97 : 1.0)
                                    .animation(.easeInOut(duration: 0.1), value: appState.selectedTVOnlyItemIDs.contains(item.id))
                                    .onTapGesture { handleTVOnlyTap(item: item) }
                                    .contextMenu { tvOnlyContextMenu(for: item) }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        // MARK: Upload Modal Sheet
        // sheet(item:) guarantees the engine is non-nil when the sheet renders —
        // unlike sheet(isPresented:) which can render before the @State update lands.
        .sheet(item: $uploadEngine) { engine in
            UploadModal(engine: engine) {
                uploadEngine = nil
            }
        }
        // MARK: Native Toolbar
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Sort", selection: $appState.sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .frame(width: 160)
            }

            ToolbarItem(placement: .primaryAction) {
                UploadControlsView(
                    onUploadSelected: startUploadSelected,
                    onUploadAll: startUploadAll,
                    onDeleteSelected: confirmDeleteSelected,
                    onScanTV: startScanTV
                )
            }
        }
        // Delete progress modal
        .sheet(item: $deleteEngine) { engine in
            DeleteModal(engine: engine) {
                deleteEngine = nil
            }
        }
        // Scan TV progress modal
        .sheet(item: $scanTVEngine) { engine in
            ScanTVModal(engine: engine) {
                scanTVEngine = nil
            }
        }
        // Menu bar trigger: Scan TV
        .onChange(of: appState.triggerScanTV) {
            if appState.triggerScanTV {
                appState.triggerScanTV = false
                startScanTV()
            }
        }
        // Menu bar trigger: Delete Selected
        .onChange(of: appState.triggerDeleteSelected) {
            if appState.triggerDeleteSelected {
                appState.triggerDeleteSelected = false
                confirmDeleteSelected()
            }
        }
        // Arrow key navigation
        .onKeyPress(.leftArrow)  { navigateGrid(direction: .left);  return .handled }
        .onKeyPress(.rightArrow) { navigateGrid(direction: .right); return .handled }
        .onKeyPress(.upArrow)    { navigateGrid(direction: .up);    return .handled }
        .onKeyPress(.downArrow)  { navigateGrid(direction: .down);  return .handled }
        .onKeyPress(.escape)     { appState.clearSelection(); return .handled }
        .focusable(interactions: .activate)
        .focusEffectDisabled()
        // Delete confirmation alert
        .alert(
            "Remove from TV",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {
                photosToDelete = []
                tvOnlyItemsToDelete = []
            }
            Button("Remove", role: .destructive) { startDelete() }
        } message: {
            let total = photosToDelete.count + tvOnlyItemsToDelete.count
            Text("Remove \(total) photo\(total == 1 ? "" : "s") from the TV? This can't be undone.")
        }
    }

    // MARK: - Start Upload: Selected Photos
    private func startUploadSelected() {
        guard let collection = currentCollection,
              tvManager.isConnected
        else { return }

        let photosToUpload = appState.selectedPhotos
        guard !photosToUpload.isEmpty else { return }

        beginUpload(photos: photosToUpload, collection: collection)
    }

    // MARK: - Start Upload: All Photos
    private func startUploadAll() {
        guard let collection = currentCollection,
              tvManager.isConnected
        else { return }

        let photosToUpload = appState.filteredPhotos.filter { !$0.isOnTV }
        guard !photosToUpload.isEmpty else { return }

        beginUpload(photos: photosToUpload, collection: collection)
    }

    /// Resolves the current collection based on sidebar selection
    private var currentCollection: Collection? {
        switch appState.sidebarSelection {
        case .collection(let id):
            return appState.collections.first(where: { $0.id == id })
        default:
            return appState.selectedCollection
        }
    }

    // MARK: - Begin Upload Session
    private func beginUpload(photos: [Photo], collection: Collection) {
        guard let tv = appState.selectedTV else { return }

        let syncStore = SyncStoreManager.shared.store(for: tv)
        let engine = UploadEngine(
            tvManager: tvManager,
            appState: appState,
            syncStore: syncStore
        )

        // Set the engine first — this triggers the sheet to appear with a valid engine
        uploadEngine = engine

        // Run the upload in a Task so we don't block the UI
        Task {
            await engine.start(photos: photos, collection: collection)
        }
    }

    // MARK: - Pulsing Divider (scanning indicator)
    struct PulsingDivider: View {
        @State private var opacity: Double = 1.0

        var body: some View {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .opacity(opacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        opacity = 0.3
                    }
                }
        }
    }

    private func handleTap(photo: Photo) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command) {
            appState.togglePhotoSelection(photo)
        } else if modifiers.contains(.shift) {
            appState.selectRange(to: photo, in: appState.filteredPhotos)
        } else {
            appState.selectPhoto(photo)
        }
    }

    private func handleTVOnlyTap(item: TVOnlyItem) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command) {
            appState.toggleTVOnlyItemSelection(item)
        } else if modifiers.contains(.shift) {
            appState.selectTVOnlyRange(to: item)
        } else {
            appState.selectTVOnlyItem(item)
        }
    }

    // MARK: - Arrow Key Navigation
    enum NavigationDirection { case left, right, up, down }

    private func navigateGrid(direction: NavigationDirection) {
        let photos = appState.filteredPhotos
        guard !photos.isEmpty else { return }

        // Estimate column count from thumbnail size and a reasonable grid width
        let colCount = max(1, Int((600 / (appState.thumbnailSize + 20)).rounded(.down)))

        // Find current index
        let currentIndex: Int
        if let lastPhoto = appState.lastTappedPhoto,
           let idx = photos.firstIndex(where: { $0.id == lastPhoto.id }) {
            currentIndex = idx
        } else {
            // Nothing selected — start at first photo
            appState.selectPhoto(photos[0])
            return
        }

        let newIndex: Int
        switch direction {
        case .left:  newIndex = max(0, currentIndex - 1)
        case .right: newIndex = min(photos.count - 1, currentIndex + 1)
        case .up:    newIndex = max(0, currentIndex - colCount)
        case .down:  newIndex = min(photos.count - 1, currentIndex + colCount)
        }

        guard newIndex != currentIndex else { return }
        appState.selectPhoto(photos[newIndex])
    }

    @ViewBuilder
    private func tvOnlyContextMenu(for item: TVOnlyItem) -> some View {
        let isConnected = tvManager.isConnected
        let isPartOfSelection = appState.selectedTVOnlyItemIDs.contains(item.id) && appState.selectedTVOnlyItemIDs.count > 1

        Button {
            // Display currently tapped item
            Task { try? await tvManager.selectPhoto(contentID: item.id) }
        } label: {
            Label("Display on TV", systemImage: "tv")
        }
        .disabled(!isConnected)

        Button(role: .destructive) {
            photosToDelete = []
            if isPartOfSelection {
                tvOnlyItemsToDelete = appState.selectedTVOnlyItems
            } else {
                tvOnlyItemsToDelete = [item]
            }
            showDeleteConfirmation = true
        } label: {
            if isPartOfSelection {
                Label("Remove \(appState.selectedTVOnlyItemIDs.count) from TV", systemImage: "trash")
            } else {
                Label("Remove from TV", systemImage: "trash")
            }
        }
        .disabled(!isConnected)

        Divider()

        Button {
            // Select all TV-only items
            appState.selectedTVOnlyItemIDs = Set(appState.tvOnlyItems.map { $0.id })
        } label: {
            Label("Select All TV-Only", systemImage: "checkmark.circle")
        }

        if !appState.selectedTVOnlyItemIDs.isEmpty {
            Button {
                appState.clearSelection()
            } label: {
                Label("Deselect All", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - Context Menu
    @ViewBuilder
    private func photoContextMenu(for photo: Photo) -> some View {
        let isConnected = tvManager.isConnected
        let isPartOfSelection = appState.selectedPhotoIDs.contains(photo.id) && appState.selectedPhotoIDs.count > 1

        // Send to TV — respects multi-selection
        Button {
            if isPartOfSelection {
                // Upload the entire selection (don't change it)
                startUploadSelected()
            } else {
                // Single photo — select it then upload
                appState.selectPhoto(photo)
                startUploadSelected()
            }
        } label: {
            if isPartOfSelection {
                Label("Send \(appState.selectedPhotoIDs.count) to TV", systemImage: "arrow.up.circle")
            } else {
                Label(photo.isOnTV ? "Re-send to TV" : "Send to TV", systemImage: "arrow.up.circle")
            }
        }
        .disabled(!isConnected)

        // Remove from TV (single or selected)
        if photo.isOnTV || (isPartOfSelection && appState.selectedPhotos.contains(where: { $0.isOnTV })) {
            Button(role: .destructive) {
                if isPartOfSelection {
                    confirmDeleteSelected()
                } else {
                    photosToDelete = [photo]
                    showDeleteConfirmation = true
                }
            } label: {
                if isPartOfSelection {
                    let onTVCount = appState.selectedPhotos.filter { $0.isOnTV }.count
                    Label("Remove \(onTVCount) from TV", systemImage: "trash")
                } else {
                    Label("Remove from TV", systemImage: "trash")
                }
            }
            .disabled(!isConnected)
        }

        Divider()

        // Selection helpers
        Button {
            appState.selectAll(photos: appState.filteredPhotos)
        } label: {
            Label("Select All", systemImage: "checkmark.circle")
        }

        if !appState.selectedPhotoIDs.isEmpty {
            Button {
                appState.clearSelection()
            } label: {
                Label("Deselect All", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - Confirm Delete Selected
    private func confirmDeleteSelected() {
        let onTVPhotos = appState.selectedPhotos.filter { $0.isOnTV }
        let tvOnlySelected = appState.selectedTVOnlyItems
        guard !onTVPhotos.isEmpty || !tvOnlySelected.isEmpty else { return }
        photosToDelete = onTVPhotos
        tvOnlyItemsToDelete = tvOnlySelected
        showDeleteConfirmation = true
    }

    // MARK: - Start Delete
    private func startDelete() {
        guard tvManager.isConnected,
              let tv = appState.selectedTV
        else { return }

        let photos = photosToDelete
        let tvOnlyItems = tvOnlyItemsToDelete
        photosToDelete = []
        tvOnlyItemsToDelete = []

        guard !photos.isEmpty || !tvOnlyItems.isEmpty else { return }

        let syncStore = SyncStoreManager.shared.store(for: tv)
        let engine = DeleteEngine(
            tvManager: tvManager,
            appState: appState,
            syncStore: syncStore
        )
        deleteEngine = engine

        Task {
            await engine.start(photos: photos, tvOnlyItems: tvOnlyItems)
        }
    }

    // MARK: - Start Scan TV
    private func startScanTV() {
        guard let tv = appState.selectedTV else { return }

        let syncStore = SyncStoreManager.shared.store(for: tv)

        Task {
            // Reconnect if needed
            if !tvManager.isConnected {
                await tvManager.reconnect()
            }
            guard tvManager.isConnected else { return }

            let engine = ScanTVEngine(
                tvManager: tvManager,
                appState: appState,
                syncStore: syncStore,
                collections: appState.collections
            )
            scanTVEngine = engine
            await engine.start()
        }
    }
}

// MARK: - Photo Thumbnail
struct PhotoThumbnailView: View {
    @EnvironmentObject var appState: AppState
    let photo: Photo

    var isSelected: Bool { appState.selectedPhotoIDs.contains(photo.id) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MattePreviewView(photo: photo, size: appState.thumbnailSize)
                .frame(
                    width: appState.thumbnailSize,
                    height: appState.thumbnailSize * 9 / 16
                )

            // Badge stack in lower-right
            HStack(spacing: 3) {
                if !photo.is16x9 {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Color.orange.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(4)
        }
        .frame(
            width: appState.thumbnailSize,
            height: appState.thumbnailSize * 9 / 16
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isSelected ? 0.97 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
        .focusable(false)
    }
}

// MARK: - TV-Only Thumbnail
// Shows a TV-only item (no local file) with dashed border and "TV" label badge.
struct TVOnlyThumbnailView: View {
    let item: TVOnlyItem
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let data = item.thumbnailData,
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size * 9 / 16)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.3))
                    .frame(width: size, height: size * 9 / 16)
                    .overlay(
                        Image(systemName: "tv")
                            .foregroundColor(.secondary)
                    )
            }

            // Badge stack in lower-right
            HStack(spacing: 3) {
                if !item.is16x9 {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Color.orange.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                // "TV" label badge
                Text("TV")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(4)
        }
        .frame(width: size, height: size * 9 / 16)
        // Dashed inset border for TV-only items
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                .foregroundColor(.blue.opacity(0.5))
                .padding(2)
        )
    }
}

// MARK: - Empty Grid View
struct EmptyGridView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            switch appState.sidebarSelection {
            case .photosOnTV:
                if appState.selectedTV == nil {
                    Text("No TV selected")
                        .foregroundColor(.secondary)
                    Text("Select a TV in the sidebar to see its photos.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("No photos on TV")
                        .foregroundColor(.secondary)
                    Text("Scan TV to see what's on it, or upload photos from a collection.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            case .allPhotos:
                if appState.collections.isEmpty {
                    Text("No collections yet")
                        .foregroundColor(.secondary)
                    Text("Add a folder in the sidebar to get started.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("No photos found")
                        .foregroundColor(.secondary)
                }
            case .collection:
                if appState.selectedCollection == nil {
                    Text("No collection selected")
                        .foregroundColor(.secondary)
                    Text("Add a folder in the sidebar to get started.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("No photos found")
                        .foregroundColor(.secondary)
                    Text("Add JPEG or PNG files to \(appState.selectedCollection!.name).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Upload Controls
// The Scan / Upload / Delete buttons in the grid toolbar.
struct UploadControlsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tvManager: TVConnectionManager

    let onUploadSelected: () -> Void
    let onUploadAll: () -> Void
    let onDeleteSelected: () -> Void
    let onScanTV: () -> Void

    var isConnected: Bool {
        tvManager.isConnected
    }

    var hasSelection: Bool { !appState.selectedPhotoIDs.isEmpty }

    var isPhotosOnTV: Bool {
        if case .photosOnTV = appState.sidebarSelection { return true }
        return false
    }

    // Count of photos not yet on the TV (what "Upload All" will act on)
    var notOnTVCount: Int {
        appState.filteredPhotos.filter { !$0.isOnTV }.count
    }

    // Count of selected photos that are on the TV (what "Remove from TV" will act on)
    var selectedOnTVCount: Int {
        appState.selectedPhotos.filter { $0.isOnTV }.count + appState.selectedTVOnlyItemIDs.count
    }

    var body: some View {
        HStack(spacing: 8) {
            // Scan TV button — always available when a TV is selected
            Button("Scan TV") {
                onScanTV()
            }
            .disabled(!isConnected || appState.isScanning || appState.selectedTV == nil)

            if !isPhotosOnTV {
                // Scan folder
                Button("Scan Folder") {
                    Task { await appState.scanSelectedCollection() }
                }
                .disabled(appState.selectedCollection == nil || appState.isScanning)

                // Upload buttons
                if hasSelection {
                    Button("Upload Selected (\(appState.selectedPhotoIDs.count))") {
                        onUploadSelected()
                    }
                    .disabled(!isConnected)
                }

                if notOnTVCount > 0 {
                    Button("Upload All (\(notOnTVCount))") {
                        onUploadAll()
                    }
                    .disabled(!isConnected)
                }
            }

            // "Remove from TV" shows when selected photos are on the TV
            if selectedOnTVCount > 0 {
                Button(role: .destructive) {
                    onDeleteSelected()
                } label: {
                    Text("Remove from TV (\(selectedOnTVCount))")
                }
                .disabled(!isConnected)
            }
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Upload Progress View (inline, not used when modal is active)
struct UploadProgressView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Uploading \(appState.uploadCurrent) of \(appState.uploadTotal)")
                    .font(.caption)
                Spacer()
                Text(appState.uploadTimeRemaining)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ProgressView(value: appState.uploadProgress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - DeleteEngine
// Deletes photos from the TV one at a time with progress tracking.
// Sequential because the TV can't handle batch deletes reliably.
@MainActor
class DeleteEngine: ObservableObject, Identifiable {
    let id = UUID()

    @Published var totalCount: Int = 0
    @Published var completedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var currentFilename: String = ""
    @Published var isComplete: Bool = false
    @Published var isCancelled: Bool = false

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount + failedCount) / Double(totalCount)
    }

    private let tvManager: TVConnectionManager
    private let appState: AppState
    private let syncStore: SyncStore

    init(tvManager: TVConnectionManager, appState: AppState, syncStore: SyncStore) {
        self.tvManager = tvManager
        self.appState = appState
        self.syncStore = syncStore
    }

    func start(photos: [Photo], tvOnlyItems: [TVOnlyItem] = []) async {
        totalCount = photos.count + tvOnlyItems.count
        var deleteIndex = 0

        // Delete local-matched photos
        for photo in photos {
            guard !isCancelled else { break }
            guard let contentID = photo.tvContentID else {
                failedCount += 1
                continue
            }

            currentFilename = photo.filename

            if deleteIndex > 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            deleteIndex += 1

            do {
                try await tvManager.deletePhotos(contentIDs: [contentID])

                syncStore.recordDeletion(filename: photo.filename)

                if let collection = appState.collections.first(where: { col in
                    col.photos.contains(where: { $0.id == photo.id })
                }) {
                    var updated = photo
                    updated.isOnTV = false
                    updated.tvContentID = nil
                    appState.updatePhotoInPlace(updated, in: collection)
                }

                completedCount += 1
            } catch {
                let errMsg = error.localizedDescription
                if errMsg.contains("-10") {
                    print("⚠️ \(photo.filename) already gone from TV — cleaning up")
                    syncStore.recordDeletion(filename: photo.filename)
                    if let collection = appState.collections.first(where: { col in
                        col.photos.contains(where: { $0.id == photo.id })
                    }) {
                        var updated = photo
                        updated.isOnTV = false
                        updated.tvContentID = nil
                        appState.updatePhotoInPlace(updated, in: collection)
                    }
                    completedCount += 1
                } else {
                    failedCount += 1
                    print("❌ Delete failed for \(photo.filename): \(errMsg)")
                }
            }
        }

        // Delete TV-only items (no local file)
        for item in tvOnlyItems {
            guard !isCancelled else { break }

            currentFilename = item.id

            if deleteIndex > 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            deleteIndex += 1

            do {
                try await tvManager.deletePhotos(contentIDs: [item.id])
                syncStore.removeTVOnlyItem(contentID: item.id)
                appState.tvOnlyItems.removeAll { $0.id == item.id }
                completedCount += 1
            } catch {
                let errMsg = error.localizedDescription
                if errMsg.contains("-10") {
                    syncStore.removeTVOnlyItem(contentID: item.id)
                    appState.tvOnlyItems.removeAll { $0.id == item.id }
                    completedCount += 1
                } else {
                    failedCount += 1
                    print("❌ Delete failed for TV item \(item.id): \(errMsg)")
                }
            }
        }

        isComplete = true
    }

    func cancel() {
        isCancelled = true
    }
}

// MARK: - DeleteModal
// Simple progress modal shown during delete operations.
struct DeleteModal: View {
    @ObservedObject var engine: DeleteEngine
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(engine.isComplete ? (engine.isCancelled ? "Delete Cancelled" : "Delete Complete") : "Removing from TV")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            VStack(spacing: 16) {
                if engine.isComplete {
                    // Summary
                    Image(systemName: engine.isCancelled ? "xmark.circle" : "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(engine.isCancelled ? .secondary : .green)

                    VStack(spacing: 6) {
                        if engine.completedCount > 0 {
                            HStack {
                                Image(systemName: "trash.fill").foregroundColor(.green).frame(width: 20)
                                Text("Removed")
                                Spacer()
                                Text("\(engine.completedCount)").fontWeight(.semibold).monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                        if engine.failedCount > 0 {
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red).frame(width: 20)
                                Text("Failed")
                                Spacer()
                                Text("\(engine.failedCount)").fontWeight(.semibold).monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                } else {
                    // Progress
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.currentFilename)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(engine.completedCount + engine.failedCount + 1) of \(engine.totalCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    ProgressView(value: engine.progress)
                        .progressViewStyle(.linear)
                }
            }
            .padding(24)

            Divider()

            // Footer
            HStack {
                Spacer()
                if engine.isComplete {
                    Button("Done") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") { engine.cancel() }
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 380)
    }
}

// MARK: - ScanTVEngine
// Queries the TV for its photo library, reconciles with local SyncStore,
// and downloads thumbnails for TV-only items (uploaded from Samsung app etc).
@MainActor
class ScanTVEngine: ObservableObject, Identifiable {
    let id = UUID()

    @Published var statusMessage: String = "Connecting to TV..."
    @Published var tvPhotoCount: Int = 0
    @Published var matchedCount: Int = 0
    @Published var unmatchedCount: Int = 0
    @Published var downloadedCount: Int = 0
    @Published var isComplete: Bool = false
    @Published var isCancelled: Bool = false
    @Published var errorMessage: String? = nil

    var downloadProgress: Double {
        guard unmatchedCount > 0 else { return 0 }
        return Double(downloadedCount) / Double(unmatchedCount)
    }

    private let tvManager: TVConnectionManager
    private let appState: AppState
    private let syncStore: SyncStore
    private let collections: [Collection]

    init(tvManager: TVConnectionManager, appState: AppState, syncStore: SyncStore, collections: [Collection]) {
        self.tvManager = tvManager
        self.appState = appState
        self.syncStore = syncStore
        self.collections = collections
    }

    func start() async {
        do {
            statusMessage = "Querying TV art library..."

            let tvItems = try await tvManager.getMyPhotos()
            tvPhotoCount = tvItems.count
            statusMessage = "Found \(tvPhotoCount) photo(s) on TV. Matching..."

            // Build lookup structures
            let tvContentIDs = Set(tvItems.map { $0.id })
            var tvItemByID: [String: TVArtItem] = [:]
            for item in tvItems {
                tvItemByID[item.id] = item
            }

            // Reconcile local photos across ALL collections with TV state
            var matched = 0
            let allPhotos = collections.flatMap { $0.photos }

            for photo in allPhotos {
                guard let collection = collections.first(where: { col in
                    col.photos.contains(where: { $0.id == photo.id })
                }) else { continue }

                if let knownID = photo.tvContentID {
                    if tvContentIDs.contains(knownID) {
                        if !photo.isOnTV {
                            var p = photo
                            p.isOnTV = true
                            appState.updatePhotoInPlace(p, in: collection)
                        }
                        // Update SyncStore record with source tracking
                        if syncStore.records[photo.filename] == nil {
                            syncStore.recordUpload(filename: photo.filename, tvContentID: knownID, matte: photo.matte)
                        }
                        matched += 1
                    } else {
                        if photo.isOnTV {
                            var p = photo
                            p.isOnTV = false
                            p.tvContentID = nil
                            appState.updatePhotoInPlace(p, in: collection)
                            syncStore.recordDeletion(filename: photo.filename)
                        }
                    }
                } else if let syncRecord = syncStore.records[photo.filename] {
                    if tvContentIDs.contains(syncRecord.tvContentID) {
                        var p = photo
                        p.tvContentID = syncRecord.tvContentID
                        p.isOnTV = true
                        appState.updatePhotoInPlace(p, in: collection)
                        matched += 1
                    } else {
                        syncStore.recordDeletion(filename: photo.filename)
                    }
                }
            }

            matchedCount = matched

            // Find TV-only items (not matched to any local file)
            let knownContentIDs = Set(allPhotos.compactMap { $0.tvContentID })
            let syncContentIDs = Set(syncStore.records.values.map { $0.tvContentID })
            let allKnown = knownContentIDs.union(syncContentIDs)
            let unmatchedIDs = Array(tvContentIDs.subtracting(allKnown))
            unmatchedCount = unmatchedIDs.count

            // Download thumbnails for unmatched items — ONE batch request
            if !unmatchedIDs.isEmpty && !isCancelled {
                statusMessage = "Downloading \(unmatchedIDs.count) thumbnail(s)..."

                var thumbnailsByID: [String: Data] = [:]
                do {
                    thumbnailsByID = try await tvManager.getThumbnails(contentIDs: unmatchedIDs)
                    downloadedCount = thumbnailsByID.count
                } catch {
                    print("⚠️ Batch thumbnail download failed: \(error.localizedDescription)")
                }

                // Build TVOnlyItem array from typed TVArtItem results
                var tvOnlyItems: [TVOnlyItem] = []
                for contentID in unmatchedIDs {
                    let tvData = tvItemByID[contentID]
                    let matteStr = tvData?.matteID
                    let matte = matteStr.flatMap { Matte.parse($0) }

                    tvOnlyItems.append(TVOnlyItem(
                        id: contentID,
                        matte: matte,
                        isBuiltIn: TVOnlyItem.isBuiltInID(contentID),
                        thumbnailData: thumbnailsByID[contentID],
                        width: tvData?.width,
                        height: tvData?.height
                    ))
                }

                // Write to SyncStore (persisted per-TV)
                syncStore.setTVOnlyItems(tvOnlyItems)
                appState.tvOnlyItems = tvOnlyItems
            } else {
                syncStore.setTVOnlyItems([])
                appState.tvOnlyItems = []
            }

            // Mark full sync complete
            syncStore.markFullSync()

            statusMessage = "Scan complete"
            print("📺 TV Scan: \(tvPhotoCount) on TV, \(matched) matched, \(unmatchedIDs.count) TV-only")

        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Scan failed"
            print("❌ TV Scan failed: \(error.localizedDescription)")
        }

        isComplete = true
    }

    func cancel() {
        isCancelled = true
    }
}

// MARK: - ScanTVModal
struct ScanTVModal: View {
    @ObservedObject var engine: ScanTVEngine
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(engine.isComplete ? "TV Scan Complete" : "Scanning TV")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            VStack(spacing: 16) {
                if engine.isComplete {
                    // Summary
                    if let error = engine.errorMessage {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.red)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.green)

                        VStack(spacing: 6) {
                            HStack {
                                Image(systemName: "tv.fill").foregroundColor(.blue).frame(width: 20)
                                Text("Photos on TV")
                                Spacer()
                                Text("\(engine.tvPhotoCount)").fontWeight(.semibold).monospacedDigit()
                            }
                            .font(.subheadline)

                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).frame(width: 20)
                                Text("Matched to local files")
                                Spacer()
                                Text("\(engine.matchedCount)").fontWeight(.semibold).monospacedDigit()
                            }
                            .font(.subheadline)

                            if engine.unmatchedCount > 0 {
                                HStack {
                                    Image(systemName: "icloud.and.arrow.down").foregroundColor(.orange).frame(width: 20)
                                    Text("TV-only (thumbnails downloaded)")
                                    Spacer()
                                    Text("\(engine.downloadedCount)").fontWeight(.semibold).monospacedDigit()
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    }
                } else {
                    // In progress
                    if engine.unmatchedCount > 0 {
                        // Downloading thumbnails phase — show progress bar
                        VStack(alignment: .leading, spacing: 4) {
                            Text(engine.statusMessage)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("\(engine.downloadedCount) of \(engine.unmatchedCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        ProgressView(value: engine.downloadProgress)
                            .progressViewStyle(.linear)
                    } else {
                        // Querying / matching phase — spinner
                        ProgressView()
                            .scaleEffect(1.2)
                        Text(engine.statusMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(24)

            Divider()

            // Footer
            HStack {
                if !engine.isComplete {
                    Button("Cancel") { engine.cancel() }
                        .foregroundColor(.red)
                }
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!engine.isComplete)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 380)
    }
}
