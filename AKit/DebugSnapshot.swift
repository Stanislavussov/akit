import AppKit
import SwiftUI

/// Debug mode: AKit renders its own window to a PNG and quits.
/// No Screen Recording permission needed — the app only draws its own window.
///
///   AKit.app/Contents/MacOS/AKit --snapshot /tmp/shot.png [--section overview] [--delay 2] [--query tdd]
///     [--harness pi] [--project akit] [--capture] [--tab prompt] [--add]   (Sessions: harness and project filters, session tab;
///     --add opens Review in Terminal…)
///
/// `--query` fills the search field of the section (skills.sh selects the first result;
/// Usage takes it as the period: week, month, quarter, year, all);
/// `--own-copy` opens the skills.sh install form in "My own copy" mode; `--project <folder name>`
/// picks that project as the install place; `--add` opens the MCP screen's Add Server sheet
/// (`--query <json>` fills its form, `--tab preview` shows the plan; `--tab catalog` opens its catalog search, `--query` is the search text, `--select <server name>` picks a result and `--capture` fills the form from it);
/// `--settings` shows the Settings view in the main window; `--guide <section id>` the guide window's
/// view, opened at that section (`--query` fills its search field);
/// `--brain <folder>` reads the brain repo from there (not saved in Settings); `--appearance light|dark`;
/// `--click 640,400` clicks there (snapshot points from the top left) before the capture;
/// `--size 1280x800` sets the window size; `--select <layer>` (or `project:<id>`) on the Brain screen; `--demo` hides the build badge (README screenshots, see `make screenshots`); on the Brain screen
/// `--tab setup` opens Set Up Project (with `--project`, `--query <layers>`, `--local-only` picks Local only, `--capture` for the preview).
/// Lab: `--tab sends` shows the send log; with `--select <run id>` of a review, `--tab notes` opens its
/// notes' disclosures and `--tab recheck` the Re-check sheet (`tools/demo-home.sh` has one). Settings: `--tab lab` (or `scrub`) scrolls to the sending
/// policy, `--add` opens Add Destination, `--capture` checks the accounts. Error Analysis (`--section analysis`):
/// `--tab modes|review|bootstrap|reports` (`--tab review --add` opens Cluster Unmatched Notes' cost confirmation); on Modes `--select <mode id>` opens the mode's page (`--query judge|fix` scrolls to that panel, `--query fix --add` opens Draft Fix…), on Bootstrap
/// `--select <session key>` opens its labeling view (`--query <step>` starts a note at that step); on Reports
/// `--select <batch id>` picks the batch, `--query <batch id>` the one to compare, `--add` scrolls to the matrix and
/// `--capture` shows the difference grid. Evals: `--select <task id>[,<task id>…]`, `--add` opens Run Cells…
/// (`--query layer` on a brain layer, `--project <layer>` picks it),
/// `--query fromSession|reproduction` a new task sheet. Lab: `--tab analysis --add` opens New Lab Run on the batch form; `--select`
/// takes a batch run's or a control cell's id too. Insights (`--section insights`): `--select <project id>` picks the
/// scope, `--add` opens Apply… of the first layer patch and `--capture` opens Install Capture…; it imports first, so
/// give it `--delay 8`.
///
/// Flags are read from launch arguments; without `--snapshot` nothing happens. Put flags without
/// a value (`--add`, `--capture`, `--own-copy`, `--settings`, `--local-only`) last: Cocoa pairs arguments as "-key value", and a
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
        /// Show the Error Analysis guide opened at this section instead of the sidebar window.
        var guide: String?
        /// A real mouse click before the capture, in the snapshot's points from its top left
        /// (pixels / 2 on a Retina screen): checks what a click hits, not just what is drawn.
        var click: CGPoint?
        /// Set Up Project: pick Local only (hidden from git).
        var localOnly: Bool
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
            select: value("--select"),
            guide: value("--guide"),
            click: value("--click").flatMap { text -> CGPoint? in
                let parts = text.split(separator: ",").compactMap { Double($0) }
                return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
            },
            localOnly: args.contains("--local-only")
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
        // An open sheet (e.g. `--add`) is its own window, and so is an alert on it: capture the topmost.
        guard var window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }) else {
            FileHandle.standardError.write(Data("snapshot: window not found\n".utf8))
            exit(1)
        }
        while let sheet = window.attachedSheet { window = sheet }
        guard let view = window.contentView?.superview ?? window.contentView else {
            FileHandle.standardError.write(Data("snapshot: window not found\n".utf8))
            exit(1)
        }
        if let click = options.click {
            // SwiftUI takes clicks only in the key window of the active app.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
            let point = view.convert(NSPoint(x: click.x, y: view.isFlipped ? click.y : view.bounds.height - click.y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            try? await Task.sleep(for: .seconds(1))
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
