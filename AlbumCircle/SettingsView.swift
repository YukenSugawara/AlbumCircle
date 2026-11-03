import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AlbumStorage.settingKey) private var storage = AlbumStorage.iCloud.rawValue
    @AppStorage(AlbumStorage.deleteOriginalsKey) private var deleteOriginals = false
    @AppStorage(AlbumBackground.settingKey) private var backgroundChoice = AlbumBackground.standard.rawValue
    @AppStorage(FolderSort.settingKey) private var folderSortOrder = FolderSort.nameAscending.rawValue
    @State private var help = false
    @State private var selectedIcon: AppIconChoice = .standard
    @ObservedObject private var premium = PremiumStore.shared
    @ObservedObject private var advertising = Advertising.shared
    private var background: AlbumBackground { AlbumBackground(rawValue: backgroundChoice) ?? .standard }
    var body: some View {
        NavigationStack {
            Form {
                Section("プラン") {
                    LabeledContent("ご利用のバージョン", value: AppEdition.title)
                    NavigationLink { PremiumView() } label: {
                        Label(premium.isPremium ? "プレミアム利用中" : "プレミアムプラン", systemImage: "crown")
                    }
                    if premium.isReady && !premium.isPremium {
                        Text("無料版：1アルバム\(PhotoQuota.freePhotosPerAlbum)枚まで")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if advertising.privacyOptionsRequired && !AppEdition.isPersonal {
                        Button("広告のプライバシー設定") { Task { await advertising.showPrivacyOptions() } }
                    }
                }
                Section {
                    NavigationLink {
                        SaveMethodView(storage: $storage)
                    } label: {
                        HStack {
                            Label("保存方法", systemImage: "externaldrive")
                            Spacer()
                            Text((AlbumStorage(rawValue: storage) ?? .iCloud).title).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Picker("フォルダの並び順", selection: $folderSortOrder) {
                        ForEach(FolderSort.allCases) { order in Text(order.title).tag(order.rawValue) }
                    }
                } header: { Text("並び順") } footer: {
                    Text("アルバム内のすべての階層に適用します。写真枚数は配下のフォルダも含めます。")
                }
                Section {
                    NavigationLink { BackupSettingsView() } label: {
                        Label("写真のバックアップ", systemImage: "icloud.and.arrow.up")
                    }
                }
                Section("見た目") {
                    NavigationLink {
                        BackgroundPickerView(choice: $backgroundChoice)
                    } label: {
                        HStack {
                            Label("背景色", systemImage: "paintpalette")
                            Spacer()
                            Text(background.title).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        AppIconPickerView(selected: $selectedIcon)
                    } label: {
                        HStack {
                            Label("アプリアイコン", systemImage: "app")
                            Spacer()
                            Text(selectedIcon.title).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Toggle("追加後に元の写真を削除", isOn: $deleteOriginals)
                    Text("写真アプリからオリジナル画質で追加した写真が対象です。保存先の原本が一致した場合にiPhoneの削除確認を表示します。画質を変換した写真の元画像は残します。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("写真の取り込み")
                } footer: {
                    Text("初期設定はOFFです。未保存の写真、保存確認に失敗した写真、編集データなどを完全に保持できない写真は削除しません。ファイルから追加した元ファイルは削除対象外です。iCloud写真が有効な場合、元写真の削除は同期先の端末にも反映されます。")
                }
                Section {
                    Button("使い方", systemImage: "questionmark.circle") { help = true }
                    HStack { Text("バージョン"); Spacer(); Text("0.5.3").foregroundStyle(.secondary) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(background.color)
            .navigationTitle("設定")
            .onAppear { selectedIcon = .current }
            .sheet(isPresented: $help) { HelpView() }
            .alert("広告のプライバシー設定", isPresented: Binding(get: { advertising.errorMessage != nil }, set: { if !$0 { advertising.errorMessage = nil } })) {
                Button("OK") { advertising.errorMessage = nil }
            } message: { Text(advertising.errorMessage ?? "") }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }.tint(background.accent)
    }
}

private struct SaveMethodView: View {
    @Binding var storage: String
    @AppStorage(AlbumBackground.settingKey) private var backgroundChoice = AlbumBackground.standard.rawValue
    private var background: AlbumBackground { AlbumBackground(rawValue: backgroundChoice) ?? .standard }
    var body: some View {
        Form {
            Section {
                ForEach(AlbumStorage.allCases) { location in
                    Button {
                        storage = location.rawValue
                    } label: {
                        HStack {
                            Label(location.title, systemImage: location.icon)
                            Spacer()
                            if storage == location.rawValue { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(storage == location.rawValue ? .isSelected : [])
                }
            } header: {
                Text("新しいアルバムの保存先")
            } footer: {
                Text("新しく作るアルバムに適用します。既存のアルバムや写真は移動しません。写真の追加先は、そのアルバムの保存先に従います。")
            }
            Section("保存先について") {
                Label("端末内：この端末だけに保存", systemImage: "iphone")
                Text("共有不可。この端末だけで使います。アプリを削除すると写真も消えます。iCloudバックアップ対象外です。")
                    .font(.footnote).foregroundStyle(.secondary)
                Label("iCloud：他の人と共有できます", systemImage: "icloud")
                Text("共有する場合はこちらを選びます。設定を端末内に変えても、既存の共有アルバムは引き続き使えます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(background.color)
        .navigationTitle("保存方法")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BackgroundPickerView: View {
    @Binding var choice: String
    private var background: AlbumBackground { AlbumBackground(rawValue: choice) ?? .standard }
    var body: some View {
        Form {
            Section {
                ForEach(AlbumBackground.allCases) { option in
                    Button {
                        choice = option.rawValue
                    } label: {
                        HStack(spacing: 14) {
                            Circle().fill(option.swatch).frame(width: 28, height: 28)
                                .overlay { Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
                            Text(option.title)
                            Spacer()
                            if choice == option.rawValue {
                                Image(systemName: "checkmark").foregroundStyle(background.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityValue(choice == option.rawValue ? "選択中" : "")
                }
            } footer: {
                Text("選んだ色はアルバム一覧・フォルダ・設定画面の背景に反映されます。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(background.color)
        .navigationTitle("背景色")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum AppIconChoice: String, CaseIterable, Identifiable {
    case standard, sage, rose, lavender, peach, lemon, aqua, cocoa
    var id: String { rawValue }
    var iconName: String? {
        switch self {
        case .standard: return nil
        case .sage: return "AppIconSage"
        case .rose: return "AppIconRose"
        case .lavender: return "AppIconLavender"
        case .peach: return "AppIconPeach"
        case .lemon: return "AppIconLemon"
        case .aqua: return "AppIconAqua"
        case .cocoa: return "AppIconCocoa"
        }
    }
    var title: String {
        switch self {
        case .standard: return "ブルー"
        case .sage: return "セージ"
        case .rose: return "ローズ"
        case .lavender: return "ラベンダー"
        case .peach: return "ピーチ"
        case .lemon: return "レモン"
        case .aqua: return "アクア"
        case .cocoa: return "ココア"
        }
    }
    var previewName: String {
        switch self {
        case .standard: return "IconPreviewBlue"
        case .sage: return "IconPreviewSage"
        case .rose: return "IconPreviewRose"
        case .lavender: return "IconPreviewLavender"
        case .peach: return "IconPreviewPeach"
        case .lemon: return "IconPreviewLemon"
        case .aqua: return "IconPreviewAqua"
        case .cocoa: return "IconPreviewCocoa"
        }
    }
    @MainActor static var current: AppIconChoice {
        switch UIApplication.shared.alternateIconName {
        case "AppIconSage": return .sage
        case "AppIconRose": return .rose
        case "AppIconLavender": return .lavender
        case "AppIconPeach": return .peach
        case "AppIconLemon": return .lemon
        case "AppIconAqua": return .aqua
        case "AppIconCocoa": return .cocoa
        default: return .standard
        }
    }
}

private struct AppIconPickerView: View {
    @Binding var selected: AppIconChoice
    @AppStorage(AlbumBackground.settingKey) private var backgroundChoice = AlbumBackground.standard.rawValue
    @State private var changing = false
    @State private var errorMessage: String?
    private var background: AlbumBackground { AlbumBackground(rawValue: backgroundChoice) ?? .standard }
    var body: some View {
        Form {
            Section {
                ForEach(AppIconChoice.allCases) { option in
                    Button { choose(option) } label: {
                        HStack(spacing: 14) {
                            Image(option.previewName).resizable().scaledToFill()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(option.title)
                            Spacer()
                            if selected == option {
                                Image(systemName: "checkmark").foregroundStyle(background.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .disabled(changing)
                    .accessibilityValue(selected == option ? "選択中" : "")
                }
            } footer: {
                Text("ホーム画面のアプリアイコンを変更します。iOSの確認画面が表示されます。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(background.color)
        .navigationTitle("アプリアイコン")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selected = .current }
        .alert("アイコンを変更できませんでした", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
    @MainActor private func choose(_ option: AppIconChoice) {
        guard !changing, selected != option else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "この端末ではアプリアイコンの切り替えを使用できません。"
            return
        }
        changing = true
        UIApplication.shared.setAlternateIconName(option.iconName) { error in
            Task { @MainActor in
                changing = false
                selected = .current
                if let error { errorMessage = error.localizedDescription }
            }
        }
    }
}
