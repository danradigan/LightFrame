import SwiftUI

// MARK: - DetailPanel
struct DetailPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let photo = appState.lastTappedPhoto {
                PhotoDetailView(photo: photo)
            } else {
                EmptyDetailView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Photo Detail View
struct PhotoDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tvManager: TVConnectionManager

    let photo: Photo

    @State private var editedStyle: MatteStyle = .flexible
    @State private var editedColor: MatteColor = .warm
    @State private var isSaving: Bool = false
    @State private var saveMessage: String?

    // Upload modal state for the "Send to TV" button
    @State private var uploadEngine: UploadEngine? = nil

    var hasChanges: Bool {
        editedStyle != (photo.matte?.style ?? .flexible) ||
        editedColor != (photo.matte?.color ?? .warm)
    }

    var isConnected: Bool {
        tvManager.connection?.state == .connected
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // MARK: Large Matte Preview
                GeometryReader { geometry in
                    MattePreviewView(
                        photo: photoWithEdits,
                        size: geometry.size.width - 32
                    )
                    .frame(maxWidth: .infinity)
                }
                .aspectRatio(16/9, contentMode: .fit)
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // MARK: Photo Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(photo.filename)
                        .font(.headline)
                        .lineLimit(2)
                    Label(
                        photo.isOnTV ? "On TV" : "Not on TV",
                        systemImage: photo.isOnTV ? "tv.fill" : "tv"
                    )
                    .font(.caption)
                    .foregroundColor(photo.isOnTV ? .green : .secondary)
                }
                .padding(.horizontal, 16)

                Divider()

                // MARK: Matte Style Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Style")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        ForEach(MatteStyle.allCases, id: \.self) { style in
                            StyleButton(style: style, isSelected: editedStyle == style) {
                                editedStyle = style
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // MARK: Matte Color Picker
                if editedStyle != .none {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible()), count: 4),
                            spacing: 8
                        ) {
                            ForEach(MatteColor.allCases, id: \.self) { color in
                                ColorSwatchButton(color: color, isSelected: editedColor == color) {
                                    editedColor = color
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                Divider()

                // MARK: Action Buttons
                VStack(spacing: 8) {

                    // Save Matte — writes the matte choice into the file's EXIF
                    Button { saveMatte() } label: {
                        HStack {
                            if isSaving { ProgressView().scaleEffect(0.7) }
                            Text(isSaving ? "Saving..." : "Save Matte")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || isSaving || !photo.isJPEG)

                    // Send to TV — uploads this single photo via the upload modal
                    // Shows "Re-send to TV" if already uploaded, which will
                    // trigger the duplicate prompt inside the modal
                    Button { sendToTV() } label: {
                        Text(photo.isOnTV ? "Re-send to TV" : "Send to TV")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isConnected)

                    // Remove from TV — deletes the photo from the TV's art library
                    if photo.isOnTV {
                        Button(role: .destructive) { removeFromTV() } label: {
                            Text("Remove from TV").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!isConnected)
                    }

                    if let message = saveMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(message.contains("✓") ? .green : .red)
                    }

                    if !photo.isJPEG {
                        Text("Matte can only be saved to JPEG files")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .onAppear { loadCurrentMatte() }
        .onChange(of: photo.id) { loadCurrentMatte() }
        // Upload modal for "Send to TV"
        .sheet(item: $uploadEngine) { engine in
            UploadModal(engine: engine) {
                uploadEngine = nil
            }
        }
    }

    // MARK: - Send to TV
    private func sendToTV() {
        guard let collection = appState.collections.first(where: { col in
            col.photos.contains(where: { $0.id == photo.id })
        }),
        let conn = tvManager.connection,
        conn.state == .connected,
        let tv = appState.selectedTV
        else { return }

        let syncStore = SyncStoreManager.shared.store(for: tv)
        let engine = UploadEngine(
            connection: conn,
            appState: appState,
            syncStore: syncStore
        )
        uploadEngine = engine

        Task {
            await engine.start(photos: [photo], collection: collection)
        }
    }

    // MARK: - Remove from TV
    // Deletes the photo from the TV and clears its content ID in AppState and SyncStore.
    private func removeFromTV() {
        guard let conn = tvManager.connection,
              conn.state == .connected,
              let contentID = photo.tvContentID,
              let collection = appState.collections.first(where: { col in
                  col.photos.contains(where: { $0.id == photo.id })
              }),
              let tv = appState.selectedTV
        else { return }

        Task {
            do {
                try await conn.deletePhotos(contentIDs: [contentID])

                // Clear the content ID in SyncStore
                let syncStore = SyncStoreManager.shared.store(for: tv)
                syncStore.recordDeletion(filename: photo.filename)

                // Clear isOnTV in AppState so the grid dot updates immediately
                var updated = photo
                updated.isOnTV = false
                updated.tvContentID = nil
                appState.updatePhotoInPlace(updated, in: collection)

                saveMessage = "✓ Removed from TV"
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                saveMessage = nil

            } catch {
                saveMessage = "Failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Computed
    var photoWithEdits: Photo {
        var copy = photo
        copy.matte = Matte(style: editedStyle, color: editedStyle == .none ? nil : editedColor)
        return copy
    }

    private func loadCurrentMatte() {
        editedStyle = photo.matte?.style ?? AppSettings.defaultMatteStyle
        editedColor = photo.matte?.color ?? AppSettings.defaultMatteColor
        saveMessage = nil
    }

    // MARK: - Save Matte (unchanged)
    private func saveMatte() {
        guard photo.isJPEG else { return }
        isSaving = true
        let newMatte = Matte(style: editedStyle, color: editedStyle == .none ? nil : editedColor)
        let photoURL = photo.url
        let currentPhoto = photo

        Task {
            let result: (Bool, Data?) = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var folderURL: URL? = nil
                    var accessGranted = false

                    DispatchQueue.main.sync {
                        guard let collection = appState.collections.first(where: { col in
                            col.photos.contains(where: { $0.id == currentPhoto.id })
                        }) else { return }

                        var resolved = collection.folderURL
                        if let bookmarkData = collection.bookmarkData {
                            var isStale = false
                            if let url = try? URL(
                                resolvingBookmarkData: bookmarkData,
                                options: .withSecurityScope,
                                relativeTo: nil,
                                bookmarkDataIsStale: &isStale
                            ) { resolved = url }
                        }

                        accessGranted = resolved.startAccessingSecurityScopedResource()
                        folderURL = resolved
                    }

                    defer {
                        if accessGranted, let url = folderURL {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    guard EXIFManager.writeMatte(newMatte, to: photoURL) else {
                        continuation.resume(returning: (false, nil))
                        return
                    }

                    let updatedData = try? Data(contentsOf: photoURL)
                    continuation.resume(returning: (true, updatedData))
                }
            }

            let (writeSuccess, updatedData) = result
            isSaving = false
            saveMessage = writeSuccess ? "✓ Saved" : "Failed to save"

            if writeSuccess {
                appState.updateMatte(newMatte, for: currentPhoto, newData: updatedData)
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveMessage = nil
        }
    }
}

// MARK: - Style Button
struct StyleButton: View {
    let style: MatteStyle
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Text(style.displayName)
            .font(.caption)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color(NSColor.controlBackgroundColor))
            .foregroundColor(isSelected ? .accentColor : .primary)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
            .onTapGesture { onTap() }
    }
}

// MARK: - Color Swatch Button
struct ColorSwatchButton: View {
    let color: MatteColor
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            Circle()
                .fill(color.previewColor)
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .stroke(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.2),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                )
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            Text(color.displayName)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .onTapGesture { onTap() }
    }
}

// MARK: - Empty Detail View
struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("Select a photo")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preferences View
struct PreferencesView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("defaultMatteStyle") private var defaultStyle: String = MatteStyle.flexible.rawValue
    @AppStorage("defaultMatteColor") private var defaultColor: String = MatteColor.warm.rawValue
    @AppStorage("defaultInterval") private var defaultInterval: Int = SlideshowInterval.fifteenMinutes.rawValue
    @AppStorage("defaultOrder") private var defaultOrder: String = SlideshowOrder.random.rawValue

    var body: some View {
        Form {
            Section("Default Matte") {
                Picker("Style", selection: $defaultStyle) {
                    ForEach(MatteStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                Picker("Color", selection: $defaultColor) {
                    ForEach(MatteColor.allCases, id: \.rawValue) { color in
                        Text(color.displayName).tag(color.rawValue)
                    }
                }
            }

            Section("Default Slideshow") {
                Picker("Order", selection: $defaultOrder) {
                    ForEach(SlideshowOrder.allCases, id: \.rawValue) { order in
                        Text(order.displayName).tag(order.rawValue)
                    }
                }
                Picker("Interval", selection: $defaultInterval) {
                    ForEach(SlideshowInterval.allCases, id: \.rawValue) { interval in
                        Text(interval.displayName).tag(interval.rawValue)
                    }
                }
            }

            Section("TVs") {
                ForEach(appState.tvs) { tv in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(tv.name)
                            Text(tv.ipAddress)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Remove") { appState.removeTV(tv) }
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 500)
        .padding()
    }
}
