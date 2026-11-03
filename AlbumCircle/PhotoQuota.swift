import Foundation

struct PhotoLimitReached: LocalizedError {
    let limit: Int
    var errorDescription: String? {
        "無料版は1アルバム\(limit)枚まで保存できます。設定のプレミアムプランで枚数制限を解除できます。保存済みの写真は引き続き閲覧・書き出し・削除できます。"
    }
}

enum PhotoQuota {
    // Provisional product policy; change here after the free plan is finalized.
    static let freePhotosPerAlbum = 100

    static func check(existingIDs: Set<String>, incomingID: String, premium: Bool,
                      limit: Int = freePhotosPerAlbum) throws {
        guard !premium, !existingIDs.contains(incomingID), existingIDs.count >= limit else { return }
        throw PhotoLimitReached(limit: limit)
    }
}

/// Serializes the complete count/check/write operation, including after an async suspension.
@MainActor
final class PhotoImportGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<T>(_ action: () async throws -> T) async throws -> T {
        if locked {
            await withCheckedContinuation { waiters.append($0) }
        } else { locked = true }
        defer {
            if waiters.isEmpty { locked = false }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await action()
    }
}
