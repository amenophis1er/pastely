import AppKit

enum ClipKind: String, Codable, Sendable {
    case text, rtf, image, file
}

/// One history row as the UI sees it: metadata, a short preview and, for images,
/// a small thumbnail. The full payload stays in the database and is loaded on demand
/// through `ClipStore.payload(for:)`.
struct ClipItem: Identifiable, Hashable, Sendable {
    var id: Int64
    var createdAt: Date
    var kind: ClipKind
    var uti: String
    var preview: String
    var thumb: Data?
    /// Text recognized inside an image, used for search and shown under the preview.
    var ocrText: String?
    var byteSize: Int
    var contentHash: String
    var sourceApp: String?
    var pinned: Bool
    /// A name the user gave the item, usually when pinning. Shown in place of the preview.
    var label: String?

    var menuTitle: String {
        label ?? menuTitleWithoutLabel
    }

    /// The content-derived title, used under a label so the row still says what the item is.
    var menuTitleWithoutLabel: String {
        switch kind {
        case .image:
            // Recognized text tells screenshots apart; size alone does not.
            if let title = Self.imageTitle(from: ocrText) { return title }
            return "\(preview) · \(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file))"
        case .file: return preview.split(separator: "\n").first.map(String.init) ?? preview
        default:
            let line = preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? preview
            let short = line.count > 60 ? String(line.prefix(60)) + "…" : line
            // AppKit turns a title of "-" into a separator; keep dashes visible as text.
            return short.hasPrefix("-") || short.isEmpty ? "\u{2009}" + short : short
        }
    }

    /// Builds a menu title from recognized text: skips fragments (short, few letters),
    /// and joins the next meaningful lines when the first one is short.
    static func imageTitle(from ocr: String?, limit: Int = 48) -> String? {
        guard let ocr else { return nil }
        let lines = ocr.split(whereSeparator: \.isNewline)
            .map { line -> String in
                // Drop leading bullets, dashes and other decoration OCR picks up.
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return String(trimmed.drop { !$0.isLetter && !$0.isNumber && $0 != "$" && $0 != "#" })
            }
            .filter { line in
                let letters = line.filter(\.isLetter).count
                let words = line.split(separator: " ").count
                return line.count >= 4 && letters >= 3 && (letters * 2 >= line.count || words >= 2)
            }
        guard !lines.isEmpty else { return nil }
        // A line with several words reads like a sentence; prefer it over a lone fragment.
        let start = lines.firstIndex { $0.split(separator: " ").count >= 2 } ?? 0
        var title = lines[start]
        for line in lines[(start + 1)...] where title.count < 20 {
            let joined = title + " · " + line
            if joined.count > limit { break }
            title = joined
        }
        return title.count > limit ? String(title.prefix(limit)) + "…" : title
    }

    /// What search matches against.
    var searchText: String {
        var text = preview
        if let label { text = label + "\n" + text }
        if let ocrText { text += "\n" + ocrText }
        return text
    }

    /// Plain text for a payload of this item's kind.
    func text(from payload: Data) -> String? {
        switch kind {
        case .text: return String(data: payload, encoding: .utf8)
        case .rtf: return NSAttributedString(rtf: payload, documentAttributes: nil)?.string
        case .file: return preview
        case .image: return nil
        }
    }
}
