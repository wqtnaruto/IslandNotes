import Foundation

enum L10n {
    static let locale = Locale(identifier: "zh-Hans")

    private static let chineseBundle: Bundle = {
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
        chineseBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func defaultChineseString(_ key: String) -> String {
        string(key)
    }

    static func minutes(_ value: Int) -> String {
        String(format: string("Minutes remaining format"), locale: locale, value)
    }

    static func compactMinutes(_ value: Int) -> String {
        String(format: string("Compact minutes format"), locale: locale, value)
    }

    static func focusRemaining(_ value: Int) -> String {
        String(format: string("Focus remaining format"), locale: locale, value)
    }
}
