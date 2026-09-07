import SwiftUI
import WebKit
import ReviewBarKit

/// Renders one side of a card with the note type's CSS. Non-persistent data
/// store, JS enabled (card templates rely on it). The only native bridge is a
/// one-way height report (`cardHeight` message) so the popover can size
/// itself to the card. Media is served through `MediaSchemeHandler` from
/// Anki's collection.media directory.
struct CardWebView: NSViewRepresentable {
    let cardHTML: String
    let css: String
    let mediaDir: String?
    /// Which appearance the card document renders under. The web view's
    /// `NSAppearance` is what `prefers-color-scheme` follows inside WebKit,
    /// so overriding it here is what lets a card be light on the dark panel;
    /// the injected night-mode script mirrors it into Anki's body classes.
    var appearance: CardAppearance = .dark
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// Reports the card's content height whenever it changes — including
    /// after async rendering by note-type scripts and image loads.
    private static let heightReportScript = """
    (function () {
      let last = 0;
      const post = () => {
        const h = Math.ceil(document.body.scrollHeight);
        if (h > 0 && h !== last) {
          last = h;
          window.webkit.messageHandlers.cardHeight.postMessage(h);
        }
      };
      new ResizeObserver(post).observe(document.body);
      window.addEventListener("load", post);
      post();
    })();
    """

    func makeNSView(context: Context) -> CardWebContainer {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Card scripts start audio programmatically (autoplay, replay buttons).
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(
            MediaSchemeHandler(mediaDir: mediaDir), forURLScheme: AnkiMedia.scheme)
        config.userContentController.addUserScript(WKUserScript(
            source: Self.heightReportScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(
            WeakMessageHandler(context.coordinator), name: "cardHeight")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        let container = CardWebContainer(webView: webView)
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: CardWebContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.onHeightChange = onHeightChange
        coordinator.apply(appearance, to: container.webView)
        let document = AnkiMedia.documentHTML(cardHTML: cardHTML, css: css)
        guard document != coordinator.loadedDocument else { return }
        let isFirstLoad = coordinator.loadedDocument == nil
        coordinator.loadedDocument = document

        if isFirstLoad {
            container.webView.loadHTMLString(document, baseURL: AnkiMedia.baseURL)
            return
        }
        // Reloading navigates the web view, which flashes its backing color
        // for a few frames between documents. Freeze the current rendering
        // on top until the new page has painted (dropped in didFinish).
        container.webView.takeSnapshot(with: nil) { [weak container] image, _ in
            guard let container else { return }
            if let image {
                container.snapshotView.image = image
                container.snapshotView.isHidden = false
            }
            // Always load the newest document — a later update may have
            // arrived while the snapshot was being taken.
            if let latest = coordinator.loadedDocument {
                container.webView.loadHTMLString(latest, baseURL: AnkiMedia.baseURL)
            }
        }
    }

    static func dismantleNSView(_ container: CardWebContainer, coordinator: Coordinator) {
        container.webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "cardHeight")
    }

    func makeCoordinator() -> Coordinator { Coordinator(onHeightChange: onHeightChange) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedDocument: String?
        var onHeightChange: (CGFloat) -> Void
        weak var container: CardWebContainer?
        /// Live only under `.system`: the panel forces `darkAqua`, so the web
        /// view can't inherit the OS appearance and has to be told about
        /// changes explicitly.
        private var systemAppearanceObservation: NSKeyValueObservation?

        init(onHeightChange: @escaping (CGFloat) -> Void) {
            self.onHeightChange = onHeightChange
        }

        /// The panel is pinned to `darkAqua` (see `ReviewPanelController`), so
        /// `.dark` is the inherited default and the other two override it on
        /// the web view alone — the panel chrome never changes.
        func apply(_ appearance: CardAppearance, to webView: WKWebView) {
            switch appearance {
            case .dark:
                systemAppearanceObservation = nil
                webView.appearance = nil
            case .light:
                systemAppearanceObservation = nil
                webView.appearance = NSAppearance(named: .aqua)
            case .system:
                webView.appearance = NSApp.effectiveAppearance
                guard systemAppearanceObservation == nil else { return }
                // KVO on NSApp delivers on the main thread; say so to the
                // compiler rather than hopping through a Task.
                systemAppearanceObservation = NSApp.observe(\.effectiveAppearance) {
                    [weak webView] app, _ in
                    MainActor.assumeIsolated {
                        webView?.appearance = app.effectiveAppearance
                    }
                }
            }
        }

        /// The new document has rendered; give it a frame to paint, then
        /// drop the freeze-frame of the previous card side.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.container?.snapshotView.isHidden = true
                self?.container?.snapshotView.image = nil
            }
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "cardHeight",
                  let height = message.body as? NSNumber else { return }
            onHeightChange(CGFloat(truncating: height))
        }

        /// Only the card document itself may load; external links open in
        /// the browser instead of navigating the popover.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async
            -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if url.scheme == AnkiMedia.scheme || url.absoluteString == "about:blank" {
                return .allow
            }
            if navigationAction.navigationType == .linkActivated,
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }
}

/// The web view plus a freeze-frame image layered on top of it, shown only
/// while a new card document is loading so navigation never flashes through.
final class CardWebContainer: NSView {
    let webView: WKWebView
    let snapshotView = NSImageView()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        snapshotView.translatesAutoresizingMaskIntoConstraints = false
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.isHidden = true
        addSubview(webView)
        addSubview(snapshotView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            snapshotView.topAnchor.constraint(equalTo: topAnchor),
            snapshotView.bottomAnchor.constraint(equalTo: bottomAnchor),
            snapshotView.leadingAnchor.constraint(equalTo: leadingAnchor),
            snapshotView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// WKUserContentController retains its message handlers; this proxy keeps the
/// coordinator out of that retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Serves `anki-media://collection/<name>` from the local collection.media
/// directory (same-machine assumption; base64 `retrieveMediaFile` fallback is
/// a documented follow-up for sandboxed builds).
///
/// Responses carry full HTTP semantics (status, Content-Type, Range/206) —
/// card scripts read these via fetch/XHR, and a status-less response reads
/// as "HTTP 0", i.e. a network failure.
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    private let mediaDir: String?

    init(mediaDir: String?) {
        self.mediaDir = mediaDir
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        guard let mediaDir,
              let fileURL = AnkiMedia.fileURL(for: url, mediaDir: mediaDir),
              let data = try? Data(contentsOf: fileURL) else {
            respond(task, url: url, status: 404,
                    headers: ["Content-Length": "0"], body: Data())
            return
        }

        var headers = [
            "Content-Type": AnkiMedia.mimeType(for: fileURL),
            "Accept-Ranges": "bytes",
            "Access-Control-Allow-Origin": "*",
        ]
        if let rangeHeader = task.request.value(forHTTPHeaderField: "Range"),
           let range = AnkiMedia.byteRange(fromHeader: rangeHeader, size: data.count) {
            headers["Content-Range"] =
                "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            headers["Content-Length"] = "\(range.count)"
            respond(task, url: url, status: 206, headers: headers,
                    body: data.subdata(in: range))
        } else {
            headers["Content-Length"] = "\(data.count)"
            respond(task, url: url, status: 200, headers: headers, body: data)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int,
                         headers: [String: String], body: Data) {
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
