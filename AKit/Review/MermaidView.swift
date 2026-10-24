import AppKit
import SwiftUI
import WebKit

/// A Mermaid diagram drawn with mermaid.js shipped inside AKit (`Resources/Mermaid`, 11.4.1, MIT),
/// offline (R47). The page is locked down: a content policy with no outside loads, mermaid's
/// `securityLevel: "strict"`, a content rule list that blocks every URL but `about:` and `data:`,
/// no navigation after the first load, no windows, a data store that keeps nothing. A diagram
/// mermaid can't draw shows its error and the source; a load the policy stopped is counted.
struct MermaidView: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 80
    @State private var error: String?
    /// URLs the content policy stopped (an image or a `url(…)` in the diagram).
    @State private var blocked: [String] = []

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 6) {
                Label("Mermaid couldn't draw it: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                ScrollView(.horizontal) {
                    Text(source).font(.caption.monospaced()).textSelection(.enabled).padding(6)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                MermaidWebView(source: source, dark: colorScheme == .dark, height: $height, error: $error, blocked: $blocked)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .background(MermaidWebView.background(dark: colorScheme == .dark), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if !blocked.isEmpty {
                    Label("AKit blocked \(blocked.count) outside load\(blocked.count == 1 ? "" : "s") in this diagram: \(blocked.prefix(3).joined(separator: ", "))",
                          systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

private struct MermaidWebView: NSViewRepresentable {
    let source: String
    let dark: Bool
    @Binding var height: CGFloat
    @Binding var error: String?
    @Binding var blocked: [String]

    /// The page's background: the same in the web view and around it.
    static func background(dark: Bool) -> Color { dark ? Color(white: 0.12) : .white }

    /// mermaid.min.js, read once. Injected as a user script: the page's own policy then needs no
    /// `script-src` for files.
    @MainActor private static let library: String? = Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.suppressesIncrementalRendering = true
        let content = WKUserContentController()
        if let library = Self.library {
            content.addUserScript(WKUserScript(source: library, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        content.add(WeakHandler(context.coordinator), name: "akit")
        configuration.userContentController = content
        let web = DiagramWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.autoresizingMask = [.width, .height]
        let container = NSView()
        web.frame = container.bounds
        container.addSubview(web)
        context.coordinator.web = web
        context.coordinator.container = container
        if Self.library == nil {
            DispatchQueue.main.async { error = "mermaid.js is missing from AKit." }
        } else {
            // The rule list first: nothing loads before it is in place.
            Task { @MainActor [coordinator = context.coordinator, source, dark] in
                guard let rules = await Self.rules() else {
                    coordinator.parent.error = "AKit couldn't set up the diagram's content rules."
                    return
                }
                content.add(rules)
                coordinator.ready = true
                coordinator.load(source: source, dark: dark)
            }
        }
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(source: source, dark: dark)
    }

    /// Blocks every URL but `about:` and `data:`: a second wall behind the page's content policy.
    @MainActor private static var compiled: WKContentRuleList?
    @MainActor private static func rules() async -> WKContentRuleList? {
        if let compiled { return compiled }
        let json = #"""
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
        """#
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "akit-mermaid", encodedContentRuleList: json)
        compiled = list
        return list
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.web?.configuration.userContentController.removeScriptMessageHandler(forName: "akit")
    }

    /// The page for one diagram. The source goes in as a JSON string with `<` escaped, never as
    /// raw text, so nothing in it can end the script.
    static func page(source: String, dark: Bool) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [source])) ?? Data("[\"\"]".utf8)
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let background = dark ? "#1f1f1f" : "#ffffff"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:">
        <style>html,body{margin:0;padding:0;background:\(background);overflow:hidden}#d{padding:8px}#d svg{display:block;margin:0 auto;max-width:100%;height:auto}</style>
        </head><body><div id="d"></div><script>
        (async function () {
          const post = function (m) { window.webkit.messageHandlers.akit.postMessage(m); };
          document.addEventListener("securitypolicyviolation", function (e) { post({ blocked: String(e.blockedURI || e.violatedDirective) }); });
          try {
            if (typeof mermaid === "undefined") { throw new Error("mermaid.js didn't load"); }
            mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: \(dark ? "\"dark\"" : "\"default\""),
              fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif" });
            const source = \(json)[0];
            const result = await mermaid.render("akit-diagram", source);
            const d = document.getElementById("d");
            d.innerHTML = result.svg;
            const report = function () { post({ height: Math.ceil(d.getBoundingClientRect().height) }); };
            new ResizeObserver(report).observe(d);
            report();
          } catch (e) {
            post({ error: String((e && e.message) || e) });
          }
        })();
        </script></body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MermaidWebView
        weak var web: WKWebView?
        weak var container: NSView?
        private var loaded: (source: String, dark: Bool)?
        /// Only the page AKit loads itself is allowed; every other navigation is cancelled.
        private var allowLoad = false
        private var snapshot: NSImageView?
        /// The content rule list is in place.
        var ready = false

        init(_ parent: MermaidWebView) { self.parent = parent }

        func load(source: String, dark: Bool) {
            guard ready, let web, loaded.map({ $0.source != source || $0.dark != dark }) ?? true else { return }
            loaded = (source, dark)
            snapshot?.removeFromSuperview()
            snapshot = nil
            allowLoad = true
            web.loadHTMLString(MermaidWebView.page(source: source, dark: dark), baseURL: nil)
        }

        func receive(_ body: Any) {
            guard let message = body as? [String: Any] else { return }
            if let url = message["blocked"] as? String {
                if !parent.blocked.contains(url) { parent.blocked.append(String(url.prefix(200))) }
                // Snapshot runs print it: a check that a diagram's outside load was stopped.
                if DebugSnapshot.options != nil { print("mermaid: blocked \(url)") }
            } else if let error = message["error"] as? String {
                parent.error = String(error.prefix(500))
                if DebugSnapshot.options != nil { print("mermaid: error \(error)") }
            } else if let height = message["height"] as? Double, height > 0 {
                let fitted = min(CGFloat(height), 4000)
                if abs(parent.height - fitted) > 1 { parent.height = fitted }
                if DebugSnapshot.options != nil {
                    print("mermaid: drawn, \(Int(fitted)) points high")
                    freeze()
                }
            }
        }

        /// Snapshots draw the window with `cacheDisplay`, which can't see a web view's content
        /// (it is drawn in another process): show a picture of it on top instead.
        private func freeze() {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard let web, let container, let image = try? await web.takeSnapshot(configuration: nil) else { return }
                snapshot?.removeFromSuperview()
                let view = NSImageView(frame: container.bounds)
                view.image = image
                view.imageScaling = .scaleProportionallyUpOrDown
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
                snapshot = view
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard allowLoad, action.targetFrame?.isMainFrame == true, action.navigationType == .other,
                  action.request.url?.absoluteString == "about:blank" else { return .cancel }
            allowLoad = false
            return .allow
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }

    /// The content controller keeps its handler: a weak link lets the coordinator go.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?
        init(_ coordinator: Coordinator) { self.coordinator = coordinator }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body
            MainActor.assumeIsolated { coordinator?.receive(body) }
        }
    }
}

/// The diagram fits its height, so the wheel scrolls the screen around it, and it has no
/// context menu (Reload, Inspect Element).
private final class DiagramWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) { menu.removeAllItems() }
}
