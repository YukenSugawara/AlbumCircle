import SwiftUI

/// Personal preferences never change the shared album or its members' favorites.
@MainActor
final class FavoritePhotos: ObservableObject {
    static let shared = FavoritePhotos()
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func ids(scope: String?) -> Set<String> {
        guard let scope else { return [] }
        return Set(defaults.stringArray(forKey: "favorites.v1." + scope) ?? [])
    }
    func contains(_ id: String, scope: String?) -> Bool { ids(scope: scope).contains(id) }
    func toggle(_ id: String, scope: String?) {
        guard let scope else { return }
        var values = ids(scope: scope)
        if !values.insert(id).inserted { values.remove(id) }
        defaults.set(values.sorted(), forKey: "favorites.v1." + scope)
        revision += 1
    }
}

struct FavoritePhotoButton: View {
    let picture: Picture
    let album: Album
    @ObservedObject private var favorites = FavoritePhotos.shared
    @ObservedObject private var store = CloudStore.shared
    private var scope: String? { store.personalPhotoScope(for: album) }
    private var selected: Bool { favorites.contains(picture.id.recordName, scope: scope) }
    var body: some View {
        Button(selected ? "お気に入りを解除" : "お気に入りに追加",
               systemImage: selected ? "heart.fill" : "heart") {
            favorites.toggle(picture.id.recordName, scope: scope)
        }.disabled(scope == nil)
    }
}
