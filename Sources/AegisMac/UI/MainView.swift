import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Active sheet routing

enum MainSheet: Identifiable {
    case add
    case edit(VaultEntry)
    case assignGroups(VaultEntry)
    case showQR(VaultEntry)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let e): return "edit-\(e.uuid.uuidString)"
        case .assignGroups(let e): return "groups-\(e.uuid.uuidString)"
        case .showQR(let e): return "qr-\(e.uuid.uuidString)"
        }
    }
}

// MARK: - MainView

struct MainView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.palette) private var palette
    @FocusState private var searchFocused: Bool

    @State private var sheet: MainSheet?
    @State private var entryToDelete: VaultEntry?
    @State private var draggingEntry: UUID?

    var body: some View {
        NavigationStack {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            GroupChips()
            globalProgressBar
            errorBanner
            listOrEmpty
            footer
        }
        .background(palette.backgroundColor)
        .navigationTitle(app.isSearching && !app.searchText.isEmpty ? "Search" : "Aegis")
        .navigationSubtitle(app.isSearching && !app.searchText.isEmpty ? app.searchText : "")
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search")
        .onChange(of: app.searchText) { _, newValue in
            app.isSearching = !newValue.isEmpty
        }
        .toolbar { toolbarContent }
        .sheet(item: $sheet) { which in
            switch which {
            case .add:
                EditEntryView(entry: nil).environmentObject(app)
            case .edit(let e):
                EditEntryView(entry: e).environmentObject(app)
            case .assignGroups(let e):
                AssignGroupsView(entry: e).environmentObject(app)
            case .showQR(let e):
                ShowQRView(entry: e).environment(\.palette, palette)
            }
        }
        .alert("Delete entry?", isPresented: Binding(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { entryToDelete = nil }
            Button("Delete", role: .destructive) {
                if let e = entryToDelete { app.deleteEntry(e) }
                entryToDelete = nil
            }
        } message: {
            if let e = entryToDelete {
                Text("\"\(e.issuer.isEmpty ? e.name : e.issuer)\" will be permanently removed from this vault.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aegisAddEntry)) { _ in sheet = .add }
        .onReceive(NotificationCenter.default.publisher(for: .aegisFocusSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .aegisLock)) { _ in
            if app.isEncrypted { app.lock() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aegisCopyCode)) { _ in app.copySelected() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if app.isEncrypted {
                Button {
                    app.lock()
                } label: { Image(systemName: "lock") }
                .help("Lock vault")
            }

            Menu {
                Picker("Sort", selection: $app.sortCategory) {
                    ForEach(SortCategory.allCases) { cat in
                        Text(cat.displayName).tag(cat)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .help("Sort")

            Menu {
                Button {
                    Task { await scanScreen() }
                } label: { Label("Scan QR from screen", systemImage: "qrcode.viewfinder") }
                Button {
                    scanImage()
                } label: { Label("Scan image…", systemImage: "photo") }
                Button {
                    sheet = .add
                } label: { Label("Enter manually", systemImage: "square.and.pencil") }
            } label: {
                Image(systemName: "plus")
            }
            .help("Add entry")
        }
    }

    // MARK: Global progress bar (uniform period)

    @ViewBuilder private var globalProgressBar: some View {
        if let period = app.dominantPeriod {
            TotpProgressBar(period: period, color: palette.progressbarColor, height: 4)
                .padding(.horizontal, 0)
        }
    }

    // MARK: Error banner

    @ViewBuilder private var errorBanner: some View {
        if let message = app.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).bold()
                Spacer()
                Button {
                    app.errorMessage = nil
                } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .foregroundColor(palette.onErrorContainerColor)
            .padding(16)
            .background(palette.errorContainerColor)
            .cornerRadius(12)
            .padding(10)
        }
    }

    // MARK: List / empty state

    private var shown: [DisplayEntry] { app.shownEntries }
    private var favCount: Int { app.shownFavoritesCount }

    private func corners(for index: Int) -> (top: Bool, bottom: Bool) {
        // Favorites (the top slice) are merged into one rounded block.
        guard index < favCount, favCount > 1 else { return (true, true) }
        if index == 0 { return (true, false) }
        if index == favCount - 1 { return (false, true) }
        return (false, false)
    }

    private func showsPerCardBar(_ entry: VaultEntry) -> Bool {
        guard let period = entry.info.totpPeriod else { return false }
        return period != app.dominantPeriod
    }

    @ViewBuilder private var listOrEmpty: some View {
        if let repo = app.repository, repo.vault.entries.isEmpty {
            emptyState
        } else if shown.isEmpty {
            if app.isSearching && !app.searchText.isEmpty {
                Spacer()
            } else {
                VStack {
                    Spacer()
                    Text("No entries found").font(.system(size: 18)).foregroundColor(palette.onSurfaceDimColor)
                    Spacer()
                }
            }
        } else {
            entryList
        }
    }

    @ViewBuilder private var entryList: some View {
        ScrollView {
            if app.viewMode == .tiles {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    entryRows
                }
                .padding(8)
            } else {
                LazyVStack(spacing: app.viewMode.itemOffset) {
                    entryRows
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private var entryRows: some View {
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, display in
            let c = corners(for: index)
            EntryRow(entry: display.entry,
                     roundTop: app.viewMode == .tiles ? true : c.top,
                     roundBottom: app.viewMode == .tiles ? true : c.bottom,
                     showPerCardBar: showsPerCardBar(display.entry),
                     onEdit: { sheet = .edit(display.entry) },
                     onAssignGroups: { sheet = .assignGroups(display.entry) },
                     onShowQR: { sheet = .showQR(display.entry) },
                     onDelete: { entryToDelete = display.entry })
                .environmentObject(app)
                .modifier(ReorderModifier(enabled: app.canReorder,
                                          uuid: display.entry.uuid,
                                          dragging: $draggingEntry,
                                          onMove: { from, to in moveEntry(from: from, to: to) }))
        }
    }

    // MARK: Footer

    private var footer: some View {
        let n = shown.count
        return (Text("Showing ") + Text("\(n)").bold() + Text(n == 1 ? " entry" : " entries"))
            .font(.system(size: 14))
            .foregroundColor(palette.onSurfaceDimColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    // MARK: Empty state (ui-style spec §8.1)

    private var emptyState: some View {
        VStack(spacing: 7) {
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .resizable().scaledToFit().frame(width: 50, height: 50)
                .foregroundColor(palette.onSurfaceDimColor)
            Text("No entries found").font(.system(size: 18)).padding(.top, 10)
                .foregroundColor(palette.onSurfaceColor)
            Text("There are no codes to be shown. Start adding entries by tapping the plus sign in the top right corner")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .foregroundColor(palette.onSurfaceDimColor)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Reorder

    private func moveEntry(from sourceUUID: UUID, to targetUUID: UUID) {
        guard app.canReorder, let repo = app.repository else { return }
        let entries = repo.vault.entries
        guard let src = entries.firstIndex(where: { $0.uuid == sourceUUID }),
              let dst = entries.firstIndex(where: { $0.uuid == targetUUID }),
              src != dst else { return }
        app.moveEntry(from: src, to: dst)
    }

    // MARK: Scan actions

    private func scanScreen() async {
        let result = await app.scanScreenAndImport()
        switch result {
        case .success(let n):
            if n == 0 { app.errorMessage = "No QR code found on screen" }
        case .failure(let e):
            app.errorMessage = (e as? AegisError)?.errorDescription ?? e.localizedDescription
        }
    }

    private func scanImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let result = app.scanImageAndImport(url: url)
            switch result {
            case .success(let n):
                if n == 0 { app.errorMessage = "No QR code found in image" }
            case .failure(let e):
                app.errorMessage = (e as? AegisError)?.errorDescription ?? e.localizedDescription
            }
        }
    }
}

// MARK: - Drag-to-reorder modifier

/// Enables basic drag-and-drop reordering when `enabled`. Each row provides its uuid as a drag
/// payload and accepts a dropped uuid to move it to this row's position.
private struct ReorderModifier: ViewModifier {
    let enabled: Bool
    let uuid: UUID
    @Binding var dragging: UUID?
    let onMove: (UUID, UUID) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    dragging = uuid
                    return NSItemProvider(object: uuid.uuidString as NSString)
                }
                .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(target: uuid, dragging: $dragging, onMove: onMove))
        } else {
            content
        }
    }
}

private struct ReorderDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let onMove: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        if let src = dragging, src != target {
            onMove(src, target)
        }
    }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - Notifications for menu commands

extension Notification.Name {
    static let aegisAddEntry = Notification.Name("aegisAddEntry")
    static let aegisFocusSearch = Notification.Name("aegisFocusSearch")
    static let aegisLock = Notification.Name("aegisLock")
    static let aegisCopyCode = Notification.Name("aegisCopyCode")
}
