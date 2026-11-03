import Foundation
import Photos
import CloudKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import UIKit
import CoreLocation

/// Portable metadata shared by local storage, CloudKit and converted images.
struct PhotoLocation: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?

    init?(_ location: CLLocation) {
        guard CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var clLocation: CLLocation {
        CLLocation(coordinate: coordinate, altitude: altitude ?? 0, horizontalAccuracy: 0,
                   verticalAccuracy: altitude == nil ? -1 : 0, timestamp: .distantPast)
    }
    static func read(from url: URL) -> PhotoLocation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue,
              let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
              let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String,
              ["N", "S"].contains(latRef), ["E", "W"].contains(lonRef),
              lat.isFinite, lon.isFinite, (0...90).contains(lat), (0...180).contains(lon) else { return nil }
        let altitude = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue
        let below = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1
        return PhotoLocation(CLLocation(coordinate: .init(latitude: latRef == "S" ? -lat : lat,
                                                          longitude: lonRef == "W" ? -lon : lon),
                                        altitude: (altitude ?? 0) * (below ? -1 : 1),
                                        horizontalAccuracy: 0, verticalAccuracy: altitude == nil ? -1 : 0,
                                        timestamp: .distantPast))
    }
    var gpsProperties: [CFString: Any] {
        var gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: abs(latitude),
                                   kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
                                   kCGImagePropertyGPSLongitude: abs(longitude),
                                   kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E"]
        if let altitude {
            gps[kCGImagePropertyGPSAltitude] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
        }
        return gps
    }
}

enum UploadQuality: String, CaseIterable, Codable, Hashable {
    case original, high, compact
    var title: String {
        switch self {
        case .original: "オリジナル（無変換）"
        case .high: "高画質（最大4096px）"
        case .compact: "標準（最大2048px）"
        }
    }
    var pixelLimit: Int {
        switch self {
        case .original: 0
        case .high: 4096
        case .compact: 2048
        }
    }
    var compression: CGFloat { self == .high ? 0.9 : 0.78 }
}

struct Original {
    let directory: URL
    let urls: [URL]
    let names: [String]
    let kinds: [Int]
    let hashes: [String]
    let date: Date
    let bytes: Int64
    let preview: Data?
    var location: PhotoLocation? = nil
    var sourceSnapshot: PhotoSourceSnapshot? = nil
    var sourceIdentity: String? = nil
    var identity: String { Self.digest(Data(zip(kinds, hashes).map { "\($0.0):\($0.1)" }.joined(separator: "|").utf8)) }
    var duplicateIdentity: String { sourceIdentity ?? identity }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Original-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func resourceURL(_ directory: URL, index: Int, name: String) throws -> URL {
        let folder = directory.appendingPathComponent(String(index), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let basename = name.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? ""
        guard !basename.isEmpty, basename != ".", basename != "..", !basename.contains("\0") else {
            throw UserError(message: "原本のファイル名が正しくありません。")
        }
        return folder.appendingPathComponent(basename)
    }
    static func thumbnail(_ url: URL, size: Int = 360) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }
    /// Decode the verified original for screen display without a lossy JPEG round trip.
    static func displayImage(_ url: URL, maxPixelSize: Int = 4096) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    /// Only the explicit JPEG modes transform bytes. Never convert Live Photo pairs.
    func prepared(for quality: UploadQuality) throws -> Original {
        guard quality != .original else { return self }
        guard urls.count == 1, kinds == [PHAssetResourceType.photo.rawValue] else {
            throw UserError(message: "Live Photosなど複数の原本を持つ写真は、オリジナル画質で追加してください。")
        }
        let output = try Self.makeDirectory()
        do {
            let filename = names[0]
            let target = try Self.resourceURL(output, index: 0, name: filename)
            guard let source = CGImageSourceCreateWithURL(urls[0] as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: quality.pixelLimit
                  ] as CFDictionary),
                  let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw UserError(message: "この画像は選んだ画質へ変換できません。オリジナルをお試しください。")
            }
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality.compression]
            if let location { properties[kCGImagePropertyGPSDictionary] = location.gpsProperties }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw UserError(message: "JPEGへの変換に失敗しました。") }
            // A transformed file cannot qualify for deletion of the original PhotoKit asset.
            var converted = try Self.assemble(directory: output, urls: [target], names: [filename],
                                              kinds: [PHAssetResourceType.photo.rawValue], date: date, location: location)
            converted.sourceIdentity = duplicateIdentity
            return converted
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
    static func assemble(directory: URL, urls: [URL], names: [String], kinds: [Int], date: Date,
                         includePreview: Bool = true, verifiedHashes: [String]? = nil,
                         location: PhotoLocation? = nil) throws -> Original {
        guard !urls.isEmpty, urls.count == names.count, names.count == kinds.count else {
            throw UserError(message: "原本の構成を確認できませんでした。")
        }
        let hashes: [String]
        if let verifiedHashes {
            guard verifiedHashes.count == urls.count else { throw UserError(message: "原本の検証情報が正しくありません。") }
            hashes = verifiedHashes
        } else {
            hashes = try urls.map { try hashFile($0) }
        }
        let bytes = try urls.reduce(Int64(0)) { total, url in
            total + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        return Original(directory: directory, urls: urls, names: names, kinds: kinds,
                        hashes: hashes, date: date, bytes: bytes, preview: includePreview ? thumbnail(urls[0]) : nil,
                        location: location ?? PhotoLocation.read(from: urls[0]))
    }
    static func fromAsset(identifier: String) async throws -> Original {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw UserError(message: "写真へのアクセスが許可されていません。設定で対象の写真へのアクセスを許可してください。")
        }
        let all = PHAssetResource.assetResources(for: asset)
        // Use the original resources, never requestImage / rendered edited images.
        let resources = all.filter { [.photo, .pairedVideo, .alternatePhoto].contains($0.type) }
            .sorted { $0.type.rawValue < $1.type.rawValue }
        guard resources.contains(where: { $0.type == .photo }) else {
            throw UserError(message: "この写真の原本を取得できませんでした。ファイルからの追加をお試しください。")
        }
        let dir = try makeDirectory()
        do {
            var urls: [URL] = []
            for (index, resource) in resources.enumerated() {
                let url = try resourceURL(dir, index: index, name: resource.originalFilename)
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                urls.append(url)
            }
            var original = try assemble(directory: dir, urls: urls, names: resources.map(\.originalFilename),
                                        kinds: resources.map { $0.type.rawValue }, date: asset.creationDate ?? Date(),
                                        location: asset.location.flatMap(PhotoLocation.init))
            original.sourceSnapshot = PhotoSourceSnapshot(asset: asset, resources: all)
            return original
        } catch { try? FileManager.default.removeItem(at: dir); throw error }
    }
    static func fromFile(_ source: URL) throws -> Original {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let dir = try makeDirectory()
        do {
            let target = dir.appendingPathComponent(source.lastPathComponent)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                do { try FileManager.default.copyItem(at: coordinated, to: target) }
                catch { copyError = error }
            }
            if let error = coordinationError { throw error }
            if let error = copyError { throw error }
            return try assemble(directory: dir, urls: [target], names: [source.lastPathComponent],
                                kinds: [PHAssetResourceType.photo.rawValue], date: Date())
        } catch { try? FileManager.default.removeItem(at: dir); throw error }
    }
    static func from(_ record: CKRecord) throws -> Original {
        guard let assets = record["files"] as? [CKAsset], let names = record["names"] as? [String],
              let kinds = record["kinds"] as? [NSNumber], let expected = record["hashes"] as? [String],
              assets.count == names.count, names.count == kinds.count, kinds.count == expected.count,
              !assets.isEmpty else { throw UserError(message: "写真データの構成を読み取れませんでした。") }
        let dir = try makeDirectory()
        do {
            var urls: [URL] = []
            for (i, asset) in assets.enumerated() {
                guard let source = asset.fileURL else { throw UserError(message: "原本のダウンロードが完了していません。もう一度お試しください。") }
                let target = try resourceURL(dir, index: i, name: names[i])
                try FileManager.default.copyItem(at: source, to: target)
                guard try hashFile(target) == expected[i] else { throw UserError(message: "原本の検証に失敗しました。再度ダウンロードしてください。") }
                urls.append(target)
            }
            return try assemble(directory: dir, urls: urls, names: names, kinds: kinds.map(\.intValue),
                                date: (record["takenAt"] as? Date) ?? Date(), includePreview: false,
                                verifiedHashes: expected, location: (record["location"] as? CLLocation).flatMap(PhotoLocation.init))
        } catch { try? FileManager.default.removeItem(at: dir); throw error }
    }
    func saveToPhotos() async throws {
        let allowed: Set<Int> = [PHAssetResourceType.photo.rawValue, PHAssetResourceType.pairedVideo.rawValue, PHAssetResourceType.alternatePhoto.rawValue]
        guard urls.count == names.count, names.count == kinds.count,
              kinds.contains(PHAssetResourceType.photo.rawValue), kinds.allSatisfy({ allowed.contains($0) }) else {
            throw UserError(message: "写真アプリに復元できない構成です。ファイルへ保存してください。")
        }
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else { throw UserError(message: "写真への保存を設定で許可してください。") }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = date
            request.location = location?.clLocation
            for i in urls.indices {
                let type = PHAssetResourceType(rawValue: kinds[i])! // Preflight above rejects unknown types.
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = names[i]
                // Converted JPEG bytes may retain an original HEIC/PNG filename.
                if let source = CGImageSourceCreateWithURL(urls[i] as CFURL, nil),
                   let type = CGImageSourceGetType(source) { options.uniformTypeIdentifier = type as String }
                options.shouldMoveFile = false
                request.addResource(with: type, fileURL: urls[i], options: options)
            }
        }
    }
}
