import SwiftUI

// MARK: - DetailPanel
struct DetailPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let item = appState.lastTappedTVOnlyItem {
                TVOnlyDetailView(item: item)
            } else if let photo = appState.lastTappedPhoto {
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
    @State private var isUpdatingMatte: Bool = false
    @State private var isDisplaying: Bool = false
    @State private var saveMessage: String?

    // Upload modal state for the "Send to TV" button
    @State private var uploadEngine: UploadEngine? = nil

    var hasChanges: Bool {
        editedStyle != (photo.matte?.style ?? .flexible) ||
        editedColor != (photo.matte?.color ?? .warm)
    }

    var isConnected: Bool {
        tvManager.isConnected
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

                    // Update Matte on TV — pushes the matte change without re-uploading
                    if photo.isOnTV && hasChanges {
                        Button { updateMatteOnTV() } label: {
                            HStack {
                                if isUpdatingMatte { ProgressView().scaleEffect(0.7) }
                                Text(isUpdatingMatte ? "Updating..." : "Update Matte on TV")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!isConnected || isUpdatingMatte)
                    }

                    // Display on TV — sets this photo as the currently displayed artwork
                    if photo.isOnTV {
                        Button { displayOnTV() } label: {
                            HStack {
                                if isDisplaying { ProgressView().scaleEffect(0.7) }
                                Text(isDisplaying ? "Setting..." : "Display on TV")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!isConnected || isDisplaying)
                    }

                    // Send to TV — uploads this single photo via the upload modal
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
        tvManager.isConnected,
        let tv = appState.selectedTV
        else { return }

        let syncStore = SyncStoreManager.shared.store(for: tv)
        let engine = UploadEngine(
            tvManager: tvManager,
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
        guard tvManager.isConnected,
              let contentID = photo.tvContentID,
              let collection = appState.collections.first(where: { col in
                  col.photos.contains(where: { $0.id == photo.id })
              }),
              let tv = appState.selectedTV
        else { return }

        Task {
            do {
                try await tvManager.deletePhotos(contentIDs: [contentID])

                let syncStore = SyncStoreManager.shared.store(for: tv)
                syncStore.recordDeletion(filename: photo.filename)

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

    // MARK: - Update Matte on TV
    private func updateMatteOnTV() {
        guard tvManager.isConnected,
              let contentID = photo.tvContentID
        else { return }

        isUpdatingMatte = true
        let newMatte = Matte(style: editedStyle, color: editedStyle == .none ? nil : editedColor)

        Task {
            do {
                try await tvManager.changeMatte(contentID: contentID, matte: newMatte)
                saveMessage = "✓ Matte updated on TV"
            } catch {
                saveMessage = "Failed: \(error.localizedDescription)"
            }
            isUpdatingMatte = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveMessage = nil
        }
    }

    // MARK: - Display on TV
    private func displayOnTV() {
        guard tvManager.isConnected,
              let contentID = photo.tvContentID
        else { return }

        isDisplaying = true

        Task {
            do {
                try await tvManager.selectPhoto(contentID: contentID)
                saveMessage = "✓ Now displaying"
            } catch {
                saveMessage = "Failed: \(error.localizedDescription)"
            }
            isDisplaying = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveMessage = nil
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

// MARK: - TV-Only Detail View
// Shows details for a photo that exists only on the TV (no local file).
// Supports Display on TV, Change Matte, and Remove from TV.
struct TVOnlyDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tvManager: TVConnectionManager

    let item: TVOnlyItem

    @State private var editedStyle: MatteStyle = .flexible
    @State private var editedColor: MatteColor = .warm
    @State private var isUpdatingMatte: Bool = false
    @State private var isDisplaying: Bool = false
    @State private var isDeleting: Bool = false
    @State private var statusMessage: String?

    var isConnected: Bool {
        tvManager.isConnected
    }

    var currentMatte: Matte {
        Matte(style: editedStyle, color: editedStyle == .none ? nil : editedColor)
    }

    var hasMatteChanges: Bool {
        editedStyle != (item.matte?.style ?? .flexible) ||
        editedColor != (item.matte?.color ?? .warm)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // MARK: Thumbnail Preview
                if let data = item.thumbnailData, let nsImage = NSImage(data: data) {
                    ZStack {
                        Color.black
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.black.opacity(0.3))
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay(Image(systemName: "tv").font(.largeTitle).foregroundColor(.secondary))
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                }

                // MARK: Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.id)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Image(systemName: "icloud.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("TV only — no local file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let matte = item.matte {
                        Text("Matte: \(matte.displayName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let w = item.width, let h = item.height {
                        Text("\(w) × \(h)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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

                // MARK: Actions
                VStack(spacing: 8) {
                    // Update matte on TV
                    if hasMatteChanges {
                        Button { updateMatteOnTV() } label: {
                            HStack {
                                if isUpdatingMatte { ProgressView().scaleEffect(0.7) }
                                Text(isUpdatingMatte ? "Updating..." : "Update Matte on TV")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isConnected || isUpdatingMatte)
                    }

                    // Display on TV
                    Button { displayOnTV() } label: {
                        HStack {
                            if isDisplaying { ProgressView().scaleEffect(0.7) }
                            Text(isDisplaying ? "Setting..." : "Display on TV")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isConnected || isDisplaying)

                    // Remove from TV
                    Button(role: .destructive) { removeFromTV() } label: {
                        HStack {
                            if isDeleting { ProgressView().scaleEffect(0.7) }
                            Text(isDeleting ? "Removing..." : "Remove from TV")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isConnected || isDeleting)

                    if let msg = statusMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(msg.contains("✓") ? .green : .red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .onAppear { loadMatte() }
        .onChange(of: item.id) { loadMatte() }
    }

    private func loadMatte() {
        editedStyle = item.matte?.style ?? .flexible
        editedColor = item.matte?.color ?? .warm
        statusMessage = nil
    }

    private func updateMatteOnTV() {
        guard tvManager.isConnected else { return }
        isUpdatingMatte = true
        let newMatte = currentMatte

        Task {
            do {
                try await tvManager.changeMatte(contentID: item.id, matte: newMatte)
                if let index = appState.tvOnlyItems.firstIndex(where: { $0.id == item.id }) {
                    appState.tvOnlyItems[index].matte = newMatte
                    appState.lastTappedTVOnlyItem = appState.tvOnlyItems[index]
                }
                statusMessage = "✓ Matte updated"
            } catch {
                statusMessage = "Failed: \(error.localizedDescription)"
            }
            isUpdatingMatte = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            statusMessage = nil
        }
    }

    private func displayOnTV() {
        guard tvManager.isConnected else { return }
        isDisplaying = true

        Task {
            do {
                try await tvManager.selectPhoto(contentID: item.id)
                statusMessage = "✓ Now displaying"
            } catch {
                statusMessage = "Failed: \(error.localizedDescription)"
            }
            isDisplaying = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            statusMessage = nil
        }
    }

    private func removeFromTV() {
        guard tvManager.isConnected else { return }
        isDeleting = true

        Task {
            do {
                try await tvManager.deletePhotos(contentIDs: [item.id])
                appState.tvOnlyItems.removeAll { $0.id == item.id }
                appState.lastTappedTVOnlyItem = nil
                statusMessage = "✓ Removed"
            } catch {
                let msg = error.localizedDescription
                if msg.contains("-10") {
                    appState.tvOnlyItems.removeAll { $0.id == item.id }
                    appState.lastTappedTVOnlyItem = nil
                } else {
                    statusMessage = "Failed: \(msg)"
                }
            }
            isDeleting = false
        }
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
