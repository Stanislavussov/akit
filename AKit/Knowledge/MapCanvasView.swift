import AKitKnowledge
import AppKit
import SwiftUI
import WebKit

/// A knowledge map: the vendored Excalidraw canvas (`web/excalidraw`, bundled as the app's
/// `excalidraw` folder) in a web view that can load nothing but that folder. Pages come from the
/// `akit-web:` scheme handler with a strict Content-Security-Policy, a content rule list blocks
/// every http(s) load, and other navigations are cancelled. The page talks to AKit through the
/// `kb` message handler (`web/excalidraw/bridge.js` describes the messages).
struct MapCanvasView: NSViewRepresentable {
    /// What the canvas shows: a map's `.excalidraw` text, the key its saves carry (the map id), and
    /// a generation that a Reload raises, so the same text can be loaded again.
    struct Scene: Equatable {
        var key: String
        var text: String
        var generation = 0
    }

    /// The scene to show once the canvas is ready; a different one replaces it.
    var scene: Scene
    /// Excalidraw's view mode (`viewModeEnabled`): nothing can be edited, and a click on a block or
    /// arrow opens its link. Off is Edit: every change is posted as `save` (`bridge.js`).
    var viewMode = true
    /// Every message from the page (`type`: ready, sceneLoaded, linkOpen, save, problem).
    var onMessage: (MapCanvasMessage) -> Void = { _ in }

    /// The page's policy, sent as a header with every response; the smallest one that works
    /// (spike 2.0, `docs/design/knowledge.md`). Excalidraw injects its CSS as `<style>` tags
    /// (`'unsafe-inline'` for styles) and draws its cursors and icons from `data:` images.
    /// Scripts are files only. Its workers serve only image import, which is off, so none
    /// is allowed (`default-src` also covers `worker-src`, `connect-src` and `font-src`).
    static let contentSecurityPolicy = "default-src akit-web:; img-src akit-web: data:; style-src akit-web: 'unsafe-inline'"

    static let scheme = "akit-web"
    static let pageURL = URL(string: "\(scheme)://app/index.html")!

    func makeCoordinator() -> Coordinator { Coordinator(scene: scene, viewMode: viewMode, onMessage: onMessage) }

    /// What the page reads before its scripts run (the CSP doesn't apply to a user script).
    static func optionsScript(viewMode: Bool) -> WKUserScript {
        WKUserScript(source: "window.akitOptions = { viewMode: \(viewMode) };", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.files, forURLScheme: Self.scheme)
        configuration.userContentController.add(context.coordinator, name: "kb")
        configuration.userContentController.addUserScript(Self.optionsScript(viewMode: viewMode))
        // Nothing is kept between runs: no cookies, caches or storage on disk.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Drops go to SwiftUI's drop destination around the canvas (a note → a linked block), not
        // into the page, which would make a free text of it.
        webView.unregisterDraggedTypes()
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.start()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        let coordinator = context.coordinator
        if coordinator.scene != scene {
            coordinator.scene = scene
            if coordinator.isReady { Task { await coordinator.loadScene() } }
        }
        if coordinator.viewMode != viewMode {
            coordinator.viewMode = viewMode
            if coordinator.isReady {
                Task { _ = try? await webView.callAsyncJavaScript("akitSetViewMode(on)", arguments: ["on": viewMode], contentWorld: .page) }
            }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kb")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let files = MapWebFiles(root: Bundle.main.resourceURL!.appending(path: "excalidraw"),
                                contentSecurityPolicy: MapCanvasView.contentSecurityPolicy)
        var scene: Scene
        /// The view mode the page has (set at start by the options script, later by `akitSetViewMode`).
        var viewMode: Bool
        var onMessage: (MapCanvasMessage) -> Void
        weak var webView: WKWebView?
        /// Navigations the delegate cancelled (anything but the map page itself).
        private(set) var cancelledNavigations = 0
        /// The page posted `ready`: its API is there.
        private(set) var isReady = false
        /// The element count of the last `sceneLoaded`; nil until a scene is on the canvas.
        private(set) var loadedElements: Int?

        /// The canvas on screen (the map in view or the Inbox draft): the model saves and drops
        /// through it, snapshots read it.
        private(set) static weak var current: Coordinator?

        init(scene: Scene, viewMode: Bool, onMessage: @escaping (MapCanvasMessage) -> Void) {
            self.scene = scene
            self.viewMode = viewMode
            self.onMessage = onMessage
            super.init()
            Self.current = self
        }

        /// Installs the http(s) block, then loads the page.
        func start() {
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "akit-map-offline", encodedContentRuleList: rules) { [weak self] list, error in
                MainActor.assumeIsolated {
                    guard let self, let webView = self.webView else { return }
                    if let list {
                        webView.configuration.userContentController.add(list)
                        webView.load(URLRequest(url: MapCanvasView.pageURL))
                    } else {
                        // No block list, no page: never risk an online load.
                        self.onMessage(MapCanvasMessage(type: "problem", body: ["message": "content rules: \(error?.localizedDescription ?? "unknown")"]))
                    }
                }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            let event = MapCanvasMessage(type: type, body: body)
            onMessage(event)
            if DebugSnapshot.options != nil {
                if type == "save" {
                    print("map: save \(body["key"] as? String ?? "?"), \((body["json"] as? String)?.utf8.count ?? 0) bytes")
                } else {
                    print("map: \(type) \(Self.json(body))")
                }
            }
            switch type {
            case "ready":
                isReady = true
                Task { await loadScene() }
            case "sceneLoaded":
                loadedElements = (body["elements"] as? NSNumber)?.intValue ?? 0
            default: break
            }
        }

        /// Snapshots: waits (up to `timeout` seconds) until the page is ready and a scene is on the
        /// canvas, then (up to 3 s more) until no font reports `error`: right after a fresh build
        /// a font can report `error` first and `loaded` a moment later (spike 2.0). Prints what
        /// the page loaded and what was refused, as text (no image needed). WebKit lists no
        /// resource timing for a custom scheme, so the served paths come from the scheme handler.
        static func waitAndPrint(timeout: Double = 10) async {
            let deadline = Date.now.addingTimeInterval(timeout)
            while current?.isReady != true || current?.loadedElements == nil, Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let canvas = current, canvas.isReady, let elements = canvas.loadedElements else {
                print("map: not loaded after \(Int(timeout)) s (ready \(current?.isReady ?? false))")
                return
            }
            var result: [String: Any] = [:]
            let fontDeadline = Date.now.addingTimeInterval(3)
            repeat {
                result = (try? await canvas.call("akitDiagnostics")) as? [String: Any] ?? [:]
                let fonts = result["fonts"] as? [String] ?? []
                if !fonts.contains(where: { $0.hasSuffix(" error") }) { break }
                try? await Task.sleep(for: .milliseconds(250))
            } while Date.now < fontDeadline
            // Excalidraw draws on the next animation frames.
            try? await Task.sleep(for: .milliseconds(400))
            for font in result["fonts"] as? [String] ?? [] { print("map font: \(font)") }
            for problem in result["problems"] as? [String] ?? [] { print("map problem: \(problem)") }
            for link in result["links"] as? [String] ?? [] { print("map link: \(link)") }
            for path in canvas.files.served { print("map served: \(MapCanvasView.scheme)://app/\(path)") }
            print("map refused loads: \(canvas.files.refused), cancelled navigations: \(canvas.cancelledNavigations)")
            print("map elements: \(elements)")
            await canvas.printPosts()
        }

        static func json(_ value: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
        }

        /// Snapshots: how many saves the page handed to AKit (N4: 0 after an open without edits).
        func printPosts() async {
            let posts = (try? await webView?.callAsyncJavaScript("return akitPosts()", contentWorld: .page)) as? NSNumber
            print("posts: \(posts?.intValue ?? -1)")
        }

        /// The flushes (N5): a change still waiting for its 800 ms post, handed over now; nil when
        /// the scene is as last posted. Throws when the page doesn't answer.
        func takeUnsaved() async throws -> (key: String, json: String)? {
            guard isReady, let webView else { return nil }
            guard let save = try await webView.callAsyncJavaScript("return akitTakeUnsaved()", contentWorld: .page) as? [String: Any],
                  let key = save["key"] as? String, let json = save["json"] as? String
            else { return nil }
            return (key, json)
        }

        /// A note dropped on the canvas (K6): a labelled block with its link, centred on `point`
        /// (page pixels from the top left). The element id, or nil when the page refused.
        func addLinkedBlock(link: String, label: String, at point: CGPoint) async -> String? {
            try? await webView?.callAsyncJavaScript("return akitAddLinkedBlock(link, label, x, y)",
                                                    arguments: ["link": link, "label": label, "x": point.x, "y": point.y],
                                                    contentWorld: .page) as? String
        }

        /// Accept of an arrow proposal (5.3): the arrow between the plan's blocks, and a new linked
        /// block for an end the map lacks. The arrow's element id; throws the page's error.
        func addArrow(_ plan: KnowledgeInbox.ArrowPlan) async throws -> String? {
            func end(_ end: KnowledgeInbox.ArrowPlan.End) -> [String: Any] {
                ["element": end.element ?? NSNull(), "link": end.link, "label": end.label]
            }
            let spec: [String: Any] = ["from": end(plan.from), "to": end(plan.to), "label": plan.kind ?? NSNull()]
            let result = try await webView?.callAsyncJavaScript("return akitAddArrow(spec)", arguments: ["spec": spec], contentWorld: .page)
            return (result as? [String: Any])?["arrow"] as? String
        }

        /// Accept of a map proposal (5.4): each element's link (`[[note]]`), set on the canvas so the
        /// saved bytes are Excalidraw's own. How many elements got one; throws the page's error.
        func setLinks(_ links: [String: String]) async throws -> Int {
            let result = try await webView?.callAsyncJavaScript("return akitSetLinks(links)", arguments: ["links": links], contentWorld: .page)
            return (result as? NSNumber)?.intValue ?? 0
        }

        /// Snapshots and Accept of a map proposal: waits (up to `timeout` seconds) until this canvas
        /// is ready and shows the scene with `key`.
        func waitForScene(_ key: String, timeout: Double = 10) async -> Bool {
            let deadline = Date.now.addingTimeInterval(timeout)
            while !(isReady && loadedElements != nil && scene.key == key), Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return isReady && loadedElements != nil && scene.key == key
        }

        func loadScene() async {
            guard let webView else { return }
            loadedElements = nil
            do {
                _ = try await webView.callAsyncJavaScript("return akitLoadScene(json, key)", arguments: ["json": scene.text, "key": scene.key],
                                                          contentWorld: .page)
            } catch {
                onMessage(MapCanvasMessage(type: "problem", body: ["message": "akitLoadScene: \(error.localizedDescription)"]))
            }
        }

        /// Snapshots (`--click` on the canvas): a click at a point of the page, in CSS pixels from its top left.
        func click(x: Double, y: Double) async {
            let target = try? await webView?.callAsyncJavaScript("return akitClick(x, y)", arguments: ["x": x, "y": y], contentWorld: .page)
            print("map click: \(Int(x)),\(Int(y)) on \(target as? String ?? "nothing")")
        }

        /// Runs a bridge function and returns its result (`akitSerialize`, `akitDiagnostics`).
        func call(_ function: String) async throws -> Any? {
            try await webView?.callAsyncJavaScript("return await \(function)()", contentWorld: .page)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.targetFrame?.isMainFrame == true, action.request.url == MapCanvasView.pageURL {
                return .allow
            }
            cancelledNavigations += 1
            // A web link the user clicked opens in the default browser, never in the canvas.
            if action.navigationType == .linkActivated, let url = action.request.url,
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }
}

/// One message from the map page.
struct MapCanvasMessage: @unchecked Sendable {
    var type: String
    var body: [String: Any]
}

/// Serves `akit-web://app/<path>` from one folder: no `..`, no absolute paths, nothing outside it.
@MainActor
final class MapWebFiles: NSObject, WKURLSchemeHandler {
    let root: URL
    let contentSecurityPolicy: String
    /// Requests that were refused (outside the folder, missing, or not `akit-web://app/`).
    private(set) var refused = 0
    /// Every path that was served, in order.
    private(set) var served: [String] = []

    init(root: URL, contentSecurityPolicy: String) {
        self.root = root.standardizedFileURL
        self.contentSecurityPolicy = contentSecurityPolicy
    }

    static let mimeTypes = [
        "html": "text/html", "js": "text/javascript", "css": "text/css", "json": "application/json",
        "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "svg": "image/svg+xml",
        "png": "image/png", "txt": "text/plain",
    ]

    /// The file for a request URL, or nil when it must be refused.
    func file(for url: URL) -> URL? {
        guard url.scheme == MapCanvasView.scheme, url.host() == "app" else { return nil }
        let path = url.path(percentEncoded: false)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\\") })
        else { return nil }
        let file = parts.reduce(root) { $0.appending(path: String($1)) }.standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), Self.mimeTypes[file.pathExtension.lowercased()] != nil,
              FileManager.default.isReadableFile(atPath: file.path)
        else { return nil }
        return file
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = file(for: url), let data = try? Data(contentsOf: file) else {
            refused += 1
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        served.append(file.path.dropFirst(root.path.count + 1).description)
        let mime = Self.mimeTypes[file.pathExtension.lowercased()]!
        let headers = [
            "Content-Type": mime.hasPrefix("text/") ? "\(mime); charset=utf-8" : mime,
            "Content-Length": String(data.count),
            "Content-Security-Policy": contentSecurityPolicy,
            "Cache-Control": "no-store",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
