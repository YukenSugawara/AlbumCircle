import SwiftUI

struct ImportStatusView: View {
    var albumID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CloudStore.shared
    @ObservedObject private var monitor = ImportMonitor.shared
    @State private var jobs: [PendingImport] = []
    @State private var issue: String?
    @State private var deleting: PendingImport?
    var body: some View {
        NavigationStack {
            List {
                if let issue { Text(issue).foregroundStyle(.red) }
                if jobs.isEmpty && issue == nil {
                    ContentUnavailableView("追加の履歴はありません", systemImage: "arrow.up.circle",
                        description: Text("これから追加する写真の保存状況をここで確認できます。"))
                }
                ForEach(jobs.reversed()) { job in
                    Section {
                        ForEach(0..<job.count, id: \.self) { index in
                            item(job, index: index)
                        }
                        if job.paused == true {
                            Button("未完了の写真を再開") { retry(job.id) }.disabled(store.busy)
                        }
                        Button(job.settled == true ? "履歴を削除" : "この追加を取り消す", role: .destructive) {
                            deleting = job
                        }.disabled(store.busy)
                    } header: {
                        Text((job.albumTitle ?? "アルバム") + " · \(job.completed.count)/\(job.count)枚完了")
                    } footer: {
                        if let date = job.createdAt { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                    }
                }
            }
            .navigationTitle("アップロード状況").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    if store.importCanStop {
                        Button("一時停止") { store.requestStop() }.disabled(store.stopRequested)
                    }
                }
            }
            .task { reload() }
            .onChange(of: monitor.revision) { _, _ in reload() }
            .onChange(of: store.accountEpoch) { _, _ in reload() }
            .onChange(of: store.albums.map(\.id)) { _, _ in reload() }
            .refreshable { reload() }
            .alert("履歴から削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("キャンセル", role: .cancel) { deleting = nil }
                Button("削除", role: .destructive) {
                    guard let job = deleting else { return }
                    deleting = nil
                    do {
                        guard !store.busy, !AlbumImporter.isProcessing else {
                            throw UserError(message: "保存処理が終わってから操作してください。")
                        }
                        try PendingImports.remove(job.id)
                    } catch { issue = error.localizedDescription }
                }
            } message: {
                Text("未完了の写真は再試行できなくなります。保存済みの写真と追加元の写真は削除しません。")
            }
        }
    }
    private func item(_ job: PendingImport, index: Int) -> some View {
        let state = job.state(at: index, active: monitor.active[job.id] ?? [])
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if state == .saving { ProgressView() }
                Text(job.name(at: index)).lineLimit(2)
                Spacer()
                Text(state.rawValue).font(.caption).foregroundStyle(state == .failed ? .red : .secondary)
            }
            if let error = job.errors?[index], state == .failed {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("この写真を再試行") { retry(job.id, index: index) }.disabled(store.busy)
            }
        }
    }
    private func reload() {
        do {
            jobs = try PendingImports.all().filter { (albumID == nil || $0.albumID == albumID) && PendingImports.visible($0) }
            issue = nil
        } catch { issue = "状況を読み込めませんでした。" + error.localizedDescription }
    }
    private func retry(_ id: UUID, index: Int? = nil) {
        Task {
            do { try await AlbumImporter.retry(id, index: index) }
            catch { issue = error.localizedDescription }
        }
    }
}
