import SwiftUI

struct BackupSettingsView: View {
    @ObservedObject private var backup = PhotoBackup.shared
    @ObservedObject private var store = CloudStore.shared
    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1,
                hour: backup.configuration.hour, minute: backup.configuration.minute)) ?? Date()
        }, set: { date in
            var updated = backup.configuration
            updated.hour = Calendar.current.component(.hour, from: date)
            updated.minute = Calendar.current.component(.minute, from: date)
            backup.configuration = updated
        })
    }
    var body: some View {
        Form {
            Section {
                Toggle("自動バックアップ", isOn: $backup.configuration.enabled)
                Picker("実施間隔", selection: $backup.configuration.frequency) {
                    ForEach(BackupFrequency.allCases) { item in Text(item.title).tag(item) }
                }
                if backup.configuration.frequency == .weekly {
                    Picker("曜日", selection: $backup.configuration.weekday) {
                        ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
                    }
                }
                DatePicker("実行時刻", selection: time, displayedComponents: .hourAndMinute)
            } header: { Text("スケジュール") } footer: {
                Text("端末の現在のタイムゾーンを使用します。指定時刻以降にiOSが実行を許可したタイミングで動作します。実行できなかった場合は、次にアプリを開いた際に補完します。")
            }
            Section("保存先") {
                LabeledContent("保存先", value: "iCloud Drive／アルバムの輪／Backups")
                Text("端末内・iCloudのアルバム（参加中の共有アルバムを含む）の写真原本と、アルバム・フォルダ情報を保存します。写真アプリ全体は対象外です。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("過去のバックアップは自動削除しません。同じ原本は再利用します。容量が足りない場合は失敗理由を表示します。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("実行状況") {
                if let due = backup.requestedDate {
                    LabeledContent("次回の実行目安", value: due.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("最終バックアップ作成", value: backup.lastCreated?.formatted(date: .abbreviated, time: .shortened) ?? "未実行")
                if backup.isRunning {
                    ProgressView(backup.progress)
                    Button("バックアップを中断") { backup.cancel() }
                } else {
                    Button("今すぐバックアップ") { Task { await backup.runIfDue(force: true) } }
                        .disabled(store.busy || AlbumImporter.isProcessing)
                }
                if let message = backup.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Text("作成完了はiCloud Driveへの書き出しと原本の検証完了を示します。クラウドへの転送はiOSが行い、通信状況によって遅れる場合があります。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("ファイルアプリからバックアップを確認できます。Photos内の原本ファイルは『ファイルから追加』で再取り込みできます。アルバム構成の一括復元には未対応です。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("写真のバックアップ")
        .navigationBarTitleDisplayMode(.inline)
    }
}
