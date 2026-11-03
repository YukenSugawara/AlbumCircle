import Foundation
import CloudKit

/// Only controls NEW albums. An existing album keeps its own location.
enum AlbumStorage: String, CaseIterable, Identifiable, Codable {
    case device, iCloud
    var id: String { rawValue }
    var title: String { self == .device ? "端末内" : "iCloud" }
    var icon: String { self == .device ? "iphone" : "icloud" }
    static let settingKey = "newAlbumStorage"
    static let deleteOriginalsKey = "deleteOriginalPhotosAfterImport"
    static var preferred: AlbumStorage {
        AlbumStorage(rawValue: UserDefaults.standard.string(forKey: settingKey) ?? "") ?? .iCloud
    }
}

/// Serialized disk operations; never uploads local files to CloudKit.
actor LocalStore {
    static let shared = LocalStore()
    private let fm = FileManager.default
    private let rootOverride: URL?
    init(rootURL: URL? = nil) { rootOverride = rootURL }
    private struct AlbumInfo: Codable {
        var title: String
        var coverPhotoID: String?
        var coverFolderID: String?
    }
    private struct FolderInfo: Codable {
        var title: String
        var parentID: String?
        var coverPhotoID: String?
    }
    private struct PhotoInfo: Codable {
        var names: [String]
        var kinds: [Int]
        var hashes: [String]
        var date: Date
        var bytes: Int64
        var preview: Data?
        var folderID: String?
        var sourceIdentity: String?
        var rotationQuarterTurns: Int? = nil
        var addedAt: Date? = nil
        var location: PhotoLocation? = nil
    }
    private func root() throws -> URL {
        var url: URL
        if let rootOverride { url = rootOverride }
        else {
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            url = support.appendingPathComponent("LocalAlbums", isDirectory: true)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }
    private func albumURL(_ album: Album) throws -> URL {
        guard album.storage == .device, album.zone.zoneName.hasPrefix("Local-"),
              UUID(uuidString: String(album.zone.zoneName.dropFirst(6))) != nil else {
            throw UserError(message: "本体アルバムの情報が正しくありません。")
        }
        return try root().appendingPathComponent(album.zone.zoneName, isDirectory: true)
    }
    private func makeAlbum(_ folder: URL, _ info: AlbumInfo) -> Album {
        let id = CKRecord.ID(recordName: "album", zoneID: .init(zoneName: folder.lastPathComponent, ownerName: CKCurrentUserDefaultName))
        let record = CKRecord(recordType: "Album", recordID: id)
        record["title"] = info.title as CKRecordValue
        record["coverPhotoID"] = info.coverPhotoID as CKRecordValue?
        record["coverFolderID"] = info.coverFolderID as CKRecordValue?
        return Album(record: record, shared: false, storage: .device)
    }
    func albums() throws -> ReadBatch<Album> {
        let folders = try fm.contentsOfDirectory(at: root(), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var values: [Album] = []
        var skipped = 0
        for folder in folders where folder.lastPathComponent.hasPrefix("Local-") {
            do {
                guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                      UUID(uuidString: String(folder.lastPathComponent.dropFirst(6))) != nil else { continue }
                let info = try JSONDecoder().decode(AlbumInfo.self, from: Data(contentsOf: folder.appendingPathComponent("album.json")))
                values.append(makeAlbum(folder, info))
            } catch { skipped += 1 }
        }
        return ReadBatch(values: values, skipped: skipped)
    }
    func createAlbum(title: String) throws {
        let base = try root()
        let stage = base.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try fm.createDirectory(at: stage.appendingPathComponent("Pictures"), withIntermediateDirectories: true)
        try JSONEncoder().encode(AlbumInfo(title: title)).write(to: stage.appendingPathComponent("album.json"), options: .atomic)
        try fm.moveItem(at: stage, to: base.appendingPathComponent("Local-" + UUID().uuidString))
    }
    func rename(_ album: Album, title: String) throws {
        let url = try albumURL(album).appendingPathComponent("album.json")
        guard fm.fileExists(atPath: url.path) else { throw UserError(message: "アルバムが見つかりません。") }
        var info = try JSONDecoder().decode(AlbumInfo.self, from: Data(contentsOf: url))
        info.title = title
        try JSONEncoder().encode(info).write(to: url, options: .atomic)
    }
    func deleteAlbum(_ album: Album) throws { try fm.removeItem(at: albumURL(album)) }
    private func photoURL(_ id: CKRecord.ID, album: Album) throws -> URL {
        guard id.zoneID == album.zone, id.recordName.count == 64,
              id.recordName.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw UserError(message: "写真の保存情報が正しくありません。")
        }
        return try albumURL(album).appendingPathComponent("Pictures").appendingPathComponent(id.recordName)
    }
    private func record(at folder: URL, album: Album, includeAssets: Bool) throws -> CKRecord {
        let info = try JSONDecoder().decode(PhotoInfo.self, from: Data(contentsOf: folder.appendingPathComponent("photo.json")))
        guard !info.names.isEmpty, info.names.count == info.kinds.count, info.kinds.count == info.hashes.count else {
            throw UserError(message: "写真の保存情報を読み取れませんでした。")
        }
        let result = CKRecord(recordType: "Picture", recordID: .init(recordName: folder.lastPathComponent, zoneID: album.zone))
        result["filename"] = info.names[0] as CKRecordValue
        result["location"] = info.location?.clLocation
        result["takenAt"] = info.date as CKRecordValue
        result["addedAt"] = (info.addedAt ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? info.date) as CKRecordValue
        result["bytes"] = NSNumber(value: info.bytes)
        result["preview"] = info.preview as CKRecordValue?
        result["folderID"] = info.folderID as CKRecordValue?
        result["sourceIdentity"] = info.sourceIdentity as CKRecordValue?
        if let turns = info.rotationQuarterTurns { result["rotationQuarterTurns"] = NSNumber(value: turns) }
        if includeAssets {
            result["names"] = info.names as CKRecordValue
            result["kinds"] = info.kinds.map { NSNumber(value: $0) } as CKRecordValue
            result["hashes"] = info.hashes as CKRecordValue
            result["files"] = info.names.enumerated().map { i, name in
                CKAsset(fileURL: folder.appendingPathComponent(String(i)).appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent))
            } as CKRecordValue
        }
        return result
    }
    func pictures(in album: Album) throws -> ReadBatch<Picture> {
        let folder = try albumURL(album).appendingPathComponent("Pictures")
        let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var values: [Picture] = []
        var skipped = 0
        for child in children {
            do {
                guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                let id = child.lastPathComponent
                guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    skipped += 1; continue
                }
                values.append(Picture(record: try record(at: child, album: album, includeAssets: false)))
            } catch { skipped += 1 }
        }
        values.sort { $0.date == $1.date ? $0.id.recordName < $1.id.recordName : $0.date > $1.date }
        return ReadBatch(values: values, skipped: skipped)
    }
    func save(_ original: Original, into album: Album, folderID: String? = nil) throws -> SaveOutcome {
        try requireFolder(folderID, album: album)
        let id = CKRecord.ID(recordName: original.duplicateIdentity, zoneID: album.zone)
        let destination = try photoURL(id, album: album)
        // Existing duplicate must also be intact before it counts as success.
        if fm.fileExists(atPath: destination.path) {
            let verified = try Original.from(record(at: destination, album: album, includeAssets: true))
            defer { verified.clean() }
            let savedInfo = try JSONDecoder().decode(PhotoInfo.self, from: Data(contentsOf: destination.appendingPathComponent("photo.json")))
            guard (savedInfo.sourceIdentity ?? verified.identity) == original.duplicateIdentity else {
                throw UserError(message: "保存済みの原本を確認できません。元の写真は削除しません。")
            }
            return .alreadyPresent
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".stage-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        for i in original.urls.indices {
            let target = try Original.resourceURL(stage, index: i, name: original.names[i])
            try fm.copyItem(at: original.urls[i], to: target)
            guard try Original.hashFile(target) == original.hashes[i] else {
                throw UserError(message: "本体への保存確認に失敗しました。元の写真は削除しません。")
            }
        }
        let info = PhotoInfo(names: original.names, kinds: original.kinds, hashes: original.hashes,
                             date: original.date, bytes: original.bytes, preview: original.preview, folderID: folderID,
                             sourceIdentity: original.sourceIdentity, addedAt: Date(), location: original.location)
        try JSONEncoder().encode(info).write(to: stage.appendingPathComponent("photo.json"), options: .atomic)
        // Commit only a complete, verified directory on the same volume.
        try fm.moveItem(at: stage, to: destination)
        return .added
    }
    private func folderURL(_ id: String, album: Album) throws -> URL {
        guard id.hasPrefix("Folder-"), UUID(uuidString: String(id.dropFirst(7))) != nil else {
            throw UserError(message: "フォルダの情報が正しくありません。")
        }
        return try albumURL(album).appendingPathComponent("Folders").appendingPathComponent(id + ".json")
    }
    private func requireFolder(_ id: String?, album: Album) throws {
        if let id {
            _ = try JSONDecoder().decode(FolderInfo.self, from: Data(contentsOf: folderURL(id, album: album)))
        }
    }
    func folders(in album: Album) throws -> ReadBatch<PhotoFolder> {
        let directory = try albumURL(album).appendingPathComponent("Folders")
        guard fm.fileExists(atPath: directory.path) else { return ReadBatch(values: [], skipped: 0) }
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var values: [PhotoFolder] = []
        var skipped = 0
        for url in urls where url.pathExtension == "json" {
            do {
                let id = url.deletingPathExtension().lastPathComponent
                guard id.hasPrefix("Folder-"), UUID(uuidString: String(id.dropFirst(7))) != nil else {
                    skipped += 1; continue
                }
                let info = try JSONDecoder().decode(FolderInfo.self, from: Data(contentsOf: url))
                let record = CKRecord(recordType: "Folder", recordID: .init(recordName: id, zoneID: album.zone))
                record["title"] = info.title as CKRecordValue
                record["parentFolderID"] = info.parentID as CKRecordValue?
                record["coverPhotoID"] = info.coverPhotoID as CKRecordValue?
                values.append(PhotoFolder(record: record))
            } catch { skipped += 1 }
        }
        return ReadBatch(values: values, skipped: skipped)
    }
    func contents(in album: Album) throws -> AlbumContents {
        let photos = try pictures(in: album)
        let folders = try folders(in: album)
        return AlbumContents(pictures: photos.values, folders: folders.values, skipped: photos.skipped + folders.skipped)
    }
    @discardableResult
    func createFolder(_ title: String, in album: Album, parentID: String? = nil) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw UserError(message: "フォルダ名を入力してください。") }
        try requireFolder(parentID, album: album)
        let id = "Folder-" + UUID().uuidString
        let url = try folderURL(id, album: album)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(FolderInfo(title: title, parentID: parentID)).write(to: url, options: .atomic)
        return id
    }
    func renameFolder(_ id: String, in album: Album, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw UserError(message: "フォルダ名を入力してください。") }
        let url = try folderURL(id, album: album)
        var info = try JSONDecoder().decode(FolderInfo.self, from: Data(contentsOf: url))
        info.title = title
        try JSONEncoder().encode(info).write(to: url, options: .atomic)
    }
    func setCover(_ picture: Picture?, in album: Album, folderID: String? = nil) throws {
        if let picture {
            let contents = try contents(in: album)
            guard picture.id.zoneID == album.zone,
                  contents.cover(picture.id.recordName, in: folderID) != nil else {
                throw UserError(message: "このフォルダ内の写真を選択してください。")
            }
        }
        if let folderID {
            let url = try folderURL(folderID, album: album)
            var info = try JSONDecoder().decode(FolderInfo.self, from: Data(contentsOf: url))
            info.coverPhotoID = picture?.id.recordName
            try JSONEncoder().encode(info).write(to: url, options: .atomic)
        } else {
            let url = try albumURL(album).appendingPathComponent("album.json")
            var info = try JSONDecoder().decode(AlbumInfo.self, from: Data(contentsOf: url))
            info.coverPhotoID = picture?.id.recordName
            info.coverFolderID = nil
            try JSONEncoder().encode(info).write(to: url, options: .atomic)
        }
    }
    func setAlbumCoverFolder(_ folderID: String, in album: Album) throws {
        try requireFolder(folderID, album: album)
        let url = try albumURL(album).appendingPathComponent("album.json")
        var info = try JSONDecoder().decode(AlbumInfo.self, from: Data(contentsOf: url))
        info.coverPhotoID = nil
        info.coverFolderID = folderID
        try JSONEncoder().encode(info).write(to: url, options: .atomic)
    }
    func download(_ picture: Picture, album: Album) throws -> Original {
        try Original.from(record(at: photoURL(picture.id, album: album), album: album, includeAssets: true))
    }
    func setRotation(_ quarterTurns: Int, for picture: Picture, in album: Album) throws {
        guard (0..<4).contains(quarterTurns) else {
            throw UserError(message: "写真の回転情報が正しくありません。")
        }
        let folder = try photoURL(picture.id, album: album)
        let url = folder.appendingPathComponent("photo.json")
        var info = try JSONDecoder().decode(PhotoInfo.self, from: Data(contentsOf: url))
        info.rotationQuarterTurns = quarterTurns
        try JSONEncoder().encode(info).write(to: url, options: .atomic)
    }
    func move(_ pictures: [Picture], in album: Album, to folderID: String?) throws {
        try requireFolder(folderID, album: album)
        // Validate the entire selection before writing any metadata. Originals stay in place.
        let changes = try pictures.map { picture -> (URL, Data) in
            let url = try photoURL(picture.id, album: album).appendingPathComponent("photo.json")
            var info = try JSONDecoder().decode(PhotoInfo.self, from: Data(contentsOf: url))
            info.folderID = folderID
            return (url, try JSONEncoder().encode(info))
        }
        for (url, data) in changes { try data.write(to: url, options: .atomic) }
    }
    func delete(_ picture: Picture, album: Album) throws {
        try fm.removeItem(at: photoURL(picture.id, album: album))
    }
}
