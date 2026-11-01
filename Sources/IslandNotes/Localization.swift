import Foundation

enum L10n {
    private static let defaultBundle: Bundle = {
        let localization = "zh-Hans"
        if let stringsURL = Bundle.module.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: localization
        ), let bundle = Bundle(url: stringsURL.deletingLastPathComponent()) {
            return bundle
        }

        if let resourceURL = Bundle.module.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("\(localization).lproj")) {
            return bundle
        }
        return Bundle.module
    }()

    static func string(_ key: String) -> String {
        defaultBundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Starter content is part of the product's default experience, rather than
    /// user-authored text. Keep it Chinese even when Xcode temporarily overrides
    /// the process language in the Run scheme.
    static func defaultChineseString(_ key: String) -> String {
        string(key)
    }

    static func minutes(_ value: Int) -> String {
        String(format: string("Minutes remaining format"), locale: .current, value)
    }
}
