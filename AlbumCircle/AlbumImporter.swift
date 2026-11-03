import Foundation
import BackgroundTasks
import UIKit
import Photos
import Combine

fileprivate enum CloudImportSource {
    case photo(String)
    case file(URL)

    func original(quality: UploadQuality) async throws -> Original {
        let source: Original
        switch self {
        case .photo(let identifier): source = try await Original.fromAsset(identifier: identifier)
        case .file(let url): source = try await Task.detached(priority: .userInitiated) { try Original.fromFile(url) }.value
        }
        guard quality != .original else { return source }
        defer { source.clean() }
        return try await Task.detached(priority: .userInitiated) { try source.prepared(for: quality) }.value
    }
}

enum ImportItemState: String {
    case waiting = "追加待ち", saving = "保存中", completed = "完了", failed = "失敗", paused = "一時停止"
}

struct PendingImport: Codable, Identifiable {
    let id: UUID
    let albumID: String
    let folderID: String?
    let quality: UploadQuality
    let photoIDs: [String]?
    let fileNames: [String]?
    let deleteOriginals: Bool
    var completed: Set<Int> = []
    var errors: [Int: String]? = nil
    var displayNames: [Int: String]? = nil
    var paused: Bool? = nil
    var settled: Bool? = nil
    var albumTitle: String? = nil
    var createdAt: Date? = nil
    var scope: String? = nil
    var storage: AlbumStorage? = nil
    var readyIndices: [Int] { (0..<count).filter { !completed.contains($0) && errors?[$0] == nil } }
    var runnable: Bool { settled != true && paused != true }
    func name(at index: Int) -> String { displayNames?[index] ?? fileNames?[index] ?? "写真 \(index + 1)" }
    func state(at index: Int, active: Set<Int> = []) -> ImportItemState {
        if completed.contains(index) { return .completed }
        if active.contains(index) { return .saving }
        if errors?[index] != nil { return .failed }
        return paused == true ? .paused : .waiting
    }
    mutating func retry(_ index: Int? = nil) {
        guard settled != true else { return }
        if let index { errors?.removeValue(forKey: index) } else { errors = [:] }
        paused = false
    }
    mutating func complete(_ index: Int) {
        completed.insert(index)
        errors?.removeValue(forKey: index)
    }
    var count: Int { photoIDs?.count ?? fileNames?.count ?? 0 }
    fileprivate func source(at index: Int, folder: URL) throws -> CloudImportSource {
        if let photoIDs { return .photo(photoIDs[index]) }
        guard let fileNames else { throw UserError(message: "保存待ちの写真を読み込めません。") }
        return .file(try Original.resourceURL(folder, index: index, name: fileNames[index]))
    }
}

struct ImportQueueFile {
    let url: URL
    func load() throws -> [PendingImport] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PendingImport].self, from: Data(contentsOf: url))
    }
    func save(_ jobs: [PendingImport]) throws {
        try JSONEncoder().encode(jobs).write(to: url, options: .atomic)
    }
}

@MainActor
final class ImportMonitor: ObservableObject {
    static let shared = ImportMonitor()
    @Published var revision = 0
    @Published var active: [UUID: Set<Int>] = [:]
    func begin(_ id: UUID, index: Int) { active[id, default: []].insert(index) }
    func end(_ id: UUID, index: Int) { active[id]?.remove(index) }
}

/// Durable work list. Each confirmed item is marked before another image is started.
@MainActor
enum PendingImports {
    nonisolated static var identifier: String { (Bundle.main.bundleIdentifier ?? "com.example.AlbumCircle") + ".imports" }
    private static func root() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        var root = support.appendingPathComponent("PendingImports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        return root
    }
    static func directory(for id: UUID) throws -> URL {
        try root().appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private static func queueURL() throws -> URL { try root().appendingPathComponent("queue.json") }
    static func all() throws -> [PendingImport] { try ImportQueueFile(url: queueURL()).load() }
    private static func write(_ jobs: [PendingImport]) throws {
        try ImportQueueFile(url: queueURL()).save(jobs)
        ImportMonitor.shared.revision += 1
    }
    static func enqueuePhotos(_ ids: [String], album: Album, folderID: String?, quality: UploadQuality) throws {
        guard let scope = CloudStore.shared.personalPhotoScope(for: album) else {
            throw UserError(message: "iCloudアカウントを確認してから追加してください。")
        }
        var jobs = try all()
        var names: [Int: String] = [:]
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: String] = [:]
        assets.enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo })?.originalFilename
        }
        for (index, id) in ids.enumerated() { names[index] = byID[id] }
        jobs.append(PendingImport(id: UUID(), albumID: album.id, folderID: folderID, quality: quality,
                                  photoIDs: ids, fileNames: nil,
                                  deleteOriginals: UserDefaults.standard.bool(forKey: AlbumStorage.deleteOriginalsKey),
                                  displayNames: names, albumTitle: album.title, createdAt: Date(),
                                  scope: scope, storage: album.storage))
        try write(jobs)
        schedule()
    }
    nonisolated static func stageFiles(_ urls: [URL], folder: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        do {
            var names: [String] = []
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let name = url.lastPathComponent
                let target = try Original.resourceURL(folder, index: index, name: name)
                let access = url.startAccessingSecurityScopedResource()
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                    do { try fm.copyItem(at: coordinated, to: target) }
                    catch { copyError = error }
                }
                if access { url.stopAccessingSecurityScopedResource() }
                if let error = coordinationError { throw error }
                if let error = copyError { throw error }
                names.append(name)
            }
            return names
        } catch { try? fm.removeItem(at: folder); throw error }
    }
    static func enqueueFiles(_ urls: [URL], album: Album, folderID: String?, quality: UploadQuality) async throws {
        let store = CloudStore.shared
        let epoch = store.accountEpoch
        guard let scope = store.personalPhotoScope(for: album) else {
            throw UserError(message: "iCloudアカウントを確認してから追加してください。")
        }
        let id = UUID(), folder = try directory(for: id)
        let names = try await Task.detached(priority: .userInitiated) {
            try stageFiles(urls, folder: folder)
        }.value
        do {
            try store.checkAccount(epoch, for: album)
            var jobs = try all()
            jobs.append(PendingImport(id: id, albumID: album.id, folderID: folderID, quality: quality,
                                      photoIDs: nil, fileNames: names, deleteOriginals: false,
                                      albumTitle: album.title, createdAt: Date(),
                                      scope: scope, storage: album.storage))
            try write(jobs)
            schedule()
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    static func mark(_ id: UUID, index: Int) throws {
        var jobs = try all()
        guard let offset = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[offset].complete(index)
        try write(jobs)
    }
    static func change(_ id: UUID, _ edit: (inout PendingImport) -> Void) throws {
        var jobs = try all()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        edit(&jobs[index])
        try write(jobs)
    }
    static func fail(_ id: UUID, index: Int, message: String) throws {
        try change(id) { job in
            if job.errors == nil { job.errors = [:] }
            job.errors?[index] = message
        }
    }
    static func finish(_ id: UUID) throws {
        try change(id) { $0.settled = true; $0.paused = false }
        try? FileManager.default.removeItem(at: directory(for: id))
        if try !all().contains(where: { $0.runnable }) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }
    static func visible(_ job: PendingImport) -> Bool {
        guard let scope = job.scope else {
            // Legacy pending work is only exposed when its destination is available.
            return CloudStore.shared.albums.contains { $0.id == job.albumID }
        }
        return scope == CloudStore.shared.personalPhotoScope(albumID: job.albumID, storage: job.storage ?? .iCloud)
    }
    static func remove(_ id: UUID) throws {
        var jobs = try all()
        jobs.removeAll { $0.id == id }
        try write(jobs)
        ImportMonitor.shared.active.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: directory(for: id))
        if !jobs.contains(where: { $0.runnable }) { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
    }
    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = false // Local albums can finish offline.
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}

@MainActor
enum AlbumImporter {
    private static var processing = false
    static var isProcessing: Bool { processing }
    static func retry(_ id: UUID, index: Int? = nil) async throws {
        guard !processing, !CloudStore.shared.busy,
              let job = try PendingImports.all().first(where: { $0.id == id }), PendingImports.visible(job) else {
            throw UserError(message: "現在の保存処理が終わってから再試行してください。")
        }
        try PendingImports.change(id) { $0.retry(index) }
        await resumePending()
    }

    // Two CloudKit writes at once; the durable queue records each confirmed image.
    private static func uploadOne(_ index: Int, job: PendingImport, into album: Album, epoch: Int) async -> String? {
        ImportMonitor.shared.begin(job.id, index: index)
        defer { ImportMonitor.shared.end(job.id, index: index) }
        do {
            try Task.checkCancellation()
            let source = try job.source(at: index, folder: PendingImports.directory(for: job.id))
            let original = try await source.original(quality: job.quality)
            defer { original.clean() }
            try Task.checkCancellation()
            let store = CloudStore.shared
            if store.stopRequested { throw CancellationError() }
            try store.checkAccount(epoch, for: album)
            _ = try await store.upload(original, into: album, folderID: job.folderID)
            try store.checkAccount(epoch, for: album)
            try PendingImports.mark(job.id, index: index)
            return nil
        } catch {
            if !(error is CancellationError) && !Task.isCancelled {
                do { try PendingImports.fail(job.id, index: index, message: error.localizedDescription) }
                catch { CloudStore.shared.report(error) }
            }
            return error.localizedDescription
        }
    }

    private static func uploadCloud(_ indices: [Int], job: PendingImport, into album: Album,
                                    epoch: Int) async -> String? {
        let store = CloudStore.shared
        do { try await store.prepareUploadDestination(in: album, folderID: job.folderID) }
        catch {
            for index in indices { try? PendingImports.fail(job.id, index: index, message: error.localizedDescription) }
            return error.localizedDescription
        }
        store.progress = "原本を保存中 \(job.completed.count)/\(job.count)"
        return await withTaskGroup(of: String?.self) { group -> String? in
            let initial = min(2, indices.count)
            for offset in 0..<initial {
                group.addTask { await uploadOne(indices[offset], job: job, into: album, epoch: epoch) }
            }
            var next = initial
            var finished = 0
            var firstError: String?
            while let issue = await group.next() {
                finished += 1
                store.progress = "原本を保存中 \(job.completed.count + finished)/\(job.count)"
                if let issue, firstError == nil, !store.stopRequested { firstError = issue }
                if store.stopRequested || Task.isCancelled { group.cancelAll() }
                if !store.stopRequested && !Task.isCancelled && next < indices.count {
                    let index = indices[next]
                    next += 1
                    group.addTask { await uploadOne(index, job: job, into: album, epoch: epoch) }
                }
            }
            return firstError
        }
    }

    private static func run(_ job: PendingImport, into album: Album) async -> Bool {
        let store = CloudStore.shared
        await PremiumStore.shared.start()
        await PremiumStore.shared.refreshEntitlements()
        guard PendingImports.visible(job) else { return false }
        let epoch = store.accountEpoch
        var finished = false
        var canceledByUser = false
        var deferredDeletion = false
        var quotaReached = false
        await store.perform("原本を準備中…") {
            store.beginImport()
            defer { store.endImport(); store.revision = UUID() }
            var verified: [PhotoSourceSnapshot] = []
            var issue: String?
            let pending = job.readyIndices
            if PremiumStore.shared.isPremium && album.storage == .iCloud && (!job.deleteOriginals || job.photoIDs == nil || job.quality != .original) && pending.count > 1 {
                issue = await uploadCloud(pending, job: job, into: album, epoch: epoch)
            } else {
                for index in pending {
                    if store.stopRequested || Task.isCancelled { break }
                    ImportMonitor.shared.begin(job.id, index: index)
                    defer { ImportMonitor.shared.end(job.id, index: index) }
                    do {
                        try store.checkAccount(epoch, for: album)
                        store.progress = "原本を保存中 \(index + 1)/\(job.count)"
                        let source = try job.source(at: index, folder: PendingImports.directory(for: job.id))
                        let original = try await source.original(quality: job.quality)
                        defer { original.clean() }
                        if store.stopRequested { break }
                        try store.checkAccount(epoch, for: album)
                        try Task.checkCancellation()
                        let outcome = try await store.upload(original, into: album, folderID: job.folderID)
                        if job.deleteOriginals && !store.stopRequested,
                           let snapshot = original.sourceSnapshot, snapshot.allResourcesPreserved {
                            store.progress = "保存先の原本を確認中 \(index + 1)/\(job.count)"
                            switch outcome {
                            case .added:
                                try await store.verifySaved(original, album: album)
                                verified.append(snapshot)
                            case .alreadyPresent:
                                // The same source may already exist at JPEG quality.
                                // Keep its original if the saved bytes are different or cannot be checked.
                                do {
                                    try await store.verifySaved(original, album: album)
                                    verified.append(snapshot)
                                } catch { /* Keep the source photo and continue with the next item. */ }
                            }
                        }
                        try PendingImports.mark(job.id, index: index)
                    } catch {
                        quotaReached = error is PhotoLimitReached
                        issue = error.localizedDescription
                        if !(error is CancellationError) && !Task.isCancelled {
                            try PendingImports.fail(job.id, index: index, message: error.localizedDescription)
                        }
                        if quotaReached || Task.isCancelled || store.accountEpoch != epoch { break }
                    }
                }
            }
            if issue == nil && !store.stopRequested && !Task.isCancelled && job.deleteOriginals && job.quality == .original {
                if UIApplication.shared.applicationState != .active {
                    // PhotoKit confirmation needs the foreground. Preserve the queue until then.
                    deferredDeletion = true
                } else {
                    if let ids = job.photoIDs {
                        // Previously confirmed items need fresh verification after a background pause.
                        for index in job.completed.sorted() {
                            guard ids.indices.contains(index) else { continue }
                            do {
                                let original = try await Original.fromAsset(identifier: ids[index])
                                defer { original.clean() }
                                guard let snapshot = original.sourceSnapshot, snapshot.allResourcesPreserved else { continue }
                                try await store.verifySaved(original, album: album)
                                verified.append(snapshot)
                            } catch { /* Keep this source photo; never delete without a fresh match. */ }
                        }
                    }
                    if !verified.isEmpty {
                        do {
                            try store.checkAccount(epoch, for: album)
                            store.progress = "保存済み写真の削除を確認中…"
                            store.importCanStop = false
                            _ = try await PhotoDeletion.deleteVerified(verified)
                        } catch {
                            store.errorMessage = "元写真の削除は完了しませんでした。保存した写真は残っています。\n" + error.localizedDescription
                        }
                    }
                }
            }
            if let issue, !store.backgroundExpired && !Task.isCancelled {
                store.errorMessage = "保存できなかった写真があります。アップロード状況から再試行できます。元の写真は残しています。\n" + issue
            }
            canceledByUser = store.stopRequested && !store.backgroundExpired
            if issue != nil && !Task.isCancelled { canceledByUser = true }
            finished = issue == nil && !deferredDeletion && !store.stopRequested && !Task.isCancelled &&
                       ((try? PendingImports.all().first(where: { $0.id == job.id })?.completed.count) ?? 0) == job.count
        }
        if finished {
            do { try PendingImports.finish(job.id) }
            catch { store.report(error); return false }
            return true
        }
        let hasFailures = (try? PendingImports.all().first(where: { $0.id == job.id })?.errors?.isEmpty == false) ?? false
        if canceledByUser || quotaReached || hasFailures {
            do { try PendingImports.change(job.id) { $0.paused = true } }
            catch { store.report(error); return false }
            return true
        }
        if deferredDeletion { return false }
        PendingImports.schedule()
        return false
    }

    /// Called at launch, on foreground entry, and by the system's processing task.
    @discardableResult static func resumePending() async -> Bool {
        if processing || CloudStore.shared.busy { return (try? !PendingImports.all().contains(where: { $0.runnable })) ?? false }
        processing = true
        defer { processing = false }
        do {
            let pending = try PendingImports.all().filter { $0.runnable }
            let store = CloudStore.shared
            if pending.contains(where: { job in
                !store.albums.contains(where: { $0.id == job.albumID }) ||
                (job.storage == .iCloud && store.personalPhotoScope(albumID: job.albumID, storage: .iCloud) == nil)
            }) {
                await store.refresh()
            }
            while let job = try PendingImports.all().first(where: { $0.runnable && PendingImports.visible($0) }) {
                let store = CloudStore.shared
                if !store.albums.contains(where: { $0.id == job.albumID }) { await store.refresh() }
                guard let album = store.albums.first(where: { $0.id == job.albumID }) else {
                    try PendingImports.change(job.id) { value in
                        value.paused = true
                        for index in value.readyIndices {
                            if value.errors == nil { value.errors = [:] }
                            value.errors?[index] = "保存先のアルバムを確認できません。接続とアクセス権を確認して再試行してください。"
                        }
                    }
                    continue
                }
                if !(await run(job, into: album)) { return false }
            }
            return true
        } catch { CloudStore.shared.report(error); return false }
    }

    static func photos(_ identifiers: [String], into album: Album, folderID: String? = nil,
                       quality: UploadQuality = .original) async {
        guard !identifiers.isEmpty else { return }
        var seen = Set<String>()
        let ids = identifiers.filter { seen.insert($0).inserted }
        do {
            try PendingImports.enqueuePhotos(ids, album: album, folderID: folderID, quality: quality)
            await resumePending()
        } catch { CloudStore.shared.report(error) }
    }

    static func files(_ urls: [URL], into album: Album, folderID: String? = nil,
                      quality: UploadQuality = .original) async {
        guard !urls.isEmpty else { return }
        let store = CloudStore.shared
        await store.perform("原本を準備中…") {
            store.beginImport()
            defer { store.endImport() }
            try await PendingImports.enqueueFiles(urls, album: album, folderID: folderID, quality: quality)
        }
        await resumePending()
    }
}
