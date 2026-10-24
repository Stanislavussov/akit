import AppKit
import SwiftUI
import WebKit

/// A knowledge map: the vendored Excalidraw canvas (`web/excalidraw`, bundled as the app's
/// `excalidraw` folder) in a web view that can load nothing but that folder. Pages come from the
/// `akit-web:` scheme handler with a strict Content-Security-Policy, a content rule list blocks
/// every http(s) load, and other navigations are cancelled. The page talks to AKit through the
/// `kb` message handler (`web/excalidraw/bridge.js` describes the messages).
struct MapCanvasView: NSViewRepresentable {
    /// The `.excalidraw` text to show once the canvas is ready.
    var scene: String
    /// Every message from the page (`type`: ready, sceneLoaded, linkOpen, problem).
    var onMessage: (MapCanvasMessage) -> Void = { _ in }

    /// The page's policy, sent as a header with every response; the smallest one that works
    /// (spike 2.0, `docs/design/knowledge.md`). Excalidraw injects its CSS as `<style>` tags
    /// (`'unsafe-inline'` for styles) and draws its cursors and icons from `data:` images.
    /// Scripts are files only. Its workers serve only image import, which is off, so none
    /// is allowed (`default-src` also covers `worker-src`, `connect-src` and `font-src`).
    static let contentSecurityPolicy = "default-src akit-web:; img-src akit-web: data:; style-src akit-web: 'unsafe-inline'"

    static let scheme = "akit-web"
    static let pageURL = URL(string: "\(scheme)://app/index.html")!

    func makeCoordinator() -> Coordinator { Coordinator(scene: scene, onMessage: onMessage) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.files, forURLScheme: Self.scheme)
        configuration.userContentController.add(context.coordinator, name: "kb")
        // Nothing is kept between runs: no cookies, caches or storage on disk.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.start()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kb")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let files = MapWebFiles(root: Bundle.main.resourceURL!.appending(path: "excalidraw"),
                                contentSecurityPolicy: MapCanvasView.contentSecurityPolicy)
        var scene: String
        var onMessage: (MapCanvasMessage) -> Void
        weak var webView: WKWebView?
        /// Navigations the delegate cancelled (anything but the map page itself).
        private(set) var cancelledNavigations = 0

        init(scene: String, onMessage: @escaping (MapCanvasMessage) -> Void) {
            self.scene = scene
            self.onMessage = onMessage
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
            if DebugSnapshot.options != nil { print("map: \(type) \(Self.json(body))") }
            if type == "ready" { Task { await loadScene() } }
            if type == "sceneLoaded", DebugSnapshot.options != nil { Task { await printDiagnostics() } }
        }

        /// Snapshots: what the page loaded and what was refused, as text (no image needed).
        /// WebKit lists no resource timing for a custom scheme, so the served paths come from
        /// the scheme handler.
        func printDiagnostics() async {
            let result = (try? await call("akitDiagnostics")) as? [String: Any] ?? [:]
            for name in result["resources"] as? [String] ?? [] { print("map resource: \(name)") }
            for font in result["fonts"] as? [String] ?? [] { print("map font: \(font)") }
            for problem in result["problems"] as? [String] ?? [] { print("map problem: \(problem)") }
            for path in files.served { print("map served: \(path)") }
            print("map refused loads: \(files.refused), cancelled navigations: \(cancelledNavigations)")
        }

        static func json(_ value: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
        }

        func loadScene() async {
            guard let webView else { return }
            do {
                _ = try await webView.callAsyncJavaScript("return akitLoadScene(json)", arguments: ["json": scene], contentWorld: .page)
            } catch {
                onMessage(MapCanvasMessage(type: "problem", body: ["message": "akitLoadScene: \(error.localizedDescription)"]))
            }
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
