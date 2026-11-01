import AppKit
import SwiftUI

/// Floating, non-activating panel that hosts the SwiftUI history browser.
@MainActor
final class HistoryPanel {
    static let size = NSSize(width: 760, height: 480)

    private let panel: NSPanel
    private let model: HistoryViewModel

    var isVisible: Bool { panel.isVisible }

    init(store: ClipStore) {
        model = HistoryViewModel(store: store)
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HistoryView(model: model))

        // Launcher behaviour: clicking anywhere else dismisses the panel.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func show(onSelect: @escaping (ClipItem, Bool, Bool) -> Void) {
        model.reset()
        model.onSelect = onSelect
        panel.setFrameOrigin(Self.origin(near: FocusLocator.targetRect()))
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Clears any filter so the item is visible, then selects it.
    func select(_ id: Int64) {
        model.query = ""
        model.filter = .all
        model.labelTarget = nil
        model.selection = id
        model.scrollTarget = id
    }

    /// Below the caret or focused field when known, else centred on the mouse's screen.
    /// Always clamped inside that screen's visible frame.
    static func origin(near target: CGRect?) -> NSPoint {
        let gap: CGFloat = 12
        let anchor = target?.origin ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return .zero }

        var origin: NSPoint
        if let target {
            origin = NSPoint(x: target.minX, y: target.minY - gap - size.height)
            if origin.y < f.minY { origin.y = target.maxY + gap } // no room below: go above
        } else {
            origin = NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, f.minX), f.maxX - size.width)
        origin.y = min(max(origin.y, f.minY), f.maxY - size.height)
        return origin
    }
}

/// Borderless panels refuse key status by default; the search field needs it.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape closes the panel whatever has focus.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { orderOut(nil) } else { super.keyDown(with: event) }
    }
}

// MARK: - View model

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, text, images, files, pinned
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .images: "Images"
        case .files: "Files"
        case .pinned: "Pinned"
        }
    }

    var symbol: String? {
        switch self {
        case .all: nil
        case .text: "text.alignleft"
        case .images: "photo"
        case .files: "doc"
        case .pinned: "pin"
        }
    }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text || item.kind == .rtf
        case .images: item.kind == .image
        case .files: item.kind == .file
        case .pinned: item.pinned
        }
    }
}

@MainActor
@Observable
final class HistoryViewModel {
    let store: ClipStore
    var query = ""
    var filter: HistoryFilter = .all
    var selection: Int64?
    /// (item, plain text, force ⌃V)
    var onSelect: ((ClipItem, Bool, Bool) -> Void)?
    /// Refreshed each time the panel opens; drives the footer warning.
    var canPaste = true
    /// Row to scroll into view. Set by keyboard navigation and programmatic selection,
    /// never by a mouse click: scrolling under the cursor breaks double-click.
    var scrollTarget: Int64?

    /// The item whose label is being edited; the header swaps search for a label field.
    var labelTarget: ClipItem?
    var labelDraft = ""

    @ObservationIgnored private var lastClick: (id: Int64, at: Date)?

    init(store: ClipStore) { self.store = store }

    /// Opens the label editor for an item, or the selection. Saving also pins it.
    func editLabel(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        selection = item.id
        labelDraft = item.label ?? ""
        labelTarget = item
    }

    func saveLabel() {
        guard let item = labelTarget else { return }
        labelTarget = nil
        // The row can be pruned or deleted while the editor is open; then there is nothing to name.
        guard store.items.contains(where: { $0.id == item.id }) else { reselect(); return }
        try? store.setLabel(labelDraft, for: item, pin: true)
        invalidate()
    }

    func cancelLabel() { labelTarget = nil }

    /// Single click selects; a second click on the same row within the system
    /// double-click interval pastes. Tracked here so it does not depend on NSEvent.
    func click(_ id: Int64) {
        selection = id
        let now = Date()
        if let last = lastClick, last.id == id, now.timeIntervalSince(last.at) <= NSEvent.doubleClickInterval {
            lastClick = nil
            choose()
        } else {
            lastClick = (id, now)
        }
    }

    /// Search is memoized: the list, rows and footer all read this several times
    /// per render, and fuzzy matching 500 items each time is what made selection lag.
    var results: [ClipItem] {
        let key = ResultsKey(query: query, filter: filter, version: store.version)
        if let cache, cache.key == key { return cache.items }
        let items = store.search(query).filter(filter.matches)
        cache = (key, items)
        return items
    }

    private struct ResultsKey: Equatable {
        var query: String
        var filter: HistoryFilter
        var version: Int
    }

    @ObservationIgnored private var cache: (key: ResultsKey, items: [ClipItem])?

    func invalidate() { cache = nil }

    var selectedItem: ClipItem? {
        results.first { $0.id == selection }
    }

    func reset() {
        query = ""
        filter = .all
        labelTarget = nil
        selection = store.items.first?.id
        canPaste = Paster.isTrusted()
    }

    func move(_ delta: Int) {
        let list = results
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == selection } ?? -1
        selection = list[max(0, min(list.count - 1, idx + delta))].id
        scrollTarget = selection
    }

    func cycleFilter(_ delta: Int) {
        let all = HistoryFilter.allCases
        let idx = all.firstIndex(of: filter) ?? 0
        filter = all[(idx + delta + all.count) % all.count]
        reselect()
    }

    func reselect() {
        if selectedItem == nil { selection = results.first?.id }
        scrollTarget = selection
    }

    func choose(plain: Bool = false, control: Bool = false) {
        guard let item = selectedItem else { return }
        tipDone()
        onSelect?(item, plain, control)
    }

    func chooseIndex(_ n: Int) {
        let list = results
        guard n >= 1, n <= list.count else { return }
        tipDone()
        onSelect?(list[n - 1], false, false)
    }

    /// Any paste or copy proves the user found the panel; retire the first-use tip.
    private func tipDone() {
        if AppSettings.shared.showFirstUseTip { AppSettings.shared.showFirstUseTip = false }
    }

    /// Puts the item on the pasteboard and closes the panel so the user can ⌘V wherever they like.
    func copy(_ item: ClipItem, plain: Bool = false) {
        tipDone()
        guard AppDelegate.shared.paster.copy(item, asPlainText: plain) else { return }
        AppDelegate.shared.panel.hide()
    }

    func togglePin() {
        guard let item = selectedItem else { return }
        store.togglePin(item)
        invalidate()
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        let list = results
        let idx = list.firstIndex(of: item) ?? 0
        store.delete(item)
        invalidate()
        let next = results
        selection = next.isEmpty ? nil : next[min(idx, next.count - 1)].id
    }
}

// MARK: - Views

struct HistoryView: View {
    @Bindable var model: HistoryViewModel
    @FocusState private var searchFocused: Bool
    @FocusState private var labelFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 320)
                Divider()
                PreviewPane(item: model.selectedItem, store: model.store)
            }
            Divider()
            footer
        }
        .frame(width: HistoryPanel.size.width, height: HistoryPanel.size.height)
        .background {
            ZStack {
                // Thick material plus a near-solid base: readable over bright pages, still a hint of blur.
                if Screenshots.isRendering {
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    Rectangle().fill(.thickMaterial)
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                }
                Theme.wash
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
        .tint(Theme.accent)
        .onAppear { searchFocused = true }
        // Focus moves after the field exists: setting it in the same pass as the swap is dropped.
        .onChange(of: model.labelTarget?.id) { _, id in
            DispatchQueue.main.async { if id != nil { labelFocused = true } else { searchFocused = true } }
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Space.sm) {
            if let target = model.labelTarget {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "pin.fill").foregroundStyle(Theme.accent)
                    TextField(target.pinned ? "Label for this pin" : "Label and pin", text: $model.labelDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($labelFocused)
                        .onSubmit { model.saveLabel() }
                        .onKeyPress(.escape) { model.cancelLabel(); return .handled }
                        .onKeyPress(.tab) { .handled } // keep focus in the field; the footer says ↩ / ⎋
                }
            } else {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search clipboard history", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($searchFocused)
                        .onSubmit { model.choose() }
                        .onKeyPress(.upArrow) { model.move(-1); return .handled }
                        .onKeyPress(.downArrow) { model.move(1); return .handled }
                        .onKeyPress(.escape) { AppDelegate.shared.panel.hide(); return .handled }
                        .onKeyPress(.tab) { model.cycleFilter(1); return .handled }
                        .onKeyPress(phases: .down) { press in handle(press) }
                        .onChange(of: model.query) { _, _ in model.selection = model.results.first?.id; model.scrollTarget = model.selection }
                        .onAppear { searchFocused = true } // the field is rebuilt after the label editor closes
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: Theme.Space.xs + 2) {
                ForEach(HistoryFilter.allCases) { f in
                    FilterChip(title: f.title, symbol: f.symbol, isOn: model.filter == f) {
                        model.filter = f
                        model.reselect()
                    }
                }
                Spacer()
                if model.store.isPaused {
                    Label("Paused", systemImage: "pause.fill")
                        .font(Theme.Text.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.top, Theme.Space.lg + 6)
        .padding(.bottom, Theme.Space.md)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .return {
            model.choose(plain: press.modifiers.contains(.shift), control: press.modifiers.contains(.control))
            return .handled
        }
        guard press.modifiers.contains(.command) else { return .ignored }
        // With ⇧ held the key arrives uppercase; compare letters case-insensitively.
        switch String(press.key.character).lowercased() {
        case "p":
            if press.modifiers.contains(.shift) { model.editLabel() } else { model.togglePin() }
            return .handled
        case String(KeyEquivalent.delete.character), "\u{7f}": model.deleteSelected(); return .handled
        case "c":
            if let item = model.selectedItem { model.copy(item) }
            return .handled
        default:
            if let n = Int(String(press.key.character)), (1...9).contains(n) {
                model.chooseIndex(n)
                return .handled
            }
            return .ignored
        }
    }

    @ViewBuilder
    private var list: some View {
        let items = model.results
        if items.isEmpty {
            EmptyState(
                symbol: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                title: model.query.isEmpty ? "Nothing here yet" : "No matches",
                detail: model.query.isEmpty ? "Copy something and it will show up here." : "Try a shorter search or another filter."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            let selected = model.selection == item.id
                            HistoryRow(item: item, index: model.labelTarget == nil ? index + 1 : 0, isSelected: selected)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                                        .fill(selected ? Theme.accent.opacity(0.18) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                                        .strokeBorder(selected ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
                                )
                                .id(item.id)
                                .contentShape(Rectangle())
                                // One handler, no double-tap recognizer: a second recognizer makes
                                // SwiftUI hold every single click until the double-click interval
                                // passes. The model counts clicks itself.
                                .onTapGesture { model.click(item.id) }
                                .contextMenu {
                                    Button("Paste") { model.selection = item.id; model.choose() }
                                    if item.kind == .image {
                                        if item.ocrText != nil {
                                            Button("Paste recognized text") { model.selection = item.id; model.choose(plain: true) }
                                        }
                                        Button("Paste with ⌃V") { model.selection = item.id; model.choose(control: true) }
                                    } else {
                                        Button("Paste as plain text") { model.selection = item.id; model.choose(plain: true) }
                                    }
                                    Button("Copy") { model.copy(item) }
                                    if item.kind == .image, item.ocrText != nil {
                                        Button("Copy recognized text") { model.copy(item, plain: true) }
                                    }
                                    Divider()
                                    Button(item.pinned ? "Unpin" : "Pin") { model.store.togglePin(item); model.invalidate() }
                                    Button(item.label == nil ? (item.pinned ? "Add label…" : "Pin with label…") : "Edit label…") { model.editLabel(item) }
                                    Button("Delete", role: .destructive) { model.store.delete(item); model.invalidate() }
                                }
                        }
                    }
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, Theme.Space.xs)
                }
                .onChange(of: model.scrollTarget) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    /// The one-time tip sits above the keyboard hints, never in place of them.
    private var footer: some View {
        VStack(spacing: 0) {
            if !model.canPaste {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Pastely can't paste into other apps yet. Return will copy instead.")
                    Spacer()
                    Button("Grant Accessibility…") { Paster.requestAccessibility() }
                        .controlSize(.small)
                }
                .font(Theme.Text.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.vertical, Theme.Space.sm)
                .background(Color.orange.opacity(0.10))
                Divider()
            }
            if AppSettings.shared.showFirstUseTip {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    Text("Pastely lives in your menu bar. Press ")
                        + Text(hotkeyLabel).bold()
                        + Text(" anytime to open this.")
                    Spacer()
                    Button("Got it") { AppSettings.shared.showFirstUseTip = false }
                        .controlSize(.small)
                }
                .font(Theme.Text.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.accent.opacity(0.08))
                Divider()
            }
            hints
        }
    }

    private var hotkeyLabel: String {
        HotkeyManager.label(keyCode: AppSettings.shared.hotkeyKeyCode, modifiers: AppSettings.shared.hotkeyModifiers)
    }

    private var hints: some View {
        HStack(spacing: Theme.Space.lg) {
            if model.labelTarget != nil {
                KeyHint(keys: "↩", label: model.labelTarget?.pinned == true ? "Save" : "Save and pin")
                KeyHint(keys: "⎋", label: "Cancel")
            } else {
                KeyHint(keys: "↩", label: "Paste")
                KeyHint(keys: "⇧↩", label: model.selectedItem?.kind == .image ? "Paste text" : "Plain text")
                if model.selectedItem?.kind == .image { KeyHint(keys: "⌃↩", label: "Paste as ⌃V") }
                KeyHint(keys: "⌘C", label: "Copy")
                // One slot: pinning first, then naming the pin. Nine hints overflow 760 pt on an image row.
                if model.selectedItem?.pinned == true {
                    KeyHint(keys: "⇧⌘P", label: "Label")
                } else {
                    KeyHint(keys: "⌘P", label: "Pin")
                }
                KeyHint(keys: "⌘⌫", label: "Delete")
                KeyHint(keys: "⇥", label: "Filter")
            }
            Spacer()
            Text("\(model.results.count) of \(model.store.items.count)")
                .font(Theme.Text.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm + 2)
    }
}

struct HistoryRow: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            if let image = AssetCache.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Color.primary.opacity(0.08)))
            } else {
                KindBadge(kind: item.kind, size: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let label = item.label {
                    Text(label).font(Theme.Text.row).fontWeight(.medium).lineLimit(1)
                    Text(item.kind == .image ? item.menuTitleWithoutLabel : item.preview.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(Theme.Text.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                } else if item.kind == .image, let ocr = item.ocrText?.split(whereSeparator: \.isNewline).first {
                    Text(item.preview).font(Theme.Text.row).lineLimit(1)
                    Text(String(ocr)).font(Theme.Text.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(item.kind == .image ? item.preview : item.preview.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(Theme.Text.row)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                HStack(spacing: Theme.Space.xs) {
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                    }
                    if let name = item.sourceAppName {
                        Text(name).lineLimit(1)
                        Text("·")
                    }
                    Text(item.createdAt.shortAgo)
                }
                .font(Theme.Text.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if (1...9).contains(index) {
                Text("⌘\(index)")
                    .font(Theme.Text.hint)
                    .foregroundStyle(.tertiary)
                    .opacity(isSelected ? 1 : 0.6)
            }
        }
        .padding(.vertical, Theme.Space.xs + 2)
        .padding(.horizontal, Theme.Space.sm)
        .contentShape(Rectangle())
    }
}

struct PreviewPane: View {
    let item: ClipItem?
    let store: ClipStore

    enum Content: Equatable {
        case loading, text(String), image(NSImage), files([String]), unavailable
    }

    @State private var content: Content = .loading

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                body(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                meta(item)
            }
            .task(id: item.id) { await load(item) }
        } else {
            EmptyState(symbol: "eye", title: "No selection", detail: "Pick an item to preview it here.")
        }
    }

    /// The row highlight moves immediately; this fills in a moment later.
    private func load(_ item: ClipItem) async {
        switch item.kind {
        case .file:
            content = .files(item.preview.split(separator: "\n").map(String.init))
        case .image:
            if let cached = AssetCache.cachedImage(for: item) { content = .image(cached); return }
            content = AssetCache.thumbnail(for: item).map(Content.image) ?? .loading
            guard let payload = store.payload(for: item) else { content = .unavailable; return }
            if let image = await AssetCache.loadImage(for: item, payload: payload), !Task.isCancelled {
                content = .image(image)
            }
        case .text, .rtf:
            guard let payload = store.payload(for: item) else { content = .unavailable; return }
            // Cap what we lay out: a 2 MB paste would otherwise stall the selection.
            content = .text(String((item.text(from: payload) ?? "").prefix(20_000)))
        }
    }

    @ViewBuilder
    private func body(for item: ClipItem) -> some View {
        switch content {
        case .loading:
            ProgressView().controlSize(.small)
        case .unavailable:
            EmptyState(symbol: "exclamationmark.triangle", title: "Unavailable", detail: "This item could not be read.")
        case .image(let image):
            VStack(spacing: 0) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(Theme.Space.lg)
                if let ocr = item.ocrText {
                    Divider()
                    ScrollView {
                        Text(ocr)
                            .font(Theme.Text.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(Theme.Space.md)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        case .files(let paths):
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: Theme.Space.sm) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).font(Theme.Text.row)
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(Theme.Text.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(looksLikeCode(text) ? Theme.Text.mono : Theme.Text.body)
                    .textSelection(.enabled)
                    .padding(Theme.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func meta(_ item: ClipItem) -> some View {
        HStack(spacing: Theme.Space.md) {
            KindBadge(kind: item.kind, size: 20)
            Text(item.kind.label)
            Text("·").foregroundStyle(.tertiary)
            Text(item.sizeLabel)
            if case .text(let text) = content {
                Text("·").foregroundStyle(.tertiary)
                Text("\(text.count) chars")
            }
            Spacer()
            if let icon = item.sourceAppIcon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
        }
        .font(Theme.Text.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
    }

    private func looksLikeCode(_ s: String) -> Bool {
        let sample = s.prefix(400)
        let signals = ["{", "}", "();", "=>", "</", "#include", "import ", "func ", "def ", "const "]
        return sample.contains("\n") && signals.filter { sample.contains($0) }.count >= 2
    }
}
