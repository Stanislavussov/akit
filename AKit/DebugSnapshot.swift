import AKitFoundation
import AKitKnowledge
import AppKit
import SwiftUI

/// Debug mode: AKit renders its own window to a PNG and quits.
/// No Screen Recording permission needed — the app only draws its own window.
///
///   AKit.app/Contents/MacOS/AKit --snapshot /tmp/shot.png [--section overview] [--delay 2] [--query tdd]
///     [--harness pi] [--project akit] [--capture] [--tab prompt] [--add]   (Sessions: harness and project filters, session tab;
///     --add opens Review in Terminal…)
///
/// Overview: `--tab pi-doctor` opens the Pi card's Check Pi… sheet (`--capture` also runs Check Servers and Sign-In).
///
/// `--query` fills the search field of the section (skills.sh selects the first result;
/// Usage takes it as the period: week, month, quarter, year, all);
/// `--own-copy` opens the skills.sh install form in "My own copy" mode; `--project <folder name>`
/// picks that project as the install place; `--add` opens the MCP screen's Add Server sheet
/// (`--query <json>` fills its form, `--tab preview` shows the plan; `--tab catalog` opens its catalog search, `--query` is the search text, `--select <server name>` picks a result and `--capture` fills the form from it);
/// MCP Servers: `--tab switch` opens Off in Project… of the first server with a switch.
/// Skills: `--add` opens the selected skill's switch sheet (the first harness with a switch, its first other state);
/// `--tab invocation` opens Make Manual… / Make Auto… (model invocation) for the skill `--select <folder name>`;
/// `--tab invocation-all` opens Model Invocation → Make All Global Skills Manual…;
/// Instructions: `--project <folder name>` picks the session folder, `--select <file name>` the first file of that name, `--tab duplicates` turns the Duplicates filter on, `--tab remove-copy` opens Remove This Copy… for the selected file's first repeated section, `--tab import` Import to Brain… for its first section, `--tab move-up` / `move-down` Move to Global… / Move to Project…, `--tab edit` / `rewrite` Edit… / Rewrite with Skill… for the selected file;
/// `--tab duplicates` turns the Duplicates filter on and selects `--select <folder name>`; `--tab resolve` opens its Resolve Duplicate…;
/// `--tab global` opens Move to Global… for the project skill `--select <folder name>` on the Skills screen;
/// `--tab remove` opens Remove Everywhere… for `--select <folder name>` on the Skills screen;
/// `--tab move` opens Move to Project… for the global skill `--select <folder name>` (`move-check`, `move-preview` go on to those pages);
/// `--settings` shows the Settings view in the main window; `--guide <section id>` the guide window's
/// view, opened at that section (`--query` fills its search field, which searches every guide and screen);
/// `--brain <folder>` reads the brain repo from there (not saved in Settings); `--appearance light|dark`;
/// `--click 640,400` clicks there (snapshot points from the top left) before the capture;
/// `--size 1280x800` sets the window size; `--select <layer>` (or `project:<id>`) on the Brain screen; `--demo` hides the build badge (README screenshots, see `make screenshots`); on the Brain screen
/// `--tab setup` opens Set Up Project (with `--project`, `--query <layers>`, `--local-only` picks Local only, `--capture` for the preview).
/// Lab: `--tab sends` shows the send log; with `--select <run id>` of a review, `--tab notes` opens its
/// notes' disclosures and `--tab recheck` the Re-check sheet (`tools/demo-home.sh` has one). Settings: `--tab lab` (or `scrub`) scrolls to the sending (`--tab knowledge` to Knowledge, and prints its folders)
/// policy, `--add` opens Add Destination, `--capture` checks the accounts. Error Analysis (`--section analysis`):
/// `--tab modes|review|bootstrap|reports` (`--tab review --add` opens Cluster Unmatched Notes' cost confirmation); on Modes `--select <mode id>` opens the mode's page (`--query judge|fix` scrolls to that panel, `--query fix --add` opens Draft Fix…), on Bootstrap
/// `--select <session key>` opens its labeling view (`--query <step>` starts a note at that step); on Reports
/// `--select <batch id>` picks the batch, `--query <batch id>` the one to compare, `--add` scrolls to the matrix and
/// `--capture` shows the difference grid. Evals: `--select <task id>[,<task id>…]`, `--add` opens Run Cells…
/// (`--query layer` on a brain layer, `--project <layer>` picks it),
/// `--query fromSession|reproduction` a new task sheet. Lab: `--tab analysis --add` opens New Lab Run on the batch form; `--select`
/// takes a batch run's or a control cell's id too. Insights (`--section insights`): `--select <project id>` picks the
/// scope, `--add` opens Apply… of the first layer patch and `--capture` opens Install Capture…; `--tab skills|servers|tools`
/// scrolls to that table, `--query unused` turns on Unused Only and `--query open` opens every MCP server's tool list; it
/// imports first, so give it `--delay 8`.
///
/// Knowledge (`--section knowledge`): `--select <note id>` (`payments/orders-api`) opens that note; `--tab edit` shows
/// it in Edit, `--tab properties` shows its Properties form, `--tab delete` asks Delete…, `--tab new-area|new-note|create-base`
/// opens that sheet, `--tab kinds` the Kinds… sheet and `--tab area-settings` Area Settings… of the selected note's space;
/// `--tab sample` shows the sample base (`akit kb seed`) and `--tab sample-remove` also asks Remove Sample Base….
/// `--tab lint` shows the Lint tab (4.1); the capture prints each finding with its buttons.
/// The capture prints the screen's state as text (base, spaces, notes, tabs, the note in view, with Properties its kind
/// and fields, the kinds or the area settings), so a check needs no image.
/// `--tab map --select <map id>` (`payments/maps/overview`) opens that map (read only); the capture waits until the
/// canvas is ready and its scene loaded (10 s at most), draws the web view into the image and prints the page's
/// messages, fonts, problems, every file the `akit-web:` handler served, the refused loads, the scene's element
/// count and the canvas frame (`map canvas: x,y,w,h` in snapshot points from the top left).
/// Maps can be edited (2.2b): `--tab map-edit` opens the map in Edit, `--tab map-delete` asks its Delete…, `--tab new-map`
/// opens New Map…. Checks: `--tab map-add` adds a rectangle through Excalidraw's API and waits past the 800 ms save
/// (prints `posts: 1`; the file is saved and queued, not committed); `--tab map-add-quit` adds one and quits at once
/// (the quit flush force-posts, saves and commits it; no image); `--tab map-conflict` first appends a space to the file
/// on disk, then adds one, so "Changed on disk" appears (`--query keep|reload` then answers it). 2.3: `--select block:<element id>`
/// opens the map with that element and its link (as a click would); `--tab rename` asks Rename… of the selected note or map
/// (`--query` the new name); `--tab map-drop --query <note id>` drops a note on the map; `--tab map-rename --query <note>=<name>`
/// renames right after an unsaved edit (N5). Every map snapshot prints `posts: N` (0 after an open).
/// 3.3: `--query <words>` (no `--tab`) fills the toolbar search and prints the hits; `--tab focus` and `--tab context`
/// open Focus… and Preview Agent Context… (`--project <folder name>` picks the project, `--query json` the JSON view).
/// 3.4: `--tab pi-template` opens Pi Template… and prints its state ("already set" or the diff it would write).
/// `--tab watch --select <note id> --query <word>` is the watcher check: it appends a section with the word to the
/// note's file from outside, waits for the watcher's batch, searches the word and prints the hit, the time it took
/// and the commit queue (the edit is queued, not committed: that waits for the 5 min idle flush, or the quit).
/// `--tab watch-edit` does the same with the note in Edit, so "Changed on disk" (Reload / Keep Mine) appears.
/// 5.3: `--tab inbox [--select <proposal id>]` shows the Inbox tab and prints each proposal with its checks and marks,
/// and the selected one's diff (or arrow) and model marks. Checks: `--tab inbox-accept --select <id>` accepts a note
/// proposal (prints the result and the new commit), `--tab inbox-reject --select <id>` rejects one (to the Trash),
/// `--tab inbox-arrow --select <id> [--query <map id>]` accepts an arrow: its map opens in Edit with "Add an arrow?",
/// Add draws it and saves the map, and the capture prints the posts, the map's relations and the inbox left.
///
/// `--right-click 300,400;300,420` right-clicks there before the capture and prints each context
/// menu's items (to check which places get Ask AKit About This);
/// `--ask` opens the Ask AKit panel with a made-up chat about the Listing budget (no model call).
///
/// Flags are read from launch arguments; without `--snapshot` nothing happens. Put flags without
/// a value (`--add`, `--capture`, `--own-copy`, `--settings`, `--local-only`, `--ask`) last: Cocoa pairs arguments as "-key value", and a
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
        /// Open the Ask AKit panel with a made-up chat (no model call).
        var ask: Bool
        /// Right-clicks, in the same points as `click`: each context menu's items are printed
        /// and the menu closed again, so a script can check which menu a place gets.
        var rightClicks: [CGPoint]
    }

    static let options: Options? = {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            // The last one wins, so a script can give a default first.
            guard let i = args.lastIndex(of: flag), i + 1 < args.count else { return nil }
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
            localOnly: args.contains("--local-only"),
            ask: args.contains("--ask"),
            rightClicks: (value("--right-click") ?? "").split(separator: ";").compactMap { pair -> CGPoint? in
                let parts = pair.split(separator: ",").compactMap { Double($0) }
                return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
            }
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
        // A map waits for its canvas first, so a click can open a block's link.
        let mapOpen = options.section == .knowledge && KnowledgeModel.current?.map != nil
        if mapOpen { await MapCanvasView.Coordinator.waitAndPrint() }
        // Checks of 2.3: `--tab map-drop --query <note id>` drops the note in the canvas's middle (K6) and waits past
        // the save; `--tab map-rename --query <note>=<new name>` adds a rectangle (not yet saved) and renames at once (N5).
        if mapOpen, let canvas = MapCanvasView.Coordinator.current, let model = KnowledgeModel.current, let webView = canvas.webView,
           let tab = options.tab, ["map-drop", "map-rename"].contains(tab), let query = options.query {
            if tab == "map-drop" {
                await model.drop(note: query, at: CGPoint(x: webView.bounds.midX, y: webView.bounds.midY))
                try? await Task.sleep(for: .milliseconds(1600))
            } else {
                let parts = query.split(separator: "=", maxSplits: 1).map(String.init)
                let count = (try? await canvas.call("akitDebugAddRectangle")) as? NSNumber
                print("map: added a rectangle, \(count?.intValue ?? -1) elements")
                if parts.count == 2 {
                    let renamed = await model.rename(parts[0], to: parts[1])
                    print("map: rename \(parts[0]) → \(parts[1]): " + (renamed ? model.notice ?? "" : model.problem ?? "refused"))
                }
                try? await Task.sleep(for: .milliseconds(1200))
                let result = (try? await canvas.call("akitDiagnostics")) as? [String: Any] ?? [:]
                for link in result["links"] as? [String] ?? [] { print("map link after: \(link)") }
                let serialized = (try? await canvas.call("akitSerialize")) as? String
                print("map elements after: \((serialized.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["elements"] as? [Any])?.count ?? -1)")
            }
            await canvas.printPosts()
        }
        if mapOpen, options.tab == "inbox-arrow", let canvas = MapCanvasView.Coordinator.current, let model = KnowledgeModel.current,
           let plan = model.arrowRequest {
            print("inbox: add an arrow? \(plan.text) on \(plan.map)")
            let added = await model.addArrow()
            print("inbox: add: " + (added ? model.notice ?? "" : model.problem ?? "refused"))
            await canvas.printPosts()
            if let base = model.base, let graph = try? base.mapGraph() {
                for edge in graph.edges where edge.map == plan.map {
                    print("relation: \(edge.from) → \(edge.to)" + (edge.kind.map { " \"\($0)\"" } ?? "") + " (\(edge.map))")
                }
                print("map pending commit: " + KnowledgeCommitQueue(base: base.root, env: .current).pending().joined(separator: ", "))
            }
        }
        if mapOpen, let canvas = MapCanvasView.Coordinator.current, let model = KnowledgeModel.current, let id = model.map,
           let tab = options.tab, ["map-add", "map-add-quit", "map-conflict"].contains(tab) {
            // Checks of 2.2b without a hand: the file changes on disk first (map-conflict), then a
            // rectangle is added through Excalidraw's API, as a user's drawing would be.
            if tab == "map-conflict", let base = model.base, let handle = try? FileHandle(forWritingTo: base.mapFile(id)) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(" ".utf8))
                try? handle.close()
                print("map: appended a space to \(base.mapPath(id)) on disk")
            }
            let count = (try? await canvas.call("akitDebugAddRectangle")) as? NSNumber
            print("map: added a rectangle, \(count?.intValue ?? -1) elements")
            if tab == "map-add-quit" {
                // Quit inside the 800 ms debounce: the quit flush must force-post, save and commit it.
                // From the run loop, not from this main-actor job: terminate waits in a nested event
                // loop for the quit flush, which needs the main actor.
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
                try? await Task.sleep(for: .seconds(30))
                exit(1)
            }
            try? await Task.sleep(for: .milliseconds(1600))
            await canvas.printPosts()
            // `--query keep|reload` answers "Changed on disk" like a click on Keep Mine or Reload.
            if tab == "map-conflict", model.mapConflict != nil, let answer = options.query {
                if answer == "keep" { model.keepMineInConflict() } else if answer == "reload" { model.reloadConflictedMap() }
                try? await Task.sleep(for: .milliseconds(800))
                print("map: answered \(answer): \(model.notice ?? model.problem ?? "")")
                await canvas.printPosts()
            }
        }
        if let click = options.click {
            // SwiftUI takes clicks only in the key window of the active app.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
            let point = view.convert(NSPoint(x: click.x, y: view.isFlipped ? click.y : view.bounds.height - click.y), to: nil)
            // A web view takes no events from sendEvent: on the map canvas the click goes into
            // the page as pointer events instead.
            let canvas = mapOpen ? MapCanvasView.Coordinator.current : nil
            let inCanvas = canvas?.webView.map { webView in webView.convert(point, from: nil) }.flatMap { local in
                canvas?.webView.flatMap { $0.bounds.contains(local) ? local : nil }
            }
            if let canvas, let local = inCanvas, let webView = canvas.webView {
                await canvas.click(x: local.x, y: webView.isFlipped ? local.y : webView.bounds.height - local.y)
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] where inCanvas == nil {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if !options.rightClicks.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
            // The menu tracks in a loop of its own inside sendEvent: print it, then close it from there.
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                nonisolated(unsafe) let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let menu, menu.supermenu == nil else { return }
                    print("  menu: " + menu.items.map { $0.isSeparatorItem ? "|" : $0.title }.joined(separator: ", "))
                    RunLoop.main.perform(inModes: [.eventTracking, .default]) { menu.cancelTrackingWithoutAnimation() }
                }
            }
            for click in options.rightClicks {
                print("right-click \(Int(click.x)),\(Int(click.y))")
                let point = view.convert(NSPoint(x: click.x, y: view.isFlipped ? click.y : view.bounds.height - click.y), to: nil)
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(event)
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            NotificationCenter.default.removeObserver(observer)
        }
        if options.section == .knowledge, ["watch", "watch-edit"].contains(options.tab), let model = KnowledgeModel.current, let base = model.base,
           let id = options.select, let word = options.query {
            let start = Date()
            if let handle = try? FileHandle(forWritingTo: base.noteFile(id)) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data("\n## Watch check\n\nWritten from outside: \(word).\n".utf8))
                try? handle.close()
                print("watch: appended a section with “\(word)” to \(base.notePath(id)) from outside")
            }
            // The watcher's quiet second plus FSEvents' latency; the search runs after its batch.
            while Date().timeIntervalSince(start) < 5,
                  !KnowledgeCommitQueue(base: base.root, env: .current).pending().contains(base.notePath(id)) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await model.watchTask?.value
            model.searchText = word
            await model.runSearch()
            let hit = model.searchAnswer?.results.first { $0.note == id }
            print(String(format: "watch: search “%@” after %.1f s: ", word, Date().timeIntervalSince(start))
                + (hit.map { "\($0.note) ## \($0.heading ?? "-")" } ?? "no hit"))
            print("watch: pending commits: " + KnowledgeCommitQueue(base: base.root, env: .current).pending().joined(separator: ", "))
        }
        if options.section == .knowledge, let tab = options.tab, ["inbox-accept", "inbox-reject"].contains(tab),
           let model = KnowledgeModel.current, let base = model.base, let entry = model.selectedProposal {
            if tab == "inbox-accept" {
                if case .success(let plan)? = model.acceptPlan(entry) {
                    let accepted = await model.accept(plan)
                    print("inbox: accept \(entry.id): " + (accepted ? model.notice ?? "" : model.problem ?? "refused"))
                } else {
                    print("inbox: accept \(entry.id) refused: " + ({ if case .failure(let error)? = model.acceptPlan(entry) { error.message } else { "not a note proposal" } }()))
                }
            } else {
                let rejected = await model.reject(entry.id)
                print("inbox: reject \(entry.id): " + (rejected ? model.notice ?? "" : model.problem ?? "refused"))
            }
            let git = URL(filePath: "/usr/bin/git")
            let log = await ProcessRunner.run(git, arguments: ["log", "-1", "--format=%s"], directory: base.root, environment: HarnessEnvironment.current.variables, timeout: 20)
            let status = await ProcessRunner.run(git, arguments: ["status", "--porcelain"], directory: base.root, environment: HarnessEnvironment.current.variables, timeout: 20)
            print("inbox: last commit: \(log?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-")")
            print("inbox: git status: " + (status?.output.split(separator: "\n").joined(separator: "; ") ?? "-"))
        }
        if options.section == .knowledge, let manifest = KnowledgeModel.current?.manifest {
            print(manifest)
        }
        if options.settings, options.tab == "knowledge" || options.tab == "knowledge-check" {
            print(KnowledgeSettingsSection.manifest())
            print(KnowledgeCheckModelSection.manifest())
        }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { exit(1) }
        view.cacheDisplay(in: bounds, to: rep)
        // cacheDisplay draws no web view: draw the map canvas's own snapshot over its place.
        if mapOpen, let webView = MapCanvasView.Coordinator.current?.webView, webView.window == window,
           let image = try? await webView.takeSnapshot(configuration: nil) {
            var frame = webView.convert(webView.bounds, to: view)
            if view.isFlipped { frame.origin.y = bounds.height - frame.maxY }
            print("map canvas: \(Int(frame.minX)),\(Int(bounds.height - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                image.draw(in: frame)
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
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
