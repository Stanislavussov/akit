import AppKit
import SwiftUI

/// Debug mode: AKit renders its own window to a PNG and quits.
/// No Screen Recording permission needed — the app only draws its own window.
///
///   AKit.app/Contents/MacOS/AKit --snapshot /tmp/shot.png [--section overview] [--delay 2] [--query tdd]
///     [--harness pi] [--capture] [--tab prompt]   (Sessions: harness filter, session tab)
///
/// `--query` fills the search field of the section (skills.sh selects the first result);
/// `--own-copy` opens the skills.sh install form in "My own copy" mode; `--project <folder name>`
/// picks that project as the install place; `--add` opens the MCP screen's Add Server sheet;
/// `--brain <folder>` reads the brain repo from there (not saved in Settings).
///
/// Flags are read from launch arguments; without `--snapshot` nothing happens.
enum DebugSnapshot {
    struct Options {
        var output: URL
        var section: SidebarSection?
        var delay: Double
        var query: String?
        var ownCopy: Bool
        var project: String?
        /// Sessions screen: show only this harness (HarnessID raw value).
        var harness: String?
        /// Session System Prompt tab: capture the prompt right away (Pi).
        var capture: Bool
        /// Session detail tab (SessionDetailTab raw value).
        var tab: String?
        /// MCP screen: open the Add Server sheet.
        var add: Bool
        /// Brain repo folder for this run only.
        var brain: String?
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
            project: value("--project"),
            harness: value("--harness"),
            capture: args.contains("--capture"),
            tab: value("--tab"),
            add: args.contains("--add"),
            brain: value("--brain")
        )
    }()

    /// Capture the main window and quit. Called after the screen has loaded its data.
    @MainActor
    static func captureAndQuit(_ options: Options) async {
        try? await Task.sleep(for: .seconds(options.delay))
        // An open sheet (e.g. `--add`) is its own window: capture it instead.
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }),
              case let window = main.attachedSheet ?? main,
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
