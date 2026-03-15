import SwiftUI

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

    var columns: [GridItem] {
        [GridItem(.adaptive(
            minimum: appState.thumbnailSize,
            maximum: appState.thumbnailSize + 20
        ))]
    }

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Tab Bar
            HStack(spacing: 0) {
                ForEach(GridFilter.allCases, id: \.self) { filter in
                    Button {
                        appState.gridFilter = filter
                        appState.clearSelection()
                    } label: {
                        VStack(spacing: 0) {
                            Text(filter.displayName)
                                .font(.subheadline)
                                .foregroundColor(
                                    appState.gridFilter == filter ? .primary : .secondary
                                )
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)

                            Rectangle()
                                .fill(appState.gridFilter == filter
                                      ? Color.accentColor
                                      : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                UploadControlsView(
                    onUploadSelected: startUploadSelected,
                    onUploadAll: startUploadAll
                )
                .padding(.trailing, 12)
            }
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // MARK: Empty State
            if appState.filteredPhotos.isEmpty && !appState.isScanning {
                EmptyGridView()
            } else {
                // MARK: Photo Grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(appState.filteredPhotos) { photo in
                            PhotoThumbnailView(photo: photo)
                                .onTapGesture { handleTap(photo: photo) }
                        }
                    }
                    .padding(16)
                }

                // MARK: Bottom Status Bar + Thumbnail Slider
                VStack(spacing: 0) {
                    if appState.isScanning {
                        PulsingDivider()
                    } else {
                        Divider()
                    }

                    HStack {
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "photo")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Slider(value: $appState.thumbnailSize, in: 80...280)
                                .frame(width: 100)
                            Image(systemName: "photo")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.windowBackgroundColor))
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
    }

    // MARK: - Start Upload: Selected Photos
    private func startUploadSelected() {
        guard let collection = appState.selectedCollection,
              let conn = tvManager.connection,
              conn.state == .connected
        else { return }

        // Only upload photos not already on the TV
        // Photos that ARE on the TV will still appear in the queue —
        // they'll trigger the duplicate prompt when reached
        let photosToUpload = appState.selectedPhotos

        guard !photosToUpload.isEmpty else { return }

        beginUpload(photos: photosToUpload, collection: collection, connection: conn)
    }

    // MARK: - Start Upload: All Photos
    private func startUploadAll() {
        guard let collection = appState.selectedCollection,
              let conn = tvManager.connection,
              conn.state == .connected
        else { return }

        // "Upload All" only queues photos not yet on the TV.
        // Photos already there are excluded entirely — no duplicate prompt.
        let photosToUpload = appState.filteredPhotos.filter { !$0.isOnTV }

        guard !photosToUpload.isEmpty else { return }

        beginUpload(photos: photosToUpload, collection: collection, connection: conn)
    }

    // MARK: - Begin Upload Session
    private func beginUpload(photos: [Photo], collection: Collection, connection: TVConnection) {
        guard let tv = appState.selectedTV else { return }

        let syncStore = SyncStoreManager.shared.store(for: tv)
        let engine = UploadEngine(
            connection: connection,
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

    var statusText: String {
        let total = appState.filteredPhotos.count
        let onTV = appState.filteredPhotos.filter { $0.isOnTV }.count
        let selected = appState.selectedPhotoIDs.count
        var parts = ["\(total) photo\(total == 1 ? "" : "s")"]
        if onTV > 0 { parts.append("\(onTV) on TV") }
        if selected > 0 { parts.append("\(selected) selected") }
        return parts.joined(separator: " · ")
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
}

// MARK: - Photo Thumbnail
struct PhotoThumbnailView: View {
    @EnvironmentObject var appState: AppState
    let photo: Photo

    var isSelected: Bool { appState.selectedPhotoIDs.contains(photo.id) }

    var body: some View {
        MattePreviewView(photo: photo, size: appState.thumbnailSize)
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

// MARK: - Empty Grid View
struct EmptyGridView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Upload Controls
// The Scan / Upload buttons in the grid toolbar.
// Now takes explicit action closures rather than embedding upload logic here.
struct UploadControlsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tvManager: TVConnectionManager

    let onUploadSelected: () -> Void
    let onUploadAll: () -> Void

    var isConnected: Bool {
        tvManager.connection?.state == .connected
    }

    var hasSelection: Bool { !appState.selectedPhotoIDs.isEmpty }

    // Count of photos not yet on the TV (what "Upload All" will act on)
    var notOnTVCount: Int {
        appState.filteredPhotos.filter { !$0.isOnTV }.count
    }

    var body: some View {
        HStack(spacing: 8) {
            Button("Scan") {
                Task { await appState.scanSelectedCollection() }
            }
            .disabled(appState.selectedCollection == nil || appState.isScanning)

            // "Upload Selected" only shows when photos are selected
            if hasSelection {
                Button("Upload Selected (\(appState.selectedPhotoIDs.count))") {
                    onUploadSelected()
                }
                .disabled(!isConnected)
            }

            // "Upload All" shows the count of photos not yet on the TV
            if notOnTVCount > 0 {
                Button("Upload All (\(notOnTVCount))") {
                    onUploadAll()
                }
                .disabled(!isConnected)
            }
        }
        .buttonStyle(.bordered)
        .opacity(isConnected ? 1.0 : 0.4)
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
