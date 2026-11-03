import SwiftUI
#if !PERSONAL_EDITION
import GoogleMobileAds
import UserMessagingPlatform
#endif

@MainActor
final class Advertising: ObservableObject {
    static let shared = Advertising()
    @Published private(set) var ready = false
    @Published private(set) var privacyOptionsRequired = false
    @Published var errorMessage: String?
    private var consentRequested = false
    private var started = false

    static var bannerID: String {
        #if DEBUG
        return "ca-app-pub-3940256099942544/2435281174"
        #else
        return CommerceConfiguration.value("AdMobBannerUnitID")
        #endif
    }
    private var configured: Bool {
        !AppEdition.isPersonal && !Self.bannerID.isEmpty &&
        !CommerceConfiguration.value("GADApplicationIdentifier").isEmpty
    }

    func prepare() async {
        #if !PERSONAL_EDITION
        guard configured, PremiumStore.shared.shouldShowAds, !consentRequested else { return }
        consentRequested = true
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
            try await ConsentForm.loadAndPresentIfRequired(from: nil)
        } catch { errorMessage = "広告のプライバシー設定を確認できませんでした。\n" + error.localizedDescription }
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        guard ConsentInformation.shared.canRequestAds, PremiumStore.shared.shouldShowAds else { return }
        if !started {
            started = true
            await MobileAds.shared.start()
        }
        ready = true
        #endif
    }

    func showPrivacyOptions() async {
        #if !PERSONAL_EDITION
        ready = false
        do { try await ConsentForm.presentPrivacyOptionsForm(from: nil) }
        catch { errorMessage = error.localizedDescription }
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        ready = started && ConsentInformation.shared.canRequestAds
        #endif
    }
}

struct AlbumAdvertisement: View {
    @ObservedObject private var premium = PremiumStore.shared
    @ObservedObject private var advertising = Advertising.shared
    var body: some View {
        #if !PERSONAL_EDITION
        if premium.shouldShowAds && advertising.ready {
            VStack(spacing: 2) {
                Text("広告").font(.caption2).foregroundStyle(.secondary)
                BannerContainer().frame(width: 320, height: 50)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 4).background(.bar)
        }
        #endif
    }
}

#if !PERSONAL_EDITION
private struct BannerContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = Advertising.bannerID
        // No ATT prompt or cross-app tracking request. Request non-personalized ads.
        let request = Request()
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        banner.load(request)
        return banner
    }
    func updateUIView(_ uiView: BannerView, context: Context) {}
}
#endif
