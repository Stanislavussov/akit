import AppKit
import SwiftUI

/// Debug mode: AKit renders its own window to a PNG and quits.
/// No Screen Recording permission needed — the app only draws its own window.
///
///   AKit.app/Contents/MacOS/AKit --snapshot /tmp/shot.png [--section overview] [--delay 2] [--query tdd]
///     [--harness pi] [--capture] [--tab prompt]
///
/// `--query` fills the search field of the section (skills.sh selects the first result);
/// `--own-copy` opens the skills.sh install form in "My own copy" mode.
///
/// Flags are read from launch arguments; without `--snapshot` nothing happens.
enum DebugSnapshot {
    struct Options {
        var output: URL
        var section: SidebarSection?
        var delay: Double
        var query: String?
        var ownCopy: Bool
        /// System Prompt screen: harness to show (HarnessID raw value).
        var harness: String?
        /// System Prompt screen: capture the prompt right away.
        var capture: Bool
        /// Session detail tab (SessionDetailTab raw value).
        var tab: String?
    }

    static let options: Options? = {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--snapshot") else { return nil }
        return Options(
            output: URL(filePath: path),
            section: value("--section").flatMap(SidebarSection.init(rawValue:)),
            delay: value("--delay").flatMap(Double.init) ?? 2,
            query: value("--query"),
            ownCopy: args.contains("--own-copy"),
            harness: value("--harness"),
            capture: args.contains("--capture"),
            tab: value("--tab")
        )
    }()

    /// Capture the main window and quit. Called after the screen has loaded its data.
    @MainActor
    static func captureAndQuit(_ options: Options) async {
        try? await Task.sleep(for: .seconds(options.delay))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView else {
            FileHandle.standardError.write(Data("snapshot: window not found\n".utf8))
            exit(1)
        }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { exit(1) }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try png.write(to: options.output)
            print("snapshot: \(options.output.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            exit(1)
        }
    }
}
