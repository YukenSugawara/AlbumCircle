import Foundation
import Photos

/// A snapshot of the exact PhotoKit asset imported, not every asset the user selected.
struct PhotoSourceSnapshot {
    let identifier: String
    let modificationDate: Date?
    let resourceSignature: [String]
    let allResourcesPreserved: Bool
    init(asset: PHAsset, resources: [PHAssetResource]) {
        identifier = asset.localIdentifier
        modificationDate = asset.modificationDate
        resourceSignature = Self.signature(resources)
        let preservedTypes: Set<Int> = [PHAssetResourceType.photo.rawValue,
                                       PHAssetResourceType.pairedVideo.rawValue,
                                       PHAssetResourceType.alternatePhoto.rawValue]
        allResourcesPreserved = !resources.isEmpty && asset.burstIdentifier == nil &&
            resources.allSatisfy { preservedTypes.contains($0.type.rawValue) }
    }
    static func signature(_ resources: [PHAssetResource]) -> [String] {
        resources.map { "\($0.type.rawValue):\($0.originalFilename)" }.sorted()
    }
    func permitsDeletion(of asset: PHAsset) -> Bool {
        guard allResourcesPreserved, let modificationDate,
              asset.localIdentifier == identifier,
              asset.modificationDate == modificationDate,
              asset.canPerform(.delete) else { return false }
        return Self.signature(PHAssetResource.assetResources(for: asset)) == resourceSignature
    }
}

@MainActor
enum PhotoDeletion {
    /// Call only after each candidate's stored bytes were read back and verified.
    /// PhotoKit handles the system confirmation and recently-deleted behavior.
    static func deleteVerified(_ candidates: [PhotoSourceSnapshot]) async throws -> (deleted: Int, skipped: Int) {
        guard !candidates.isEmpty else { return (0, 0) }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw UserError(message: "写真の読み書きが許可されていないため、元の写真は削除しませんでした。アルバムへの保存は完了しています。")
        }
        let byID = Dictionary(candidates.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(byID.keys), options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in
            if byID[asset.localIdentifier]?.permitsDeletion(of: asset) == true { assets.append(asset) }
        }
        let skipped = byID.count - assets.count
        guard !assets.isEmpty else { return (0, skipped) }
        let deletionTargets = assets
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(deletionTargets as NSArray)
        }
        return (assets.count, skipped)
    }
}
