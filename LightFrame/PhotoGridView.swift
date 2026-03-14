import SwiftUI

// MARK: - PhotoGridView
// The center column — a scrollable grid of photo thumbnails.
// Every cell is forced to 16:9 aspect ratio.
// Photos without a matte show aspect-fit on black background.
struct PhotoGridView: View {
    @EnvironmentObject var appState: AppState

    var columns: [GridItem] {
        [GridItem(.adaptive(
            minimum: appState.thumbnailSize,
            maximum: appState.thumbnailSize + 20
        ))]
    }

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Tab Bar
            // Uses an underline indicator instead of a background highlight
            // to avoid the blue box appearance
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

                            // Active tab indicator — thin line, not a box
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
                UploadControlsView()
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

                if appState.isUploading {
                    UploadProgressView()
                }

                // MARK: Bottom Status Bar + Thumbnail Slider
                // The divider above this bar pulses when scanning — no extra UI needed,
                // just a subtle animation on the existing separator line.
                VStack(spacing: 0) {

                    // Pulsing divider — replaces the static Divider() when scanning.
                    // We animate the opacity to create a gentle breathing effect.
                    // This is less intrusive than a full progress bar but still communicates activity.
                    if appState.isScanning {
                        // A colored rectangle that fades in and out repeatedly
                        // using SwiftUI's .repeatForever animation
                        PulsingDivider()
                    } else {
                        // When not scanning, just show a normal static divider line
                        Divider()
                    }

                    HStack {
                        // Status text — e.g. "273 photos · 12 on TV · 3 selected"
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()

                        // Thumbnail size slider — works like Lightroom's grid size control.
                        // The small photo icon on the left and large on the right hint at direction.
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
    }
    // MARK: - Pulsing Divider
    // A 2pt tall colored line that pulses (fades in and out) to indicate
    // background activity like a folder scan.
    // This replaces the normal Divider() above the status bar during scanning.
    //
    // How the animation works:
    // @State var opacity starts at 1.0
    // .onAppear triggers an animation that changes opacity from 1.0 → 0.3 → 1.0
    // .repeatForever keeps it looping until the view disappears
    // When scanning finishes, this view is replaced by a normal Divider()
    struct PulsingDivider: View {

        // Tracks the current opacity — SwiftUI animates changes to this automatically
        @State private var opacity: Double = 1.0

        var body: some View {
            Rectangle()
                // Accent color (blue) matches the app's action color
                .fill(Color.accentColor)
                // 2pt height — same visual weight as a normal Divider
                .frame(height: 2)
                // Animate the opacity to create the pulsing effect
                .opacity(opacity)
                .onAppear {
                    // withAnimation tells SwiftUI to smoothly transition opacity changes
                    // .easeInOut means it accelerates then decelerates — feels organic
                    // .repeatForever(autoreverses: true) means it goes 1.0→0.3→1.0 forever
                    withAnimation(
                        .easeInOut(duration: 1.0)
                        .repeatForever(autoreverses: true)
                    ) {
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
// A single cell in the photo grid.
// Every cell is strictly 16:9 — this matches the TV's screen ratio
// so thumbnails look exactly like they will on the TV.
//
// We always use MattePreviewView here because it already handles both cases:
// - No matte: photo aspect-fits on black background (expands until hits one edge)
// - Has matte: photo with colored border and bevel
struct PhotoThumbnailView: View {
    @EnvironmentObject var appState: AppState
    let photo: Photo

    // Check if this photo is currently selected in the grid
    var isSelected: Bool { appState.selectedPhotoIDs.contains(photo.id) }

    var body: some View {
        // MattePreviewView handles all rendering — matte or no matte
        MattePreviewView(photo: photo, size: appState.thumbnailSize)
            // Force every cell to exact 16:9 dimensions
            .frame(
                width: appState.thumbnailSize,
                height: appState.thumbnailSize * 9 / 16
            )
            // Blue selection ring when this photo is selected
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            // Slight shrink when selected gives a satisfying tap feel
            .scaleEffect(isSelected ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isSelected)
            // Suppress the default macOS blue focus ring that appears on click
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
struct UploadControlsView: View {
    @EnvironmentObject var appState: AppState

    var isConnected: Bool { appState.selectedTV?.isReachable ?? false }
    var hasSelection: Bool { !appState.selectedPhotoIDs.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Button("Scan") {
                Task { await appState.scanSelectedCollection() }
            }
            .disabled(appState.selectedCollection == nil || appState.isScanning)

            if hasSelection {
                Button("Upload Selected (\(appState.selectedPhotoIDs.count))") {
                    // Wired up in upload engine
                }
                .disabled(!isConnected || appState.isUploading)
            }

            Button("Upload All") {
                // Wired up in upload engine
            }
            .disabled(!isConnected || appState.isUploading || appState.filteredPhotos.isEmpty)
        }
        .buttonStyle(.bordered)
        .opacity(isConnected ? 1.0 : 0.4)
    }
}

// MARK: - Upload Progress View
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
