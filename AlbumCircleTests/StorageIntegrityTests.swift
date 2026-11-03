import XCTest
import CloudKit
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import UIKit
@testable import AlbumCircle

final class EditionConfigurationTests: XCTestCase {
    func testEditionMatchesInstalledBundleAndBackgroundTask() {
        let bundle = Bundle(for: CloudStore.self)
        let expected = AppEdition.isPersonal ? "com.example.AlbumCircle" : "com.example.AlbumCircle.AppStore"
        XCTAssertEqual(bundle.bundleIdentifier, expected)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
                       [expected + ".imports", expected + ".backup"])
    }

    @MainActor func testPersonalEditionUnlocksWithoutStoreKitAndNeverShowsAds() async {
        guard AppEdition.isPersonal else { return }
        let store = PremiumStore()
        await store.start()
        await store.restore()
        XCTAssertTrue(store.isPremium)
        XCTAssertTrue(store.isReady)
        XCTAssertFalse(store.shouldShowAds)
        XCTAssertTrue(store.products.isEmpty)
        XCTAssertNil(store.message)
    }

    @MainActor func testPublicEditionDoesNotGrantPremiumBeforeVerification() {
        guard !AppEdition.isPersonal else { return }
        let store = PremiumStore()
        XCTAssertFalse(store.isPremium)
        XCTAssertFalse(store.isReady)
        XCTAssertFalse(store.shouldShowAds, "広告は購入状態の初期確認が終わるまで表示しない")
    }
}

final class PhotoQuotaTests: XCTestCase {
    func testFreeLimitAllowsDuplicatesButRejectsNewPhotos() throws {
        let ids: Set<String> = ["one", "two"]
        XCTAssertNoThrow(try PhotoQuota.check(existingIDs: ids, incomingID: "one", premium: false, limit: 2))
        XCTAssertThrowsError(try PhotoQuota.check(existingIDs: ids, incomingID: "three", premium: false, limit: 2)) {
            XCTAssertTrue($0 is PhotoLimitReached)
        }
        XCTAssertNoThrow(try PhotoQuota.check(existingIDs: ["one"], incomingID: "two", premium: false, limit: 2))
    }

    func testPremiumBypassesLimitAndExpiredPlanDoesNotDeleteExistingPhotos() {
        let ids: Set<String> = ["one", "two", "three"]
        XCTAssertNoThrow(try PhotoQuota.check(existingIDs: ids, incomingID: "four", premium: true, limit: 2))
        XCTAssertThrowsError(try PhotoQuota.check(existingIDs: ids, incomingID: "four", premium: false, limit: 2))
        XCTAssertNoThrow(try PhotoQuota.check(existingIDs: ids, incomingID: "two", premium: false, limit: 2))
        XCTAssertEqual(ids.count, 3)
    }

    @MainActor func testConcurrentImportsCannotBothTakeTheLastSlot() async {
        let gate = PhotoImportGate()
        var saved: Set<String> = ["existing"]
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for id in ["first", "second"] {
                group.addTask { @MainActor in
                    do {
                        try await gate.perform {
                            try PhotoQuota.check(existingIDs: saved, incomingID: id, premium: false, limit: 2)
                            await Task.yield()
                            saved.insert(id)
                        }
                        return true
                    } catch { return false }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(saved.count, 2)
        // A failed import must release the gate so deletion can make room again.
        saved.remove("existing")
        do {
            try await gate.perform {
                try PhotoQuota.check(existingIDs: saved, incomingID: "replacement", premium: false, limit: 2)
                saved.insert("replacement")
            }
        } catch { XCTFail("The gate should remain usable after an error: \(error)") }
        XCTAssertEqual(saved.count, 2)
    }
}

final class StorageIntegrityTests: XCTestCase {
    private func fixture() throws -> Original {
        let directory = try Original.makeDirectory()
        let url = directory.appendingPathComponent("fixture.bin")
        // More than one hash stream chunk; exact bytes matter, thumbnail support does not.
        let bytes = Data((0..<(1024 * 1024 + 17)).map { UInt8($0 % 251) })
        try bytes.write(to: url)
        return try Original.assemble(directory: directory, urls: [url], names: ["fixture.bin"], kinds: [1], date: Date(timeIntervalSince1970: 12345))
    }
    func testSHA256KnownVector() {
        XCTAssertEqual(Original.digest(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testRejectsMalformedResourceSetAndNames() throws {
        let directory = try Original.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try Original.assemble(directory: directory, urls: [], names: [], kinds: [], date: Date()))
        XCTAssertThrowsError(try Original.assemble(directory: directory, urls: [directory], names: [], kinds: [1], date: Date()))
        for name in ["", ".", "..", "folder/..", "folder/", "bad\0name"] {
            XCTAssertThrowsError(try Original.resourceURL(directory, index: 0, name: name))
        }
        let safe = try Original.resourceURL(directory, index: 0, name: "../../IMG_0001.HEIC")
        XCTAssertEqual(safe.deletingLastPathComponent(), directory.appendingPathComponent("0", isDirectory: true))
    }
    func testLocalRoundTripAndDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "テスト")
        let albums = try await store.albums()
        let album = try XCTUnwrap(albums.values.first)
        XCTAssertEqual(album.storage, .device)
        let original = try fixture()
        defer { original.clean() }
        let first = try await store.save(original, into: album)
        let second = try await store.save(original, into: album)
        if case .added = first {} else { XCTFail("first save must add") }
        if case .alreadyPresent = second {} else { XCTFail("second save must deduplicate") }
        let batch = try await store.pictures(in: album)
        XCTAssertEqual(batch.values.count, 1)
        let restored = try await store.download(XCTUnwrap(batch.values.first), album: album)
        defer { restored.clean() }
        XCTAssertEqual(restored.hashes, original.hashes)
        XCTAssertEqual(try Data(contentsOf: restored.urls[0]), try Data(contentsOf: original.urls[0]))
    }
    func testRotationPersistsAfterRestartWithoutChangingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "向きを保存")
        let albums = try await store.albums()
        let album = try XCTUnwrap(albums.values.first)
        let original = try fixture()
        defer { original.clean() }
        _ = try await store.save(original, into: album)
        let initial = try await store.pictures(in: album)
        let picture = try XCTUnwrap(initial.values.first)
        XCTAssertEqual(picture.rotationQuarterTurns, 0)
        try await store.setRotation(1, for: picture, in: album)
        let reopened = LocalStore(rootURL: root)
        let changed = try await reopened.pictures(in: album)
        let rotated = try XCTUnwrap(changed.values.first)
        XCTAssertEqual(rotated.rotationQuarterTurns, 1)
        try await reopened.setRotation(3, for: rotated, in: album)
        let latest = try await reopened.pictures(in: album)
        let final = try XCTUnwrap(latest.values.first)
        XCTAssertEqual(final.rotationQuarterTurns, 3)
        let copy = try await reopened.download(final, album: album)
        defer { copy.clean() }
        XCTAssertEqual(copy.hashes, original.hashes)
        XCTAssertEqual(try Data(contentsOf: copy.urls[0]), try Data(contentsOf: original.urls[0]))
        do {
            try await reopened.setRotation(4, for: final, in: album)
            XCTFail("Only quarter-turns 0 through 3 may be saved")
        } catch { }
    }
    func testCorruptedOriginalCannotPassDuplicateVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "検証")
        let albums = try await store.albums()
        let album = try XCTUnwrap(albums.values.first)
        let original = try fixture()
        defer { original.clean() }
        _ = try await store.save(original, into: album)
        let savedFile = root.appendingPathComponent(album.zone.zoneName).appendingPathComponent("Pictures")
            .appendingPathComponent(original.identity).appendingPathComponent("0").appendingPathComponent("fixture.bin")
        try Data("corrupted".utf8).write(to: savedFile)
        do {
            _ = try await store.save(original, into: album)
            XCTFail("Corrupted saved data must not count as a verified duplicate")
        } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.urls[0].path))
        XCTAssertEqual(try Data(contentsOf: savedFile), Data("corrupted".utf8)) // No silent removal/overwrite.
    }
    func testBadAlbumMetadataDoesNotHideHealthyAlbumOrDeleteData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "正常")
        try await store.createAlbum(title: "破損させる")
        let before = try await store.albums()
        let damaged = try XCTUnwrap(before.values.first { $0.title == "破損させる" })
        let metadata = root.appendingPathComponent(damaged.zone.zoneName).appendingPathComponent("album.json")
        try Data("broken".utf8).write(to: metadata)
        let after = try await store.albums()
        XCTAssertEqual(after.values.map(\.title), ["正常"])
        XCTAssertEqual(after.skipped, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    }
    @MainActor
    func testDeviceSharingIsRejectedBeforeNetworkAccess() async throws {
        let record = CKRecord(recordType: "Album", recordID: .init(recordName: "album", zoneID: .init(zoneName: "Local-" + UUID().uuidString, ownerName: CKCurrentUserDefaultName)))
        let album = Album(record: record, shared: false, storage: .device)
        do {
            _ = try await CloudStore.shared.share(for: album)
            XCTFail("Device albums must never be shared")
        } catch {
            XCTAssertTrue(error is UserError)
        }
    }
    @MainActor
    func testStoppedShareIsRemovedButTemporaryFailureKeepsOtherAlbums() {
        func album(_ name: String, shared: Bool, storage: AlbumStorage = .iCloud) -> Album {
            let zone = CKRecordZone.ID(zoneName: (storage == .device ? "Local-" : "Album-") + UUID().uuidString,
                                       ownerName: shared ? "another-owner" : CKCurrentUserDefaultName)
            let record = CKRecord(recordType: "Album", recordID: .init(recordName: "album", zoneID: zone))
            record["title"] = name as CKRecordValue
            return Album(record: record, shared: shared, storage: storage)
        }
        let local = album("端末内", shared: false, storage: .device)
        let owned = album("自分のアルバム", shared: false)
        let withdrawn = album("共有停止", shared: true)
        let active = album("共有中", shared: true)
        let existing = [local, owned, withdrawn, active]
        let stopped = CloudStore.reconciledAlbums(local: [local], previous: existing,
                                                  owned: .success([owned]), shared: .success([active]))
        XCTAssertEqual(stopped.map(\.id), [local.id, owned.id, active.id])

        let offline = CloudStore.reconciledAlbums(local: [local], previous: existing,
                                                  owned: .success([owned]),
                                                  shared: .failure(UserError(message: "通信できません")))
        XCTAssertEqual(offline.map(\.id), existing.map(\.id))

        let ownedOffline = CloudStore.reconciledAlbums(local: [local], previous: existing,
                                                       owned: .failure(UserError(message: "通信できません")),
                                                       shared: .success([active]))
        XCTAssertEqual(ownedOffline.map(\.id), [local.id, owned.id, active.id])
    }
}

// Integrated from FolderHierarchyTests.swift
final class FolderHierarchyTests: XCTestCase {
    private func original(name: String = "sample.bin", byte: UInt8 = 42) throws -> Original {
        let directory = try Original.makeDirectory()
        let url = directory.appendingPathComponent(name)
        try Data(repeating: byte, count: 8193).write(to: url)
        return try Original.assemble(directory: directory, urls: [url], names: [name], kinds: [1], date: Date())
    }
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testNestedFolderRoundTripAndRenamedDuplicateKeepsFirstLocation() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "家族")
        let batch = try await store.albums()
        let album = try XCTUnwrap(batch.values.first)
        let parent = try await store.createFolder("旅行", in: album)
        let child = try await store.createFolder("1日目", in: album, parentID: parent)
        let other = try await store.createFolder("その他", in: album)
        let first = try original()
        let renamed = try original(name: "different-name.bin")
        defer { first.clean(); renamed.clean() }
        _ = try await store.save(first, into: album, folderID: child)
        let duplicate = try await store.save(renamed, into: album, folderID: other)
        if case .alreadyPresent = duplicate {} else { XCTFail("same bytes must not be imported in another folder") }
        let reopened = LocalStore(rootURL: root)
        let contents = try await reopened.contents(in: album)
        XCTAssertEqual(contents.folders.count, 3)
        XCTAssertEqual(contents.children(of: parent).map(\.id), [child])
        XCTAssertEqual(contents.pictures.count, 1)
        XCTAssertEqual(contents.photos(in: nil).count, 0)
        XCTAssertEqual(contents.photos(in: parent, recursive: true).count, 1)
        XCTAssertEqual(contents.photos(in: other).count, 0)
        XCTAssertEqual(contents.recursivePhotoCounts()[parent], 1)
        XCTAssertEqual(contents.recursivePhotoCounts()[child], 1)
        XCTAssertEqual(contents.recursivePhotoCounts()[other, default: 0], 0)
        XCTAssertEqual(contents.pictures.first?.folderID, child)
        let restored = try await reopened.download(XCTUnwrap(contents.pictures.first), album: album)
        defer { restored.clean() }
        XCTAssertEqual(try Data(contentsOf: restored.urls[0]), try Data(contentsOf: first.urls[0]))
    }

    func testExplicitCoversSurviveImportsRenamesAndRestart() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "アルバム")
        let albums = try await store.albums()
        let album = try XCTUnwrap(albums.values.first)
        let folder = try await store.createFolder("旅行", in: album)
        let nested = try await store.createFolder("景色", in: album, parentID: folder)
        let a = try original(byte: 1), b = try original(byte: 2)
        defer { a.clean(); b.clean() }
        _ = try await store.save(a, into: album, folderID: nested)
        let initial = try await store.contents(in: album)
        let chosen = try XCTUnwrap(initial.pictures.first)
        try await store.setCover(chosen, in: album)
        try await store.setCover(chosen, in: album, folderID: folder)
        _ = try await store.save(b, into: album, folderID: folder)
        try await store.rename(album, title: "新しい名前")
        try await store.renameFolder(folder, in: album, title: "新しい旅行")
        let reopened = LocalStore(rootURL: root)
        let reread = try await reopened.albums()
        let updated = try XCTUnwrap(reread.values.first)
        let contents = try await reopened.contents(in: updated)
        XCTAssertEqual(updated.coverPhotoID, a.identity)
        XCTAssertEqual(contents.folders.first { $0.id == folder }?.coverPhotoID, a.identity)
        XCTAssertEqual(contents.cover(updated.coverPhotoID, in: nil)?.id, chosen.id)
        XCTAssertEqual(contents.cover(a.identity, in: folder)?.id, chosen.id)
        try await reopened.delete(chosen, album: updated)
        let afterDelete = try await reopened.contents(in: updated)
        XCTAssertNil(afterDelete.cover(updated.coverPhotoID, in: nil)) // Never auto-select B.
        XCTAssertEqual(afterDelete.pictures.count, 1)
    }

    func testAlbumCoverCanFollowFolderAndSwitchBackToPhoto() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "家族")
        try await store.createAlbum(title: "別のアルバム")
        let albums = try await store.albums()
        let album = try XCTUnwrap(albums.values.first { $0.title == "家族" })
        let other = try XCTUnwrap(albums.values.first { $0.title == "別のアルバム" })
        let folder = try await store.createFolder("旅行", in: album)
        let nested = try await store.createFolder("一日目", in: album, parentID: folder)
        let foreign = try await store.createFolder("旅行", in: other)
        let original = try original(byte: 71)
        defer { original.clean() }
        _ = try await store.save(original, into: album, folderID: nested)
        do {
            try await store.setAlbumCoverFolder(foreign, in: album)
            XCTFail("Another album's folder must not become this album's cover")
        } catch { }
        try await store.setAlbumCoverFolder(folder, in: album)
        let reopened = LocalStore(rootURL: root)
        let reopenedAlbums = try await reopened.albums()
        let updated = try XCTUnwrap(reopenedAlbums.values.first { $0.id == album.id })
        XCTAssertEqual(updated.coverFolderID, folder)
        XCTAssertNil(updated.coverPhotoID)
        let contents = try await reopened.contents(in: updated)
        XCTAssertEqual(contents.photos(in: updated.coverFolderID, recursive: true).first?.id.recordName, original.identity)
        try await reopened.setCover(try XCTUnwrap(contents.pictures.first), in: updated)
        let currentAlbums = try await reopened.albums()
        let photoCover = try XCTUnwrap(currentAlbums.values.first { $0.id == album.id })
        XCTAssertNil(photoCover.coverFolderID)
        XCTAssertEqual(photoCover.coverPhotoID, original.identity)
    }

    func testRejectsForeignFolderAndCoverOutsideFolder() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "A")
        try await store.createAlbum(title: "B")
        let albums = try await store.albums()
        let a = try XCTUnwrap(albums.values.first { $0.title == "A" })
        let b = try XCTUnwrap(albums.values.first { $0.title == "B" })
        let foreign = try await store.createFolder("Bのフォルダ", in: b)
        let empty = try await store.createFolder("空", in: a)
        let photo = try original()
        defer { photo.clean() }
        do {
            _ = try await store.save(photo, into: a, folderID: foreign)
            XCTFail("cross-album folder must be rejected")
        } catch { }
        _ = try await store.save(photo, into: a)
        let contents = try await store.contents(in: a)
        do {
            try await store.setCover(XCTUnwrap(contents.pictures.first), in: a, folderID: empty)
            XCTFail("folder cover must come from its own descendants")
        } catch { }
        let after = try await store.contents(in: a)
        XCTAssertNil(after.folders.first { $0.id == empty }?.coverPhotoID)
        XCTAssertEqual(after.pictures.count, 1)
        // A different album is an independent audience and can keep the same original.
        let result = try await store.save(photo, into: b, folderID: foreign)
        if case .added = result {} else { XCTFail("different albums should be independent") }
    }

    func testVersion03MetadataRemainsReadableWithoutMigration() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let zoneName = "Local-" + UUID().uuidString
        let base = root.appendingPathComponent(zoneName)
        let source = try original()
        defer { source.clean() }
        let saved = base.appendingPathComponent("Pictures").appendingPathComponent(source.identity)
        let resources = saved.appendingPathComponent("0")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("{\"title\":\"旧版アルバム\"}".utf8).write(to: base.appendingPathComponent("album.json"))
        try FileManager.default.copyItem(at: source.urls[0], to: resources.appendingPathComponent(source.names[0]))
        // v0.3.0 has no coverPhotoID, folderID or Folders directory.
        let manifest: [String: Any] = ["names": source.names, "kinds": source.kinds, "hashes": source.hashes,
                                      "date": source.date.timeIntervalSinceReferenceDate, "bytes": source.bytes]
        try JSONSerialization.data(withJSONObject: manifest).write(to: saved.appendingPathComponent("photo.json"))
        let store = LocalStore(rootURL: root)
        let albums = try await store.albums()
        let album = try XCTUnwrap(albums.values.first)
        let contents = try await store.contents(in: album)
        XCTAssertNil(album.coverPhotoID)
        XCTAssertTrue(contents.folders.isEmpty)
        XCTAssertEqual(contents.photos(in: nil).count, 1)
        XCTAssertEqual(contents.pictures.first?.rotationQuarterTurns, 0)
        XCTAssertEqual(contents.skipped, 0)
        let roundTrip = try await store.download(XCTUnwrap(contents.pictures.first), album: album)
        defer { roundTrip.clean() }
        XCTAssertEqual(roundTrip.hashes, source.hashes)
    }
}

final class PhotoOrganizationTests: XCTestCase {
    private func picture(_ id: String, taken: Date, added: Date) -> Picture {
        let record = CKRecord(recordType: "Picture", recordID: .init(recordName: id))
        record["takenAt"] = taken as CKRecordValue
        record["addedAt"] = added as CKRecordValue
        return Picture(record: record)
    }
    func testSortUsesIndependentTakenAndAddedDatesAndStableTies() {
        let early = Date(timeIntervalSince1970: 10), late = Date(timeIntervalSince1970: 20)
        let photos = [picture("b", taken: early, added: late), picture("a", taken: late, added: early), picture("c", taken: early, added: late)]
        XCTAssertEqual(PhotoSort.takenNewest.apply(photos).map { $0.id.recordName }, ["a", "b", "c"])
        XCTAssertEqual(PhotoSort.takenOldest.apply(photos).map { $0.id.recordName }, ["b", "c", "a"])
        XCTAssertEqual(PhotoSort.addedNewest.apply(photos).map { $0.id.recordName }, ["b", "c", "a"])
        XCTAssertEqual(PhotoSort.addedOldest.apply(photos).map { $0.id.recordName }, ["a", "b", "c"])
    }
    func testDateFilterIncludesWholeFinalDayAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        let photos = [picture("before", taken: start.addingTimeInterval(-1), added: start),
                      picture("first", taken: start, added: start),
                      picture("last", taken: end.addingTimeInterval(-1), added: start),
                      picture("after", taken: end, added: start)]
        XCTAssertEqual(PhotoSort.takenOldest.apply(photos, from: start, through: start, calendar: calendar).map { $0.id.recordName }, ["first", "last"])
    }
    private func original() throws -> Original {
        let directory = try Original.makeDirectory(), url = directory.appendingPathComponent("sample.bin")
        try Data([1, 2, 3, 4]).write(to: url)
        return try Original.assemble(directory: directory, urls: [url], names: ["sample.bin"], kinds: [1], date: Date(timeIntervalSince1970: 123))
    }
    func testMovePreservesOriginalAdditionDateRotationAndCoverScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "移動")
        let albums = try await store.albums(), album = try XCTUnwrap(albums.values.first)
        let parent = try await store.createFolder("親", in: album)
        let child = try await store.createFolder("子", in: album, parentID: parent)
        let other = try await store.createFolder("別", in: album)
        let source = try original()
        defer { source.clean() }
        _ = try await store.save(source, into: album, folderID: child)
        let before = try await store.contents(in: album), photo = try XCTUnwrap(before.pictures.first)
        try await store.setRotation(2, for: photo, in: album)
        try await store.setCover(photo, in: album, folderID: parent)
        try await store.move([photo], in: album, to: other)
        let reopened = LocalStore(rootURL: root)
        let moved = try await reopened.contents(in: album), result = try XCTUnwrap(moved.pictures.first)
        XCTAssertEqual(moved.pictures.count, 1)
        XCTAssertEqual(result.folderID, other)
        XCTAssertEqual(result.date, photo.date)
        XCTAssertEqual(result.addedAt, photo.addedAt)
        XCTAssertEqual(result.rotationQuarterTurns, 2)
        XCTAssertNil(moved.cover(photo.id.recordName, in: parent))
        XCTAssertNotNil(moved.cover(photo.id.recordName, in: nil))
        let downloaded = try await reopened.download(result, album: album)
        defer { downloaded.clean() }
        XCTAssertEqual(downloaded.hashes, source.hashes)
        try await reopened.move([result], in: album, to: nil)
        let final = try await reopened.contents(in: album)
        XCTAssertNil(final.pictures.first?.folderID)
        XCTAssertEqual(final.pictures.first?.addedAt, photo.addedAt)
    }
    func testMovePrevalidatesMissingPhotoAndForeignDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "A")
        try await store.createAlbum(title: "B")
        let albums = try await store.albums()
        let album = try XCTUnwrap(albums.values.first(where: { $0.title == "A" }))
        let foreign = try XCTUnwrap(albums.values.first(where: { $0.title == "B" }))
        let folder = try await store.createFolder("移動先", in: album)
        let foreignFolder = try await store.createFolder("他アルバム", in: foreign)
        let source = try original()
        defer { source.clean() }
        _ = try await store.save(source, into: album)
        let contents = try await store.contents(in: album), photo = try XCTUnwrap(contents.pictures.first)
        do { try await store.move([photo], in: album, to: foreignFolder); XCTFail("Foreign destination must be rejected") } catch { }
        let missing = Picture(record: CKRecord(recordType: "Picture", recordID: .init(recordName: String(repeating: "f", count: 64), zoneID: album.zone)))
        do { try await store.move([photo, missing], in: album, to: folder); XCTFail("Missing selection must be rejected") } catch { }
        do { try await store.move([photo], in: foreign, to: foreignFolder); XCTFail("Foreign photo must be rejected") } catch { }
        let after = try await store.contents(in: album)
        XCTAssertEqual(after.pictures.count, 1)
        XCTAssertNil(after.pictures.first?.folderID)
    }
    @MainActor func testNewPhotosBaselineOwnUploadsMovesAndPersistentReadState() throws {
        let suite = "PhotoOrganizationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = NewPhotoTracker(defaults: defaults)
        let scope = NewPhotoTracker.scope(account: "user", album: "album")
        tracker.observe(ids: ["existing"], ownIDs: [], scope: scope)
        XCTAssertTrue(tracker.unread(scope: scope).isEmpty)
        tracker.markRead(["local"], scope: scope)
        tracker.observe(ids: ["existing", "remote", "local", "otherDeviceOwn"], ownIDs: ["otherDeviceOwn"], scope: scope)
        XCTAssertEqual(tracker.unread(scope: scope), ["remote"])
        // A folder move changes metadata, not the photo's identity.
        tracker.observe(ids: ["existing", "remote", "local", "otherDeviceOwn"], ownIDs: ["otherDeviceOwn"], scope: scope)
        XCTAssertEqual(tracker.unread(scope: scope), ["remote"])
        let restarted = NewPhotoTracker(defaults: defaults)
        XCTAssertEqual(restarted.unread(scope: scope), ["remote"])
        restarted.markRead(["remote"], scope: scope)
        XCTAssertTrue(NewPhotoTracker(defaults: defaults).unread(scope: scope).isEmpty)
        XCTAssertTrue(tracker.unread(scope: NewPhotoTracker.scope(account: "another", album: "album")).isEmpty)
    }
    @MainActor func testDeletedUnreadPhotosDisappearAndReadditionIsNew() throws {
        let suite = "PhotoOrganizationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = NewPhotoTracker(defaults: defaults), scope = "test"
        tracker.observe(ids: [], ownIDs: [], scope: scope)
        tracker.observe(ids: ["new"], ownIDs: [], scope: scope)
        XCTAssertEqual(tracker.unread(scope: scope), ["new"])
        tracker.observe(ids: [], ownIDs: [], scope: scope)
        XCTAssertTrue(tracker.unread(scope: scope).isEmpty)
        tracker.observe(ids: ["new"], ownIDs: [], scope: scope)
        XCTAssertEqual(tracker.unread(scope: scope), ["new"])
    }
}

final class PhotoPreviewSelectionTests: XCTestCase {
    private func picture(_ name: String) -> Picture {
        Picture(record: CKRecord(recordType: "Picture", recordID: .init(recordName: name)))
    }

    func testPresentationCarriesTappedPhotoAndPreservesPagingOrder() {
        let first = picture("first"), second = picture("second"), third = picture("third")
        let preview = PhotoPreviewSelection(picture: second, pictures: [first, second, third])
        XCTAssertEqual(preview.initialID, second.id)
        XCTAssertEqual(preview.pictures.map(\.id), [first.id, second.id, third.id])
    }

    func testEmptyOrRefreshedListStillDisplaysTappedPhoto() {
        let tapped = picture("tapped"), other = picture("other")
        let empty = PhotoPreviewSelection(picture: tapped, pictures: [])
        XCTAssertEqual(empty.pictures.map(\.id), [tapped.id])
        let refreshed = PhotoPreviewSelection(picture: tapped, pictures: [other])
        XCTAssertEqual(refreshed.pictures.first?.id, refreshed.initialID)
        XCTAssertEqual(refreshed.pictures.map(\.id), [tapped.id, other.id])
    }

    func testReadStateFilteringDoesNotEmptyPresentedSnapshot() {
        let tapped = picture("unread")
        var filtered = [tapped]
        let preview = PhotoPreviewSelection(picture: tapped, pictures: filtered)
        filtered.removeAll() // Opening a new photo makes it disappear from the unread filter.
        XCTAssertEqual(preview.pictures.map(\.id), [tapped.id])
        XCTAssertEqual(preview.initialID, tapped.id)
        XCTAssertNotEqual(preview.id, PhotoPreviewSelection(picture: tapped, pictures: [tapped]).id)
    }
}

final class PhotoMetadataTests: XCTestCase {
    private func fixture(withLocation: Bool = true) throws -> Original {
        let directory = try Original.makeDirectory()
        let url = try Original.resourceURL(directory, index: 0, name: "旅行の写真.PNG")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let target = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(target, try XCTUnwrap(image.cgImage), nil)
        XCTAssertTrue(CGImageDestinationFinalize(target))
        return try Original.assemble(directory: directory, urls: [url], names: [url.lastPathComponent],
                                     kinds: [1], date: Date(timeIntervalSince1970: 12345),
                                     location: withLocation ? PhotoLocation(CLLocation(latitude: -33.8688, longitude: 151.2093)) : nil)
    }

    func testQualityConversionKeepsExactFilenameAndLocationInJPEG() throws {
        let source = try fixture()
        defer { source.clean() }
        for quality in [UploadQuality.high, .compact] {
            let converted = try source.prepared(for: quality)
            defer { converted.clean() }
            XCTAssertEqual(converted.names, source.names)
            XCTAssertEqual(converted.urls.first?.lastPathComponent, source.names.first)
            XCTAssertEqual(converted.location, source.location)
            XCTAssertEqual(converted.duplicateIdentity, source.duplicateIdentity)
            XCTAssertNil(converted.sourceSnapshot)
            let url = try XCTUnwrap(converted.urls.first)
            let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(decoded) as String?, UTType.jpeg.identifier)
            let embedded = try XCTUnwrap(PhotoLocation.read(from: url))
            XCTAssertEqual(embedded.latitude, -33.8688, accuracy: 0.000001)
            XCTAssertEqual(embedded.longitude, 151.2093, accuracy: 0.000001)
        }
    }

    func testLocalSaveReloadMoveAndRotationPreserveLocationAndFilename() async throws {
        let root = try Original.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "Location")
        let albums = try await store.albums()
        let album = try XCTUnwrap(albums.values.first)
        let original = try fixture()
        defer { original.clean() }
        _ = try await store.save(original, into: album)
        let pictures = try await store.pictures(in: album)
        let picture = try XCTUnwrap(pictures.values.first)
        XCTAssertEqual(picture.location, original.location)
        let folder = try await store.createFolder("Folder", in: album)
        try await store.move([picture], in: album, to: folder)
        try await store.setRotation(1, for: picture, in: album)
        let reopened = LocalStore(rootURL: root)
        let restored = try await reopened.download(picture, album: album)
        defer { restored.clean() }
        XCTAssertEqual(restored.names, original.names)
        XCTAssertEqual(restored.location, original.location)
        XCTAssertEqual(restored.hashes, original.hashes)
    }

    func testMissingLocationRemainsMissingAndLegacyMetadataLoads() async throws {
        let root = try Original.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(rootURL: root)
        try await store.createAlbum(title: "Legacy")
        let albums = try await store.albums()
        let album = try XCTUnwrap(albums.values.first)
        let original = try fixture(withLocation: false)
        defer { original.clean() }
        _ = try await store.save(original, into: album)
        let converted = try original.prepared(for: .compact)
        defer { converted.clean() }
        XCTAssertNil(converted.location)
        XCTAssertNil(PhotoLocation.read(from: converted.urls[0]))
        let pictures = try await store.pictures(in: album)
        let picture = try XCTUnwrap(pictures.values.first)
        XCTAssertNil(picture.location)
        let restored = try await store.download(picture, album: album)
        defer { restored.clean() }
        XCTAssertNil(restored.location)
    }

    func testCloudRecordLocationOverridesEmbeddedLocation() throws {
        let original = try fixture()
        defer { original.clean() }
        let record = CKRecord(recordType: "Picture")
        record["files"] = original.urls.map { CKAsset(fileURL: $0) } as CKRecordValue
        record["names"] = original.names as CKRecordValue
        record["kinds"] = original.kinds.map { NSNumber(value: $0) } as CKRecordValue
        record["hashes"] = original.hashes as CKRecordValue
        record["location"] = original.location?.clLocation
        let restored = try Original.from(record)
        defer { restored.clean() }
        XCTAssertEqual(restored.location, original.location)
        XCTAssertEqual(Picture(record: record).location, original.location)
    }
}

final class FolderSortTests: XCTestCase {
    private func folder(_ id: String, _ title: String, parent: String? = nil) -> PhotoFolder {
        let record = CKRecord(recordType: "Folder", recordID: .init(recordName: id))
        record["title"] = title as CKRecordValue
        record["parentFolderID"] = parent as CKRecordValue?
        return PhotoFolder(record: record)
    }
    func testNaturalNameOrderingAndStableTies() {
        let values = [folder("b", "旅行10"), folder("c", "旅行2"), folder("a", "旅行2")]
        XCTAssertEqual(FolderSort.nameAscending.apply(values, counts: [:]).map(\.id), ["a", "c", "b"])
        XCTAssertEqual(FolderSort.nameDescending.apply(values, counts: [:]).map(\.id), ["b", "a", "c"])
    }
    func testPhotoCountOrderingIncludesDescendantsAndEmptyFolders() {
        let values = [folder("root", "A"), folder("child", "B", parent: "root"), folder("empty", "C")]
        let record = CKRecord(recordType: "Picture")
        record["folderID"] = "child" as CKRecordValue
        let contents = AlbumContents(pictures: [Picture(record: record)], folders: values)
        let roots = contents.children(of: nil), counts = contents.recursivePhotoCounts()
        XCTAssertEqual(FolderSort.mostPhotos.apply(roots, counts: counts).map(\.id), ["root", "empty"])
        XCTAssertEqual(FolderSort.fewestPhotos.apply(roots, counts: counts).map(\.id), ["empty", "root"])
    }
}

final class FavoritePhotosTests: XCTestCase {
    @MainActor func testFavoritesPersistAndRemainPrivateToAccountAndAlbum() throws {
        let suite = "FavoritePhotosTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FavoritePhotos(defaults: defaults)
        let scope = NewPhotoTracker.scope(account: "a", album: "one")
        first.toggle("photo", scope: scope)
        let reloaded = FavoritePhotos(defaults: defaults)
        XCTAssertTrue(reloaded.contains("photo", scope: scope))
        XCTAssertFalse(reloaded.contains("photo", scope: NewPhotoTracker.scope(account: "b", album: "one")))
        XCTAssertFalse(reloaded.contains("photo", scope: NewPhotoTracker.scope(account: "a", album: "two")))
        reloaded.toggle("photo", scope: scope)
        XCTAssertTrue(first.ids(scope: scope).isEmpty)
        reloaded.toggle("photo", scope: nil)
        XCTAssertTrue(reloaded.ids(scope: nil).isEmpty)
    }
}

final class ImportHistoryTests: XCTestCase {
    private func job() -> PendingImport {
        PendingImport(id: UUID(), albumID: "album", folderID: "folder", quality: .compact,
                      photoIDs: nil, fileNames: ["one.png", "two.png", "three.png"], deleteOriginals: false)
    }
    func testRetryOnlyFailedItemDoesNotRequeueCompletedOrOtherFailures() {
        var value = job()
        value.complete(0)
        value.errors = [1: "offline", 2: "unavailable"]
        value.paused = true
        value.retry(1)
        XCTAssertEqual(value.readyIndices, [1])
        XCTAssertEqual(value.state(at: 0), .completed)
        XCTAssertEqual(value.state(at: 1), .waiting)
        XCTAssertEqual(value.state(at: 2), .failed)
        XCTAssertEqual(value.state(at: 1, active: [1]), .saving)
        value.complete(1)
        XCTAssertEqual(value.readyIndices, [])
        value.retry()
        XCTAssertEqual(value.readyIndices, [2])
    }
    func testQueueSurvivesRestartWithoutLosingStagedFilesOrErrors() throws {
        let directory = try Original.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = try Original.resourceURL(directory, index: 1, name: "two.png")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: staged)
        let file = ImportQueueFile(url: directory.appendingPathComponent("queue.json"))
        var value = job()
        value.complete(0); value.errors = [1: "offline"]; value.paused = true
        value.scope = "account-scoped"; value.storage = .device
        try file.save([value])
        let reloaded = try XCTUnwrap(ImportQueueFile(url: file.url).load().first)
        XCTAssertEqual(reloaded.completed, [0])
        XCTAssertEqual(reloaded.errors, [1: "offline"])
        XCTAssertEqual(reloaded.scope, "account-scoped")
        XCTAssertFalse(reloaded.runnable)
        XCTAssertEqual(reloaded.state(at: 2), .paused)
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }
    func testLegacyQueueDecodesAndCompletedHistoryDoesNotRunAgain() throws {
        let encoded = try JSONEncoder().encode(job())
        let legacy = try JSONDecoder().decode(PendingImport.self, from: encoded)
        XCTAssertNil(legacy.errors)
        XCTAssertTrue(legacy.runnable)
        var completed = legacy
        for index in 0..<completed.count { completed.complete(index) }
        completed.settled = true
        completed.retry()
        XCTAssertFalse(completed.runnable)
        XCTAssertTrue(completed.readyIndices.isEmpty)
    }
    func testCorruptQueueIsReportedRatherThanOverwritten() throws {
        let directory = try Original.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ImportQueueFile(url: directory.appendingPathComponent("queue.json"))
        let bytes = Data("broken json".utf8)
        try bytes.write(to: file.url)
        XCTAssertThrowsError(try file.load())
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }
    func testCompletionClearsStaleErrorAndActiveStatus() {
        var value = job()
        value.errors = [0: "temporary"]
        value.complete(0)
        XCTAssertNil(value.errors?[0])
        XCTAssertEqual(value.state(at: 0, active: [0]), .completed)
    }
}

final class PhotoMapTests: XCTestCase {
    private func photo(_ id: String, latitude: Double? = nil, longitude: Double = 0) -> Picture {
        let record = CKRecord(recordType: "Picture", recordID: .init(recordName: id))
        if let latitude { record["location"] = CLLocation(latitude: latitude, longitude: longitude) }
        return Picture(record: record)
    }
    func testSamePlaceGroupsPhotosAndExcludesMissingLocation() {
        let pictures = [photo("one", latitude: 35, longitude: 139), photo("two", latitude: 35, longitude: 139),
                        photo("three", latitude: -33, longitude: 151), photo("missing")]
        let groups = PhotoMapGroup.make(pictures, locations: [:])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.pictures.count }, 3)
        XCTAssertEqual(groups.first { $0.pictures.count == 2 }?.pictures.map(\.id.recordName), ["one", "two"])
    }
    func testLegacyLocationAndZeroCoordinatesAreShown() throws {
        let picture = photo("legacy")
        let location = try XCTUnwrap(PhotoLocation(CLLocation(latitude: 0, longitude: 0)))
        let groups = PhotoMapGroup.make([picture], locations: [picture.id: location])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.location, location)
        XCTAssertEqual(groups.first?.pictures.first?.id, picture.id)
    }
}

final class BackupScheduleTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Tokyo") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0,
                      calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    func testDailyTimeBeforeAndAfterScheduledMinute() {
        let cal = calendar()
        let config = BackupConfiguration(enabled: true, frequency: .daily, hour: 21, minute: 30)
        let planned = date(2026, 11, 1, 21, 30, calendar: cal)
        XCTAssertEqual(config.nextDate(after: date(2026, 11, 1, 20, calendar: cal), calendar: cal), planned)
        XCTAssertEqual(config.nextDate(after: planned, calendar: cal), date(2026, 11, 2, 21, 30, calendar: cal))
    }
    func testWeeklyWeekdayTimeAndFollowingWeek() {
        let cal = calendar()
        let config = BackupConfiguration(enabled: true, frequency: .weekly, hour: 8, minute: 15, weekday: 2)
        let monday = date(2026, 11, 2, 8, 15, calendar: cal)
        XCTAssertEqual(config.nextDate(after: date(2026, 11, 1, 23, calendar: cal), calendar: cal), monday)
        XCTAssertEqual(config.nextDate(after: monday, calendar: cal), date(2026, 11, 9, 8, 15, calendar: cal))
    }
    func testDSTMissingHourAndRepeatedHourOnlyScheduleOnce() throws {
        let cal = calendar("America/New_York")
        let spring = BackupConfiguration(enabled: true, hour: 2, minute: 30)
        let next = try XCTUnwrap(spring.nextDate(after: date(2026, 3, 8, 0, calendar: cal), calendar: cal))
        XCTAssertEqual(cal.component(.day, from: next), 8)
        XCTAssertEqual(cal.component(.hour, from: next), 3)
        let fall = BackupConfiguration(enabled: true, hour: 1, minute: 30)
        let first = try XCTUnwrap(fall.nextDate(after: date(2026, 11, 1, 0, calendar: cal), calendar: cal))
        let following = try XCTUnwrap(fall.nextDate(after: first, calendar: cal))
        XCTAssertEqual(cal.component(.day, from: following), 2)
    }
    func testConfigurationRoundTripIncludesEnabledFrequencyWeekdayAndTime() throws {
        let config = BackupConfiguration(enabled: true, frequency: .weekly, hour: 23, minute: 59, weekday: 7)
        XCTAssertEqual(try JSONDecoder().decode(BackupConfiguration.self, from: JSONEncoder().encode(config)), config)
        XCTAssertFalse(BackupConfiguration().enabled)
    }
}

final class BackupArchiveTests: XCTestCase {
    private func original(_ name: String = "IMG_0001.HEIC") throws -> Original {
        let dir = try Original.makeDirectory()
        let file = try Original.resourceURL(dir, index: 0, name: name)
        try Data([0, 1, 2, 3, 255]).write(to: file)
        return try Original.assemble(directory: dir, urls: [file], names: [name], kinds: [1], date: .distantPast)
    }
    func testExactOriginalNamesAndHashesArePreservedAndReused() async throws {
        let dir = try Original.makeDirectory(), source = try original()
        defer { source.clean(); try? FileManager.default.removeItem(at: dir) }
        let archive = BackupArchive(root: dir)
        let first = try await archive.save(source)
        let second = try await archive.save(source)
        XCTAssertEqual(first[0].name, source.names[0])
        XCTAssertEqual(first[0].path, second[0].path)
        XCTAssertEqual(try Original.hashFile(dir.appendingPathComponent(first[0].path)), source.hashes[0])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(first[0].path)), try Data(contentsOf: source.urls[0]))
    }
    func testSameBytesWithDifferentNamesStaySeparate() async throws {
        let dir = try Original.makeDirectory(), first = try original("one.jpg"), second = try original("two.jpg")
        defer { first.clean(); second.clean(); try? FileManager.default.removeItem(at: dir) }
        let archive = BackupArchive(root: dir)
        let a = try await archive.save(first), b = try await archive.save(second)
        XCTAssertNotEqual(a[0].path, b[0].path)
        XCTAssertEqual(a[0].name, "one.jpg")
        XCTAssertEqual(b[0].name, "two.jpg")
    }
    func testInterruptedRunKeepsCompletedCatalogAndOriginals() async throws {
        let dir = try Original.makeDirectory(), source = try original()
        defer { source.clean(); try? FileManager.default.removeItem(at: dir) }
        let archive = BackupArchive(root: dir)
        let resources = try await archive.save(source)
        let manifest = BackupManifest(version: 1, createdAt: Date(), albums: [])
        let first = try await archive.finish(manifest)
        let existing = try Data(contentsOf: dir.appendingPathComponent(first))
        try FileManager.default.removeItem(at: source.urls[0])
        let missing = try original("missing.jpg")
        defer { missing.clean() }
        try FileManager.default.removeItem(at: missing.urls[0])
        do { _ = try await archive.save(missing); XCTFail("Missing source must fail") } catch { }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(first)), existing)
        XCTAssertEqual(try Original.hashFile(dir.appendingPathComponent(resources[0].path)), source.hashes[0])
        let children = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("Photos"), includingPropertiesForKeys: nil)
        XCTAssertFalse(children.contains { $0.lastPathComponent.hasPrefix(".staging-") })
    }
    func testCorruptBackupIsPreservedAndNewVerifiedCopyIsCreated() async throws {
        let dir = try Original.makeDirectory(), source = try original()
        defer { source.clean(); try? FileManager.default.removeItem(at: dir) }
        let archive = BackupArchive(root: dir)
        let first = try await archive.save(source)
        try Data([99]).write(to: dir.appendingPathComponent(first[0].path))
        let repaired = try await archive.save(source)
        XCTAssertNotEqual(first[0].path, repaired[0].path)
        XCTAssertEqual(try Original.hashFile(dir.appendingPathComponent(repaired[0].path)), source.hashes[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(first[0].path).path))
    }
    func testCanceledWriteDoesNotPublishCatalog() async throws {
        let dir = try Original.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = BackupArchive(root: dir)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await archive.finish(BackupManifest(version: 1, createdAt: Date(), albums: []))
        }
        do { _ = try await task.value; XCTFail("Canceled write must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.contains { $0.pathExtension == "json" })
    }
    func testAllLivePhotoResourcesAreCopied() async throws {
        let dir = try Original.makeDirectory(), sourceDir = try Original.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: sourceDir) }
        let photo = try Original.resourceURL(sourceDir, index: 0, name: "IMG.HEIC")
        let video = try Original.resourceURL(sourceDir, index: 1, name: "IMG.MOV")
        try Data([1, 2]).write(to: photo); try Data([3, 4]).write(to: video)
        let source = try Original.assemble(directory: sourceDir, urls: [photo, video],
            names: ["IMG.HEIC", "IMG.MOV"], kinds: [1, 9], date: Date())
        let archive = BackupArchive(root: dir)
        let resources = try await archive.save(source)
        XCTAssertEqual(resources.count, 2)
        XCTAssertEqual(resources.map(\.kind), [1, 9])
        for (index, item) in resources.enumerated() {
            XCTAssertEqual(try Original.hashFile(dir.appendingPathComponent(item.path)), source.hashes[index])
        }
    }
    func testManifestPreservesFolderAndPhotoMetadata() async throws {
        let dir = try Original.makeDirectory(), source = try original()
        defer { source.clean(); try? FileManager.default.removeItem(at: dir) }
        let archive = BackupArchive(root: dir)
        let resources = try await archive.save(source)
        let location = PhotoLocation(CLLocation(latitude: 35, longitude: 139))
        let photo = BackupPhoto(id: "photo", folderID: "child", takenAt: Date(timeIntervalSince1970: 100),
            addedAt: Date(timeIntervalSince1970: 200), location: location, rotationQuarterTurns: 3,
            favorite: true, resources: resources)
        let album = BackupAlbum(id: "album", title: "旅行", storage: .device, shared: false,
            coverPhotoID: "photo", coverFolderID: nil,
            folders: [BackupFolder(id: "parent", title: "親", parentID: nil, coverPhotoID: nil),
                      BackupFolder(id: "child", title: "子", parentID: "parent", coverPhotoID: "photo")], photos: [photo])
        let name = try await archive.finish(BackupManifest(version: 1, createdAt: Date(), albums: [album]))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(BackupManifest.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
        XCTAssertEqual(saved.albums[0].title, "旅行")
        XCTAssertEqual(saved.albums[0].folders[1].parentID, "parent")
        XCTAssertEqual(saved.albums[0].photos[0].location, location)
        XCTAssertTrue(saved.albums[0].photos[0].favorite)
        XCTAssertEqual(saved.albums[0].photos[0].rotationQuarterTurns, 3)
        XCTAssertEqual(saved.albums[0].photos[0].resources[0].sha256, source.hashes[0])
    }
}
