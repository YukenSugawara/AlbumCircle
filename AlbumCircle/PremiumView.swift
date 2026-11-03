import SwiftUI
import StoreKit

struct PremiumView: View {
    @ObservedObject private var premium = PremiumStore.shared
    @State private var manageSubscriptions = false
    var body: some View {
        List {
            Section {
                Label("広告なしで写真を楽しむ", systemImage: "photo.on.rectangle.angled")
                Label("写真の保存枚数制限を解除", systemImage: "infinity")
                Text("保存できる容量は、端末またはiCloudの空き容量によって異なります。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !premium.isPremium {
                    Text("無料版は1アルバム\(PhotoQuota.freePhotosPerAlbum)枚まで。フォルダ内の写真も含みます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if AppEdition.isPersonal {
                Section { Text("個人利用版では、すべてのプレミアム機能が有効です。購入は不要です。") }
            } else {
                Section("プラン") {
                    if premium.isPremium {
                        Label("プレミアム利用中", systemImage: "checkmark.seal.fill")
                    } else if premium.products.isEmpty {
                        Text("現在プランを取得できません。時間をおいてもう一度お試しください。")
                        Button("再読み込み") { Task { await premium.loadProducts() } }
                    } else {
                        ForEach(premium.products, id: \.id) { product in
                            Button { Task { await premium.purchase(product) } } label: {
                                HStack {
                                    Text(product.displayName)
                                    Spacer()
                                    Text(product.displayPrice + period(product))
                                }
                            }.disabled(premium.busy || CommerceConfiguration.privacyURL == nil)
                        }
                    }
                    Button("購入を復元") { Task { await premium.restore() } }.disabled(premium.busy)
                    Button("サブスクリプションを管理") { manageSubscriptions = true }
                }
                Section {
                    Text("月額・年額プランは自動更新されます。購入の確認時にApple Accountへ請求されます。解約後も有効期限までは利用できます。期限終了後も保存済みの写真の閲覧・書き出しはできます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("利用規約", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    if let url = CommerceConfiguration.privacyURL { Link("プライバシーポリシー", destination: url) }
                }
            }
        }
        .navigationTitle("プレミアム")
        .task { await premium.start() }
        .manageSubscriptionsSheet(isPresented: $manageSubscriptions)
        .alert("お知らせ", isPresented: Binding(get: { premium.message != nil }, set: { if !$0 { premium.message = nil } })) {
            Button("OK") { premium.message = nil }
        } message: { Text(premium.message ?? "") }
    }
    private func period(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .month: return "／\(period.value)か月"
        case .year: return "／\(period.value)年"
        case .week: return "／\(period.value)週間"
        case .day: return "／\(period.value)日"
        @unknown default: return ""
        }
    }
}
