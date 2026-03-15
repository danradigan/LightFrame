import SwiftUI

// MARK: - DuplicatePromptSheet
// Shown as a sheet over the UploadModal when a photo that's already on the TV
// is encountered during an upload batch.
//
// The user can:
//   • Skip — leave the existing copy on the TV, move on
//   • Re-upload — delete the old copy and upload the new one
//   • Check "Apply to all" — use the same answer for all remaining duplicates
//     in this batch without prompting again
//
struct DuplicatePromptSheet: View {
    let item: UploadItem

    // Called when the user taps either button.
    // resolution: what to do with this photo
    // applyToAll: whether to use the same answer for all future duplicates
    let onResolve: (DuplicateResolution, Bool) -> Void

    // Whether the "apply to all" checkbox is checked
    @State private var applyToAll: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: Header
            VStack(alignment: .leading, spacing: 6) {
                Text("Already on TV")
                    .font(.headline)
                Text("This photo is already in your TV's art library.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // MARK: Photo Info
            VStack(alignment: .leading, spacing: 12) {

                // File name
                HStack(spacing: 10) {
                    Image(systemName: "photo")
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.photo.filename)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(2)
                        if let matte = item.photo.matte {
                            Text("Matte: \(matte.displayName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                // Apply-to-all checkbox
                // This lets the user make one decision for the entire batch
                // without being asked for every duplicate
                Toggle(isOn: $applyToAll) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apply to all duplicates in this batch")
                            .font(.subheadline)
                        Text("You won't be asked again for this upload session.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(24)

            Divider()

            // MARK: Action Buttons
            HStack(spacing: 12) {
                // Skip — leave the TV copy as-is, move on to the next photo
                Button {
                    onResolve(.skip, applyToAll)
                } label: {
                    Text("Skip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)  // Esc = skip

                // Re-upload — delete old copy, upload new one
                Button {
                    onResolve(.overwrite, applyToAll)
                } label: {
                    Text("Re-upload & Overwrite")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)  // Return = overwrite
            }
            .padding(24)
        }
        .frame(width: 380)
        // No fixed height — let content determine height
    }
}
