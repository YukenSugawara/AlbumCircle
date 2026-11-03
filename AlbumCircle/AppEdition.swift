import Foundation

enum AppEdition {
    #if PERSONAL_EDITION
    static let isPersonal = true
    #else
    static let isPersonal = false
    #endif
    static var title: String { isPersonal ? "個人利用版" : "App Store版" }
}

enum CommerceConfiguration {
    static func value(_ key: String) -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("$(") ? "" : value
    }
    static var productIDs: [String] {
        [value("PremiumMonthlyProductID"), value("PremiumYearlyProductID")].filter { !$0.isEmpty }
    }
    static var privacyURL: URL? {
        guard let url = URL(string: value("PrivacyPolicyURL")),
              url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
