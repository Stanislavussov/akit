import AppKit
import SwiftUI
import WebKit

/// A Mermaid diagram drawn with mermaid.js shipped inside AKit (`Resources/Mermaid`, 11.17.2, MIT),
/// offline (R47). The page is locked down: a content policy with no script and no outside loads,
/// mermaid and AKit's code in a world of their own, mermaid's `securityLevel: "strict"` and SVG
/// text labels, a content rule list that blocks every URL but `about:` and `data:`,
/// no navigation after the first load, no windows, a data store that keeps nothing. A diagram
/// mermaid can't draw shows its error and the source; a load the policy stopped is counted.
///
/// Inline it fits the pane's width but never shrinks below `minScale` (text about 11 points):
/// a wider diagram scrolls sideways. With a `zoom` (Open Larger) it is drawn at that share of its
/// natural size, for a scroll view around it.
struct MermaidView: View {
    let source: String
    var zoom: CGFloat?
    /// Called with the diagram's natural size in points once it is drawn.
    var onDrawn: ((CGSize) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 80
    @State private var natural: CGSize = .zero
    @State private var pane: CGFloat = 0
    @State private var error: String?
    /// URLs the content policy stopped (an image or a `url(…)` in the diagram).
    @State private var blocked: [String] = []

    var body: some View {
        content
            // Another diagram: the last one's error and blocked loads go.
            .onChange(of: source) {
                error = nil
                blocked = []
            }
    }

    @ViewBuilder private var content: some View {
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
                diagram
                    .background(MermaidWebView.background(dark: colorScheme == .dark), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if !blocked.isEmpty {
                    Label("AKit blocked \(blocked.count) outside load\(blocked.count == 1 ? "" : "s") in this diagram: \(blocked.prefix(3).joined(separator: ", "))",
                          systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .onChange(of: natural) { _, size in onDrawn?(size) }
        }
    }

    /// Mermaid draws its text at 16 px: 0.7 keeps it at about 11.
    static let minScale: CGFloat = 0.7
    /// The page's padding around the diagram, both sides together.
    static let padding: CGFloat = 16

    @ViewBuilder private var diagram: some View {
        let web = MermaidWebView(source: source, dark: colorScheme == .dark, large: zoom != nil,
                                 height: $height, natural: $natural, error: $error, blocked: $blocked)
        if let zoom {
            web.frame(width: natural.width > 0 ? natural.width * zoom + Self.padding : 600, height: height)
        } else {
            // One structure whether it scrolls or not: a switch would load the page again.
            let least = natural.width > 0 ? natural.width * Self.minScale + Self.padding : 0
            let scrolls = pane > 0 && least > pane + 1
            ScrollView(.horizontal) {
                web.frame(width: pane > 0 ? max(pane, least) : nil, height: height)
            }
            .scrollDisabled(!scrolls)
            .scrollIndicators(scrolls ? .visible : .never)
            .frame(height: height + (scrolls ? 14 : 0))
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { pane = $0 }
        }
    }
}

/// Open Larger: the diagram in a sheet of 90% of the screen, with Fit, 100% and zoom buttons.
struct MermaidLargeView: View {
    let title: String
    let source: String
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var natural: CGSize = .zero
    @State private var viewport: CGSize = .zero
    @State private var fitted = false

    static let zooms: ClosedRange<CGFloat> = 0.25...4

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer()
                Button("Fit") { zoom = fit }
                    .keyboardShortcut("0")
                    .help("Show the whole diagram in the window (⌘0)")
                Button("100%") { zoom = 1 }
                    .help("The diagram at its natural size")
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { set(zoom / 1.25) }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("-")
                    .help("Zoom out (⌘−)")
                    .disabled(zoom <= Self.zooms.lowerBound)
                Text("\(Int((zoom * 100).rounded()))%").font(.callout.monospacedDigit()).frame(width: 44)
                Button("Zoom In", systemImage: "plus.magnifyingglass") { set(zoom * 1.25) }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("=")
                    .help("Zoom in (⌘=)")
                    .disabled(zoom >= Self.zooms.upperBound)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                MermaidView(source: source, zoom: zoom) { size in
                    natural = size
                    // It opens larger than inline: a small diagram fitted (up to 200%), a wide one at 100%.
                    if !fitted { fitted = true; zoom = min(max(fit, 1), 2) }
                }
                .padding(8)
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { viewport = $0 }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// 90% of the screen.
    static var size: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        return CGSize(width: (screen.width * 0.9).rounded(), height: (screen.height * 0.9).rounded())
    }

    /// The zoom that shows the whole diagram in the viewport.
    private var fit: CGFloat {
        guard natural.width > 0, natural.height > 0, viewport.width > 0 else { return 1 }
        let room = CGSize(width: viewport.width - 16 - MermaidView.padding - 4, height: viewport.height - 16 - MermaidView.padding - 4)
        return min(max(min(room.width / natural.width, room.height / natural.height), Self.zooms.lowerBound), Self.zooms.upperBound)
    }

    private func set(_ value: CGFloat) { zoom = min(max(value, Self.zooms.lowerBound), Self.zooms.upperBound) }
}

private struct MermaidWebView: NSViewRepresentable {
    let source: String
    let dark: Bool
    /// Open Larger: the diagram fills the page's width at any size, larger than natural too.
    let large: Bool
    @Binding var height: CGFloat
    /// The diagram's natural size (its view box), whatever the page's width.
    @Binding var natural: CGSize
    @Binding var error: String?
    @Binding var blocked: [String]

    /// The page's background: the same in the web view and around it.
    static func background(dark: Bool) -> Color { dark ? Color(white: 0.12) : .white }

    /// mermaid.min.js, read once.
    @MainActor private static let library: String? = Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The world mermaid and AKit's render code run in, and the only one the `akit` handler
    /// listens to. It shares the page's DOM, not its scripts: the page world runs nothing (its
    /// policy allows no script), and if something there ever ran it couldn't post to AKit.
    @MainActor static let world = WKContentWorld.world(name: "akit-mermaid")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.suppressesIncrementalRendering = true
        let content = WKUserContentController()
        if let library = Self.library {
            content.addUserScript(WKUserScript(source: library, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        }
        content.add(WeakHandler(context.coordinator), contentWorld: Self.world, name: "akit")
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
            // The rule list first: nothing loads before it is in place. The diagram is the one
            // shown when the list is ready, not the one at the start.
            Task { @MainActor [coordinator = context.coordinator] in
                guard let rules = await Self.rules() else {
                    coordinator.parent.error = "AKit couldn't set up the diagram's content rules."
                    return
                }
                content.add(rules)
                coordinator.ready = true
                let parent = coordinator.parent
                coordinator.load(source: parent.source, dark: parent.dark, large: parent.large)
            }
        }
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(source: source, dark: dark, large: large)
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
        coordinator.web?.configuration.userContentController.removeScriptMessageHandler(forName: "akit", contentWorld: world)
    }

    /// The page for one diagram: an empty box and no script. Its policy runs no script at all
    /// (inline handlers neither); mermaid and `render` run in AKit's own world, which the page's
    /// policy doesn't bind. Images and fonts only from `data:`.
    static func page(dark: Bool, large: Bool) -> String {
        let background = dark ? "#1f1f1f" : "#ffffff"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">
        <style>html,body{margin:0;padding:0;background:\(background);overflow:hidden}#d{padding:8px}#d svg{display:block;margin:0 auto;max-width:100%;height:auto}\(large ? "#d svg{max-width:none!important;width:100%}" : "")</style>
        </head><body><div id="d"></div></body></html>
        """
    }

    /// Draws the diagram, in AKit's world once the page has loaded. The source and the theme
    /// come in as arguments, never as page text. Labels are SVG text (`htmlLabels: false`), so a
    /// flowchart's labels carry no HTML; `<br/>` still breaks a line. (A sequence diagram's KaTeX
    /// `$$…$$` is still HTML: the flow check refuses `$$`.)
    static let render = """
        const post = function (m) { window.webkit.messageHandlers.akit.postMessage(m); };
        document.addEventListener("securitypolicyviolation", function (e) { post({ blocked: String(e.blockedURI || e.violatedDirective) }); });
        try {
          if (typeof mermaid === "undefined") { throw new Error("mermaid.js didn't load"); }
          mermaid.initialize({ startOnLoad: false, securityLevel: "strict", htmlLabels: false, flowchart: { htmlLabels: false },
            theme: dark ? "dark" : "default", fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif" });
          const result = await mermaid.render("akit-diagram", source);
          const d = document.getElementById("d");
          d.innerHTML = result.svg;
          const svg = d.querySelector("svg");
          const box = svg && svg.viewBox && svg.viewBox.baseVal;
          const natural = box && box.width > 0 ? [box.width, box.height] : [0, 0];
          const report = function () { post({ height: Math.ceil(d.getBoundingClientRect().height), natural: natural }); };
          new ResizeObserver(report).observe(d);
          report();
        } catch (e) {
          post({ error: String((e && e.message) || e) });
        }
        """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MermaidWebView
        weak var web: WKWebView?
        weak var container: NSView?
        private var loaded: (source: String, dark: Bool, large: Bool)?
        /// Only the page AKit loads itself is allowed; every other navigation is cancelled.
        private var allowLoad = false
        private var snapshot: NSImageView?
        /// The content rule list is in place.
        var ready = false

        init(_ parent: MermaidWebView) { self.parent = parent }

        func load(source: String, dark: Bool, large: Bool) {
            guard ready, let web, loaded.map({ $0.source != source || $0.dark != dark || $0.large != large }) ?? true else { return }
            loaded = (source, dark, large)
            snapshot?.removeFromSuperview()
            snapshot = nil
            // A new page starts with no error and no blocked loads (after this update, not in it).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if parent.error != nil { parent.error = nil }
                if !parent.blocked.isEmpty { parent.blocked = [] }
            }
            allowLoad = true
            web.loadHTMLString(MermaidWebView.page(dark: dark, large: large), baseURL: nil)
        }

        /// The page AKit loaded is in: draw the diagram in AKit's world.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let loaded else { return }
            webView.callAsyncJavaScript(MermaidWebView.render, arguments: ["source": loaded.source, "dark": loaded.dark],
                                        in: nil, in: MermaidWebView.world) { [weak self] result in
                if case .failure(let failure) = result, let self, parent.error == nil {
                    parent.error = String(failure.localizedDescription.prefix(500))
                    if DebugSnapshot.options != nil { print("mermaid: error \(failure.localizedDescription)") }
                }
            }
        }

        /// At most this many blocked loads are kept, each its first 200 characters.
        static let blockedKept = 20

        func receive(_ body: Any) {
            guard let message = body as? [String: Any] else { return }
            if let url = message["blocked"] as? String {
                let entry = String(url.prefix(200))
                if !parent.blocked.contains(entry), parent.blocked.count < Self.blockedKept { parent.blocked.append(entry) }
                // Snapshot runs print it: a check that a diagram's outside load was stopped.
                if DebugSnapshot.options != nil { print("mermaid: blocked \(url)") }
            } else if let error = message["error"] as? String {
                parent.error = String(error.prefix(500))
                if DebugSnapshot.options != nil { print("mermaid: error \(error)") }
            } else if let height = message["height"] as? Double, height > 0 {
                if let size = message["natural"] as? [Double], size.count == 2, size[0] > 0 {
                    let natural = CGSize(width: size[0], height: size[1])
                    if parent.natural != natural { parent.natural = natural }
                }
                let fitted = min(CGFloat(height), parent.large ? 40000 : 4000)
                if abs(parent.height - fitted) > 1 { parent.height = fitted }
                if DebugSnapshot.options != nil {
                    print("mermaid: drawn, \(Int(fitted)) points high, natural \(Int(parent.natural.width))×\(Int(parent.natural.height))\(parent.large ? ", large" : "")")
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

/// The diagram fits its height, so the wheel scrolls the scroll view around it, and it has no
/// context menu (Reload, Inspect Element).
private final class DiagramWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) { menu.removeAllItems() }
}
