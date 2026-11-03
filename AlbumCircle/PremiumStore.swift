import StoreKit
import Combine

@MainActor
final class PremiumStore: ObservableObject {
    static let shared = PremiumStore()
    @Published private(set) var isPremium = AppEdition.isPersonal
    @Published private(set) var isReady = AppEdition.isPersonal
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published var message: String?
    private var updates: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    var shouldShowAds: Bool { !AppEdition.isPersonal && isReady && !isPremium }

    func start() async {
        guard !AppEdition.isPersonal else { return }
        if let startup { await startup.value; return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = result,
                      CommerceConfiguration.productIDs.contains(transaction.productID) else { continue }
                await self.refreshEntitlements()
                await transaction.finish()
            }
        }
        let task = Task {
            await refreshEntitlements()
            await loadProducts()
        }
        startup = task
        await task.value
    }

    func refreshEntitlements() async {
        guard !AppEdition.isPersonal else { return }
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               CommerceConfiguration.productIDs.contains(transaction.productID),
               transaction.revocationDate == nil, !transaction.isUpgraded {
                // StoreKit includes subscriptions in their billing grace period.
                unlocked = true
            }
        }
        isPremium = unlocked
        isReady = true
    }

    func loadProducts() async {
        guard !AppEdition.isPersonal, !CommerceConfiguration.productIDs.isEmpty else { return }
        do {
            products = try await Product.products(for: CommerceConfiguration.productIDs)
                .filter { $0.type == .autoRenewable }
                .sorted { $0.price < $1.price }
        } catch { message = "プランを読み込めませんでした。\n" + error.localizedDescription }
    }

    func purchase(_ product: Product) async {
        guard !AppEdition.isPersonal, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    message = "購入情報を確認できませんでした。購入の復元をお試しください。"
                    return
                }
                await refreshEntitlements()
                await transaction.finish()
            case .pending: message = "購入の承認を待っています。承認後に自動で反映されます。"
            case .userCancelled: break
            @unknown default: break
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        guard !AppEdition.isPersonal, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = isPremium ? "購入を復元しました。" : "有効なプレミアムプランは見つかりませんでした。"
        } catch { message = error.localizedDescription }
    }
}
