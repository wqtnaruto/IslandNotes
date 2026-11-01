import AppKit

@main
struct IslandNotesMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let applicationDelegate = AppDelegate()
        application.delegate = applicationDelegate
        application.run()
    }
}
