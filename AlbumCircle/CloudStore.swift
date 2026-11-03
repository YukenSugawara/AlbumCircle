import Foundation
import CloudKit
import Combine
import UIKit
import CryptoKit
import CoreLocation

struct Album: Identifiable {
    let record: CKRecord
    let shared: Bool
    var storage: AlbumStorage = .iCloud
    var id: String { "\(record.recordID.zoneID.ownerName)/\(record.recordID.zoneID.zoneName)" }
    var title: String { (record["title"] as? String) ?? "アルバム" }
    var coverPhotoID: String? {
        guard let value = record["coverPhotoID"] as? String, !value.hasPrefix("Folder-") else { return nil }
        return value
    }
    var coverFolderID: String? {
        if let value = record["coverPhotoID"] as? String, value.hasPrefix("Folder-") { return value }
        return record["coverFolderID"] as? String // Local albums store the two choices separately.
    }
    var zone: CKRecordZone.ID { record.recordID.zoneID }
}
struct Picture: Identifiable {
    let record: CKRecord
    var id: CKRecord.ID { record.recordID }
    var location: PhotoLocation? { (record["location"] as? CLLocation).flatMap(PhotoLocation.init) }
    var name: String { (record["filename"] as? String) ?? "写真" }
    var date: Date { (record["takenAt"] as? Date) ?? record.creationDate ?? .distantPast }
    var addedAt: Date { (record["addedAt"] as? Date) ?? record.creationDate ?? date }
    var creatorID: String? { record.creatorUserRecordID?.recordName ?? record["creatorID"] as? String }
    var bytes: Int64 { (record["bytes"] as? NSNumber)?.int64Value ?? 0 }
    var preview: Data? { record["preview"] as? Data }
    var folderID: String? { record["folderID"] as? String }
    var rotationQuarterTurns: Int {
        let value = (record["rotationQuarterTurns"] as? NSNumber)?.intValue ?? 0
        return (value % 4 + 4) % 4
    }
}
enum SaveOutcome { case added, alreadyPresent }

struct ReadBatch<Value> {
    let values: [Value]
    let skipped: Int
}

struct ShareSheet: Identifiable {
    let id = UUID()
    let share: CKShare
}
struct UserError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ContentsSnapshot {
    var value: AlbumContents
    var records: [CKRecord.ID: CKRecord] = [:]
    var token: CKServerChangeToken?
    var date = Date()
    var changed = false
}

@MainActor
final class CloudStore: ObservableObject {
    static let shared = CloudStore()
    // Change this identifier together with the entitlements and Xcode iCloud capability.
    lazy var container = CKContainer(identifier: "iCloud.com.example.AlbumCircle")
    @Published var albums: [Album] = []
    @Published var errorMessage: String?
    @Published var busy = false
    @Published var progress = ""
    @Published var revision = UUID() {
        didSet {
            // Keep zone change tokens so the next refresh downloads only changed records.
            for id in Array(contentsCache.keys) { contentsCache[id]?.date = .distantPast }
            editPermissionCache.removeAll()
            validatedFolders.removeAll()
            inFlightContents.removeAll()
            inFlightPreviews.removeAll()
        }
    }
    @Published private(set) var contentsRevision = UUID()
    @Published private(set) var contentsCheckID = UUID()
    @Published var cloudStatus: String?
    @Published var localStatus: String?
    @Published private(set) var initialLoadFinished = false
    @Published private(set) var accountEpoch = 0
    @Published var importCanStop = false
    @Published private(set) var stopRequested = false
    @Published private(set) var backgroundExpired = false
    private var importBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var refreshing = false
    private var refreshAgain = false
    private var cloudAccountID: String?
    func personalPhotoScope(for album: Album) -> String? {
        personalPhotoScope(albumID: album.id, storage: album.storage)
    }
    func personalPhotoScope(albumID: String, storage: AlbumStorage) -> String? {
        if storage == .device { return NewPhotoTracker.scope(account: "device", album: albumID) }
        guard let cloudAccountID else { return nil }
        return NewPhotoTracker.scope(account: cloudAccountID, album: albumID)
    }
    func newPhotoScope(for album: Album) -> String? {
        guard album.storage == .iCloud, album.shared || album.record.share != nil,
              let account = cloudAccountID else { return nil }
        return NewPhotoTracker.scope(account: account, album: album.id)
    }
    private func observeNewPhotos(_ pictures: [Picture], in album: Album) {
        guard let scope = newPhotoScope(for: album) else { return }
        let own = Set(pictures.filter { $0.creatorID == cloudAccountID || $0.creatorID == CKCurrentUserDefaultName }.map { $0.id.recordName })
        NewPhotoTracker.shared.observe(ids: Set(pictures.map { $0.id.recordName }), ownIDs: own, scope: scope)
    }
    private let metadataCache = CloudMetadataCache()
    private var contentsCache: [String: ContentsSnapshot] = [:]
    private var contentsWriteEpoch: [String: Int] = [:]
    private var unavailableSharedIDs: Set<String> = []
    private var inFlightContents: [String: (id: UUID, task: Task<AlbumContents, Error>)] = [:]
    private var inFlightPreviews: [String: UUID] = [:]
    private var editPermissionCache: [String: (allowed: Bool, date: Date)] = [:]
    private var validatedFolders: Set<CKRecord.ID> = []
    private let photoImportGate = PhotoImportGate()

    private func keepContents(_ snapshot: ContentsSnapshot, for album: Album, revisionAtStart: UUID) {
        guard revisionAtStart == revision else { return }
        if contentsCache[album.id] == nil, contentsCache.count >= 12,
           let oldest = contentsCache.min(by: { $0.value.date < $1.value.date })?.key {
            contentsCache.removeValue(forKey: oldest)
        }
        contentsCache[album.id] = snapshot
    }

    private func database(for album: Album) -> CKDatabase {
        album.shared ? container.sharedCloudDatabase : container.privateCloudDatabase
    }
    func report(_ error: Error) {
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated: errorMessage = "iPhoneの設定でiCloudにサインインしてください。"
            case .networkFailure, .networkUnavailable: errorMessage = "通信できませんでした。接続を確認して、もう一度お試しください。"
            case .quotaExceeded: errorMessage = "保存容量が不足しています。アルバム所有者のiCloud容量を確認してください。"
            case .permissionFailure: errorMessage = "このアルバムを操作する権限がありません。共有メンバー・権限を確認してください。"
            case .serverRecordChanged: errorMessage = "別の端末で更新されました。更新してからやり直してください。"
            default: errorMessage = ck.localizedDescription
            }
        } else { errorMessage = error.localizedDescription }
    }
    func requestStop() { stopRequested = true; backgroundExpired = false }
    func expireImport() { stopRequested = true; backgroundExpired = true }
    func beginImport() {
        stopRequested = false
        backgroundExpired = false
        importCanStop = true
        guard importBackgroundTask == .invalid else { return }
        importBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "写真を保存中") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.expireImport()
                self.finishImportBackgroundTask()
            }
        }
    }
    private func finishImportBackgroundTask() {
        let task = importBackgroundTask
        importBackgroundTask = .invalid
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
    func endImport() {
        finishImportBackgroundTask()
        importCanStop = false
        stopRequested = false
    }
    func checkAccount(_ epoch: Int, for album: Album) throws {
        if album.storage == .iCloud && accountEpoch != epoch {
            throw UserError(message: "iCloudアカウントが変更されました。更新してからやり直してください。元の写真は残しています。")
        }
    }
    func perform(_ title: String, action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        progress = title
        defer { busy = false; progress = "" }
        do { try await action() } catch { report(error) }
    }
    private func publish(_ values: [Album]) {
        let sorted = values.filter { !$0.shared || !unavailableSharedIDs.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let validIDs = Set(sorted.map(\.id))
        contentsCache = contentsCache.filter { validIDs.contains($0.key) }
        contentsWriteEpoch = contentsWriteEpoch.filter { validIDs.contains($0.key) }
        guard !sameAlbums(albums, sorted) else { return }
        albums = sorted
        revision = UUID()
    }
    private func readLocalAlbums() async -> [Album]? {
        do {
            let local = try await LocalStore.shared.albums()
            localStatus = local.skipped == 0 ? nil : "本体の\(local.skipped)件のアルバム情報を読み取れませんでした。データは削除せず残しています。"
            return local.values
        } catch { report(error); return nil }
    }
    private func refreshLocalAlbums() async {
        if let local = await readLocalAlbums() {
            publish(local + albums.filter { $0.storage == .iCloud })
        }
    }
    private func sameAlbums(_ first: [Album], _ second: [Album]) -> Bool {
        let a = first.sorted { $0.id < $1.id }, b = second.sorted { $0.id < $1.id }
        return a.count == b.count && zip(a, b).allSatisfy { left, right in
            left.id == right.id && left.title == right.title && left.coverPhotoID == right.coverPhotoID &&
            left.coverFolderID == right.coverFolderID &&
            left.storage == right.storage && left.shared == right.shared &&
            left.record.share?.recordID == right.record.share?.recordID
        }
    }
    static func reconciledAlbums(local: [Album], previous: [Album],
                                 owned: Result<[Album], Error>, shared: Result<[Album], Error>) -> [Album] {
        let ownedAlbums: [Album]
        switch owned {
        case .success(let values): ownedAlbums = values
        case .failure: ownedAlbums = previous.filter { $0.storage == .iCloud && !$0.shared }
        }
        let sharedAlbums: [Album]
        switch shared {
        case .success(let values): sharedAlbums = values
        case .failure: sharedAlbums = previous.filter { $0.storage == .iCloud && $0.shared }
        }
        return local + ownedAlbums + sharedAlbums
    }
    private static func isRevokedShareError(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        switch ck.code {
        case .unknownItem, .zoneNotFound, .userDeletedZone, .permissionFailure: return true
        case .partialFailure:
            guard let failures = ck.partialErrorsByItemID, !failures.isEmpty else { return false }
            return failures.values.allSatisfy { isRevokedShareError($0) }
        default: return false
        }
    }
    private static func isCancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? CKError)?.code == .operationCancelled
    }
    private static func shouldCheckAlbumRoots(_ error: Error, shared: Bool) -> Bool {
        guard let ck = error as? CKError else { return false }
        switch ck.code {
        case .partialFailure, .batchRequestFailed, .operationCancelled, .unknownItem, .zoneNotFound,
             .userDeletedZone: return true
        case .permissionFailure: return shared
        default: return false
        }
    }
    func forgetUnavailableShare(_ album: Album, error: Error) async {
        guard album.shared, Self.isRevokedShareError(error) else { return }
        unavailableSharedIDs.insert(album.id)
        guard albums.contains(where: { $0.id == album.id }) else { return }
        publish(albums.filter { $0.id != album.id })
        if let accountID = cloudAccountID {
            await metadataCache.saveAlbums(albums.filter { $0.storage == .iCloud }, accountID: accountID)
        }
    }
    private func album(from result: Result<CKRecord, Error>, shared: Bool) throws -> Album? {
        switch result {
        case .success(let record):
            guard record.recordType == "Album" else {
                throw UserError(message: "アルバムの情報を読み取れませんでした。")
            }
            return Album(record: record, shared: shared)
        case .failure(let error):
            if let ck = error as? CKError,
               ck.code == .unknownItem || ck.code == .zoneNotFound ||
               (shared && Self.isRevokedShareError(error)) {
                return nil
            }
            throw error
        }
    }
    private func singleCloudAlbum(_ id: CKRecord.ID, in db: CKDatabase, shared: Bool) async throws -> Album? {
        let results = try await db.records(for: [id], desiredKeys: ["title", "coverPhotoID"])
        guard let result = results[id] else { throw UserError(message: "アルバムの一覧を確認できませんでした。") }
        return try album(from: result, shared: shared)
    }
    private func checkedCloudAlbum(_ id: CKRecord.ID, in db: CKDatabase, shared: Bool) async throws -> Album? {
        do { return try await singleCloudAlbum(id, in: db, shared: shared) }
        catch {
            // An operation cancellation alone does not confirm that access was removed.
            if Self.isCancelled(error),
               let previous = albums.first(where: { $0.storage == .iCloud && $0.shared == shared &&
                   $0.record.recordID == id }) { return previous }
            throw error
        }
    }
    private func cloudAlbums(in db: CKDatabase, shared: Bool) async throws -> [Album] {
        let zones: [CKRecordZone]
        do { zones = try await db.allRecordZones() }
        catch {
            guard shared, let ck = error as? CKError,
                  ck.code == .operationCancelled || ck.code == .partialFailure else { throw error }
            // A revoked zone may interrupt the zone list. Confirm each previously
            // accessible root before deciding which cached shares to retain.
            let known = albums.filter { $0.storage == .iCloud && $0.shared }
            guard !known.isEmpty else { throw error }
            var available: [Album] = []
            for album in known {
                if let item = try await checkedCloudAlbum(album.record.recordID, in: db, shared: true) {
                    available.append(item)
                }
            }
            return available
        }
        let ids = zones.filter { $0.zoneID.zoneName.hasPrefix("Album-") }
            .map { CKRecord.ID(recordName: "album", zoneID: $0.zoneID) }
        guard !ids.isEmpty else { return [] }
        // One batch per database avoids a network round trip for every album.
        let results: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            results = try await db.records(for: ids, desiredKeys: ["title", "coverPhotoID"])
        } catch {
            guard Self.shouldCheckAlbumRoots(error, shared: shared) else { throw error }
            // A withdrawn share can cancel a batched request. Check each root so
            // one inaccessible zone does not hide the other albums.
            var available: [Album] = []
            for id in ids {
                if let item = try await checkedCloudAlbum(id, in: db, shared: shared) { available.append(item) }
            }
            return available
        }
        var albums: [Album] = []
        for id in ids {
            if let result = results[id] {
                if case .failure(let error) = result, Self.isCancelled(error) {
                    if let item = try await checkedCloudAlbum(id, in: db, shared: shared) { albums.append(item) }
                } else if let item = try album(from: result, shared: shared) { albums.append(item) }
            } else if let item = try await checkedCloudAlbum(id, in: db, shared: shared) {
                albums.append(item)
            }
        }
        return albums
    }
    private func cloudAlbumsResult(in db: CKDatabase, shared: Bool) async -> Result<[Album], Error> {
        do { return .success(try await cloudAlbums(in: db, shared: shared)) }
        catch { return .failure(error) }
    }
    func refresh() async {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false; initialLoadFinished = true }
        var retriedCancellation = false
        repeat {
            refreshAgain = false
            let epoch = accountEpoch
            let local = await readLocalAlbums() ?? albums.filter { $0.storage == .device }
            let currentLocal = albums.filter { $0.storage == .device }
            if !sameAlbums(local, currentLocal) {
                publish(local + albums.filter { $0.storage == .iCloud })
            }
            do {
                let status = try await container.accountStatus()
                guard epoch == accountEpoch else { refreshAgain = true; continue }
                guard status == .available else {
                    cloudAccountID = nil
                    publish(local)
                    cloudStatus = "iCloud保存・共有には、iPhoneの設定でiCloudへのサインインが必要です。本体保存は利用できます。"
                    continue
                }
                async let account = container.userRecordID()
                async let owned = cloudAlbumsResult(in: container.privateCloudDatabase, shared: false)
                async let shared = cloudAlbumsResult(in: container.sharedCloudDatabase, shared: true)
                let resolvedAccount = (try? await account)?.recordName
                guard epoch == accountEpoch else { refreshAgain = true; continue }
                cloudAccountID = resolvedAccount
                let revisionBeforeCache = revision
                if let resolvedAccount, !albums.contains(where: { $0.storage == .iCloud }),
                   let savedAlbums = await metadataCache.loadAlbums(accountID: resolvedAccount) {
                    guard epoch == accountEpoch, revision == revisionBeforeCache else {
                        refreshAgain = true; continue
                    }
                    publish(local + savedAlbums)
                }
                let revisionBeforeList = revision
                let (ownedResult, sharedResult) = await (owned, shared)
                guard epoch == accountEpoch, revision == revisionBeforeList else {
                    refreshAgain = true; continue
                }
                if case .success(let accessible) = sharedResult {
                    let validSharedIDs = Set(accessible.map(\.id))
                    unavailableSharedIDs.subtract(validSharedIDs)
                    for prior in albums where prior.shared && !validSharedIDs.contains(prior.id) {
                        unavailableSharedIDs.insert(prior.id)
                    }
                }
                let result = Self.reconciledAlbums(local: local, previous: albums,
                                                   owned: ownedResult, shared: sharedResult)
                publish(result)
                let publishedRevision = revision
                // Only views currently on screen need to check their zone now.
                contentsCheckID = UUID()
                if let resolvedAccount {
                    await metadataCache.saveAlbums(albums.filter { $0.storage == .iCloud }, accountID: resolvedAccount)
                }
                guard epoch == accountEpoch, revision == publishedRevision else {
                    refreshAgain = true; continue
                }
                let errors = [ownedResult, sharedResult].compactMap { read -> Error? in
                    if case .failure(let error) = read { return error }
                    return nil
                }
                if !retriedCancellation && errors.contains(where: { Self.isCancelled($0) }) {
                    retriedCancellation = true
                    refreshAgain = true
                }
                if let error = errors.first(where: { !Self.isCancelled($0) }) {
                    cloudStatus = "iCloudの更新に失敗しました。本体保存は利用できます。\n" + error.localizedDescription
                } else { cloudStatus = nil }
            } catch {
                guard epoch == accountEpoch else { refreshAgain = true; continue }
                if Self.isCancelled(error) && !retriedCancellation {
                    retriedCancellation = true
                    refreshAgain = true
                }
                cloudStatus = Self.isCancelled(error) ? nil :
                    "iCloudの更新に失敗しました。本体保存は利用できます。\n" + error.localizedDescription
            }
        } while refreshAgain
    }
    func albumsForBackup() async throws -> [Album] {
        while refreshing { try await Task.sleep(nanoseconds: 50_000_000); try Task.checkCancellation() }
        await refresh()
        try Task.checkCancellation()
        if let cloudStatus { throw UserError(message: cloudStatus) }
        let local = try await LocalStore.shared.albums()
        guard local.skipped == 0 else { throw UserError(message: "端末内のアルバムをすべて読み取れませんでした。") }
        // A backup must never silently use an old cached album list after a failed refresh.
        async let owned = cloudAlbums(in: container.privateCloudDatabase, shared: false)
        async let shared = cloudAlbums(in: container.sharedCloudDatabase, shared: true)
        return try await local.values + owned + shared
    }
    func accountChanged() async {
        accountEpoch += 1
        unavailableSharedIDs.removeAll()
        ThumbnailCache.shared.removeAll()
        HighResPhotoCache.shared.removeAll()
        contentsCache.removeAll()
        contentsWriteEpoch.removeAll()
        inFlightPreviews.removeAll()
        cloudAccountID = nil
        await metadataCache.clear()
        editPermissionCache.removeAll()
        publish(albums.filter { $0.storage == .device })
        await refresh()
    }
    func createAlbum(_ title: String, storage: AlbumStorage = .preferred) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if storage == .device {
            try await LocalStore.shared.createAlbum(title: title)
            await refreshLocalAlbums()
            return
        }
        let db = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: "Album-" + UUID().uuidString)
        _ = try await db.save(zone)
        let record = CKRecord(recordType: "Album", recordID: .init(recordName: "album", zoneID: zone.zoneID))
        record["title"] = title as CKRecordValue
        _ = try await db.save(record)
        await refresh()
    }
    func rename(_ album: Album, title: String) async throws {
        guard !album.shared else { throw UserError(message: "名前を変更できるのは所有者だけです。") }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw UserError(message: "アルバム名を入力してください。") }
        if album.storage == .device {
            try await LocalStore.shared.rename(album, title: title)
            await refreshLocalAlbums()
            return
        }
        let record = try await database(for: album).record(for: album.record.recordID)
        record["title"] = title.trimmingCharacters(in: .whitespacesAndNewlines) as CKRecordValue
        _ = try await database(for: album).save(record)
        await refresh()
    }
    func deleteAlbum(_ album: Album) async throws {
        if album.storage == .device {
            try await LocalStore.shared.deleteAlbum(album)
            await refreshLocalAlbums()
            return
        }
        guard !album.shared else { throw UserError(message: "共有への参加解除はメンバー管理から行ってください。") }
        _ = try await container.privateCloudDatabase.deleteRecordZone(withID: album.zone)
        await refresh()
    }
    func canEdit(_ album: Album) async throws -> Bool {
        if !album.shared { return true }
        if let cached = editPermissionCache[album.id], Date().timeIntervalSince(cached.date) < 90 {
            return cached.allowed
        }
        let epoch = accountEpoch
        let root = try await database(for: album).record(for: album.record.recordID)
        guard let id = root.share?.recordID,
              let share = try await database(for: album).record(for: id) as? CKShare else {
            try checkAccount(epoch, for: album)
            return false
        }
        try checkAccount(epoch, for: album)
        let allowed = share.currentUserParticipant?.permission == .readWrite
        editPermissionCache[album.id] = (allowed, Date())
        return allowed
    }
    func share(for album: Album) async throws -> CKShare {
        guard album.storage == .iCloud else {
            throw UserError(message: "共有できるのはiCloud保存のアルバムだけです。設定で保存先をiCloudにして、新しいアルバムを作成してください。")
        }
        let epoch = accountEpoch
        let db = database(for: album)
        let root = try await db.record(for: album.record.recordID)
        if let ref = root.share {
            let record = try await db.record(for: ref.recordID)
            if let share = record as? CKShare {
                try checkAccount(epoch, for: album)
                return share
            }
        }
        try checkAccount(epoch, for: album)
        guard !album.shared else { throw UserError(message: "共有情報を取得できませんでした。更新してください。") }
        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = album.title as CKRecordValue
        share.publicPermission = .none
        let result = try await db.modifyRecords(saving: [root, share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        for value in result.saveResults.values { _ = try value.get() }
        guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare else {
            throw UserError(message: "共有情報を保存できませんでした。")
        }
        try checkAccount(epoch, for: album)
        return saved
    }
    func accept(_ metadata: CKShare.Metadata) async {
        do {
            guard metadata.containerIdentifier == container.containerIdentifier else { throw UserError(message: "このアプリの招待ではありません。") }
            _ = try await container.accept(metadata)
            unavailableSharedIDs.removeAll()
            await refresh()
        } catch { report(error) }
    }
    func pictures(in album: Album) async throws -> ReadBatch<Picture> {
        let result = try await contents(in: album)
        return ReadBatch(values: result.pictures, skipped: result.skipped)
    }
    func contents(in album: Album, forceRefresh: Bool = false) async throws -> AlbumContents {
        if !forceRefresh, let cached = contentsCache[album.id] {
            // Display cached thumbnails immediately, then look for other members' edits.
            if album.storage == .iCloud && Date().timeIntervalSince(cached.date) >= 10 {
                revalidateContents(in: album)
            }
            return cached.value
        }
        if !forceRefresh, album.storage == .iCloud, let accountID = cloudAccountID,
           let cached = await metadataCache.load(album: album, accountID: accountID) {
            guard cloudAccountID == accountID, albums.contains(where: { $0.id == album.id }) else {
                throw CancellationError()
            }
            keepContents(cached, for: album, revisionAtStart: revision)
            revalidateContents(in: album)
            return cached.value
        }
        if let active = inFlightContents[album.id] { return try await active.task.value }
        let id = UUID(), revisionAtStart = revision
        let task = Task<AlbumContents, Error> { [self] in
            try await fetchContents(in: album, revisionAtStart: revisionAtStart)
        }
        inFlightContents[album.id] = (id, task)
        defer { if inFlightContents[album.id]?.id == id { inFlightContents.removeValue(forKey: album.id) } }
        return try await task.value
    }
    func checkForUpdates(in album: Album) {
        guard album.storage == .iCloud, contentsCache[album.id] != nil else { return }
        revalidateContents(in: album)
    }
    private func revalidateContents(in album: Album) {
        guard inFlightContents[album.id] == nil else { return }
        let id = UUID(), revisionAtStart = revision
        let task = Task<AlbumContents, Error> { [self] in
            try await fetchContents(in: album, revisionAtStart: revisionAtStart)
        }
        inFlightContents[album.id] = (id, task)
        Task { [self] in
            do { _ = try await task.value }
            catch { await forgetUnavailableShare(album, error: error) }
            if inFlightContents[album.id]?.id == id { inFlightContents.removeValue(forKey: album.id) }
        }
    }
    private func fetchContents(in album: Album, revisionAtStart: UUID) async throws -> AlbumContents {
        let writeEpoch = contentsWriteEpoch[album.id, default: 0]
        if album.storage == .device {
            let previous = contentsCache[album.id]
            let result = try await LocalStore.shared.contents(in: album)
            guard revisionAtStart == revision else { throw CancellationError() }
            if writeEpoch != contentsWriteEpoch[album.id, default: 0], let current = contentsCache[album.id] {
                return current.value
            }
            keepContents(ContentsSnapshot(value: result), for: album, revisionAtStart: revisionAtStart)
            if previous != nil { contentsRevision = UUID() }
            return result
        }
        let epoch = accountEpoch
        let previous = contentsCache[album.id]
        let snapshot: ContentsSnapshot
        do {
            snapshot = try await fetchCloudContents(in: album, previous: previous)
        } catch let error as CKError where error.code == .changeTokenExpired && previous?.token != nil {
            // The server can invalidate an old token. Rebuild this zone only.
            snapshot = try await fetchCloudContents(in: album, previous: nil)
        }
        try checkAccount(epoch, for: album)
        guard revisionAtStart == revision else { throw CancellationError() }
        if writeEpoch != contentsWriteEpoch[album.id, default: 0], let current = contentsCache[album.id] {
            return current.value
        }
        keepContents(snapshot, for: album, revisionAtStart: revisionAtStart)
        if let accountID = cloudAccountID, previous == nil || snapshot.changed {
            await metadataCache.save(snapshot, album: album, accountID: accountID)
        }
        guard epoch == accountEpoch, revisionAtStart == revision else { throw CancellationError() }
        if writeEpoch != contentsWriteEpoch[album.id, default: 0], let current = contentsCache[album.id] {
            return current.value
        }
        observeNewPhotos(snapshot.value.pictures, in: album)
        fetchPreviews(in: album, revisionAtStart: revisionAtStart, epoch: epoch)
        // A stale snapshot was shown immediately; refresh the visible screen only when records changed.
        if previous != nil && snapshot.changed { contentsRevision = UUID() }
        return snapshot.value
    }
    private func fetchCloudContents(in album: Album, previous: ContentsSnapshot?) async throws -> ContentsSnapshot {
        let db = database(for: album)
        let (records, token, changed): ([CKRecord.ID: CKRecord], CKServerChangeToken, Bool) = try await withCheckedThrowingContinuation { continuation in
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            // Fetch the hierarchy before transferring image previews.
            config.desiredKeys = ["location", "filename", "takenAt", "bytes", "folderID", "rotationQuarterTurns", "title", "parentFolderID", "coverPhotoID"]
            config.previousServerChangeToken = previous?.token
            let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [album.zone], configurationsByRecordZoneID: [album.zone: config])
            operation.fetchAllChanges = true
            operation.configuration.timeoutIntervalForRequest = 30
            operation.configuration.timeoutIntervalForResource = 120
            let collector = RecordCollector(initial: previous?.records ?? [:])
            operation.recordWasChangedBlock = { id, result in collector.receive(id, result) }
            operation.recordWithIDWasDeletedBlock = { id, _ in collector.remove(id) }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let value): collector.setToken(value.serverChangeToken)
                case .failure(let error): collector.fail(error)
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                do {
                    if case .failure(let error) = result { collector.fail(error) }
                    continuation.resume(returning: try collector.finish())
                } catch { continuation.resume(throwing: error) }
            }
            db.add(operation)
        }
        let pictureRecords: [CKRecord] = records.values.filter { record in
            record.recordType == "Picture"
        }
        var pictures: [Picture] = pictureRecords.map { record in
            Picture(record: record)
        }
        pictures.sort { first, second in
            if first.date != second.date { return first.date > second.date }
            return first.id.recordName < second.id.recordName
        }
        let folderRecords: [CKRecord] = records.values.filter { record in
            record.recordType == "Folder"
        }
        let folders: [PhotoFolder] = folderRecords.map { record in
            PhotoFolder(record: record)
        }
        return ContentsSnapshot(value: AlbumContents(pictures: pictures, folders: folders),
                                records: records, token: token, changed: changed)
    }
    private func fetchPreviews(in album: Album, revisionAtStart: UUID, epoch: Int) {
        guard inFlightPreviews[album.id] == nil, let snapshot = contentsCache[album.id] else { return }
        let accountID = cloudAccountID
        let folderPhoto = album.coverFolderID.flatMap { snapshot.value.photos(in: $0, recursive: true).first?.id.recordName }
        let selectedFolderCover = snapshot.value.folders.first(where: { $0.id == album.coverFolderID })?.coverPhotoID
        var idsByName: [String: CKRecord.ID] = [:]
        for picture in snapshot.value.pictures { idsByName[picture.id.recordName] = picture.id }
        var featured: [CKRecord.ID] = []
        let preferredNames: [String?] = [album.coverPhotoID, selectedFolderCover, folderPhoto]
            + snapshot.value.children(of: nil).prefix(6).map(\.coverPhotoID)
        for name in preferredNames {
            if let name, let pictureID = idsByName[name] { featured.append(pictureID) }
        }
        var candidates = featured
        candidates.reserveCapacity(featured.count + snapshot.value.pictures.count * 2)
        for picture in snapshot.value.pictures where picture.folderID == nil { candidates.append(picture.id) }
        for folder in snapshot.value.folders {
            if let name = folder.coverPhotoID, let pictureID = idsByName[name] { candidates.append(pictureID) }
        }
        for picture in snapshot.value.pictures { candidates.append(picture.id) }
        var seen: Set<CKRecord.ID> = []
        var missing: [CKRecord.ID] = []
        for pictureID in candidates {
            guard seen.insert(pictureID).inserted, snapshot.records[pictureID]?["preview"] == nil else { continue }
            missing.append(pictureID)
        }
        guard !missing.isEmpty else { return }
        let id = UUID()
        inFlightPreviews[album.id] = id
        Task(priority: .utility) { [self] in
            defer { if inFlightPreviews[album.id] == id { inFlightPreviews.removeValue(forKey: album.id) } }
            let db = database(for: album)
            let first = Array(missing.prefix(12))
            let firstData = await requestPreviewData(for: first, in: db)
            let firstSnapshot = applyPreviewData(firstData, in: album,
                                                 revisionAtStart: revisionAtStart, epoch: epoch, accountID: accountID)
            if let accountID, let firstSnapshot {
                await metadataCache.save(firstSnapshot, album: album, accountID: accountID)
            }
            guard revisionAtStart == revision, epoch == accountEpoch,
                  cloudAccountID == accountID else { return }
            let remaining = Array(missing.dropFirst(first.count))
            var batches: [[CKRecord.ID]] = []
            for offset in stride(from: 0, to: remaining.count, by: 32) {
                batches.append(Array(remaining[offset..<min(offset + 32, remaining.count)]))
            }
            await withTaskGroup(of: [String: Data].self) { group in
                let initialCount = min(2, batches.count)
                for index in 0..<initialCount {
                    let batch = batches[index]
                    group.addTask { [self] in await requestPreviewData(for: batch, in: db) }
                }
                var next = initialCount
                while let previewData = await group.next() {
                    guard revisionAtStart == revision, epoch == accountEpoch,
                          cloudAccountID == accountID else { group.cancelAll(); return }
                    _ = applyPreviewData(previewData, in: album,
                                         revisionAtStart: revisionAtStart, epoch: epoch, accountID: accountID)
                    if next < batches.count {
                        let batch = batches[next]
                        group.addTask { [self] in await requestPreviewData(for: batch, in: db) }
                        next += 1
                    }
                }
            }
            if let accountID, revisionAtStart == revision, epoch == accountEpoch,
               cloudAccountID == accountID, let latest = contentsCache[album.id] {
                await metadataCache.save(latest, album: album, accountID: accountID)
            }
        }
    }
    private func requestPreviewData(for ids: [CKRecord.ID], in db: CKDatabase) async -> [String: Data] {
        var previews: [String: Data] = [:]
        var pending = ids
        for attempt in 0..<2 {
            guard !Task.isCancelled, !pending.isEmpty else { break }
            do {
                let results = try await db.records(for: pending, desiredKeys: ["preview"])
                var retryIDs: [CKRecord.ID] = []
                var retryAfter = 0.0
                for pictureID in pending {
                    guard let result = results[pictureID] else { continue }
                    switch result {
                    case .success(let record):
                        if let data = record["preview"] as? Data { previews[pictureID.recordName] = data }
                    case .failure(let error):
                        if let cloudError = error as? CKError,
                           cloudError.code == .requestRateLimited || cloudError.code == .serviceUnavailable,
                           let seconds = cloudError.retryAfterSeconds {
                            retryIDs.append(pictureID)
                            retryAfter = max(retryAfter, seconds)
                        }
                    }
                }
                pending = retryIDs
                guard attempt == 0, !pending.isEmpty else { break }
                guard retryAfter.isFinite, retryAfter > 0, retryAfter <= 30 else { break }
                do { try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000)) }
                catch { break }
            } catch let cloudError as CKError {
                guard attempt == 0,
                      cloudError.code == .requestRateLimited || cloudError.code == .serviceUnavailable,
                      let seconds = cloudError.retryAfterSeconds,
                      seconds.isFinite, seconds > 0, seconds <= 30 else { break }
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { break }
            } catch { break }
        }
        return previews
    }
    private func applyPreviewData(_ previews: [String: Data], in album: Album,
                                  revisionAtStart: UUID, epoch: Int, accountID: String?) -> ContentsSnapshot? {
        guard revisionAtStart == revision, epoch == accountEpoch, cloudAccountID == accountID,
              var latest = contentsCache[album.id] else { return nil }
        var replacements: [CKRecord.ID: CKRecord] = [:]
        for (recordName, data) in previews {
            let pictureID = CKRecord.ID(recordName: recordName, zoneID: album.zone)
            guard let old = latest.records[pictureID], old.recordType == "Picture",
                  old["preview"] == nil else { continue }
            let updated = CKRecord(recordType: "Picture", recordID: pictureID)
            for field in ["location", "filename", "takenAt", "bytes", "folderID", "rotationQuarterTurns"] { updated[field] = old[field] }
            updated["preview"] = data as CKRecordValue
            replacements[pictureID] = updated
            latest.records[pictureID] = updated
        }
        guard !replacements.isEmpty else { return nil }
        for index in latest.value.pictures.indices {
            let pictureID = latest.value.pictures[index].id
            if let record = replacements[pictureID] {
                latest.value.pictures[index] = Picture(record: record)
            }
        }
        contentsCache[album.id] = latest
        contentsRevision = UUID()
        return latest
    }
    func upload(_ original: Original, into album: Album, folderID: String? = nil) async throws -> SaveOutcome {
        await PremiumStore.shared.start()
        if PremiumStore.shared.isPremium {
            return try await uploadOriginal(original, into: album, folderID: folderID)
        }
        return try await photoImportGate.perform {
            // Do not reuse a refresh that may have started before the preceding upload.
            if let active = self.inFlightContents[album.id] {
                _ = try await active.task.value
                if self.inFlightContents[album.id]?.id == active.id {
                    self.inFlightContents.removeValue(forKey: album.id)
                }
            }
            let current = try await self.contents(in: album, forceRefresh: true)
            guard current.skipped == 0 else {
                throw UserError(message: "写真の枚数を確認できませんでした。アルバムを更新してから再度追加してください。")
            }
            try PhotoQuota.check(existingIDs: Set(current.pictures.map { $0.id.recordName }),
                                 incomingID: original.duplicateIdentity,
                                 premium: PremiumStore.shared.isPremium)
            return try await self.uploadOriginal(original, into: album, folderID: folderID)
        }
    }

    private func uploadOriginal(_ original: Original, into album: Album, folderID: String?) async throws -> SaveOutcome {
        if album.storage == .device {
            return try await LocalStore.shared.save(original, into: album, folderID: folderID)
        }
        // Deterministic ID prevents duplicate uploads and makes manual retries idempotent.
        let id = CKRecord.ID(recordName: original.duplicateIdentity, zoneID: album.zone)
        let db = database(for: album)
        let epoch = accountEpoch
        try checkAccount(epoch, for: album)
        // The open album already knows about common duplicates. Verify those before
        // sending assets; new photos skip the per-photo CloudKit existence request.
        if contentsCache[album.id]?.value.pictures.contains(where: { $0.id == id }) == true {
            do { return try await verifyDuplicate(original, id: id, in: album, database: db, epoch: epoch) }
            catch let error as CKError where error.code == .unknownItem { /* Stale list; save below. */ }
        }
        try checkAccount(epoch, for: album)
        try await requireFolder(folderID, album: album)
        try checkAccount(epoch, for: album)
        let record = CKRecord(recordType: "Picture", recordID: id)
        record.parent = CKRecord.Reference(recordID: album.record.recordID, action: .none)
        record["filename"] = original.names[0] as CKRecordValue
        record["names"] = original.names as CKRecordValue
        record["kinds"] = original.kinds.map { NSNumber(value: $0) } as CKRecordValue
        record["hashes"] = original.hashes as CKRecordValue
        record["sourceIdentity"] = original.sourceIdentity as CKRecordValue?
        record["files"] = original.urls.map { CKAsset(fileURL: $0) } as CKRecordValue
        record["bytes"] = NSNumber(value: original.bytes)
        record["location"] = original.location?.clLocation
        record["takenAt"] = original.date as CKRecordValue
        record["preview"] = original.preview as CKRecordValue?
        record["folderID"] = folderID as CKRecordValue?
        do {
            let result = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let saved = result.saveResults[id] else { throw UserError(message: "保存結果を確認できませんでした。") }
            _ = try saved.get()
        } catch {
            let ck = error as? CKError
            let itemError = ck?.partialErrorsByItemID?[id] as? CKError
            guard ck?.code == .serverRecordChanged || (ck?.code == .partialFailure && itemError?.code == .serverRecordChanged) else { throw error }
            // Two members may import identical bytes concurrently. Never overwrite the winner.
            return try await verifyDuplicate(original, id: id, in: album, database: db, epoch: epoch)
        }
        try checkAccount(epoch, for: album)
        NewPhotoTracker.shared.markRead([id.recordName], scope: newPhotoScope(for: album))
        return .added
    }
    private func verifyDuplicate(_ original: Original, id: CKRecord.ID, in album: Album,
                                 database: CKDatabase, epoch: Int) async throws -> SaveOutcome {
        let saved = try await database.record(for: id)
        let existing = try await Task.detached(priority: .utility) { try Original.from(saved) }.value
        defer { existing.clean() }
        try checkAccount(epoch, for: album)
        guard (saved["sourceIdentity"] as? String ?? existing.identity) == original.duplicateIdentity else {
            throw UserError(message: "保存済みの原本を確認できませんでした。")
        }
        return .alreadyPresent
    }
    func prepareUploadDestination(in album: Album, folderID: String?) async throws {
        guard album.storage == .iCloud else { return }
        let epoch = accountEpoch
        try await requireFolder(folderID, album: album)
        try checkAccount(epoch, for: album)
    }
    private func requireFolder(_ id: String?, album: Album) async throws {
        guard let id else { return }
        guard id.hasPrefix("Folder-"), UUID(uuidString: String(id.dropFirst(7))) != nil else {
            throw UserError(message: "フォルダの情報が正しくありません。")
        }
        let recordID = CKRecord.ID(recordName: id, zoneID: album.zone)
        if validatedFolders.contains(recordID) { return }
        let epoch = accountEpoch
        let record = try await database(for: album).record(for: recordID)
        try checkAccount(epoch, for: album)
        guard record.recordType == "Folder" else { throw UserError(message: "フォルダが見つかりません。") }
        validatedFolders.insert(recordID)
    }
    func createFolder(_ title: String, in album: Album, parentID: String? = nil) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw UserError(message: "フォルダ名を入力してください。") }
        if album.storage == .device {
            try await LocalStore.shared.createFolder(title, in: album, parentID: parentID)
        } else {
            let epoch = accountEpoch
            try await requireFolder(parentID, album: album)
            try checkAccount(epoch, for: album)
            let record = CKRecord(recordType: "Folder", recordID: .init(recordName: "Folder-" + UUID().uuidString, zoneID: album.zone))
            // CloudKit parent is the sharing root; UI nesting is stored separately.
            record.parent = CKRecord.Reference(recordID: album.record.recordID, action: .none)
            record["title"] = title as CKRecordValue
            record["parentFolderID"] = parentID as CKRecordValue?
            _ = try await database(for: album).save(record)
            try checkAccount(epoch, for: album)
        }
        revision = UUID()
    }
    func renameFolder(_ id: String, in album: Album, title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw UserError(message: "フォルダ名を入力してください。") }
        if album.storage == .device { try await LocalStore.shared.renameFolder(id, in: album, title: title) }
        else {
            let epoch = accountEpoch
            let record = try await database(for: album).record(for: .init(recordName: id, zoneID: album.zone))
            try checkAccount(epoch, for: album)
            guard record.recordType == "Folder" else { throw UserError(message: "フォルダが見つかりません。") }
            record["title"] = title as CKRecordValue
            _ = try await database(for: album).save(record)
            try checkAccount(epoch, for: album)
        }
        revision = UUID()
    }
    func setCover(_ picture: Picture?, in album: Album, folderID: String? = nil) async throws {
        if album.storage == .device {
            try await LocalStore.shared.setCover(picture, in: album, folderID: folderID)
            if folderID == nil { await refreshLocalAlbums() }
            else { revision = UUID() }
            return
        }
        let epoch = accountEpoch
        let content = try await contents(in: album)
        if let picture {
            guard picture.id.zoneID == album.zone,
                  content.cover(picture.id.recordName, in: folderID) != nil else {
                throw UserError(message: "このフォルダ内の写真を選択してください。")
            }
        }
        if let folderID, !content.folders.contains(where: { $0.id == folderID }) {
            throw UserError(message: "フォルダが見つかりません。")
        }
        let id = CKRecord.ID(recordName: folderID ?? "album", zoneID: album.zone)
        let record = try await database(for: album).record(for: id)
        try checkAccount(epoch, for: album)
        record["coverPhotoID"] = picture?.id.recordName as CKRecordValue?
        _ = try await database(for: album).save(record)
        try checkAccount(epoch, for: album)
        if folderID == nil { await refresh() }
        else { revision = UUID() }
    }
    func setAlbumCoverFolder(_ folder: PhotoFolder, in album: Album) async throws {
        guard folder.record.recordID.zoneID == album.zone,
              (try await contents(in: album)).folders.contains(where: { $0.id == folder.id }) else {
            throw UserError(message: "このアルバムのフォルダを選択してください。")
        }
        if album.storage == .device {
            try await LocalStore.shared.setAlbumCoverFolder(folder.id, in: album)
            await refreshLocalAlbums()
            return
        }
        let epoch = accountEpoch
        let record = try await database(for: album).record(for: album.record.recordID)
        try checkAccount(epoch, for: album)
        // Folder record names and picture hashes cannot collide; reuse the existing field.
        record["coverPhotoID"] = folder.id as CKRecordValue
        _ = try await database(for: album).save(record)
        try checkAccount(epoch, for: album)
        await refresh()
    }
    func download(_ picture: Picture, album: Album) async throws -> Original {
        if album.storage == .device { return try await LocalStore.shared.download(picture, album: album) }
        let epoch = accountEpoch
        let record = try await database(for: album).record(for: picture.id)
        let result = try await Task.detached(priority: .userInitiated) { try Original.from(record) }.value
        do { try checkAccount(epoch, for: album); return result }
        catch { result.clean(); throw error }
    }
    private func readCloudRotation(for picture: Picture, in album: Album) async throws -> Int {
        let fetched = try await database(for: album).records(for: [picture.id], desiredKeys: ["rotationQuarterTurns"])
        guard let item = fetched[picture.id] else {
            throw UserError(message: "写真の向きを確認できませんでした。")
        }
        let record = try item.get()
        guard record.recordType == "Picture" else { throw UserError(message: "写真が見つかりません。") }
        return Picture(record: record).rotationQuarterTurns
    }
    func refreshRotation(for picture: Picture, in album: Album) async throws -> Int {
        guard album.storage == .iCloud else { return picture.rotationQuarterTurns }
        let epoch = accountEpoch
        let writeEpoch = contentsWriteEpoch[album.id, default: 0]
        let rotation = try await readCloudRotation(for: picture, in: album)
        try checkAccount(epoch, for: album)
        if writeEpoch != contentsWriteEpoch[album.id, default: 0] {
            return contentsCache[album.id]?.value.pictures.first(where: { $0.id == picture.id })?.rotationQuarterTurns ?? rotation
        }
        await cacheRotation(rotation, for: picture, in: album)
        return rotation
    }
    func setRotation(_ quarterTurns: Int, for picture: Picture, in album: Album) async throws {
        guard picture.id.zoneID == album.zone, (0..<4).contains(quarterTurns) else {
            throw UserError(message: "写真の回転情報が正しくありません。")
        }
        if album.storage == .device {
            try await LocalStore.shared.setRotation(quarterTurns, for: picture, in: album)
        } else {
            let epoch = accountEpoch
            let db = database(for: album)
            // Fetch metadata only: requesting the full record also downloads every original asset.
            let fetched = try await db.records(for: [picture.id], desiredKeys: [])
            try checkAccount(epoch, for: album)
            guard let item = fetched[picture.id] else {
                throw UserError(message: "写真が見つかりません。更新してからやり直してください。")
            }
            let record = try item.get()
            guard record.recordType == "Picture" else { throw UserError(message: "写真が見つかりません。") }
            record["rotationQuarterTurns"] = NSNumber(value: quarterTurns)
            let result = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true)
            guard let saved = result.saveResults[picture.id] else {
                throw UserError(message: "回転の保存結果を確認できませんでした。")
            }
            _ = try saved.get()
            try checkAccount(epoch, for: album)
            let confirmed = try await readCloudRotation(for: picture, in: album)
            try checkAccount(epoch, for: album)
            guard confirmed == quarterTurns else {
                throw UserError(message: "iCloudに回転の向きが反映されませんでした。もう一度保存してください。")
            }
        }
        await cacheRotation(quarterTurns, for: picture, in: album)
    }
    private func cacheRotation(_ quarterTurns: Int, for picture: Picture, in album: Album) async {
        if var snapshot = contentsCache[album.id],
           let index = snapshot.value.pictures.firstIndex(where: { $0.id == picture.id }) {
            let old = snapshot.value.pictures[index].record
            guard snapshot.value.pictures[index].rotationQuarterTurns != quarterTurns else { return }
            contentsWriteEpoch[album.id, default: 0] += 1
            let updated = CKRecord(recordType: "Picture", recordID: picture.id)
            for field in ["location", "filename", "takenAt", "bytes", "folderID", "preview"] { updated[field] = old[field] }
            updated["addedAt"] = Picture(record: old).addedAt as CKRecordValue
            updated["creatorID"] = Picture(record: old).creatorID as CKRecordValue?
            updated["rotationQuarterTurns"] = NSNumber(value: quarterTurns)
            snapshot.records[picture.id] = updated
            snapshot.value.pictures[index] = Picture(record: updated)
            contentsCache[album.id] = snapshot
            contentsRevision = UUID()
            if album.storage == .iCloud, let accountID = cloudAccountID {
                await metadataCache.save(snapshot, album: album, accountID: accountID)
            }
        } else {
            // The preview may have opened before the album snapshot was cached.
            if album.storage == .iCloud { checkForUpdates(in: album) }
        }
    }
    func verifySaved(_ original: Original, album: Album) async throws {
        let record = CKRecord(recordType: "Picture", recordID: .init(recordName: original.identity, zoneID: album.zone))
        let readBack = try await download(Picture(record: record), album: album)
        defer { readBack.clean() }
        guard readBack.hashes == original.hashes, readBack.kinds == original.kinds,
              readBack.identity == original.identity else {
            throw UserError(message: "保存先の原本と一致しないため、元の写真は削除しませんでした。")
        }
    }
    func move(_ pictures: [Picture], in album: Album, to folderID: String?) async throws {
        guard !pictures.isEmpty else { return }
        guard pictures.allSatisfy({ $0.id.zoneID == album.zone }) else {
            throw UserError(message: "別のアルバムの写真は移動できません。")
        }
        let epoch = accountEpoch
        guard try await canEdit(album) else { throw UserError(message: "このアルバムは閲覧のみです。") }
        try checkAccount(epoch, for: album)
        // Invalidate even on a partial batch failure so the next read shows the actual result.
        defer {
            contentsCache.removeValue(forKey: album.id)
            contentsWriteEpoch[album.id, default: 0] += 1
            revision = UUID()
        }
        if album.storage == .device {
            try await LocalStore.shared.move(pictures, in: album, to: folderID)
            return
        }
        let db = database(for: album)
        if let folderID {
            let target = try await db.record(for: .init(recordName: folderID, zoneID: album.zone))
            try checkAccount(epoch, for: album)
            guard target.recordType == "Folder" else { throw UserError(message: "移動先のフォルダが見つかりません。") }
        }
        let ids = Array(Set(pictures.map(\.id)))
        for offset in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            try checkAccount(epoch, for: album)
            let batch = Array(ids[offset..<min(offset + 100, ids.count)])
            let fetched = try await db.records(for: batch, desiredKeys: ["folderID"])
            try checkAccount(epoch, for: album)
            let records = try batch.map { id -> CKRecord in
                guard let item = fetched[id] else { throw UserError(message: "移動する写真が見つかりません。") }
                let record = try item.get()
                guard record.recordType == "Picture" else { throw UserError(message: "写真の情報が正しくありません。") }
                record["folderID"] = folderID as CKRecordValue?
                return record
            }
            let saved = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys, atomically: true)
            try checkAccount(epoch, for: album)
            for id in batch {
                guard let item = saved.saveResults[id] else { throw UserError(message: "移動結果を確認できません。") }
                _ = try item.get()
            }
        }
    }
    func delete(_ picture: Picture, album: Album) async throws {
        guard !busy else { throw UserError(message: "写真の保存・確認が終わってから削除してください。") }
        if album.storage == .device { try await LocalStore.shared.delete(picture, album: album); return }
        _ = try await database(for: album).deleteRecord(withID: picture.id)
    }
    func deleteMany(_ pictures: [Picture], album: Album) async throws {
        guard !pictures.isEmpty else { return }
        guard pictures.allSatisfy({ $0.id.zoneID == album.zone }) else {
            throw UserError(message: "別のアルバムの写真が含まれています。")
        }
        if album.storage == .device {
            for picture in pictures { try await LocalStore.shared.delete(picture, album: album) }
            return
        }
        let epoch = accountEpoch
        let ids = Array(Set(pictures.map(\.id)))
        for offset in stride(from: 0, to: ids.count, by: 50) {
            try checkAccount(epoch, for: album)
            let batch = Array(ids[offset..<min(offset + 50, ids.count)])
            let result = try await database(for: album).modifyRecords(
                saving: [], deleting: batch, savePolicy: .ifServerRecordUnchanged, atomically: false)
            try checkAccount(epoch, for: album)
            for id in batch {
                guard let deletion = result.deleteResults[id] else {
                    throw UserError(message: "写真の削除結果を確認できませんでした。更新して再試行してください。")
                }
                _ = try deletion.get()
            }
        }
    }
}

// Operation callbacks may arrive on background queues.
private final class RecordCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CKRecord.ID: CKRecord]
    private var token: CKServerChangeToken?
    private var error: Error?
    private var changed = false
    init(initial: [CKRecord.ID: CKRecord]) { records = initial }
    func receive(_ id: CKRecord.ID, _ result: Result<CKRecord, Error>) {
        lock.lock(); defer { lock.unlock() }
        switch result {
        case .success(let record):
            if record.recordType == "Picture", record["preview"] == nil,
               let previous = records[id]?["preview"] as? Data {
                record["preview"] = previous as CKRecordValue
            }
            records[id] = record
            changed = true
        case .failure(let value): error = value
        }
    }
    func remove(_ id: CKRecord.ID) { lock.lock(); defer { lock.unlock() }; changed = records.removeValue(forKey: id) != nil || changed }
    func setToken(_ value: CKServerChangeToken) { lock.lock(); defer { lock.unlock() }; token = value }
    func fail(_ value: Error) { lock.lock(); defer { lock.unlock() }; if error == nil { error = value } }
    func finish() throws -> ([CKRecord.ID: CKRecord], CKServerChangeToken, Bool) {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        guard let token else { throw UserError(message: "アルバムの更新情報を確認できませんでした。") }
        return (records, token, changed)
    }
}

// Metadata and small display previews only. Original assets are never copied into this cache.
private actor CloudMetadataCache {
    private struct StoredAlbumList: Codable {
        let accountID: String
        let albums: [StoredAlbum]
    }
    private struct StoredAlbum: Codable {
        let zone: String
        let owner: String
        let title: String
        let shared: Bool
        let coverPhotoID: String?
        let coverFolderID: String?
    }
    private struct Stored: Codable {
        let version: Int
        let accountID: String
        let albumID: String
        let tokenData: Data
        let pictures: [StoredPicture]
        let folders: [StoredFolder]
    }
    private struct StoredPicture: Codable {
        let id: String
        let filename: String
        let date: Date
        let bytes: Int64
        let preview: Data?
        let folderID: String?
        let rotationQuarterTurns: Int?
        let addedAt: Date?
        let creatorID: String?
        let location: PhotoLocation?
    }
    private struct StoredFolder: Codable {
        let id: String
        let title: String
        let parentID: String?
        let coverPhotoID: String?
    }
    private let fm = FileManager.default
    private var cachedDirectory: URL?
    private func directory() throws -> URL {
        if let cachedDirectory { return cachedDirectory }
        var url = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("CloudMetadataCache", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        cachedDirectory = url
        return url
    }
    private func file(album: Album, accountID: String) throws -> URL {
        let key = Data(SHA256.hash(data: Data((accountID + "/" + album.id).utf8)))
            .map { String(format: "%02x", $0) }.joined()
        return try directory().appendingPathComponent(key + ".json")
    }
    private func albumListFile(accountID: String) throws -> URL {
        let key = Data(SHA256.hash(data: Data(accountID.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        return try directory().appendingPathComponent("albums-" + key + ".json")
    }
    func loadAlbums(accountID: String) -> [Album]? {
        do {
            let stored = try JSONDecoder().decode(StoredAlbumList.self, from: Data(contentsOf: albumListFile(accountID: accountID)))
            guard stored.accountID == accountID else { return nil }
            return stored.albums.compactMap { item -> Album? in
                guard item.zone.hasPrefix("Album-"), !item.owner.isEmpty else { return nil }
                let id = CKRecord.ID(recordName: "album", zoneID: .init(zoneName: item.zone, ownerName: item.owner))
                let record = CKRecord(recordType: "Album", recordID: id)
                record["title"] = item.title as CKRecordValue
                record["coverPhotoID"] = item.coverPhotoID as CKRecordValue?
                record["coverFolderID"] = item.coverFolderID as CKRecordValue?
                return Album(record: record, shared: item.shared)
            }
        } catch { return nil }
    }
    func saveAlbums(_ albums: [Album], accountID: String) {
        let items = albums.map {
            StoredAlbum(zone: $0.zone.zoneName, owner: $0.zone.ownerName, title: $0.title,
                        shared: $0.shared, coverPhotoID: $0.coverPhotoID, coverFolderID: $0.coverFolderID)
        }
        do {
            try JSONEncoder().encode(StoredAlbumList(accountID: accountID, albums: items))
                .write(to: albumListFile(accountID: accountID), options: .atomic)
        } catch { /* Album metadata can always be fetched from CloudKit. */ }
    }
    func load(album: Album, accountID: String) -> ContentsSnapshot? {
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file(album: album, accountID: accountID)))
            guard stored.version == 3, stored.accountID == accountID, stored.albumID == album.id else { return nil }
            let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: stored.tokenData)
            guard let token else { return nil }
            var records: [CKRecord.ID: CKRecord] = [:]
            var pictures: [Picture] = []
            var folders: [PhotoFolder] = []
            pictures.reserveCapacity(stored.pictures.count)
            folders.reserveCapacity(stored.folders.count)
            for item in stored.pictures {
                let record = CKRecord(recordType: "Picture", recordID: .init(recordName: item.id, zoneID: album.zone))
                record["location"] = item.location?.clLocation
                record["filename"] = item.filename as CKRecordValue
                record["takenAt"] = item.date as CKRecordValue
                record["addedAt"] = item.addedAt as CKRecordValue?
                record["creatorID"] = item.creatorID as CKRecordValue?
                record["bytes"] = NSNumber(value: item.bytes)
                record["preview"] = item.preview as CKRecordValue?
                record["folderID"] = item.folderID as CKRecordValue?
                if let turns = item.rotationQuarterTurns { record["rotationQuarterTurns"] = NSNumber(value: turns) }
                records[record.recordID] = record
                pictures.append(Picture(record: record))
            }
            for item in stored.folders {
                let record = CKRecord(recordType: "Folder", recordID: .init(recordName: item.id, zoneID: album.zone))
                record["title"] = item.title as CKRecordValue
                record["parentFolderID"] = item.parentID as CKRecordValue?
                record["coverPhotoID"] = item.coverPhotoID as CKRecordValue?
                records[record.recordID] = record
                folders.append(PhotoFolder(record: record))
            }
            pictures.sort { first, second in
                if first.date != second.date { return first.date > second.date }
                return first.id.recordName < second.id.recordName
            }
            return ContentsSnapshot(value: AlbumContents(pictures: pictures, folders: folders),
                                    records: records, token: token, date: .distantPast)
        } catch { return nil }
    }
    func save(_ snapshot: ContentsSnapshot, album: Album, accountID: String) {
        guard let token = snapshot.token else { return }
        do {
            let tokenData = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            let pictures: [StoredPicture] = snapshot.value.pictures.map { picture in
                StoredPicture(id: picture.id.recordName, filename: picture.name, date: picture.date,
                              bytes: picture.bytes, preview: picture.preview, folderID: picture.folderID,
                              rotationQuarterTurns: picture.rotationQuarterTurns,
                              addedAt: picture.addedAt, creatorID: picture.creatorID, location: picture.location)
            }
            let folders: [StoredFolder] = snapshot.value.folders.map { folder in
                StoredFolder(id: folder.id, title: folder.title, parentID: folder.parentID,
                             coverPhotoID: folder.coverPhotoID)
            }
            let stored = Stored(version: 3, accountID: accountID, albumID: album.id,
                                tokenData: tokenData, pictures: pictures, folders: folders)
            try JSONEncoder().encode(stored).write(to: file(album: album, accountID: accountID), options: .atomic)
        } catch { /* A failed cache write must never prevent the album from opening. */ }
    }
    func clear() {
        if let url = try? directory() { try? fm.removeItem(at: url) }
        cachedDirectory = nil
    }
}

// Integrated from AlbumContents.swift
/// Folders organize one album; every descendant inherits that album's sharing members.
struct PhotoFolder: Identifiable {
    let record: CKRecord
    var id: String { record.recordID.recordName }
    var title: String { (record["title"] as? String) ?? "フォルダ" }
    var parentID: String? { record["parentFolderID"] as? String }
    var coverPhotoID: String? { record["coverPhotoID"] as? String }
}

struct AlbumContents {
    var pictures: [Picture] = []
    var folders: [PhotoFolder] = []
    var skipped = 0

    /// Count each photo once, then propagate folder totals to their ancestors.
    func recursivePhotoCounts() -> [String: Int] {
        let parents = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.parentID) })
        var directCounts: [String: Int] = [:]
        for picture in pictures {
            if let folderID = picture.folderID, parents[folderID] != nil {
                directCounts[folderID, default: 0] += 1
            }
        }
        var counts = directCounts
        for folder in folders {
            let direct = directCounts[folder.id, default: 0]
            guard direct > 0 else { continue }
            var visited: Set<String> = [folder.id]
            var ancestor = folder.parentID
            while let id = ancestor, let next = parents[id], visited.insert(id).inserted {
                counts[id, default: 0] += direct
                ancestor = next
            }
        }
        return counts
    }

    func children(of folderID: String?) -> [PhotoFolder] {
        folders.filter { $0.parentID == folderID }
            .sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // A visited set also makes malformed or cyclic remote data safe to traverse.
    func descendants(of folderID: String) -> Set<String> {
        var found: Set<String> = [folderID]
        var pending = [folderID]
        while let parent = pending.popLast() {
            for folder in folders where folder.parentID == parent {
                if found.insert(folder.id).inserted { pending.append(folder.id) }
            }
        }
        return found
    }

    func photos(in folderID: String?, recursive: Bool = false) -> [Picture] {
        guard recursive else { return pictures.filter { $0.folderID == folderID } }
        guard let folderID else { return pictures }
        let ids = descendants(of: folderID)
        return pictures.filter { $0.folderID.map { ids.contains($0) } ?? false }
    }

    func cover(_ photoID: String?, in folderID: String?) -> Picture? {
        guard let photoID else { return nil }
        return photos(in: folderID, recursive: true).first { $0.id.recordName == photoID }
    }
}
