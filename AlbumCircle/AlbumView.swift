import SwiftUI
import Photos
import UniformTypeIdentifiers
import CloudKit

struct AlbumView: View {
    let album: Album
    var folderID: String? = nil
    @ObservedObject private var store = CloudStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @AppStorage(AlbumBackground.settingKey) private var backgroundChoice = AlbumBackground.standard.rawValue
    @State private var contents = AlbumContents()
    @State private var loading = true
    @State private var loadError: String?
    @State private var editable = false
    @State private var checkingPermission = false
    @State private var picker = false
    @State private var files = false
    @State private var chooseQuality = false
    @State private var qualityForFiles = false
    @State private var importQuality: UploadQuality = .original
    @StateObject private var exportFiles = PreviewFiles()
    @State private var export = false
    @State private var share: ShareSheet?
    @State private var rename = false
    @State private var newFolder = false
    @State private var chooseCover = false
    @State private var title = ""
    @State private var remove = false
    @State private var selected: PhotoPreviewSelection?
    @State private var selecting = false
    @State private var selectedIDs: Set<CKRecord.ID> = []
    @State private var removeSelected = false
    @State private var loadVersion = 0
    @ObservedObject private var newPhotos = NewPhotoTracker.shared
    @AppStorage("photoSortOrder") private var sortOrder = PhotoSort.takenNewest.rawValue
    @AppStorage(FolderSort.settingKey) private var folderSortOrder = FolderSort.nameAscending.rawValue
    @State private var dateFilter = false
    @State private var startDate: Date?
    @State private var endDate: Date?
    @State private var onlyNew = false
    @State private var onlyFavorites = false
    @State private var showMap = false
    @State private var showImports = false
    @ObservedObject private var favorites = FavoritePhotos.shared
    private var favoriteIDs: Set<String> { favorites.ids(scope: store.personalPhotoScope(for: current)) }
    @State private var includeSubfolders = true
    @State private var moving = false
    @State private var moveTargets: [Picture] = []
    private var unread: Set<String> { newPhotos.unread(scope: store.newPhotoScope(for: current)) }
    private var isFiltering: Bool { startDate != nil || onlyNew || onlyFavorites }
    private var newCount: Int {
        contents.photos(in: folderID, recursive: true).filter { unread.contains($0.id.recordName) }.count
    }
    private var background: AlbumBackground { AlbumBackground(rawValue: backgroundChoice) ?? .standard }
    private var current: Album { store.albums.first { $0.id == album.id } ?? album }
    private var folder: PhotoFolder? { contents.folders.first { $0.id == folderID } }
    private var screenTitle: String { folderID == nil ? current.title : (folder?.title ?? "フォルダ") }
    private var photos: [Picture] {
        let favorites = favoriteIDs
        let candidates = contents.photos(in: folderID, recursive: isFiltering && includeSubfolders)
            .filter { (!onlyNew || unread.contains($0.id.recordName)) && (!onlyFavorites || favorites.contains($0.id.recordName)) }
        return (PhotoSort(rawValue: sortOrder) ?? .takenNewest).apply(candidates, from: startDate, through: endDate)
    }
    private var mapPictures: [Picture] {
        let favorites = favoriteIDs
        let candidates = contents.photos(in: folderID, recursive: true).filter {
            (!onlyNew || unread.contains($0.id.recordName)) && (!onlyFavorites || favorites.contains($0.id.recordName))
        }
        return (PhotoSort(rawValue: sortOrder) ?? .takenNewest).apply(candidates, from: startDate, through: endDate)
    }
    private var children: [PhotoFolder] {
        guard !isFiltering else { return [] }
        return (FolderSort(rawValue: folderSortOrder) ?? .nameAscending)
            .apply(contents.children(of: folderID), counts: contents.recursivePhotoCounts())
    }
    private var coverID: String? { folderID == nil ? current.coverPhotoID : folder?.coverPhotoID }
    var body: some View {
        let markedFavorites = favoriteIDs
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if isFiltering || newCount > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        if newCount > 0 {
                            Button("新着 \(newCount)枚を表示", systemImage: "sparkles") { onlyNew = true }
                        }
                        if let startDate, let endDate {
                            Text("撮影日：" + startDate.formatted(date: .numeric, time: .omitted) + " 〜 " + endDate.formatted(date: .numeric, time: .omitted))
                                .font(.subheadline)
                        }
                        if isFiltering {
                            HStack {
                                Text("\(onlyFavorites ? "お気に入り " : "")\(onlyNew ? "新着 " : "")\(photos.count)枚").font(.subheadline)
                                Spacer()
                                Button("絞り込みを解除") { startDate = nil; endDate = nil; onlyNew = false; onlyFavorites = false }
                            }
                            Toggle("配下のフォルダも含める", isOn: $includeSubfolders).font(.subheadline)
                        }
                    }
                }
                if !children.isEmpty {
                    let photoCounts = contents.recursivePhotoCounts()
                    LazyVGrid(columns: albumGridColumns, alignment: .leading, spacing: 16) {
                        ForEach(children) { child in
                            NavigationLink { AlbumView(album: current, folderID: child.id) } label: {
                                FolderCard(title: child.title, count: photoCounts[child.id, default: 0],
                                           cover: contents.cover(child.coverPhotoID, in: child.id))
                                    .overlay(alignment: .topTrailing) {
                                        let count = contents.photos(in: child.id, recursive: true).filter { unread.contains($0.id.recordName) }.count
                                        if count > 0 { NewPhotoBadge(count: count) }
                                    }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if editable {
                                    Button("表紙に設定", systemImage: "photo.badge.checkmark") {
                                        Task {
                                            await store.perform("表紙を保存中…") {
                                                try await store.setAlbumCoverFolder(child, in: current)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if loading && photos.isEmpty && children.isEmpty {
                    ProgressView("読み込み中…").frame(maxWidth: .infinity).padding(40)
                } else if photos.isEmpty && children.isEmpty && loadError == nil {
                    if isFiltering {
                        ContentUnavailableView("該当する写真がありません", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("絞り込み条件を変更してください。"))
                    } else {
                        ContentUnavailableView(editable ? "写真やフォルダを追加" : "まだ写真がありません", systemImage: "folder.badge.plus",
                            description: Text(editable ? "右上のメニューから写真やフォルダを追加できます。" : "メンバーが写真を追加するとここに表示されます。"))
                    }
                }
                if !photos.isEmpty {
                    if !children.isEmpty { Text("写真").font(.headline) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 3), spacing: 3) {
                        ForEach(photos) { picture in
                            Button {
                                if selecting {
                                    if !selectedIDs.insert(picture.id).inserted { selectedIDs.remove(picture.id) }
                                } else { selected = PhotoPreviewSelection(picture: picture, pictures: photos) }
                            } label: {
                                PictureThumbnail(picture: picture)
                                    .overlay(alignment: .bottomLeading) {
                                        if markedFavorites.contains(picture.id.recordName) {
                                            Image(systemName: "heart.fill").foregroundStyle(.pink)
                                                .padding(5).background(.thinMaterial, in: Circle()).padding(5)
                                        }
                                    }
                                    .overlay(alignment: .topLeading) {
                                        if unread.contains(picture.id.recordName) { NewPhotoBadge() }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if selecting {
                                            Image(systemName: selectedIDs.contains(picture.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.title2).foregroundStyle(.white, Color.albumAccent)
                                                .padding(7)
                                        }
                                    }
                            }
                            .accessibilityLabel(picture.name)
                            .contextMenu {
                                if !selecting {
                                    FavoritePhotoButton(picture: picture, album: current)
                                    Button("写真へダウンロード", systemImage: "square.and.arrow.down") {
                                        Task { await download(picture) }
                                    }
                                    Button("ファイルへダウンロード", systemImage: "folder") {
                                        Task { await exportFile(picture) }
                                    }
                                    if editable {
                                        Button("フォルダへ移動", systemImage: "folder") { moveTargets = [picture]; moving = true }
                                            .disabled(store.busy || checkingPermission)
                                        Button("このフォルダの表紙にする", systemImage: "photo.badge.checkmark") {
                                            Task { await store.perform("表紙を保存中…") { try await store.setCover(picture, in: current, folderID: folderID) } }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if let loadError {
                    InlineNotice(text: loadError, symbol: "exclamationmark.circle")
                    Button("再試行") { Task { await load() } }.disabled(loading)
                }
                if contents.skipped > 0 {
                    InlineNotice(text: "\(contents.skipped)件を読み取れませんでした。該当データは削除せず残しています。", symbol: "exclamationmark.circle")
                }
                if current.storage == .device {
                    Text("この端末に保存しています。共有にはiCloudのアルバムを使います。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !editable && !loading && !checkingPermission && loadError == nil {
                    Text("閲覧のみのアルバムです。").font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(16)
        }
        .background(background.color)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ScrollingTitle(title: screenTitle)
                    .frame(width: UIDevice.current.userInterfaceIdiom == .pad ? 250 : 160)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if current.storage == .iCloud {
                    Button("アルバムのメンバー", systemImage: "person.2") {
                        Task { await store.perform("共有情報を取得中…") { share = ShareSheet(share: try await store.share(for: current)) } }
                    }.disabled(store.busy)
                }
                Menu {
                    Button("更新", systemImage: "arrow.clockwise") { Task { await load(forceRefresh: true) } }
                    Picker("並び替え", selection: $sortOrder) {
                        ForEach(PhotoSort.allCases) { order in Text(order.title).tag(order.rawValue) }
                    }
                    Toggle("お気に入りのみ表示", isOn: $onlyFavorites)
                    Button("撮影場所から探す", systemImage: "map") { showMap = true }
                    Button("アップロード状況", systemImage: "arrow.up.circle") { showImports = true }
                    Button("日付で絞り込み", systemImage: "calendar") { dateFilter = true }
                    if store.newPhotoScope(for: current) != nil {
                        Toggle("新着のみ表示", isOn: $onlyNew)
                        Button("表示中の写真を既読にする", systemImage: "checkmark") {
                            newPhotos.markRead(Set(photos.map { $0.id.recordName }), scope: store.newPhotoScope(for: current))
                        }.disabled(!photos.contains { unread.contains($0.id.recordName) })
                    }
                    if editable {
                        Divider()
                        Button("写真から追加", systemImage: "photo.badge.plus") {
                            qualityForFiles = false; chooseQuality = true
                        }.disabled(store.busy)
                        Button("ファイルから追加", systemImage: "doc.badge.plus") {
                            qualityForFiles = true; chooseQuality = true
                        }.disabled(store.busy)
                        Button("フォルダを作成", systemImage: "folder.badge.plus") {
                            title = ""; newFolder = true
                        }.disabled(store.busy)
                        Button("表紙を選択", systemImage: "photo") { chooseCover = true }
                        if folderID != nil || !album.shared {
                            Button("名前を変更", systemImage: "pencil") { title = screenTitle; rename = true }
                        }
                    }
                    if !photos.isEmpty {
                        Divider()
                        Button(selecting ? "選択を終了" : "複数選択", systemImage: "checkmark.circle") {
                            selecting.toggle(); selectedIDs.removeAll()
                        }
                        if selecting {
                            Button("すべて選択", systemImage: "checkmark.circle.fill") {
                                selectedIDs = Set(photos.map(\.id))
                            }
                            Button("選択した写真をダウンロード（\(selectedIDs.count)枚）", systemImage: "square.and.arrow.down") {
                                Task { await downloadSelectedPhotos() }
                            }.disabled(selectedIDs.isEmpty || store.busy)
                            if editable {
                                Button("選択した写真を移動（\(selectedIDs.count)枚）", systemImage: "folder") {
                                    moveTargets = photos.filter { selectedIDs.contains($0.id) }; moving = true
                                }.disabled(selectedIDs.isEmpty || store.busy || checkingPermission)
                                Button("選択した写真を削除（\(selectedIDs.count)枚）", systemImage: "trash", role: .destructive) {
                                    removeSelected = true
                                }.disabled(selectedIDs.isEmpty || store.busy)
                            }
                        }
                    }
                    if folderID == nil && !album.shared {
                        Button("アルバムを削除", systemImage: "trash", role: .destructive) { remove = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.disabled(loading)
            }
        }
        .task { await load(); store.checkForUpdates(in: current) }
        .onChange(of: store.revision) { _, _ in
            if !store.albums.contains(where: { $0.id == album.id }) {
                loadVersion += 1; contents = AlbumContents(); selected = nil; chooseCover = false; dismiss()
            } else { Task { await load() } }
        }
        .onChange(of: store.contentsRevision) { _, _ in Task { await loadCachedContents() } }
        .onChange(of: store.contentsCheckID) { _, _ in
            Task { await loadCachedContents(); store.checkForUpdates(in: current) }
        }
        .onChange(of: phase) { _, value in
            if value == .active { store.checkForUpdates(in: current) }
        }
        .refreshable { await load(forceRefresh: true) }
        .onChange(of: sortOrder) { _, _ in selectedIDs.removeAll() }
        .onChange(of: startDate) { _, _ in selectedIDs.removeAll() }
        .onChange(of: endDate) { _, _ in selectedIDs.removeAll() }
        .onChange(of: onlyNew) { _, _ in selectedIDs.removeAll() }
        .onChange(of: includeSubfolders) { _, _ in selectedIDs.removeAll() }
        .onChange(of: onlyFavorites) { _, _ in selectedIDs.removeAll() }
        .onChange(of: favorites.revision) { _, _ in selectedIDs.formIntersection(Set(photos.map(\.id))) }
        .sheet(isPresented: $showImports) { ImportStatusView(albumID: current.id) }
        .sheet(isPresented: $showMap, onDismiss: { Task { await load() } }) {
            PhotoMapView(pictures: mapPictures, album: current, editable: editable)
        }
        .sheet(isPresented: $dateFilter) {
            PhotoDateFilter(start: startDate ?? Date(), end: endDate ?? Date(), apply: { start, end in
                startDate = start; endDate = end
            }, clear: { startDate = nil; endDate = nil })
        }
        .sheet(isPresented: $moving, onDismiss: { Task { await load(forceRefresh: true) } }) {
            MovePhotosSheet(albumTitle: current.title, contents: contents, pictures: moveTargets) { destination in
                guard !store.busy else { throw UserError(message: "現在の処理が終わってから移動してください。") }
                store.busy = true; store.progress = "写真を移動中…"
                defer { store.busy = false; selectedIDs.removeAll(); selecting = false }
                try await store.move(moveTargets, in: current, to: destination)
            }
        }
        .sheet(isPresented: $picker) {
            PhotoPicker { identifiers in
                picker = false
                let quality = importQuality
                Task { await AlbumImporter.photos(identifiers, into: current, folderID: folderID, quality: quality); await load() }
            }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let quality = importQuality
                Task { await AlbumImporter.files(urls, into: current, folderID: folderID, quality: quality); await load() }
            case .failure(let error): store.report(error)
            }
        }
        .confirmationDialog("追加する写真の画質", isPresented: $chooseQuality, titleVisibility: .visible) {
            ForEach(UploadQuality.allCases, id: \.self) { quality in
                Button(quality.title) {
                    importQuality = quality
                    if qualityForFiles { files = true }
                    else { Task { await openPhotos() } }
                }
            }
        } message: {
            Text("オリジナルは原本をそのまま保存します。高画質と標準はJPEGに変換し、元の写真は削除しません。Live Photosはオリジナルを選んでください。")
        }
        .sheet(item: $share, onDismiss: { Task { await store.refresh() } }) { item in
            ShareManagementView(share: item.share)
        }
        .sheet(isPresented: $chooseCover) {
            CoverPicker(title: screenTitle, pictures: contents.photos(in: folderID, recursive: true), selectedID: coverID) { picture in
                try await store.setCover(picture, in: current, folderID: folderID)
            }
        }
        .sheet(isPresented: $export, onDismiss: { exportFiles.clear() }) {
            if let original = exportFiles.original { FileExportView(urls: original.urls) }
        }
        .fullScreenCover(item: $selected, onDismiss: { Task { await load() } }) { preview in
            PictureView(pictures: preview.pictures, initialID: preview.initialID, album: current, editable: editable)
        }
        .alert("選択した\(selectedIDs.count)枚の写真を削除しますか？", isPresented: $removeSelected) {
            Button("キャンセル", role: .cancel) {}
            Button(current.storage == .device ? "本体から削除" : "全員から削除", role: .destructive) {
                let targets = photos.filter { selectedIDs.contains($0.id) }
                Task {
                    await store.perform("写真を削除中…") {
                        defer { store.revision = UUID() }
                        try await store.deleteMany(targets, album: current)
                    }
                    selectedIDs.removeAll(); selecting = false
                    await load(forceRefresh: true)
                }
            }
        } message: {
            Text("このアルバムから選択した写真を削除します。取り消しはできません。")
        }
        .alert("フォルダを作成", isPresented: $newFolder) {
            TextField("フォルダ名", text: $title)
            Button("キャンセル", role: .cancel) {}
            Button("作成") { Task { await store.perform("作成中…") { try await store.createFolder(title, in: current, parentID: folderID) } } }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("「\(screenTitle)」の中に作成します。") }
        .alert("名前を変更", isPresented: $rename) {
            TextField("名前", text: $title)
            Button("キャンセル", role: .cancel) {}
            Button("保存") {
                Task {
                    await store.perform("保存中…") {
                        if let folderID { try await store.renameFolder(folderID, in: current, title: title) }
                        else { try await store.rename(current, title: title) }
                    }
                }
            }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("アルバムを削除しますか？", isPresented: $remove) {
            Button("キャンセル", role: .cancel) {}
            Button(current.storage == .device ? "本体から削除" : "全員から削除", role: .destructive) {
                Task { await store.perform("削除中…") { try await store.deleteAlbum(current); dismiss() } }
            }
        } message: { Text("アルバム内の全フォルダ・写真・共有設定を削除します。この操作は取り消せません。端末の写真アプリに保存済みの写真は削除されません。") }
    }
    private func load(forceRefresh: Bool = false) async {
        loadVersion += 1
        let version = loadVersion, destination = current, epoch = store.accountEpoch
        loading = true
        checkingPermission = true
        defer { if version == loadVersion { loading = false; checkingPermission = false } }
        do {
            async let permission = store.canEdit(destination)
            let loadedContents = try await store.contents(in: destination, forceRefresh: forceRefresh)
            try store.checkAccount(epoch, for: destination)
            guard version == loadVersion, !Task.isCancelled else { return }
            contents = loadedContents
            loading = false
            selectedIDs.formIntersection(Set(photos.map(\.id)))
            loadError = nil
            if let folderID, !loadedContents.folders.contains(where: { $0.id == folderID }) {
                editable = false
                loadError = "フォルダ情報を読み込めません。戻って更新してください。"
            }
            let canEdit = try await permission
            guard version == loadVersion, !Task.isCancelled else { return }
            editable = canEdit
        } catch {
            guard version == loadVersion, !Task.isCancelled else { return }
            editable = false
            if epoch != store.accountEpoch && destination.storage == .iCloud {
                contents = AlbumContents(); selected = nil
            } else if let ck = error as? CKError,
                      [.permissionFailure, .zoneNotFound, .unknownItem, .notAuthenticated].contains(ck.code) {
                contents = AlbumContents(); selected = nil
            }
            loadError = "更新できませんでした。再試行してください。\n" + error.localizedDescription
            await store.forgetUnavailableShare(destination, error: error)
        }
    }
    private func loadCachedContents() async {
        let destination = current, epoch = store.accountEpoch
        guard let loaded = try? await store.contents(in: destination),
              epoch == store.accountEpoch, !Task.isCancelled else { return }
        contents = loaded
        selectedIDs.formIntersection(Set(photos.map(\.id)))
    }
    private func openPhotos() async {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if auth == .authorized || auth == .limited { picker = true }
        else { store.errorMessage = "原本を読み込むには写真へのアクセスが必要です。iPhoneの設定から許可してください。" }
    }
    private func download(_ picture: Picture) async {
        let epoch = store.accountEpoch
        await store.perform("原本をダウンロード中…") {
            let original = try await store.download(picture, album: current)
            defer { original.clean() }
            try store.checkAccount(epoch, for: current)
            try await original.saveToPhotos()
        }
    }
    private func downloadSelectedPhotos() async {
        let targets = photos.filter { selectedIDs.contains($0.id) }
        let epoch = store.accountEpoch
        await store.perform("原本をダウンロード中…") {
            for (index, picture) in targets.enumerated() {
                store.progress = "原本をダウンロード中 \(index + 1)/\(targets.count)"
                let original = try await store.download(picture, album: current)
                defer { original.clean() }
                try store.checkAccount(epoch, for: current)
                try await original.saveToPhotos()
            }
        }
    }
    private func exportFile(_ picture: Picture) async {
        let epoch = store.accountEpoch
        await store.perform("原本をダウンロード中…") {
            let original = try await store.download(picture, album: current)
            do { try store.checkAccount(epoch, for: current) }
            catch { original.clean(); throw error }
            exportFiles.clear()
            exportFiles.original = original
            export = true
        }
    }
}

// Integrated from CoverPicker.swift
struct CoverPicker: View {
    let title: String
    let pictures: [Picture]
    let selectedID: String?
    let onSelect: (Picture?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AlbumBackground.settingKey) private var backgroundChoice = AlbumBackground.standard.rawValue
    @State private var saving = false
    @State private var errorMessage: String?
    private var background: AlbumBackground { AlbumBackground(rawValue: backgroundChoice) ?? .standard }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("このフォルダと、その中のフォルダにある写真から選べます。写真を追加しても、選んだ表紙は変わりません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if pictures.isEmpty {
                        ContentUnavailableView("写真がありません", systemImage: "photo", description: Text("写真を追加してから表紙を選んでください。"))
                    }
                    LazyVGrid(columns: albumGridColumns, spacing: 5) {
                        ForEach(pictures) { picture in
                            Button { choose(picture) } label: {
                                PictureThumbnail(picture: picture).overlay(alignment: .bottomTrailing) {
                                    if selectedID == picture.id.recordName {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.albumAccent).padding(6)
                                    }
                                }
                            }.accessibilityLabel(picture.name).disabled(saving)
                        }
                    }
                }.padding(16)
            }
            .background(background.color)
            .navigationTitle(title + "の表紙").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .primaryAction) {
                    if saving { ProgressView() }
                    else { Button("表紙を解除") { choose(nil) }.disabled(selectedID == nil) }
                }
            }
            .alert("表紙を変更できませんでした", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }.tint(.albumAccent).interactiveDismissDisabled(saving)
    }
    private func choose(_ picture: Picture?) {
        saving = true
        Task {
            defer { saving = false }
            do { try await onSelect(picture); dismiss() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
