import Foundation
import UniformTypeIdentifiers

/// WebKit-free helpers behind the card view's media scheme handler:
/// requests like `anki-media://collection/foo.jpg` resolve to files inside
/// Anki's `collection.media` directory (from `getMediaDirPath`).
public enum AnkiMedia {
    /// The custom scheme CardWebView registers; card HTML is loaded with this
    /// as its base URL so relative `src` attributes route to the handler.
    public static let scheme = "anki-media"
    public static let baseURL = URL(string: "\(scheme)://collection/")!

    /// Resolve a media request to a file inside `mediaDir`, or nil if the
    /// request escapes it. Anki media filenames are flat (no subdirectories),
    /// so anything that isn't a plain filename is rejected.
    public static func fileURL(for requestURL: URL, mediaDir: String) -> URL? {
        let components = requestURL.path.split(separator: "/")
        guard components.count == 1, let name = components.first.map(String.init),
              name != ".", name != ".." else { return nil }
        let base = URL(fileURLWithPath: mediaDir, isDirectory: true)
        let file = base.appendingPathComponent(name).standardizedFileURL
        guard file.path.hasPrefix(base.standardizedFileURL.path + "/") else { return nil }
        return file
    }

    /// Parse an HTTP `Range` header ("bytes=0-499", "bytes=500-", "bytes=-200")
    /// against a resource size. Nil for absent/malformed/unsatisfiable ranges
    /// (callers then serve the whole file with status 200).
    public static func byteRange(fromHeader header: String, size: Int) -> Range<Int>? {
        guard size > 0, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let startText = spec[..<dash], endText = spec[spec.index(after: dash)...]
        switch (Int(startText), Int(endText)) {
        case (let start?, let end?) where start <= end && start < size:
            return start..<Swift.min(end + 1, size)
        case (let start?, nil) where endText.isEmpty && start < size:
            return start..<size
        case (nil, let suffix?) where startText.isEmpty && suffix > 0:
            return Swift.max(0, size - suffix)..<size
        default:
            return nil
        }
    }

    public static func mimeType(for fileURL: URL) -> String {
        UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    /// Wrap one side of a card in a full document matching Anki's reviewer
    /// DOM: the card HTML inside `<div id="qa">`, a direct child of
    /// `<body class="card">`. Note-type CSS routinely depends on exactly this
    /// shape (e.g. `.card:has(> #qa)`), and on Anki's `nightMode`/`night_mode`
    /// body classes for dark themes — mirrored here from the system scheme.
    public static func documentHTML(cardHTML: String, css: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root { color-scheme: light dark; } body { margin: 0; }</style>
        <style>\(css)</style>
        </head>
        <body class="card isMac"><div id="qa">\(cardHTML)</div>
        <script>
        (function () {
          const mq = matchMedia("(prefers-color-scheme: dark)");
          const apply = () => {
            document.body.classList.toggle("nightMode", mq.matches);
            document.body.classList.toggle("night_mode", mq.matches);
            document.documentElement.classList.toggle("night-mode", mq.matches);
          };
          apply();
          mq.addEventListener("change", apply);
        })();
        </script>
        </body>
        </html>
        """
    }
}
