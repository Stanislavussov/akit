import AppKit
import SwiftUI

/// Debug mode: AKit renders its own window to a PNG and quits.
/// No Screen Recording permission needed — the app only draws its own window.
///
///   AKit.app/Contents/MacOS/AKit --snapshot /tmp/shot.png [--section overview] [--delay 2] [--query tdd]
///     [--harness pi] [--capture] [--tab prompt]   (Sessions: harness filter, session tab)
///
/// `--query` fills the search field of the section (skills.sh selects the first result;
/// Usage takes it as the period: week, month, quarter, year, all);
/// `--own-copy` opens the skills.sh install form in "My own copy" mode; `--project <folder name>`
/// picks that project as the install place; `--add` opens the MCP screen's Add Server sheet;
/// `--settings` shows the Settings view in the main window;
/// `--brain <folder>` reads the brain repo from there (not saved in Settings); `--appearance light|dark`;
/// `--size 1280x800` sets the window size; `--select <layer>` (or `project:<id>`) on the Brain screen; `--demo` hides the build badge (README screenshots, see `make screenshots`); on the Brain screen
/// `--tab setup` opens Set Up Project (with `--project`, `--query <layers>`, `--capture` for the preview).
/// Lab: `--tab sends` shows the send log; with `--select <run id>` of a review, `--tab notes` opens its
/// notes' disclosures and `--tab recheck` the Re-check sheet (`tools/demo-home.sh` has one). Settings: `--tab lab` (or `scrub`) scrolls to the sending
/// policy, `--add` opens Add Destination, `--capture` checks the accounts. Error Analysis (`--section analysis`):
/// `--tab modes|review|bootstrap` (`--tab review --add` opens Cluster Unmatched Notes' cost confirmation); on Modes `--select <mode id>` opens the mode's page, on Bootstrap
/// `--select <session key>` opens its labeling view.
///
/// Flags are read from launch arguments; without `--snapshot` nothing happens. Put flags without
/// a value (`--add`, `--capture`, `--own-copy`, `--settings`) last: Cocoa pairs arguments as "-key value", and a
/// word left over is opened as a document, whose error alert keeps the window from appearing.
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
        /// Show the Settings view instead of the sidebar window.
        var settings: Bool
        /// README screenshots: no build badge in the sidebar.
        var demo: Bool
        /// `light` or `dark`; default: the system's.
        var appearance: String?
        /// Window content size in points, `1280x800`; default: as it opens.
        var size: CGSize?
        /// Brain screen: the layer to select.
        var select: String?
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
            brain: value("--brain"),
            settings: args.contains("--settings"),
            demo: args.contains("--demo"),
            appearance: value("--appearance"),
            size: value("--size").flatMap { text -> CGSize? in
                let parts = text.split(separator: "x").compactMap { Double($0) }
                return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
            },
            select: value("--select")
        )
    }()

    /// Capture the main window and quit. Called after the screen has loaded its data.
    @MainActor
    static func captureAndQuit(_ options: Options) async {
        switch options.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let size = options.size, let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) {
            window.setContentSize(size)
            window.center()
        }
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
