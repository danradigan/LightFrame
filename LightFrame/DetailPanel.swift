//
//  DetailPanel.swift
//  LightFrame
//
//  Created by Dan Radigan on 3/14/26.
//


import SwiftUI

// MARK: - DetailPanel
// The right column — shows the selected photo with its matte,
// plus controls to change the matte style and color.
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
// Shows the selected photo with its matte and editing controls
struct PhotoDetailView: View {
    @EnvironmentObject var appState: AppState
    let photo: Photo

    // Local edits — these don't save until the user hits Save
    @State private var editedStyle: MatteStyle = .flexible
    @State private var editedColor: MatteColor = .warm
    @State private var isSaving: Bool = false
    @State private var saveMessage: String?

    // Whether the user has made unsaved changes
    var hasChanges: Bool {
        editedStyle != (photo.matte?.style ?? .flexible) ||
        editedColor != (photo.matte?.color ?? .warm)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Large Matte Preview
                // Shows how the photo will look on the TV with current matte settings
                MattePreviewView(
                    photo: photoWithEdits,
                    size: 240
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 16)

                // MARK: Photo Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(photo.filename)
                        .font(.headline)
                        .lineLimit(2)

                    HStack {
                        // TV status badge
                        Label(
                            photo.isOnTV ? "On TV" : "Not on TV",
                            systemImage: photo.isOnTV ? "tv.fill" : "tv"
                        )
                        .font(.caption)
                        .foregroundColor(photo.isOnTV ? .green : .secondary)
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

                    // Grid of style buttons — 2 columns
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(MatteStyle.allCases, id: \.self) { style in
                            StyleButton(
                                style: style,
                                isSelected: editedStyle == style
                            ) {
                                editedStyle = style
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // MARK: Matte Color Picker
                // Only show if style is not "none"
                if editedStyle != .none {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        // Grid of color swatches — 4 columns
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible()), count: 4),
                            spacing: 8
                        ) {
                            ForEach(MatteColor.allCases, id: \.self) { color in
                                ColorSwatchButton(
                                    color: color,
                                    isSelected: editedColor == color
                                ) {
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
                    // Save — writes matte back to the JPEG EXIF
                    Button {
                        saveMatte()
                    } label: {
                        HStack {
                            if isSaving {
                                ProgressView().scaleEffect(0.7)
                            }
                            Text(isSaving ? "Saving..." : "Save Matte")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || isSaving || !photo.isJPEG)

                    // Send to TV
                    Button {
                        // Upload action — wired up in next group
                    } label: {
                        Text("Send to TV")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!(appState.selectedTV?.isReachable ?? false))

                    // Remove from TV
                    if photo.isOnTV {
                        Button(role: .destructive) {
                            // Delete action — wired up in next group
                        } label: {
                            Text("Remove from TV")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!(appState.selectedTV?.isReachable ?? false))
                    }

                    // Save feedback message
                    if let message = saveMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Note if file isn't a JPEG
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
        // When a new photo is selected, load its current matte into the editor
        .onAppear { loadCurrentMatte() }
        .onChange(of: photo.id) { _ in loadCurrentMatte() }
    }

    // A copy of the photo with the current edited matte applied
    // Used to drive the live preview in the detail panel
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

    private func saveMatte() {
        guard photo.isJPEG else { return }
        isSaving = true
        let newMatte = Matte(style: editedStyle, color: editedStyle == .none ? nil : editedColor)

        Task {
            let success = await Task.detached(priority: .userInitiated) {
                EXIFManager.writeMatte(newMatte, to: photo.url)
            }.value

            isSaving = false
            saveMessage = success ? "✓ Saved" : "Failed to save"

            // Clear the message after 2 seconds
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
            // Color circle
            Circle()
                .fill(color.previewColor)
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2),
                                lineWidth: isSelected ? 2 : 0.5)
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
// Shown when no photo is selected
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
// Opens via Cmd+, — settings that don't belong in the main UI
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
                        Button("Remove") {
                            appState.removeTV(tv)
                        }
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