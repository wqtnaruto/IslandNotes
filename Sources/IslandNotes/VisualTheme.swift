import AppKit
import SwiftUI

struct VisualTheme: Equatable, Sendable {
    let isDark: Bool

    private static let darkNSForeground = NSColor.white
    private static let lightNSForeground = NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.19, alpha: 1)
    private static let darkNSSecondary = NSColor.white.withAlphaComponent(0.62)
    private static let lightNSSecondary = NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.19, alpha: 0.62)
    private static let darkNSAccent = NSColor(calibratedRed: 128/255, green: 82/255, blue: 1, alpha: 1)
    private static let lightNSAccent = NSColor(calibratedRed: 0.46, green: 0.62, blue: 0.47, alpha: 1)

    var panel: Color { isDark ? Color(red: 8/255, green: 8/255, blue: 8/255) : Color(red: 0.94, green: 0.95, blue: 0.92) }
    var editor: Color { isDark ? Color(red: 13/255, green: 13/255, blue: 16/255) : .white.opacity(0.86) }
    var activeTab: Color { isDark ? Color(red: 36/255, green: 36/255, blue: 41/255) : .white.opacity(0.85) }
    var inactiveTab: Color { isDark ? Color(red: 18/255, green: 18/255, blue: 20/255) : .white.opacity(0.25) }
    var foreground: Color { isDark ? .white : Color(red: 0.18, green: 0.20, blue: 0.19) }
    var secondary: Color { foreground.opacity(isDark ? 0.62 : 0.60) }
    var edge: Color { foreground.opacity(isDark ? 0.13 : 0.10) }
    var accent: Color { isDark ? Color(red: 128/255, green: 82/255, blue: 1) : Color(red: 0.46, green: 0.62, blue: 0.47) }
    var focus: Color { isDark ? Color(red: 1, green: 184/255, blue: 41/255) : accent }
    var nsForeground: NSColor { isDark ? Self.darkNSForeground : Self.lightNSForeground }
    var nsSecondary: NSColor { isDark ? Self.darkNSSecondary : Self.lightNSSecondary }
    var nsAccent: NSColor { isDark ? Self.darkNSAccent : Self.lightNSAccent }
}
