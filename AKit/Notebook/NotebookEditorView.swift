import AppKit
import SwiftUI
import WebKit

/// The notebook's editor (docs/design/notebook.md, NB3): Crepe, bundled offline in the app's
/// `notebook` folder (`web/notebook`, built by tools/build-notebook-editor.sh), in a web view that
/// loads nothing but that folder and the notebook's images. As for maps, pages come from the
/// `akit-web:` scheme with a strict Content-Security-Policy, a content rule list blocks every
/// http(s) load, and other navigations are cancelled. `web/notebook/bridge.js` lists the messages.
struct NotebookEditorView: NSViewRepresentable {
    /// What the editor shows: a tab's text, the tab its saves carry, and a generation that a Reload
    /// raises, so the same text can be loaded again.
    struct Document: Equatable {
        var key: String
        var text: String
        var generation = 0
    }

    var document: Document
    /// The file of a tab's image link (`assets/…`); nil refuses it.
    var imageFile: (String) -> URL?
    /// A pasted or dropped image: its bytes and file extension → its link (`assets/…`).
    var upload: (Data, String) async throws -> String
    /// Every message from the page (`type`: ready, loaded, linkOpen, save, problem).
    var onMessage: (MapCanvasMessage) -> Void = { _ in }

    /// Crepe's Vue parts and CodeMirror set inline styles; images come from the notebook (`files/`),
    /// from a paste (`blob:`, `data:`). Scripts are the bundle's files only.
    static let contentSecurityPolicy = "default-src akit-web:; img-src akit-web: data: blob:; style-src akit-web: 'unsafe-inline'"
    static let pageURL = URL(string: "\(MapCanvasView.scheme)://app/index.html")!

    func makeCoordinator() -> Coordinator { Coordinator(document: document, imageFile: imageFile, upload: upload, onMessage: onMessage) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.files, forURLScheme: MapCanvasView.scheme)
        configuration.userContentController.add(context.coordinator, name: "nb")
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "nbUpload")
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.start()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onMessage = onMessage
        coordinator.imageFile = imageFile
        coordinator.upload = upload
        if coordinator.document != document {
            coordinator.document = document
            if coordinator.isReady { Task { await coordinator.load() } }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nb")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nbUpload", contentWorld: .page)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        lazy var files = MapWebFiles(root: Bundle.main.resourceURL!.appending(path: "notebook"),
                                     contentSecurityPolicy: NotebookEditorView.contentSecurityPolicy) { [weak self] link in
            self?.imageFile(link)
        }
        var document: Document
        var imageFile: (String) -> URL?
        var upload: (Data, String) async throws -> String
        var onMessage: (MapCanvasMessage) -> Void
        weak var webView: WKWebView?
        private(set) var cancelledNavigations = 0
        private(set) var isReady = false
        /// The tab the editor shows now (`loaded`); nil while one loads.
        private(set) var loadedKey: String?

        /// The editor on screen: the model saves and flushes through it, snapshots read it.
        private(set) static weak var current: Coordinator?

        init(document: Document, imageFile: @escaping (String) -> URL?, upload: @escaping (Data, String) async throws -> String,
             onMessage: @escaping (MapCanvasMessage) -> Void) {
            self.document = document
            self.imageFile = imageFile
            self.upload = upload
            self.onMessage = onMessage
            super.init()
            Self.current = self
        }

        func start() {
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "akit-notebook-offline", encodedContentRuleList: rules) { [weak self] list, error in
                MainActor.assumeIsolated {
                    guard let self, let webView = self.webView else { return }
                    if let list {
                        webView.configuration.userContentController.add(list)
                        webView.load(URLRequest(url: NotebookEditorView.pageURL))
                    } else {
                        self.onMessage(MapCanvasMessage(type: "problem", body: ["message": "content rules: \(error?.localizedDescription ?? "unknown")"]))
                    }
                }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if DebugSnapshot.options != nil {
                if type == "save" {
                    print("notebook: save \(body["key"] as? String ?? "?"), \((body["text"] as? String)?.utf8.count ?? 0) bytes")
                } else {
                    print("notebook: \(type) \(MapCanvasView.Coordinator.json(body))")
                }
            }
            switch type {
            case "ready":
                isReady = true
                Task { await load() }
            case "loaded":
                loadedKey = body["key"] as? String
            default: break
            }
            onMessage(MapCanvasMessage(type: type, body: body))
        }

        /// A pasted or dropped image (NB5): the bytes go to AKit, the page gets the link.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard let body = message.body as? [String: Any], let base64 = body["base64"] as? String,
                  let data = Data(base64Encoded: base64) else { return (nil, "No image.") }
            let name = body["name"] as? String ?? "", type = body["type"] as? String ?? ""
            let ext = URL(filePath: name).pathExtension.isEmpty ? Self.ext(ofType: type) : URL(filePath: name).pathExtension
            do { return (try await upload(data, ext), nil) } catch { return (nil, error.localizedDescription) }
        }

        /// A file extension for an image's MIME type (a pasted screenshot has no file name).
        static func ext(ofType type: String) -> String {
            switch type.lowercased() {
            case "image/jpeg": "jpg"
            case "image/gif": "gif"
            case "image/webp": "webp"
            case "image/heic": "heic"
            case "image/svg+xml": "svg"
            case "application/pdf": "pdf"
            default: "png"
            }
        }

        func load() async {
            guard let webView else { return }
            loadedKey = nil
            do {
                _ = try await webView.callAsyncJavaScript("await akitLoad(text, key)", arguments: ["text": document.text, "key": document.key],
                                                          contentWorld: .page)
            } catch {
                onMessage(MapCanvasMessage(type: "problem", body: ["message": "akitLoad: \(error.localizedDescription)"]))
            }
        }

        /// A change still waiting for its 800 ms post, handed over now; nil when the tab is as last
        /// posted. Throws when the page doesn't answer.
        func takeUnsaved() async throws -> (key: String, text: String)? {
            guard isReady, let webView else { return nil }
            guard let save = try await webView.callAsyncJavaScript("return akitTakeUnsaved()", contentWorld: .page) as? [String: Any],
                  let key = save["key"] as? String, let text = save["text"] as? String
            else { return nil }
            return (key, text)
        }

        /// Today (NB7): the day's heading at the top of the tab, the cursor under it. The change is
        /// saved like any other.
        func today(_ date: String) async throws {
            webView?.window?.makeFirstResponder(webView)
            _ = try await webView?.callAsyncJavaScript("return await akitToday(heading)", arguments: ["heading": date], contentWorld: .page)
        }

        /// Snapshots: waits (up to `timeout` seconds) until the tab `key` is in the editor.
        func waitForTab(_ key: String, timeout: Double = 10) async -> Bool {
            let deadline = Date.now.addingTimeInterval(timeout)
            while !(isReady && loadedKey == key), Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return isReady && loadedKey == key
        }

        /// Snapshots: what the page loaded, the tab's tasks (`x` ticked, ` ` open), images and links,
        /// as text (no image needed).
        static func waitAndPrint(timeout: Double = 10) async {
            guard let editor = current, await editor.waitForTab(editor.document.key, timeout: timeout) else {
                print("notebook: not loaded after \(Int(timeout)) s")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            let result = (try? await editor.webView?.callAsyncJavaScript("return await akitDiagnostics()", contentWorld: .page)) as? [String: Any] ?? [:]
            for problem in result["problems"] as? [String] ?? [] { print("notebook problem: \(problem)") }
            print("notebook tasks: [\(result["tasks"] as? String ?? "")]")
            for image in result["images"] as? [String] ?? [] { print("notebook image: \(image)") }
            for link in result["wikilinks"] as? [String] ?? [] { print("notebook link: \(link)") }
            for path in editor.files.served { print("notebook served: \(path)") }
            print("notebook refused loads: \(editor.files.refused), cancelled navigations: \(editor.cancelledNavigations)")
            let posts = (try? await editor.webView?.callAsyncJavaScript("return akitPosts()", contentWorld: .page)) as? NSNumber
            print("posts: \(posts?.intValue ?? -1)")
        }

        /// Snapshots (`--tab notebook-tick`): a click on the first check box, as a user's.
        func debugTick(_ index: Int) async -> Bool {
            ((try? await webView?.callAsyncJavaScript("return await akitDebugTick(index)", arguments: ["index": index], contentWorld: .page)) as? Bool) ?? false
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.targetFrame?.isMainFrame == true, action.request.url == NotebookEditorView.pageURL {
                return .allow
            }
            cancelledNavigations += 1
            return .cancel
        }
    }
}
