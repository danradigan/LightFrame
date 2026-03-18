import SwiftUI

// MARK: - Timestamped Matte Logger
// Produces "[Matte HH:mm:ss.SSS] ..." lines so Dan and Claude can correlate events.
private let matteTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

private func matteLog(_ message: String) {
    let ts = matteTimestampFormatter.string(from: Date())
    print("[Matte \(ts)] \(message)")
}

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
    @State private var isApplying: Bool = false
    @State private var saveMessage: String?
    @State private var matteError: String?

    // Upload modal state for the "Send to TV" button
    @State private var uploadEngine: UploadEngine? = nil

    var hasChanges: Bool {
        editedStyle != (photo.matte?.style ?? AppSettings.defaultMatteStyle) ||
        editedColor != (photo.matte?.color ?? AppSettings.defaultMatteColor)
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

                // MARK: Matte Picker
                MattePickerView(selectedStyle: $editedStyle, selectedColor: $editedColor)

                Divider()

                // MARK: Action Buttons
                VStack(spacing: 8) {

                    // Display on TV — updates matte if changed, then displays
                    if photo.isOnTV {
                        Button { applyAndDisplay() } label: {
                            HStack {
                                if isApplying { ProgressView().scaleEffect(0.7) }
                                Text(isApplying ? "Applying..." : (hasChanges ? "Update & Display on TV" : "Display on TV"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isConnected || isApplying)
                    }

                    // Save Matte — writes the matte choice into the file's EXIF only
                    Button { saveMatte() } label: {
                        HStack {
                            if isSaving { ProgressView().scaleEffect(0.7) }
                            Text(isSaving ? "Saving..." : "Save Matte to File")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasChanges || isSaving || !photo.isJPEG)

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

                    // Matte error banner — shown when the TV rejects a matte change
                    if let error = matteError {
                        MatteErrorBanner(message: error) {
                            matteError = nil
                        }
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
        matteLog("🔘 BUTTON: sendToTV clicked — photo=\(photo.filename), matte=\(photo.matte?.apiToken ?? "nil")")
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
        matteLog("🔘 BUTTON: removeFromTV clicked — photo=\(photo.filename), contentID=\(photo.tvContentID ?? "nil")")
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

    // MARK: - Apply & Display on TV
    // Compares the picker state against what the TV last confirmed.
    // Sends change_matte only when needed, then select_image to display.
    // EXIF and model are updated only after the TV confirms the change.
    private func applyAndDisplay() {
        guard tvManager.isConnected,
              let contentID = photo.tvContentID
        else { return }

        isApplying = true
        matteError = nil
        let previousMatte = photo.matte
        let newMatte = Matte(style: editedStyle, color: editedStyle == .none ? nil : editedColor)
        let matteChanged = newMatte != previousMatte

        matteLog("🔘 BUTTON: applyAndDisplay clicked")
        matteLog("  photo: \(photo.filename), contentID=\(contentID), dims=\(photo.width ?? 0)×\(photo.height ?? 0)")
        matteLog("  TV state: connected=\(tvManager.isConnected), tv=\(appState.selectedTV?.name ?? "nil") @ \(appState.selectedTV?.ipAddress ?? "nil")")
        matteLog("  current matte (model): \(previousMatte?.apiToken ?? "nil")")
        matteLog("  picker state: style=\(editedStyle.rawValue), color=\(editedColor.rawValue)")
        matteLog("  new matte (to send): \(newMatte.apiToken), matteChanged=\(matteChanged)")

        Task {
            // Step 1: Always send change_matte to ensure TV matches our intended matte.
            // The TV's own matte state may differ from our EXIF (changed via remote, etc.)
            if newMatte.style != .none {
                do {
                    matteLog("Sending change_matte: contentID=\(contentID), matteID=\(newMatte.apiToken)")
                    try await tvManager.changeMatte(contentID: contentID, matte: newMatte)
                    matteLog("change_matte succeeded — waiting for TV to render")
                    // Give the TV time to finish rendering the new matte before select_image
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    matteLog("change_matte FAILED: \(error.localizedDescription)")
                    // Revert UI to the previously confirmed matte
                    editedStyle = previousMatte?.style ?? AppSettings.defaultMatteStyle
                    editedColor = previousMatte?.color ?? AppSettings.defaultMatteColor
                    matteError = "Matte could not be applied — your TV didn't accept this style for this image"
                    isApplying = false

                    // Auto-dismiss error after 5 seconds
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    matteError = nil
                    return
                }
            } else {
                // For "none", also send change_matte (no portrait_matte_id)
                do {
                    matteLog("Sending change_matte: contentID=\(contentID), matteID=none")
                    try await tvManager.changeMatte(contentID: contentID, matte: newMatte)
                    matteLog("change_matte to none succeeded")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    matteLog("change_matte to none FAILED: \(error.localizedDescription)")
                    // Revert UI to the previously confirmed matte
                    editedStyle = previousMatte?.style ?? AppSettings.defaultMatteStyle
                    editedColor = previousMatte?.color ?? AppSettings.defaultMatteColor
                    matteError = "Matte could not be applied — your TV didn't accept this style for this image"
                    isApplying = false

                    // Auto-dismiss error after 5 seconds
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    matteError = nil
                    return
                }
            }

            // Step 2: Save confirmed matte to EXIF and update model (only if changed)
            if matteChanged {
                if photo.isJPEG {
                    matteLog("Writing EXIF matte: \(newMatte.apiToken)")
                    let photoURL = photo.url
                    let currentPhoto = photo
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            guard let collection = DispatchQueue.main.sync(execute: {
                                appState.collections.first { col in
                                    col.photos.contains { $0.id == currentPhoto.id }
                                }
                            }) else {
                                continuation.resume()
                                return
                            }

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
                            let accessGranted = resolved.startAccessingSecurityScopedResource()
                            defer { if accessGranted { resolved.stopAccessingSecurityScopedResource() } }
                            EXIFManager.writeMatte(newMatte, to: photoURL)
                            continuation.resume()
                        }
                    }
                }
                appState.updateMatte(newMatte, for: photo, newData: nil)
                matteLog("In-memory model updated to: \(newMatte.apiToken)")
            }

            // Step 3: Display on TV
            do {
                matteLog("Sending select_image: contentID=\(contentID)")
                try await tvManager.selectPhoto(contentID: contentID)
                saveMessage = "✓ Now displaying"
                matteLog("select_image succeeded")
            } catch {
                saveMessage = "Failed: \(error.localizedDescription)"
                matteLog("select_image FAILED: \(error.localizedDescription)")
            }
            isApplying = false
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
        let style = photo.matte?.style ?? AppSettings.defaultMatteStyle
        let color = photo.matte?.color ?? AppSettings.defaultMatteColor
        matteLog("📋 loadCurrentMatte: photo=\(photo.filename), contentID=\(photo.tvContentID ?? "nil"), isOnTV=\(photo.isOnTV)")
        matteLog("  photo.matte=\(photo.matte?.apiToken ?? "nil") → editedStyle=\(style.rawValue), editedColor=\(color.rawValue)")
        editedStyle = style
        editedColor = color
        saveMessage = nil
    }

    // MARK: - Save Matte
    private func saveMatte() {
        guard photo.isJPEG else { return }
        matteLog("🔘 BUTTON: saveMatte clicked — style=\(editedStyle.rawValue), color=\(editedColor.rawValue), photo=\(photo.filename)")
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

// MARK: - TV-Only Detail View
// Shows details for a photo that exists only on the TV (no local file).
// Supports Display on TV, Change Matte, and Remove from TV.
struct TVOnlyDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tvManager: TVConnectionManager

    let item: TVOnlyItem

    @State private var editedStyle: MatteStyle = .flexible
    @State private var editedColor: MatteColor = .warm
    @State private var isApplying: Bool = false
    @State private var isDeleting: Bool = false
    @State private var statusMessage: String?
    @State private var matteError: String?

    var isConnected: Bool {
        tvManager.isConnected
    }

    var currentMatte: Matte {
        Matte(style: editedStyle, color: editedStyle == .none ? nil : editedColor)
    }

    var hasMatteChanges: Bool {
        editedStyle != (item.matte?.style ?? AppSettings.defaultMatteStyle) ||
        editedColor != (item.matte?.color ?? AppSettings.defaultMatteColor)
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

                // MARK: Matte Picker
                MattePickerView(selectedStyle: $editedStyle, selectedColor: $editedColor)

                Divider()

                // MARK: Actions
                VStack(spacing: 8) {
                    // Display on TV — updates matte if changed, then displays
                    Button { applyAndDisplay() } label: {
                        HStack {
                            if isApplying { ProgressView().scaleEffect(0.7) }
                            Text(isApplying ? "Applying..." : (hasMatteChanges ? "Update & Display on TV" : "Display on TV"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConnected || isApplying)

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

                    // Matte error banner — shown when the TV rejects a matte change
                    if let error = matteError {
                        MatteErrorBanner(message: error) {
                            matteError = nil
                        }
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
        editedStyle = item.matte?.style ?? AppSettings.defaultMatteStyle
        editedColor = item.matte?.color ?? AppSettings.defaultMatteColor
        matteLog("📋 TVOnly loadMatte: item=\(item.id), dims=\(item.width ?? 0)×\(item.height ?? 0), builtIn=\(item.isBuiltIn)")
        matteLog("  item.matte=\(item.matte?.apiToken ?? "nil") → editedStyle=\(editedStyle.rawValue), editedColor=\(editedColor.rawValue)")
        statusMessage = nil
        matteError = nil
    }

    // Apply matte changes (if any) then display on TV.
    // On matte failure, reverts the UI and shows an error banner.
    private func applyAndDisplay() {
        guard tvManager.isConnected else { return }
        isApplying = true
        matteError = nil
        let previousMatte = item.matte
        let newMatte = currentMatte
        let matteChanged = newMatte != previousMatte

        matteLog("🔘 BUTTON: TVOnly applyAndDisplay clicked")
        matteLog("  item: \(item.id), dims=\(item.width ?? 0)×\(item.height ?? 0), builtIn=\(item.isBuiltIn)")
        matteLog("  TV state: connected=\(tvManager.isConnected), tv=\(appState.selectedTV?.name ?? "nil") @ \(appState.selectedTV?.ipAddress ?? "nil")")
        matteLog("  current matte (model): \(previousMatte?.apiToken ?? "nil")")
        matteLog("  picker state: style=\(editedStyle.rawValue), color=\(editedColor.rawValue)")
        matteLog("  new matte (to send): \(newMatte.apiToken), matteChanged=\(matteChanged)")

        Task {
            // Step 1: Always send change_matte to ensure TV matches our intended matte.
            if newMatte.style != .none {
                do {
                    matteLog("TVOnly Sending change_matte: contentID=\(item.id), matteID=\(newMatte.apiToken)")
                    try await tvManager.changeMatte(contentID: item.id, matte: newMatte)
                    matteLog("TVOnly change_matte succeeded — waiting for TV to render")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    matteLog("TVOnly change_matte FAILED: \(error.localizedDescription)")
                    // Revert UI to the previously confirmed matte
                    editedStyle = previousMatte?.style ?? AppSettings.defaultMatteStyle
                    editedColor = previousMatte?.color ?? AppSettings.defaultMatteColor
                    matteError = "Matte could not be applied — your TV didn't accept this style for this image"
                    isApplying = false

                    // Auto-dismiss error after 5 seconds
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    matteError = nil
                    return
                }
            } else {
                do {
                    matteLog("TVOnly Sending change_matte: contentID=\(item.id), matteID=none")
                    try await tvManager.changeMatte(contentID: item.id, matte: newMatte)
                    matteLog("TVOnly change_matte to none succeeded")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    matteLog("TVOnly change_matte to none FAILED: \(error.localizedDescription)")
                    // Revert UI to the previously confirmed matte
                    editedStyle = previousMatte?.style ?? AppSettings.defaultMatteStyle
                    editedColor = previousMatte?.color ?? AppSettings.defaultMatteColor
                    matteError = "Matte could not be applied — your TV didn't accept this style for this image"
                    isApplying = false

                    // Auto-dismiss error after 5 seconds
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    matteError = nil
                    return
                }
            }

            // Step 2: Update in-memory model (only if changed)
            if matteChanged {
                if let index = appState.tvOnlyItems.firstIndex(where: { $0.id == item.id }) {
                    appState.tvOnlyItems[index].matte = newMatte
                    appState.lastTappedTVOnlyItem = appState.tvOnlyItems[index]
                }
                matteLog("TVOnly In-memory model updated to: \(newMatte.apiToken)")
            }

            // Step 3: Display on TV
            do {
                matteLog("TVOnly Sending select_image: contentID=\(item.id)")
                try await tvManager.selectPhoto(contentID: item.id)
                statusMessage = "✓ Now displaying"
                matteLog("TVOnly select_image succeeded")
            } catch {
                statusMessage = "Failed: \(error.localizedDescription)"
                matteLog("TVOnly select_image FAILED: \(error.localizedDescription)")
            }
            isApplying = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            statusMessage = nil
        }
    }

    private func removeFromTV() {
        matteLog("🔘 BUTTON: TVOnly removeFromTV clicked — item=\(item.id)")
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
