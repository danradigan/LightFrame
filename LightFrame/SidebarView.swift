import SwiftUI

// MARK: - SidebarView
// The left column of the app. Three sections:
//   1. TV — context switcher (which TV to work with)
//   2. Collections — navigation (what to show in the grid)
//   3. Filters — matte style/color filters
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    // Controls whether the Add Collection sheet is showing
    @State private var showingAddCollection = false
    // Controls whether the Add TV sheet is showing
    @State private var showingAddTV = false

    var body: some View {
        List(selection: Binding(
            get: { appState.sidebarSelection },
            set: { newValue in
                if let value = newValue {
                    appState.setSidebarSelection(value)
                    // Defer collection switch out of the view update
                    if case .collection(let id) = value {
                        Task { @MainActor in
                            if let collection = appState.collections.first(where: { $0.id == id }) {
                                appState.selectedCollection = collection
                                await appState.scanSelectedCollection()
                            }
                        }
                    }
                }
            }
        )) {
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
                // Photos on TV — virtual collection from SyncStore
                Label {
                    HStack {
                        Text("Photos on TV")
                        Spacer()
                        if appState.selectedTV != nil {
                            Text("\(appState.syncStorePhotoCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "tv")
                }
                .tag(SidebarSelection.photosOnTV)
                .disabled(appState.selectedTV == nil)

                // All Photos — merge all collections
                Label {
                    HStack {
                        Text("All Photos")
                        Spacer()
                        Text("\(allPhotosCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .tag(SidebarSelection.allPhotos)

                // User collections
                ForEach(appState.collections) { collection in
                    Label {
                        HStack {
                            Text(collection.name)
                            Spacer()
                            Text("\(collection.photos.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .tag(SidebarSelection.collection(collection.id))
                    .contextMenu {
                        CollectionContextMenu(collection: collection)
                    }
                }
                .onDelete { indexSet in
                    indexSet.forEach { appState.removeCollection(appState.collections[$0]) }
                }

                Button {
                    showingAddCollection = true
                } label: {
                    Label("Add Folder...", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            // MARK: Filters Section
            Section("Filters") {
                // TV status filter
                VStack(alignment: .leading, spacing: 6) {
                    Text("TV Status")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Picker("", selection: $appState.gridFilter) {
                        ForEach(GridFilter.allCases, id: \.self) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(appState.isFilterLocked)
                }

                // Aspect ratio filter
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aspect Ratio")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack {
                        Picker("", selection: $appState.aspectRatioFilter) {
                            ForEach(AspectRatioFilter.allCases, id: \.self) { filter in
                                Text(filter.displayName).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Spacer()
                    }
                }

                // Matte style filter — 3x2 grid + full-width None button
                VStack(alignment: .leading, spacing: 6) {
                    Text("Style")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(MatteStyle.allCases.filter { $0 != .none }, id: \.self) { style in
                            Button {
                                if appState.activeStyleFilters.contains(style) {
                                    appState.activeStyleFilters.remove(style)
                                } else {
                                    appState.activeStyleFilters.insert(style)
                                }
                            } label: {
                                GeometryReader { geo in
                                    let tileWidth = geo.size.width
                                    ZStack {
                                        MatteStyleIcon(style: style, size: tileWidth)
                                        if appState.activeStyleFilters.contains(style) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .stroke(Color.accentColor, lineWidth: 2)
                                        }
                                    }
                                }
                                .aspectRatio(16.0/9.0, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                            .help(style.displayName)
                        }
                    }

                    // None — full-width button below the grid
                    Button {
                        if appState.activeStyleFilters.contains(.none) {
                            appState.activeStyleFilters.remove(.none)
                        } else {
                            appState.activeStyleFilters.insert(.none)
                        }
                    } label: {
                        Text("None")
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(appState.activeStyleFilters.contains(.none) ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(appState.activeStyleFilters.contains(.none) ? Color.accentColor : Color.primary.opacity(0.2),
                                            lineWidth: appState.activeStyleFilters.contains(.none) ? 2 : 0.5)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Matte color filter — 4-column rectangle swatch grid
                VStack(alignment: .leading, spacing: 6) {
                    Text("Color")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(MatteColor.allCases, id: \.self) { color in
                            Button {
                                if appState.activeColorFilters.contains(color) {
                                    appState.activeColorFilters.remove(color)
                                } else {
                                    appState.activeColorFilters.insert(color)
                                }
                            } label: {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(color.previewColor)
                                    .frame(height: 28)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(appState.activeColorFilters.contains(color) ? Color.accentColor : Color.primary.opacity(0.2),
                                                    lineWidth: appState.activeColorFilters.contains(color) ? 2 : 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(color.displayName)
                        }
                    }
                }

                // Clear Filters button
                if !appState.activeStyleFilters.isEmpty || !appState.activeColorFilters.isEmpty || appState.aspectRatioFilter != .all || (appState.gridFilter != .all && !appState.isFilterLocked) {
                    Button {
                        appState.activeStyleFilters = []
                        appState.activeColorFilters = []
                        appState.aspectRatioFilter = .all
                        if !appState.isFilterLocked {
                            appState.gridFilter = .all
                        }
                    } label: {
                        Label("Clear Filters", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
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

    private var allPhotosCount: Int {
        var seen = Set<String>()
        return appState.collections.flatMap { $0.photos }
            .filter { seen.insert($0.filename).inserted }
            .count
    }
}

// MARK: - Collection Context Menu
struct CollectionContextMenu: View {
    @EnvironmentObject var appState: AppState
    let collection: Collection

    var body: some View {
        Button("Rename...") {
            // Handled by alert on the row — trigger via notification or state
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

