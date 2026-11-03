import SwiftUI
import MapKit
import CloudKit

struct PhotoMapGroup: Identifiable {
    let id: String
    let location: PhotoLocation
    var pictures: [Picture]
    static func make(_ pictures: [Picture], locations: [CKRecord.ID: PhotoLocation]) -> [PhotoMapGroup] {
        var groups: [String: PhotoMapGroup] = [:]
        for picture in pictures {
            guard let location = locations[picture.id] ?? picture.location,
                  location.latitude.isFinite, location.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(location.coordinate) else { continue }
            // Group photos taken within roughly ten meters, including identical coordinates.
            let key = "\(Int((location.latitude * 10000).rounded()))/\(Int((location.longitude * 10000).rounded()))"
            if groups[key] != nil { groups[key]?.pictures.append(picture) }
            else { groups[key] = PhotoMapGroup(id: key, location: location, pictures: [picture]) }
        }
        return groups.values.sorted { $0.id < $1.id }
    }
}

struct PhotoMapView: View {
    let pictures: [Picture]
    let album: Album
    let editable: Bool
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CloudStore.shared
    @State private var locations: [CKRecord.ID: PhotoLocation] = [:]
    @State private var checked: Set<CKRecord.ID> = []
    @State private var removed: Set<CKRecord.ID> = []
    @State private var selectedGroup: String?
    @State private var preview: PhotoPreviewSelection?
    @State private var position: MapCameraPosition = .automatic
    @State private var reading = false
    @State private var scanID = 0
    @State private var scanned = 0
    @State private var failures = 0
    @State private var message: String?
    private var visible: [Picture] { pictures.filter { !removed.contains($0.id) } }
    private var groups: [PhotoMapGroup] { PhotoMapGroup.make(visible, locations: locations) }
    private var unknown: [Picture] {
        visible.filter { $0.location == nil && locations[$0.id] == nil && !checked.contains($0.id) }
    }
    private var selectedPictures: [Picture] { groups.first { $0.id == selectedGroup }?.pictures ?? [] }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if groups.isEmpty {
                    ContentUnavailableView("撮影場所がありません", systemImage: "map",
                        description: Text("位置情報付きの写真を地図に表示します。以前追加した写真は下のボタンから確認できます。"))
                } else {
                    Map(position: $position) {
                        ForEach(groups) { group in
                            Annotation("\(group.pictures.count)枚", coordinate: group.location.coordinate) {
                                Button { selectedGroup = group.id } label: {
                                    Label("\(group.pictures.count)", systemImage: "photo.fill")
                                        .padding(9).foregroundStyle(.white)
                                        .background(selectedGroup == group.id ? Color.orange : Color.albumAccent, in: Capsule())
                                }.accessibilityLabel("この撮影場所の写真\(group.pictures.count)枚を表示")
                            }
                        }
                    }
                    .mapControls { MapCompass(); MapScaleView() }
                }
                if !selectedPictures.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(selectedPictures) { picture in
                                Button { preview = PhotoPreviewSelection(picture: picture, pictures: selectedPictures) } label: {
                                    VStack {
                                        PictureThumbnail(picture: picture).frame(width: 88, height: 88)
                                        Text(picture.name).font(.caption).lineLimit(1).frame(width: 88)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding(12)
                    }.frame(height: 132)
                }
                VStack(spacing: 6) {
                    Text("撮影場所あり：\(groups.reduce(0) { $0 + $1.pictures.count })／\(visible.count)枚")
                        .font(.footnote).foregroundStyle(.secondary)
                    if reading {
                        ProgressView("原本の位置情報を確認中… \(scanned)枚")
                        Button("確認を停止") { reading = false; scanID += 1 }
                    } else if !unknown.isEmpty {
                        Button("既存写真の撮影場所を読み込む（\(unknown.count)枚）") {
                            scanned = 0; failures = 0; reading = true; scanID += 1
                        }
                        Text("位置情報未確認の原本をダウンロードします。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if failures > 0 { Text("\(failures)枚を読み込めませんでした。再度確認できます。").font(.caption) }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }.padding(12)
            }
            .navigationTitle("撮影場所から探す").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("全体を表示") { position = .automatic } }
            }
            .task(id: scanID) { if reading { await readLocations() } }
            .fullScreenCover(item: $preview, onDismiss: { Task { await refreshPhotos() } }) { selection in
                PictureView(pictures: selection.pictures, initialID: selection.initialID, album: album, editable: editable)
            }
            .onChange(of: store.accountEpoch) { _, _ in if album.storage == .iCloud { dismiss() } }
        }
    }
    private func readLocations() async {
        let epoch = store.accountEpoch
        let generation = scanID
        defer { if generation == scanID { reading = false } }
        for picture in unknown {
            guard !Task.isCancelled, generation == scanID,
                  album.storage == .device || epoch == store.accountEpoch else { return }
            do {
                let original = try await store.download(picture, album: album)
                defer { original.clean() }
                try store.checkAccount(epoch, for: album)
                try Task.checkCancellation()
                guard generation == scanID else { return }
                if let location = original.location { locations[picture.id] = location }
                checked.insert(picture.id)
            } catch {
                if Task.isCancelled || generation != scanID { return }
                failures += 1
            }
            scanned += 1
        }
        position = .automatic
    }
    private func refreshPhotos() async {
        do {
            let epoch = store.accountEpoch
            let latest = try await store.contents(in: album)
            try store.checkAccount(epoch, for: album)
            let ids = Set(latest.pictures.map(\.id))
            removed = Set(pictures.map(\.id)).subtracting(ids)
        } catch { message = "一覧を更新できませんでした。" + error.localizedDescription }
    }
}
