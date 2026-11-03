import Foundation
import SwiftUI
import BackgroundTasks
import UIKit
import CloudKit

enum BackupFrequency: String, Codable, CaseIterable, Identifiable {
    case daily, weekly
    var id: String { rawValue }
    var title: String { self == .daily ? "毎日" : "毎週" }
}

struct BackupConfiguration: Codable, Equatable {
    var enabled = false
    var frequency: BackupFrequency = .daily
    var hour = 2
    var minute = 0
    var weekday = 1 // Calendar weekday: Sunday = 1.
    func nextDate(after date: Date, calendar: Calendar = .current) -> Date? {
        var parts = DateComponents()
        parts.hour = min(23, max(0, hour))
        parts.minute = min(59, max(0, minute))
        parts.second = 0
        if frequency == .weekly { parts.weekday = min(7, max(1, weekday)) }
        return calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .forward)
    }
}

struct BackupResource: Codable {
    let name: String
    let kind: Int
    let sha256: String
    let path: String
}
struct BackupPhoto: Codable {
    let id: String
    let folderID: String?
    let takenAt: Date
    let addedAt: Date
    let location: PhotoLocation?
    let rotationQuarterTurns: Int
    let favorite: Bool
    let resources: [BackupResource]
}
struct BackupFolder: Codable {
    let id: String
    let title: String
    let parentID: String?
    let coverPhotoID: String?
}
struct BackupAlbum: Codable {
    let id: String
    let title: String
    let storage: AlbumStorage
    let shared: Bool
    let coverPhotoID: String?
    let coverFolderID: String?
    let folders: [BackupFolder]
    let photos: [BackupPhoto]
}
struct BackupManifest: Codable {
    let version: Int
    let createdAt: Date
    let albums: [BackupAlbum]
}

/// Immutable original files plus a dated catalog. Failed runs never replace a complete catalog.
actor BackupArchive {
    let root: URL
    init(root: URL) { self.root = root }
    static func iCloudRoot(deviceID: String, accountScope: String, edition: String) throws -> URL {
        guard FileManager.default.ubiquityIdentityToken != nil,
              let container = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.example.AlbumCircle") else {
            throw UserError(message: "iCloud Driveを利用できません。iPhoneの設定でiCloud Driveとこのアプリの利用を確認してください。")
        }
        return container.appendingPathComponent("Documents/Backups", isDirectory: true)
            .appendingPathComponent(edition, isDirectory: true)
            .appendingPathComponent(deviceID, isDirectory: true)
            .appendingPathComponent(Original.digest(Data(accountScope.utf8)), isDirectory: true)
    }
    func save(_ original: Original) throws -> [BackupResource] {
        try Task.checkCancellation()
        let fm = FileManager.default
        let objects = root.appendingPathComponent("Photos", isDirectory: true)
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)
        let namesHash = Original.digest(try JSONEncoder().encode(original.names))
        let key = original.identity + "-" + namesHash
        var destination = objects.appendingPathComponent(key, isDirectory: true)
        func resources(_ directory: URL) -> [BackupResource] {
            original.names.indices.map { index in
                BackupResource(name: original.names[index], kind: original.kinds[index], sha256: original.hashes[index],
                    path: "Photos/" + directory.lastPathComponent + "/\(index)/" + original.names[index].replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last!)
            }
        }
        if fm.fileExists(atPath: destination.path) {
            var valid = true
            for index in original.urls.indices {
                try Task.checkCancellation()
                let file = try Original.resourceURL(destination, index: index, name: original.names[index])
                if (try? Original.hashFile(file)) != original.hashes[index] { valid = false; break }
            }
            if valid { return resources(destination) }
            // Preserve any prior backup, including an iCloud file that is not downloaded yet.
            destination = objects.appendingPathComponent(key + "-" + UUID().uuidString, isDirectory: true)
        }
        let stage = objects.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        for index in original.urls.indices {
            try Task.checkCancellation()
            let target = try Original.resourceURL(stage, index: index, name: original.names[index])
            try fm.copyItem(at: original.urls[index], to: target)
            guard try Original.hashFile(target) == original.hashes[index] else {
                throw UserError(message: "バックアップした写真の検証に失敗しました。")
            }
        }
        try Task.checkCancellation()
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: [], error: &coordinationError) { target in
            do { try fm.moveItem(at: stage, to: target) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        return resources(destination)
    }
    func finish(_ manifest: BackupManifest) throws -> String {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "Backup-" + formatter.string(from: manifest.createdAt) + "-" + UUID().uuidString + ".json"
        let url = root.appendingPathComponent(name)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        return name
    }
}

@MainActor
final class PhotoBackup: ObservableObject {
    static let shared = PhotoBackup()
    nonisolated static var identifier: String { (Bundle.main.bundleIdentifier ?? "com.example.AlbumCircle") + ".backup" }
    @Published var configuration: BackupConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: "backup.configuration") }
            nextDue = configuration.enabled ? configuration.nextDate(after: Date()) : nil
            retryAfter = nil
            if !configuration.enabled { work?.cancel() }
            schedule()
        }
    }
    @Published private(set) var nextDue: Date? { didSet { defaults.set(nextDue, forKey: "backup.nextDue") } }
    @Published private(set) var lastCreated: Date? { didSet { defaults.set(lastCreated, forKey: "backup.lastCreated") } }
    @Published private(set) var message: String? { didSet { defaults.set(message, forKey: "backup.message") } }
    @Published private(set) var isRunning = false
    @Published private(set) var progress = ""
    private let defaults: UserDefaults
    @Published private var retryAfter: Date? { didSet { defaults.set(retryAfter, forKey: "backup.retryAfter") } }
    private var work: Task<Bool, Never>?
    private var foregroundTask: UIBackgroundTaskIdentifier = .invalid
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: "backup.configuration").flatMap { try? JSONDecoder().decode(BackupConfiguration.self, from: $0) } ?? BackupConfiguration()
        nextDue = defaults.object(forKey: "backup.nextDue") as? Date
        lastCreated = defaults.object(forKey: "backup.lastCreated") as? Date
        message = defaults.string(forKey: "backup.message")
        retryAfter = defaults.object(forKey: "backup.retryAfter") as? Date
        if configuration.enabled && nextDue == nil { nextDue = configuration.nextDate(after: Date()) }
    }
    var requestedDate: Date? {
        guard configuration.enabled, let nextDue else { return nil }
        return max(nextDue, retryAfter ?? nextDue)
    }
    func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        guard let due = requestedDate else { return }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = max(due, Date().addingTimeInterval(30))
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do { try BGTaskScheduler.shared.submit(request) }
        catch { message = "バックグラウンド実行を予約できませんでした。アプリを開いた際に再確認します。" }
    }
    func clockChanged() {
        guard configuration.enabled else { return }
        if let nextDue, nextDue <= Date() { schedule(); return }
        nextDue = configuration.nextDate(after: Date())
        schedule()
    }
    func accountChanged() {
        work?.cancel()
        lastCreated = nil
        message = nil
        retryAfter = nil
        if configuration.enabled { nextDue = configuration.nextDate(after: Date()); schedule() }
    }
    func cancel() { work?.cancel() }
    @discardableResult func runIfDue(force: Bool = false) async -> Bool {
        guard !isRunning, !Task.isCancelled else { return false }
        if !force {
            guard let due = requestedDate, due <= Date() else { schedule(); return true }
        }
        let store = CloudStore.shared
        guard !store.busy, !AlbumImporter.isProcessing else {
            if force { message = "写真の保存処理が終わってから実行してください。" }
            retryAfter = Date().addingTimeInterval(15 * 60)
            schedule()
            return false
        }
        isRunning = true
        message = nil
        store.busy = true
        let epoch = store.accountEpoch
        let task = Task { await self.createBackup() }
        work = task
        // BGProcessingTask owns its expiration. A short UIKit extension must not cut it off.
        if UIApplication.shared.applicationState == .active {
            foregroundTask = UIApplication.shared.beginBackgroundTask(withName: "写真のバックアップ") { [weak self] in
                Task { @MainActor in self?.cancel() }
            }
        }
        let completed = await task.value
        let success = completed && !task.isCancelled && epoch == store.accountEpoch
        work = nil
        if foregroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(foregroundTask)
            foregroundTask = .invalid
        }
        store.busy = false
        store.progress = ""
        isRunning = false
        if success {
            lastCreated = Date()
            nextDue = configuration.enabled ? configuration.nextDate(after: Date()) : nil
            retryAfter = nil
        } else { retryAfter = Date().addingTimeInterval(60 * 60) }
        schedule()
        return success
    }
    private func createBackup() async -> Bool {
        let store = CloudStore.shared
        let epoch = store.accountEpoch
        let identity = FileManager.default.ubiquityIdentityToken as? NSObject
        func check() throws {
            try Task.checkCancellation()
            guard epoch == store.accountEpoch,
                  let identity, let current = FileManager.default.ubiquityIdentityToken as? NSObject,
                  identity.isEqual(current) else {
                throw UserError(message: "iCloudアカウントが変更されたためバックアップを停止しました。")
            }
        }
        do {
            guard identity != nil else { throw UserError(message: "iCloud Driveにサインインしてください。") }
            progress = "アルバムを確認中…"; store.progress = progress
            let albums = try await store.albumsForBackup()
            try check()
            guard let scope = store.personalPhotoScope(albumID: "backup", storage: .iCloud) else {
                throw UserError(message: "iCloudアカウントを確認できませんでした。")
            }
            let deviceID = defaults.string(forKey: "backup.deviceID") ?? UUID().uuidString
            defaults.set(deviceID, forKey: "backup.deviceID")
            let edition = AppEdition.isPersonal ? "Personal" : "AppStore"
            let root = try await Task.detached {
                try BackupArchive.iCloudRoot(deviceID: deviceID, accountScope: scope, edition: edition)
            }.value
            try check()
            let archive = BackupArchive(root: root)
            var saved: [BackupAlbum] = []
            for album in albums {
                try check()
                let contents = try await store.contents(in: album, forceRefresh: true)
                guard contents.skipped == 0 else { throw UserError(message: "読み取れない写真やフォルダがあります。完全なバックアップを作成できませんでした。") }
                var photos: [BackupPhoto] = []
                for (index, picture) in contents.pictures.enumerated() {
                    try check()
                    progress = "\(album.title)：\(index + 1)/\(contents.pictures.count)枚をバックアップ中"
                    store.progress = progress
                    let original = try await store.download(picture, album: album)
                    defer { original.clean() }
                    try check()
                    let resources = try await archive.save(original)
                    try check()
                    photos.append(BackupPhoto(id: picture.id.recordName, folderID: picture.folderID,
                        takenAt: original.date, addedAt: picture.addedAt, location: original.location,
                        rotationQuarterTurns: picture.rotationQuarterTurns,
                        favorite: FavoritePhotos.shared.contains(picture.id.recordName, scope: store.personalPhotoScope(for: album)),
                        resources: resources))
                }
                saved.append(BackupAlbum(id: album.id, title: album.title, storage: album.storage, shared: album.shared,
                    coverPhotoID: album.coverPhotoID, coverFolderID: album.coverFolderID,
                    folders: contents.folders.map { BackupFolder(id: $0.id, title: $0.title, parentID: $0.parentID, coverPhotoID: $0.coverPhotoID) }, photos: photos))
            }
            try check()
            _ = try await archive.finish(BackupManifest(version: 1, createdAt: Date(), albums: saved))
            try check()
            progress = "バックアップを作成しました"
            return true
        } catch is CancellationError {
            message = "バックアップを中断しました。以前のバックアップは残っています。"
        } catch { message = error.localizedDescription }
        return false
    }
}
