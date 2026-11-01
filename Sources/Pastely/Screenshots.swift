import AppKit
import SwiftUI

/// Dev-only marketing screenshots: renders each screen offscreen at 2x and 3x with demo data.
/// Trigger with `open "pastely-dev://screenshots"`. Output: ~/Desktop/Pastely Screenshots/.
@MainActor
enum Screenshots {
    /// While rendering, views swap translucent materials for solid fills (materials need a live window).
    nonisolated(unsafe) static var isRendering = false

    static func render() async {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Pastely Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        isRendering = true
        defer { isRendering = false }

        let store = DemoData.makeStore()
        let model = HistoryViewModel(store: store)
        model.reset()
        model.query = ""

        let searching = HistoryViewModel(store: store)
        searching.reset()
        searching.query = "invoice"
        searching.selection = searching.results.first?.id

        let shots: [(String, AnyView, CGSize)] = [
            ("history-panel", AnyView(HistoryView(model: model)), HistoryPanel.size),
            ("history-search", AnyView(HistoryView(model: searching)), HistoryPanel.size),
            ("welcome", AnyView(WelcomeView(onDone: {})), CGSize(width: 520, height: 600)),
            // Tab chrome only draws inside a real Settings window, so each pane is rendered on its own.
            ("settings-general", AnyView(GeneralSettings()), CGSize(width: 560, height: 400)),
            ("settings-history", AnyView(HistorySettings()), CGSize(width: 560, height: 400)),
            ("settings-privacy", AnyView(PrivacySettings()), CGSize(width: 560, height: 400)),
            ("menu", AnyView(MenuMockup(store: store)), CGSize(width: 320, height: 372)),
        ]
        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let themeDir = dir.appendingPathComponent(theme, isDirectory: true)
            try? FileManager.default.createDirectory(at: themeDir, withIntermediateDirectories: true)
            for scale in [2.0, 3.0] {
                for (name, view, size) in shots {
                    let image = await snapshot(view, size: size, scale: scale, appearance: appearance)
                    try? image?.write(to: themeDir.appendingPathComponent("\(name)@\(Int(scale))x.png"))
                }
            }
        }
        NSWorkspace.shared.open(dir)
    }

    private static func snapshot(_ view: AnyView, size: CGSize, scale: CGFloat, appearance: NSAppearance.Name) async -> Data? {
        let host = NSHostingView(rootView: view.tint(Theme.accent))
        host.frame = NSRect(origin: .zero, size: size)
        // A real (hidden) window gives SwiftUI an environment, appearance and run loop to lay out in.
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(700)) // let async previews and images land

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// A static rendition of the menu bar menu, since NSMenu cannot be drawn offscreen.
struct MenuMockup: View {
    let store: ClipStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(store.items.prefix(8))) { item in
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: item.kind.symbol).frame(width: 16).foregroundStyle(.secondary)
                    Text(item.menuTitle).lineLimit(1)
                }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 3)
            }
            Divider().padding(.vertical, 4)
            row("Open History", trailing: "⇧⌘V")
            row("Pause Capture")
            Divider().padding(.vertical, 4)
            row("Check for Updates…")
            row("Settings…", trailing: "⌘,")
            row("Quit Pastely", trailing: "⌘Q")
        }
        .font(.system(size: 13))
        .padding(.vertical, 6)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func row(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, 3)
    }
}

/// Realistic, non-personal content for screenshots.
@MainActor
enum DemoData {
    static func makeStore() -> ClipStore {
        let store = try! ClipStore(path: ":memory:")
        let now = Date()
        func add(_ text: String, kind: ClipKind = .text, app: String, minutesAgo: Double, payload: Data? = nil,
                 thumb: Data? = nil, ocr: String? = nil, pinned: Bool = false, label: String? = nil) {
            let payload = payload ?? Data(text.utf8)
            let item = ClipItem(id: 0, createdAt: now.addingTimeInterval(-minutesAgo * 60), kind: kind,
                                uti: "public.utf8-plain-text", preview: String(text.prefix(200)), thumb: thumb, ocrText: ocr,
                                byteSize: payload.count, contentHash: PasteboardWatcher.contentHash(kind: kind, payload: payload),
                                sourceApp: app, pinned: false)
            guard let (id, _) = try? store.insert(item, payload: payload) else { return }
            if let ocr { try? store.setOCRText(ocr, for: id) }
            if pinned, let row = store.items.first(where: { $0.id == id }) { try? store.setLabel(label, for: row, pin: true) }
        }
        let invoice = invoiceImage(size: 720)
        add("Image 1280×800", kind: .image, app: "com.apple.Safari", minutesAgo: 2, payload: invoice,
            thumb: invoiceImage(size: 144), ocr: "INVOICE #4521\nAcme Studio\nDue Friday, Oct 24\nTotal: $1,250.00")
        add("Let's ship the clipboard manager this week and write the landing page after.", app: "com.apple.MobileSMS", minutesAgo: 6)
        add("func debounce<T>(_ delay: Duration, _ work: @escaping (T) -> Void) -> (T) -> Void {\n    var task: Task<Void, Never>?\n    return { value in\n        task?.cancel()\n        task = Task { try? await Task.sleep(for: delay); work(value) }\n    }\n}", app: "com.apple.dt.Xcode", minutesAgo: 14)
        add("https://github.com/amenophis1er/pastely", app: "com.google.Chrome", minutesAgo: 31, pinned: true, label: "Pastely repo")
        add("/Users/you/Documents/Q4 Roadmap.pdf\n/Users/you/Documents/Budget 2026.numbers", kind: .file, app: "com.apple.finder", minutesAgo: 48)
        add("Meeting moved to 3:30. Same room.", app: "com.tinyspeck.slackmacgap", minutesAgo: 70)
        add("brew install --cask pastely", app: "com.googlecode.iterm2", minutesAgo: 125)
        add("Everything you copy, one keystroke away.", app: "com.apple.Notes", minutesAgo: 190)
        return store
    }

    /// Draws a small fake invoice so the image row and preview have something to show.
    static func invoiceImage(size: CGFloat) -> Data? {
        let w = size * 1.6, h = size
        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            let ink = NSColor(calibratedWhite: 0.15, alpha: 1)
            ("INVOICE #4521" as NSString).draw(at: NSPoint(x: 10, y: h - 24), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: ink])
            let lines = ["Acme Studio", "Due Friday, Oct 24", "Total: $1,250.00"]
            for (i, l) in lines.enumerated() {
                (l as NSString).draw(at: NSPoint(x: 10, y: h - 44 - CGFloat(i) * 16), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ink])
            }
            NSColor(calibratedRed: 0.33, green: 0.39, blue: 0.96, alpha: 1).setFill()
            NSRect(x: 10, y: 10, width: w - 20, height: 6).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
