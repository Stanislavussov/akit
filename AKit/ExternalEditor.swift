import AppKit

/// Opens files and folders in VS Code. Folders open as a workspace window.
enum ExternalEditor {
    static let name = "VS Code"
    private static let bundleID = "com.microsoft.VSCode"

    /// nil when VS Code is not installed on this machine.
    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func open(_ url: URL) {
        guard let appURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
