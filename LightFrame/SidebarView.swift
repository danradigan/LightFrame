import SwiftUI

// MARK: - SidebarView
// The left column of the app. Contains:
//   - TV switcher and connection status
//   - Collection (folder) picker
//   - Matte style and color filters
//   - Slideshow controls
//   - Upload and scan actions
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    // Controls whether the Add Collection sheet is showing
    @State private var showingAddCollection = false
    // Controls whether the Add TV sheet is showing
    @State private var showingAddTV = false

    var body: some View {
        List {
            // MARK: TV Section
            Section("TV") {
                if appState.tvs.isEmpty {
                    Button {
                        showingAddTV = true
                    } label: {
                        Label("Add a TV", systemImage: "plus.circle")
                    }
                } else {
                    ForEach(appState.tvs) { tv in
                        TVRowView(tv: tv)
                    }
                    Button {
                        showingAddTV = true
                    } label: {
                        Label("Add TV", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }

            // MARK: Collections Section
            Section("Collections") {
                if appState.collections.isEmpty {
                    Button {
                        showingAddCollection = true
                    } label: {
                        Label("Add Folder", systemImage: "plus.circle")
                    }
                } else {
                    ForEach(appState.collections) { collection in
                        CollectionRowView(collection: collection)
                    }
                    .onDelete { indexSet in
                        indexSet.forEach { appState.removeCollection(appState.collections[$0]) }
                    }
                    Button {
                        showingAddCollection = true
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }

            // MARK: Matte Style Filter
            Section("Style") {
                ForEach(MatteStyle.allCases, id: \.self) { style in
                    FilterToggleRow(
                        label: style.displayName,
                        isActive: appState.activeStyleFilters.contains(style)
                    ) {
                        // Toggle this style in/out of the active filters
                        if appState.activeStyleFilters.contains(style) {
                            appState.activeStyleFilters.remove(style)
                        } else {
                            appState.activeStyleFilters.insert(style)
                        }
                    }
                }
            }

            // MARK: Matte Color Filter
            Section("Color") {
                ForEach(MatteColor.allCases, id: \.self) { color in
                    HStack {
                        // Color swatch
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.previewColor)
                            .frame(width: 14, height: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                            )
                        FilterToggleRow(
                            label: color.displayName,
                            isActive: appState.activeColorFilters.contains(color)
                        ) {
                            if appState.activeColorFilters.contains(color) {
                                appState.activeColorFilters.remove(color)
                            } else {
                                appState.activeColorFilters.insert(color)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $showingAddCollection) {
            AddCollectionSheet()
        }
        .sheet(isPresented: $showingAddTV) {
            AddTVSheet()
        }
    }
}

// MARK: - Collection Row
// Shows a single named folder collection
struct CollectionRowView: View {
    @EnvironmentObject var appState: AppState
    let collection: Collection

    var isSelected: Bool { appState.selectedCollection?.id == collection.id }

    @State private var isRenaming = false
    @State private var renameName = ""

    var body: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundColor(isSelected ? .accentColor : .secondary)
            Text(collection.name)
                .fontWeight(isSelected ? .semibold : .regular)
            Spacer()
            // Show photo count
            Text("\(collection.photos.count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedCollection = collection
            Task {
                await appState.scanSelectedCollection()
            }
        }
        .contextMenu {
            Button("Rename…") {
                renameName = collection.name
                isRenaming = true
            }
            Button {
                appState.selectedCollection = collection
                Task { await appState.scanSelectedCollection() }
            } label: {
                Label("Rescan Folder", systemImage: "arrow.clockwise")
            }
            Divider()
            Button("Remove", role: .destructive) {
                appState.removeCollection(collection)
            }
        }
        .alert("Rename Collection", isPresented: $isRenaming) {
            TextField("Name", text: $renameName)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                let trimmed = renameName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    appState.renameCollection(collection, to: trimmed)
                }
            }
        }
    }
}

// MARK: - Filter Toggle Row
// A row that shows a checkmark when the filter is active
struct FilterToggleRow: View {
    let label: String
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(isActive ? .primary : .secondary)
            Spacer()
            if isActive {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}


// MARK: - Add Collection Sheet
// Modal that lets the user name and choose a folder
struct AddCollectionSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var name: String = ""
    @State private var folderURL: URL?

    var canSave: Bool { !name.isEmpty && folderURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Collection")
                .font(.headline)

            // Name field
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundColor(.secondary)
                TextField("e.g. Landscapes", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            // Folder picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Folder").font(.caption).foregroundColor(.secondary)
                HStack {
                    Text(folderURL?.lastPathComponent ?? "No folder selected")
                        .foregroundColor(folderURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Button("Choose...") {
                        chooseFolder()
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }

            Spacer()

            // Buttons
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    if let url = folderURL {
                        appState.addCollection(name: name, folderURL: url)
                        dismiss()
                    }
                }
                .disabled(!canSave)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360, height: 260)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"

        if panel.runModal() == .OK, let url = panel.url {
            // Start security-scoped access immediately so we can hand
            // a live URL to addCollection (which creates its own bookmark)
            _ = url.startAccessingSecurityScopedResource()
            folderURL = url
            // Auto-fill name from folder name if empty
            if name.isEmpty {
                name = url.lastPathComponent
            }
        }
    }
}
