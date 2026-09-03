import Foundation

/// Anki's template renderer replaces `[sound:file]` field content with
/// numbered AV markers (`[anki:play:q:0]`); in Anki's own reviewer, GUI code
/// then swaps the markers for replay-button anchors wired to native audio.
/// ReviewBar has no native audio bridge, so each marker becomes an
/// Anki-shaped replay anchor with an embedded `<audio>` element instead.
/// Card scripts that scan field content for anchors/audio (Kiku's root-card
/// path, verified live) then work unchanged, and plain note types get a
/// visible, clickable play button.
public enum AVTagRestorer {
    /// Markers are numbered per side in render order, which is string order
    /// in the rendered HTML. Each marker is resolved to a sound file from the
    /// note's fields: preferentially from the field named by an enclosing
    /// `<template data-field="…">` wrapper (how Kiku-style templates embed
    /// field content), otherwise from all fields' sounds in field order.
    public static func replaceAVMarkers(in html: String,
                                        fields: [String: CardField]) -> String {
        let nsHTML = html as NSString
        let markers = markerRegex.matches(
            in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !markers.isEmpty else { return html }

        let soundsByField = fields.mapValues { soundTags(in: $0.value) }
        let globalPool = fields
            .sorted { $0.value.order < $1.value.order }
            .flatMap { soundsByField[$0.key] ?? [] }
        let templateSpans = fieldTemplateSpans(in: html)

        var consumedByField: [String: Int] = [:]
        var consumedGlobal = 0
        var replacements: [(NSRange, String)] = []
        for marker in markers {
            var sound: String?
            if let field = templateSpans.first(where: {
                   $0.range.contains(marker.range.location)
               })?.field,
               let sounds = soundsByField[field] {
                let used = consumedByField[field, default: 0]
                if sounds.indices.contains(used) {
                    sound = sounds[used]
                    consumedByField[field] = used + 1
                }
            }
            if sound == nil, globalPool.indices.contains(consumedGlobal) {
                sound = globalPool[consumedGlobal]
            }
            consumedGlobal += 1
            if let sound {
                replacements.append((marker.range, replayElement(file: sound)))
            }
        }

        var result = nsHTML
        for (range, tag) in replacements.reversed() {
            result = result.replacingCharacters(in: range, with: tag) as NSString
        }
        return result as String
    }

    /// Anki-shaped replay button: an `<a class="replay-button">` whose click
    /// (re)starts the embedded `<audio>`. The nested audio element also
    /// serves scripts that call `.play()` on it directly.
    public static func replayElement(file: String) -> String {
        let escaped = file
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return ##"<a class="replay-button soundLink" href="#" "##
            + ##"onclick="var a=this.querySelector('audio');a.currentTime=0;a.play();return false;">"##
            + ##"<svg viewBox="0 0 24 24" width="24" height="24">"##
            + ##"<path d="M8 5v14l11-7z" fill="currentColor"/></svg>"##
            + ##"<audio src="\##(escaped)" preload="none"></audio></a>"##
    }

    /// `[sound:…]` file names in a field value, in order.
    public static func soundTags(in fieldValue: String) -> [String] {
        let ns = fieldValue as NSString
        return soundRegex
            .matches(in: fieldValue, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    private static let markerRegex = try! NSRegularExpression(
        pattern: #"\[anki:play:[qa]:\d+\]"#)
    private static let soundRegex = try! NSRegularExpression(
        pattern: #"\[sound:([^\]]+)\]"#)
    private static let templateRegex = try! NSRegularExpression(
        pattern: #"<template[^>]*\bdata-field="([^"]*)"[^>]*>([\s\S]*?)</template>"#)

    private static func fieldTemplateSpans(in html: String)
        -> [(field: String, range: NSRange)] {
        let ns = html as NSString
        return templateRegex
            .matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { (ns.substring(with: $0.range(at: 1)), $0.range) }
    }
}

private extension NSRange {
    func contains(_ location: Int) -> Bool {
        location >= self.location && location < self.location + length
    }
}
