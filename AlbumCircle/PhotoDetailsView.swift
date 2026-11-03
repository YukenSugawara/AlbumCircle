import SwiftUI
import CloudKit
import ImageIO
import MapKit
import UniformTypeIdentifiers

struct PhotoDetailsView: View {
    let picture: Picture
    let album: Album
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CloudStore.shared
    @State private var folderPath = "確認中…"
    @State private var pixelSize: String?
    @State private var location: PhotoLocation?
    @State private var format: String?
    @State private var resourceCount: Int?
    @State private var loading = true
    @State private var issue: String?
    @State private var retry = 0
    var body: some View {
        NavigationStack {
            List {
                Section("写真") {
                    row("ファイル名", picture.name)
                    row("形式", format ?? "確認中…")
                    row("撮影日", picture.date == .distantPast ? "不明" : picture.date.formatted(date: .long, time: .shortened))
                    row("追加日", picture.record["addedAt"] == nil && picture.record.creationDate == nil ? "不明" : picture.addedAt.formatted(date: .long, time: .shortened))
                    row("容量", ByteCountFormatter.string(fromByteCount: picture.bytes, countStyle: .file))
                    if let pixelSize { row("原本の画像サイズ", pixelSize) }
                    if let resourceCount { row("原本ファイル数", "\(resourceCount)") }
                }
                Section("撮影場所") {
                    if let location = location ?? picture.location {
                        row("緯度", String(format: "%.6f", location.latitude))
                        row("経度", String(format: "%.6f", location.longitude))
                        Map(initialPosition: .region(MKCoordinateRegion(center: location.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))) {
                            Marker("撮影場所", coordinate: location.coordinate)
                        }
                        .frame(height: 220)
                        .accessibilityLabel("写真の撮影場所")
                    } else {
                        Text(loading ? "位置情報を確認中…" : (resourceCount == nil ? "位置情報を確認できませんでした" : "位置情報がありません"))
                            .foregroundStyle(.secondary)
                    }
                }
                Section("保存場所") {
                    row("保存先", album.storage.title)
                    row("アルバム", store.albums.first(where: { $0.id == album.id })?.title ?? album.title)
                    row("フォルダ", folderPath)
                    row("共有", album.shared || album.record.share != nil ? "共有アルバム" : "共有なし")
                }
                if loading { ProgressView("画像情報を確認中…") }
                if let issue {
                    Section {
                        Text(issue).font(.footnote).foregroundStyle(.secondary)
                        Button("再試行") { retry += 1 }.disabled(loading)
                    }
                }
            }
            .textSelection(.enabled)
            .navigationTitle("写真の詳細").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .task(id: retry) { await load() }
            .onChange(of: store.accountEpoch) { _, _ in if album.storage == .iCloud { dismiss() } }
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value.isEmpty ? "不明" : value).multilineTextAlignment(.trailing) }
    }
    private func load() async {
        loading = true; issue = nil
        defer { loading = false }
        let epoch = store.accountEpoch
        do {
            let contents = try await store.contents(in: album)
            try store.checkAccount(epoch, for: album)
            try Task.checkCancellation()
            let current = contents.pictures.first(where: { $0.id == picture.id }) ?? picture
            var names: [String] = [], parent = current.folderID, visited = Set<String>()
            while let id = parent, visited.insert(id).inserted {
                guard let folder = contents.folders.first(where: { $0.id == id }) else { names.insert("不明なフォルダ", at: 0); break }
                names.insert(folder.title, at: 0); parent = folder.parentID
            }
            folderPath = names.isEmpty ? "アルバム直下" : names.joined(separator: " / ")
        } catch {
            if Task.isCancelled { return }
            folderPath = "確認できませんでした"
            issue = error.localizedDescription
        }
        do {
            try Task.checkCancellation()
            let original = try await store.download(picture, album: album)
            defer { original.clean() }
            try store.checkAccount(epoch, for: album)
            try Task.checkCancellation()
            resourceCount = original.urls.count
            location = original.location ?? picture.location
            if let url = original.urls.first,
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let type = CGImageSourceGetType(source) {
                format = UTType(type as String)?.preferredFilenameExtension?.uppercased() ?? (type as String)
            } else { format = "不明" }
            if let url = original.urls.first,
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
               let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                pixelSize = "\(width.intValue) × \(height.intValue) px"
            } else { pixelSize = "この形式では取得できません" }
        } catch {
            if !Task.isCancelled { format = "確認できませんでした"; issue = "原本の画像情報を確認できませんでした。\n" + error.localizedDescription }
        }
    }
}
