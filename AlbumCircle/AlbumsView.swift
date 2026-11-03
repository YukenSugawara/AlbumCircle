import SwiftUI
import CloudKit

struct AlbumsView: View {
    @StateObject private var store = CloudStore.shared
    @ObservedObject private var premium = PremiumStore.shared
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var backup = PhotoBackup.shared
    @State private var create = false
    @State private var title = ""
    @State private var settings = false
    @State private var showImports = false
    @AppStorage(AlbumStorage.settingKey) private var storageChoice = AlbumStorage.iCloud.rawValue
    @AppStorage(AlbumBackground.settingKey) private var backgroundChoice = AlbumBackground.standard.rawValue
    private var preferredStorage: AlbumStorage { AlbumStorage(rawValue: storageChoice) ?? .iCloud }
    private var background: AlbumBackground { AlbumBackground(rawValue: backgroundChoice) ?? .standard }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let status = store.localStatus { InlineNotice(text: status, symbol: "exclamationmark.circle") }
                    if let status = store.cloudStatus { InlineNotice(text: status, symbol: "icloud.slash") }
                    if store.albums.isEmpty && !store.initialLoadFinished {
                        ProgressView("アルバムを確認中…").frame(maxWidth: .infinity).padding(.vertical, 48)
                    } else if store.albums.isEmpty {
                        ContentUnavailableView("最初のアルバムを作りましょう",
                                               systemImage: "rectangle.stack.badge.plus",
                                               description: Text("家族、旅行、友達。共有する人をアルバムごとに選べます。"))
                        Button("アルバムを作成", systemImage: "plus") { title = ""; create = true }
                            .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).disabled(store.busy)
                    }
                    LazyVGrid(columns: albumGridColumns, alignment: .leading, spacing: 18) {
                        ForEach(store.albums) { album in
                            NavigationLink { AlbumView(album: album) } label: { AlbumCard(album: album) }
                                .buttonStyle(.plain)
                        }
                    }
                }.padding(16)
            }
            .background(background.color)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("設定", systemImage: "gearshape") { settings = true }.frame(minWidth: 44, minHeight: 44).disabled(store.busy && !backup.isRunning)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("アップロード状況", systemImage: "arrow.up.circle") { showImports = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("作成", systemImage: "plus") { title = ""; create = true }.disabled(store.busy)
                }
            }
            .refreshable {
                await store.refresh()
                store.revision = UUID()
            }
            .alert("アルバムを作成", isPresented: $create) {
                TextField("アルバム名", text: $title)
                Button("キャンセル", role: .cancel) {}
                Button("作成") { Task { await store.perform("作成中…") { try await store.createAlbum(title, storage: preferredStorage) } } }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .sheet(isPresented: $showImports) { ImportStatusView() }
            .sheet(isPresented: $settings) { SettingsView() }
        }
        .tint(background.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if store.busy { ImportProgressView() }
                AlbumAdvertisement()
            }
        }
        .task {
            await premium.start()
            await Advertising.shared.prepare()
        }
        .onChange(of: premium.shouldShowAds) { _, show in
            if show { Task { await Advertising.shared.prepare() } }
        }
        .alert("お知らせ", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task { await store.refresh(); await AlbumImporter.resumePending() }
        .onChange(of: phase) { _, value in
            if value == .active && store.initialLoadFinished {
                Task { await premium.refreshEntitlements(); await store.refresh(); await AlbumImporter.resumePending() }
            }
        }
        .onChange(of: store.busy) { _, busy in
            if !busy && phase == .active { Task { await AlbumImporter.resumePending() } }
        }
        .task(id: phase) {
            guard phase == .active else { backup.schedule(); return }
            while !Task.isCancelled {
                if store.initialLoadFinished { await backup.runIfDue() }
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in backup.clockChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            backup.accountChanged()
            Task { await store.accountChanged() }
        }
    }
}
private struct AlbumCard: View {
    let album: Album
    @ObservedObject private var newPhotos = NewPhotoTracker.shared
    @ObservedObject private var store = CloudStore.shared
    @State private var contents: AlbumContents?
    @State private var failed = false
    private var cover: Picture? {
        guard let contents else { return nil }
        if let folderID = album.coverFolderID {
            guard let folder = contents.folders.first(where: { $0.id == folderID }) else { return nil }
            return contents.cover(folder.coverPhotoID, in: folderID)
                ?? contents.photos(in: folderID, recursive: true).first
        }
        return contents.cover(album.coverPhotoID, in: nil)
    }
    var body: some View {
        FolderCard(title: album.title, count: contents?.pictures.count,
                   cover: cover,
                   symbol: failed ? "exclamationmark.circle" : (album.coverFolderID == nil ? (album.shared || album.record.share != nil ? "person.2.fill" : album.storage.icon) : "folder.fill"),
                   detail: failed ? "更新に失敗しました" : album.storage.title)
            .overlay(alignment: .topTrailing) {
                let count = newPhotos.unread(scope: store.newPhotoScope(for: album)).count
                if count > 0 && !failed { NewPhotoBadge(count: count) }
            }
            .task(id: store.revision) { await load() }
            .onChange(of: store.contentsRevision) { _, _ in Task { await load() } }
            .onChange(of: store.contentsCheckID) { _, _ in Task { await load() } }
    }
    private func load() async {
        let epoch = store.accountEpoch
        do {
            let value = try await store.contents(in: album)
            try store.checkAccount(epoch, for: album)
            guard !Task.isCancelled else { return }
            contents = value
            failed = false
        } catch {
            guard !Task.isCancelled else { return }
            if epoch != store.accountEpoch { contents = nil }
            else if let ck = error as? CKError,
                    [.permissionFailure, .zoneNotFound, .unknownItem, .notAuthenticated].contains(ck.code) { contents = nil }
            failed = true
            await store.forgetUnavailableShare(album, error: error)
        }
    }
}
