import SwiftUI
import CloudKit
import CryptoKit

enum FolderSort: String, CaseIterable, Identifiable {
    case nameAscending, nameDescending, mostPhotos, fewestPhotos
    static let settingKey = "folderSortOrder"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nameAscending: return "名前順"
        case .nameDescending: return "名前の逆順"
        case .mostPhotos: return "写真が多い順"
        case .fewestPhotos: return "写真が少ない順"
        }
    }
    func apply(_ folders: [PhotoFolder], counts: [String: Int]) -> [PhotoFolder] {
        folders.sorted { lhs, rhs in
            let a = counts[lhs.id, default: 0], b = counts[rhs.id, default: 0]
            if a != b {
                if self == .mostPhotos { return a > b }
                if self == .fewestPhotos { return a < b }
            }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order == .orderedSame { return lhs.id < rhs.id }
            return self == .nameDescending ? order == .orderedDescending : order == .orderedAscending
        }
    }
}

enum PhotoSort: String, CaseIterable, Identifiable {
    case takenNewest, takenOldest, addedNewest, addedOldest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .takenNewest: return "撮影日が新しい順"
        case .takenOldest: return "撮影日が古い順"
        case .addedNewest: return "追加日が新しい順"
        case .addedOldest: return "追加日が古い順"
        }
    }
    func apply(_ pictures: [Picture], from start: Date? = nil, through end: Date? = nil,
               calendar: Calendar = .current) -> [Picture] {
        let lower = start.map { calendar.startOfDay(for: $0) }
        let upper = end.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        return pictures.filter {
            (lower == nil || $0.date >= lower!) && (upper == nil || $0.date < upper!)
        }.sorted { lhs, rhs in
            let added = self == .addedNewest || self == .addedOldest
            let a = added ? lhs.addedAt : lhs.date, b = added ? rhs.addedAt : rhs.date
            if a == b { return lhs.id.recordName < rhs.id.recordName }
            return self == .takenNewest || self == .addedNewest ? a > b : a < b
        }
    }
}

/// Read state is device-local, scoped to both the iCloud account and album.
@MainActor
final class NewPhotoTracker: ObservableObject {
    static let shared = NewPhotoTracker()
    private struct State: Codable, Equatable {
        var initialized = false
        var known: Set<String> = []
        var unread: Set<String> = []
    }
    private var states: [String: State] = [:]
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func scope(account: String, album: String) -> String {
        let bytes = try! JSONEncoder().encode([account, album])
        return "newPhotos.v1." + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func state(_ scope: String) -> State {
        if let value = states[scope] { return value }
        guard let data = defaults.data(forKey: scope),
              let value = try? JSONDecoder().decode(State.self, from: data) else {
            let empty = State(); states[scope] = empty; return empty
        }
        states[scope] = value
        return value
    }
    private func save(_ value: State, scope: String) {
        guard value != state(scope) else { return }
        states[scope] = value
        revision += 1
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: scope) }
    }
    func unread(scope: String?) -> Set<String> {
        guard let scope else { return [] }
        return state(scope).unread
    }
    func observe(ids: Set<String>, ownIDs: Set<String>, scope: String) {
        var value = state(scope)
        if value.initialized { value.unread.formUnion(ids.subtracting(value.known).subtracting(ownIDs)) }
        value.unread.formIntersection(ids)
        value.unread.subtract(ownIDs)
        value.known = ids
        value.initialized = true
        save(value, scope: scope)
    }
    func markRead(_ ids: Set<String>, scope: String?) {
        guard let scope else { return }
        var value = state(scope)
        value.known.formUnion(ids) // Also suppress a local upload before the next refresh.
        value.unread.subtract(ids)
        save(value, scope: scope)
    }
}

struct NewPhotoBadge: View {
    var count: Int? = nil
    var body: some View {
        Text(count.map { "新着 \($0)" } ?? "新着")
            .font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.blue, in: Capsule()).padding(5)
    }
}

struct PhotoDateFilter: View {
    @Environment(\.dismiss) private var dismiss
    @State var start: Date
    @State var end: Date
    let apply: (Date, Date) -> Void
    let clear: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("撮影日") {
                    DatePicker("開始日", selection: $start, displayedComponents: .date)
                    DatePicker("終了日", selection: $end, in: start..., displayedComponents: .date)
                }
                Button("日付の絞り込みを解除") { clear(); dismiss() }
            }
            .navigationTitle("日付で絞り込み")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("適用") { apply(start, end); dismiss() } }
            }
            .onChange(of: start) { _, value in if end < value { end = value } }
        }
    }
}

struct MovePhotosSheet: View {
    let albumTitle: String
    let contents: AlbumContents
    let pictures: [Picture]
    let move: (String?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    destination(title: albumTitle + "（直下）", id: nil)
                    ForEach(contents.folders.sorted { path($0) < path($1) }) { folder in
                        destination(title: path(folder), id: folder.id)
                    }
                } header: { Text("\(pictures.count)枚の移動先") }
                footer: { Text("同じアルバム内で移動します。写真の原本や共有メンバーは変わりません。") }
            }
            .navigationTitle("写真を移動")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { if saving { ProgressView() } }
            }
            .alert("移動を完了できませんでした", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("閉じる") { dismiss() }
            } message: { Text((message ?? "") + "\n一覧を更新して移動状況を確認してください。") }
        }.interactiveDismissDisabled(saving)
    }
    private func destination(title: String, id: String?) -> some View {
        Button {
            saving = true
            Task {
                defer { saving = false }
                do { try await move(id); dismiss() } catch { message = error.localizedDescription }
            }
        } label: { Label(title, systemImage: "folder") }
            .disabled(saving || pictures.isEmpty || pictures.allSatisfy { $0.folderID == id })
    }
    private func path(_ folder: PhotoFolder) -> String {
        var names = [folder.title], parent = folder.parentID, visited: Set<String> = [folder.id]
        while let id = parent, visited.insert(id).inserted,
              let value = contents.folders.first(where: { $0.id == id }) {
            names.insert(value.title, at: 0); parent = value.parentID
        }
        return names.joined(separator: " / ")
    }
}
