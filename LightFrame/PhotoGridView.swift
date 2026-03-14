//
//  PhotoGridView.swift
//  LightFrame
//
//  Created by Dan Radigan on 3/14/26.
//


import SwiftUI

// MARK: - PhotoGridView
// The center column — a scrollable grid of photo thumbnails,
// each rendered with its matte preview.
struct PhotoGridView: View {
    @EnvironmentObject var appState: AppState

    // Grid columns are adaptive — they resize based on the thumbnail slider
    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: appState.thumbnailSize, maximum: appState.thumbnailSize + 20))]
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Tab Bar
            // Filters photos to All / On TV / Not on TV
            HStack(spacing: 0) {
                ForEach(GridFilter.allCases, id: \.self) { filter in
                    Button {
                        appState.gridFilter = filter
                        appState.clearSelection()
                    } label: {
                        Text(filter.displayName)
                            .font(.subheadline)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .background(
                        appState.gridFilter == filter
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .foregroundColor(
                        appState.gridFilter == filter ? .accentColor : .secondary
                    )
                }
                Spacer()

                // Upload controls — greyed out when TV is offline
                UploadControlsView()
                    .padding(.trailing, 12)
            }
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // MARK: Empty State
            if appState.filteredPhotos.isEmpty {
                EmptyGridView()
            } else {
                // MARK: Photo Grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(appState.filteredPhotos) { photo in
                            PhotoThumbnailView(photo: photo)
                                .onTapGesture(count: 1) {
                                    handleTap(photo: photo)
                                }
                        }
                    }
                    .padding(16)
                }

                // MARK: Upload Progress Bar
                if appState.isUploading {
                    UploadProgressView()
                }

                // MARK: Bottom Status Bar + Thumbnail Slider
                HStack {
                    // Status text
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    // Thumbnail size slider — works like Lightroom's
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

    // Status bar text, e.g. "47 photos · 12 on TV · 3 selected"
    var statusText: String {
        let total = appState.filteredPhotos.count
        let onTV = appState.filteredPhotos.filter { $0.isOnTV }.count
        let selected = appState.selectedPhotoIDs.count

        var parts = ["\(total) photo\(total == 1 ? "" : "s")"]
        if onTV > 0 { parts.append("\(onTV) on TV") }
        if selected > 0 { parts.append("\(selected) selected") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tap Handling
    // Supports single click, Cmd+click, and Shift+click
    private func handleTap(photo: Photo) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []

        if modifiers.contains(.command) {
            // Cmd+click — toggle this photo in/out of selection
            appState.togglePhotoSelection(photo)
        } else if modifiers.contains(.shift) {
            // Shift+click — select range from last tapped to this one
            appState.selectRange(to: photo, in: appState.filteredPhotos)
        } else {
            // Plain click — select only this photo
            appState.selectPhoto(photo)
        }
    }
}

// MARK: - Photo Thumbnail
// A single cell in the grid — shows the photo inside its matte border
struct PhotoThumbnailView: View {
    @EnvironmentObject var appState: AppState
    let photo: Photo

    var isSelected: Bool { appState.selectedPhotoIDs.contains(photo.id) }

    var body: some View {
        MattePreviewView(
            photo: photo,
            size: appState.thumbnailSize
        )
        // Selection ring
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        // Slight scale on selection
        .scaleEffect(isSelected ? 0.97 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }
}

// MARK: - Matte Preview
// Renders a photo inside a realistic matte border.
// The bevel effect is achieved by layering inner shadows.
struct MattePreviewView: View {
    let photo: Photo
    let size: CGFloat

    // The matte color — falls back to warm if none set
    var matteColor: Color {
        photo.matte?.color?.previewColor ?? Color(red: 0.93, green: 0.88, blue: 0.78)
    }

    // Whether to show any matte at all
    var showMatte: Bool {
        photo.matte?.style != .none
    }

    // How thick the matte border is relative to thumbnail size
    var matteThickness: CGFloat { size * 0.12 }

    var body: some View {
        ZStack {
            // Outer matte background
            Rectangle()
                .fill(showMatte ? matteColor : Color.black)
                .frame(width: size, height: size * 0.75) // 4:3 aspect ratio preview

            // Photo image
            AsyncImageView(url: photo.url, size: size - (showMatte ? matteThickness * 2 : 0))
                .padding(showMatte ? matteThickness : 0)

            // Inner bevel — top and left edges (highlight)
            if showMatte {
                BevelView(size: size, matteThickness: matteThickness)
            }
        }
        .frame(width: size, height: size * 0.75)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // Dark outer shadow for depth
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Bevel View
// Renders the inner bevel of the matte — the slight highlight and shadow
// along the inner cut edge, like a real physical mat board.
struct BevelView: View {
    let size: CGFloat
    let matteThickness: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Top bevel highlight (light catches the top cut edge)
                LinearGradient(
                    colors: [.white.opacity(0.4), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: matteThickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Bottom bevel shadow (shadow on the bottom cut edge)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.25)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: matteThickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                // Left bevel highlight
                LinearGradient(
                    colors: [.white.opacity(0.3), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: matteThickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                // Right bevel shadow
                LinearGradient(
                    colors: [.clear, .black.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: matteThickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
    }
}

// MARK: - Async Image View
// Loads a photo thumbnail asynchronously using ImageIO for efficiency
struct AsyncImageView: View {
    let url: URL
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size * 0.75)
                    .clipped()
            } else {
                // Placeholder while loading
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: size, height: size * 0.75)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.5)
                    )
            }
        }
        .task {
            // Load thumbnail on a background thread
            image = await Task.detached(priority: .userInitiated) {
                PhotoScanner.thumbnail(for: url, size: size)
            }.value
        }
    }
}

// MARK: - Empty Grid View
// Shown when there are no photos to display
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
// Upload Selected and Upload All buttons shown in the tab bar
struct UploadControlsView: View {
    @EnvironmentObject var appState: AppState

    var isConnected: Bool { appState.selectedTV?.isReachable ?? false }
    var hasSelection: Bool { !appState.selectedPhotoIDs.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            if hasSelection {
                Button("Upload Selected (\(appState.selectedPhotoIDs.count))") {
                    // Upload action handled by UploadEngine (next group)
                }
                .disabled(!isConnected || appState.isUploading)
            }

            Button("Upload All") {
                // Upload action handled by UploadEngine
            }
            .disabled(!isConnected || appState.isUploading || appState.filteredPhotos.isEmpty)
        }
        .buttonStyle(.bordered)
        .opacity(isConnected ? 1.0 : 0.4)
    }
}

// MARK: - Upload Progress View
// Shown at the bottom of the grid during an upload
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