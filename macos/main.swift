// MiniSheet — native macOS shell around the MiniSheet web page (index.html).
// One window holds several spreadsheets, each in its own compact tab drawn in the title bar.
// Build with ./build.sh — it compiles this file and assembles ~/Applications/MiniSheet.app.

import Cocoa
import WebKit
import UniformTypeIdentifiers

let webDir = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
let pageURL = webDir.appendingPathComponent("index.html")
let openTypes: [UTType] = ["csv", "tsv", "txt", "xlsx", "xlsm", "xls", "ods"].compactMap { UTType(filenameExtension: $0) }
let updateRepo = "aibyos/minisheet"
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

/// User settings (MiniSheet → Settings…), stored in the app's UserDefaults.
enum Pref {
    private static var d: UserDefaults { .standard }
    static var theme: String {                         // "", "light" or "dark"  ("" = follow macOS)
        get { d.string(forKey: "theme") ?? "" }
        set { d.set(newValue, forKey: "theme") }
    }
    static var autoUpdate: Bool {
        get { d.object(forKey: "autoUpdate") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoUpdate") }
    }
    static var openIn: String {                        // "tab" or "window"
        get { d.string(forKey: "openIn") ?? "tab" }
        set { d.set(newValue, forKey: "openIn") }
    }
    static var zoom: Double {
        get { let z = d.double(forKey: "zoom"); return z > 0 ? z : 1 }
        set { d.set(newValue, forKey: "zoom") }
    }
    static var freezeOnOpen: Bool {
        get { d.bool(forKey: "freezeOnOpen") }
        set { d.set(newValue, forKey: "freezeOnOpen") }
    }
    static var lastUpdateCheck: Date? {
        get { d.object(forKey: "lastUpdateCheck") as? Date }
        set { d.set(newValue, forKey: "lastUpdateCheck") }
    }
    static var skippedVersion: String? {
        get { d.string(forKey: "skippedVersion") }
        set { d.set(newValue, forKey: "skippedVersion") }
    }
    /// What the page needs to know, injected before it boots.
    static var pageScript: String {
        "try{localStorage.setItem('minisheet.theme', \(jsString(theme)))}catch(e){}; window.__msPrefs = {freezeOnOpen: \(freezeOnOpen)};"
    }
}

/// A Swift string as a JavaScript string literal.
func jsString(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s])
    let arr = String(data: data, encoding: .utf8)!
    return String(arr.dropFirst().dropLast())
}
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
}
// matches the page's --chrome colour so the tab bar and the sheet header read as one surface
let chromeBG     = dynamic(rgb(0xF9FBFD), rgb(0x202124))
let tabSelBG     = dynamic(.white, rgb(0x34353A))
let tabSelBorder = dynamic(rgb(0xDADCE0), rgb(0x46474C))
let tabHoverBG   = dynamic(NSColor.black.withAlphaComponent(0.05), NSColor.white.withAlphaComponent(0.07))
let excelGreen   = dynamic(rgb(0x188038), rgb(0x81C995))

// MARK: - One spreadsheet (one tab)

final class SheetTab: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    let web: WKWebView
    weak var owner: MainWindowController?
    private var loaded = false
    private var pending: [String] = []
    var filePath: String?
    var fileName = ""                       // e.g. "Q3 pipeline.xlsx"; empty for an unsaved sheet
    var title = "Untitled spreadsheet"
    var edited = false
    var isBlank = true
    var onTitle: (([String: Any]) -> Void)?
    var displayName: String { fileName.isEmpty ? title : fileName }
    var window: NSWindow? { owner?.window }

    override init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: Pref.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        web = WKWebView(frame: .zero, configuration: cfg)
        web.pageZoom = Pref.zoom
        if #available(macOS 13.3, *) { web.isInspectable = true }
        super.init()
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: "ms")
        web.navigationDelegate = self
        web.uiDelegate = self
        web.autoresizingMask = [.width, .height]
        web.loadFileURL(pageURL, allowingReadAccessTo: webDir)
    }

    func teardown() { web.configuration.userContentController.removeAllScriptMessageHandlers() }

    /// Run JavaScript now, or once the page has finished loading.
    func run(_ js: String) {
        if loaded { web.evaluateJavaScript(js, completionHandler: nil) } else { pending.append(js) }
    }

    func openFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            let a = NSAlert(); a.messageText = "Could not open “\(url.lastPathComponent)”."
            a.informativeText = "MiniSheet doesn't have permission to read it, or it no longer exists."
            a.runModal(); return
        }
        filePath = url.path
        fileName = url.lastPathComponent
        title = url.deletingPathExtension().lastPathComponent
        isBlank = false
        owner?.tabChanged(self)
        run("msNative.open(\(jsString(url.lastPathComponent)), \"\(data.base64EncodedString())\", \(jsString(url.path)))")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    // MARK: page → app messages
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let d = message.body as? [String: Any], let cmd = d["cmd"] as? String, let win = window else {
            replyHandler(nil, "bad message"); return
        }
        switch cmd {
        case "title":
            title = (d["title"] as? String) ?? "Untitled spreadsheet"
            fileName = (d["file"] as? String) ?? ""
            edited = (d["edited"] as? Bool) ?? false
            isBlank = (d["blank"] as? Bool) ?? false
            if let p = d["path"] as? String, !p.isEmpty { filePath = p }
            owner?.tabChanged(self)
            onTitle?(d)
            replyHandler(true, nil)

        case "open":
            let blank = (d["blank"] as? Bool) ?? false
            let panel = NSOpenPanel()
            panel.allowedContentTypes = openTypes
            panel.allowsMultipleSelection = true
            panel.beginSheetModal(for: win) { resp in
                guard resp == .OK else { replyHandler(false, nil); return }
                var urls = panel.urls
                if blank, let first = urls.first { self.openFile(first); urls.removeFirst() }
                for u in urls { AppDelegate.shared.openURL(u) }
                replyHandler(true, nil)
            }

        case "save":
            guard let path = d["path"] as? String, let b64 = d["b64"] as? String, let data = Data(base64Encoded: b64) else {
                replyHandler("Nothing to save.", nil); return
            }
            do { try data.write(to: URL(fileURLWithPath: path), options: .atomic); replyHandler(true, nil) }
            catch { replyHandler(error.localizedDescription, nil) }

        case "saveAs":
            guard let b64 = d["b64"] as? String, let data = Data(base64Encoded: b64) else { replyHandler(nil, nil); return }
            owner?.selectTab(self)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (d["name"] as? String) ?? "Untitled.xlsx"
            if let ext = d["ext"] as? String, let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
            if let fp = filePath { panel.directoryURL = URL(fileURLWithPath: fp).deletingLastPathComponent() }
            panel.beginSheetModal(for: win) { resp in
                guard resp == .OK, let url = panel.url else { replyHandler(nil, nil); return }
                do {
                    try data.write(to: url, options: .atomic)
                    self.filePath = url.path
                    replyHandler(["path": url.path, "name": url.lastPathComponent], nil)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: win)
                    replyHandler(nil, nil)
                }
            }

        case "newTab":
            AppDelegate.shared.newTab(nil); replyHandler(true, nil)

        case "appearance":
            AppDelegate.shared.setTheme((d["mode"] as? String) ?? "auto", from: self)
            replyHandler(true, nil)

        default:
            replyHandler(nil, "unknown command")
        }
    }

    // MARK: web view plumbing
    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        loaded = true
        let p = pending; pending = []
        p.forEach { web.evaluateJavaScript($0, completionHandler: nil) }
        if owner?.current === self { window?.makeFirstResponder(web) }
    }
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = action.request.url {
            if u.isFileURL && u.standardizedFileURL.path.hasPrefix(webDir.standardizedFileURL.path) { decisionHandler(.allow); return }
            if ["http", "https", "mailto"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
            else if u.isFileURL { AppDelegate.shared.openURL(u) }
        }
        decisionHandler(.cancel)
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { w.reload() }

    // JavaScript alert / confirm / prompt as native sheets (the tab is brought forward first)
    private func alert(_ message: String) -> NSAlert {
        owner?.selectTab(self)
        let a = NSAlert()
        let parts = message.components(separatedBy: "\n\n")
        a.messageText = parts.first ?? message
        if parts.count > 1 { a.informativeText = parts.dropFirst().joined(separator: "\n\n") }
        return a
    }
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = alert(message); a.addButton(withTitle: "OK")
        guard let win = window else { completionHandler(); return }
        a.beginSheetModal(for: win) { _ in completionHandler() }
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = alert(message); a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        guard let win = window else { completionHandler(false); return }
        a.beginSheetModal(for: win) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = alert(prompt); a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.window.initialFirstResponder = field
        guard let win = window else { completionHandler(nil); return }
        a.beginSheetModal(for: win) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    func webView(_ w: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel(); p.allowedContentTypes = openTypes; p.allowsMultipleSelection = parameters.allowsMultipleSelection
        guard let win = window else { completionHandler(nil); return }
        p.beginSheetModal(for: win) { completionHandler($0 == .OK ? p.urls : nil) }
    }
}

// MARK: - Tab bar

func tabIcon(for name: String) -> (NSImage?, NSColor) {
    let ext = (name as NSString).pathExtension.lowercased()
    let isText = ["csv", "tsv", "txt"].contains(ext)
    let img = NSImage(systemSymbolName: isText ? "doc.text" : "tablecells", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    return (img, ["xlsx", "xlsm", "xls", "ods"].contains(ext) ? excelGreen : .secondaryLabelColor)
}

final class TabCloseButton: NSButton {
    var hover = false { didSet { needsDisplay = true; onHover?() } }
    var onHover: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func draw(_ r: NSRect) {
        if hover { tabHoverBG.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
        super.draw(r)
    }
}

final class TabItemView: NSView {
    let tab: SheetTab
    weak var strip: TabStripView?
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()
    let close = TabCloseButton()
    private(set) var selected = false
    private var hovering = false
    private var downX: CGFloat = 0, startX: CGFloat = 0, dragging = false
    private static let xmark = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
        .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
    private static let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unsaved changes")?
        .withSymbolConfiguration(.init(pointSize: 6, weight: .regular))

    override var mouseDownCanMoveWindow: Bool { false }

    init(tab: SheetTab, strip: TabStripView) {
        self.tab = tab; self.strip = strip
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        icon.imageScaling = .scaleProportionallyDown
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.setButtonType(.momentaryChange)
        close.target = self
        close.action = #selector(closeClicked)
        close.contentTintColor = .secondaryLabelColor
        close.onHover = { [weak self] in self?.updateClose() }
        [icon, label, close].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh(selected s: Bool) {
        selected = s
        label.stringValue = tab.displayName
        label.font = .systemFont(ofSize: 12, weight: s ? .medium : .regular)
        label.textColor = s ? .labelColor : .secondaryLabelColor
        let (img, color) = tabIcon(for: tab.fileName)
        icon.image = img; icon.contentTintColor = color
        updateClose(); updateTooltip()
        needsDisplay = true
    }
    func updateClose() {
        if close.hover || hovering { close.image = Self.xmark; close.isHidden = false; close.toolTip = "Close tab (⌘W)" }
        else if tab.edited { close.image = Self.dot; close.isHidden = false; close.toolTip = "Unsaved changes" }
        else { close.image = Self.xmark; close.isHidden = !selected; close.toolTip = "Close tab (⌘W)" }
    }
    /// Hovering shows the full file name only when it doesn't fit in the tab.
    func updateTooltip() {
        let needed = ceil(label.attributedStringValue.size().width) + 4
        toolTip = needed > label.frame.width ? tab.displayName : nil
    }
    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 9, y: (h - 14) / 2, width: 14, height: 14)
        close.frame = NSRect(x: bounds.width - 23, y: (h - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 28, y: (h - 16) / 2, width: max(10, bounds.width - 28 - 27), height: 16)
        updateTooltip()
    }
    override func draw(_ r: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        if selected {
            let p = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            tabSelBG.setFill(); p.fill()
            tabSelBorder.setStroke(); p.lineWidth = 1; p.stroke()
        } else if hovering {
            tabHoverBG.setFill(); NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; updateClose(); needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hovering = false; updateClose(); needsDisplay = true }

    // click to select, drag sideways to reorder, middle-click to close
    override func mouseDown(with e: NSEvent) {
        strip?.owner?.selectTab(tab)
        downX = e.locationInWindow.x; startX = frame.origin.x; dragging = false
    }
    override func mouseDragged(with e: NSEvent) {
        let dx = e.locationInWindow.x - downX
        if !dragging && abs(dx) < 4 { return }
        if !dragging { dragging = true; strip?.beginDrag(self) }
        frame.origin.x = startX + dx
        strip?.dragMoved(self)
    }
    override func mouseUp(with e: NSEvent) { if dragging { strip?.endDrag() }; dragging = false }
    override func otherMouseUp(with e: NSEvent) { if e.buttonNumber == 2 { strip?.owner?.closeTab(tab) } }

    @objc func closeClicked() { strip?.owner?.closeTab(tab) }
    @objc func closeOthers() { strip?.owner?.closeOtherTabs(than: tab) }
    @objc func reveal() { if let p = tab.filePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }
    @objc func copyPath() { if let p = tab.filePath { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p, forType: .string) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu(); m.autoenablesItems = false
        m.addItem(withTitle: "Close Tab", action: #selector(closeClicked), keyEquivalent: "").target = self
        let others = m.addItem(withTitle: "Close Other Tabs", action: #selector(closeOthers), keyEquivalent: "")
        others.target = self; others.isEnabled = (strip?.owner?.tabs.count ?? 0) > 1
        if tab.filePath != nil {
            m.addItem(.separator())
            m.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "").target = self
            m.addItem(withTitle: "Copy File Path", action: #selector(copyPath), keyEquivalent: "").target = self
        }
        return m
    }
}

final class TabStripView: NSView {
    weak var owner: MainWindowController?
    var leadingInset: CGFloat = 80 { didSet { needsLayout = true } }   // room for the red/yellow/green buttons
    private(set) var items: [TabItemView] = []
    private weak var dragging: TabItemView?
    private let plus = NSButton()
    private var itemWidth: CGFloat = 160
    private let gap: CGFloat = 4, tabH: CGFloat = 26

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        plus.isBordered = false
        plus.imagePosition = .imageOnly
        plus.contentTintColor = .secondaryLabelColor
        plus.toolTip = "New tab (⌘T)"
        plus.target = nil
        plus.action = #selector(AppDelegate.newTab(_:))
        addSubview(plus)
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        guard let o = owner else { return }
        var next: [TabItemView] = []
        for t in o.tabs {
            let v = items.first { $0.tab === t } ?? { let v = TabItemView(tab: t, strip: self); addSubview(v); return v }()
            v.refresh(selected: t === o.current)
            next.append(v)
        }
        for v in items where !next.contains(v) { v.removeFromSuperview() }
        items = next
        needsLayout = true
    }
    private func frames() -> [NSRect] {
        let avail = bounds.width - leadingInset - 44
        let n = CGFloat(max(items.count, 1))
        itemWidth = max(96, min(210, (avail - gap * (n - 1)) / n))
        let y = floor((bounds.height - tabH) / 2) + 1
        return items.indices.map { NSRect(x: leadingInset + CGFloat($0) * (itemWidth + gap), y: y, width: itemWidth, height: tabH) }
    }
    private func place(animated: Bool) {
        let fr = frames()
        for (v, f) in zip(items, fr) where v !== dragging {
            if animated { v.animator().frame = f } else { v.frame = f }
        }
        let x = (fr.last?.maxX ?? leadingInset) + 6
        plus.frame = NSRect(x: x, y: (fr.first?.minY ?? 4) + 3, width: 20, height: 20)
    }
    override func layout() { super.layout(); place(animated: false) }

    func beginDrag(_ v: TabItemView) { dragging = v; addSubview(v, positioned: .above, relativeTo: nil) }
    func dragMoved(_ v: TabItemView) {
        guard let o = owner, let from = o.tabs.firstIndex(of: v.tab) else { return }
        let slot = itemWidth + gap
        let to = max(0, min(o.tabs.count - 1, Int(((v.frame.midX - leadingInset) / slot).rounded(.down))))
        guard to != from else { return }
        o.tabs.insert(o.tabs.remove(at: from), at: to)
        items = o.tabs.compactMap { t in items.first { $0.tab === t } }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; place(animated: true) }
    }
    func endDrag() {
        dragging = nil
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; place(animated: true) }
    }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { window?.performZoom(nil) } else { super.mouseDown(with: e) }
    }
    override func draw(_ r: NSRect) { chromeBG.setFill(); r.fill() }
}

// MARK: - A window with tabs

final class MainWindowController: NSWindowController, NSWindowDelegate {
    var tabs: [SheetTab] = []
    private(set) weak var current: SheetTab?
    let strip = TabStripView()
    private let content = NSView()
    static let stripHeight: CGFloat = 34

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.tabbingMode = .disallowed
        win.backgroundColor = chromeBG
        win.minSize = NSSize(width: 640, height: 420)
        win.isReleasedWhenClosed = false
        let root = NSView()
        win.contentView = root
        for v in [content, strip] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: root.topAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: Self.stripHeight),
            content.topAnchor.constraint(equalTo: strip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        super.init(window: win)
        win.delegate = self
        strip.owner = self
    }
    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func addTab(select: Bool = true) -> SheetTab {
        let t = SheetTab(); t.owner = self
        let at = current.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.count
        tabs.insert(t, at: at)
        t.web.frame = content.bounds
        t.web.isHidden = true
        content.addSubview(t.web)
        if select { selectTab(t) } else { strip.reload() }
        return t
    }
    func selectTab(_ t: SheetTab) {
        guard tabs.contains(t) else { return }
        if current !== t {
            current?.web.isHidden = true
            current = t
            t.web.frame = content.bounds
            t.web.isHidden = false
        }
        updateWindow(); strip.reload()
        window?.makeFirstResponder(t.web)
    }
    func closeTab(_ t: SheetTab) {
        guard let i = tabs.firstIndex(of: t) else { return }
        if tabs.count == 1 { window?.close(); return }
        tabs.remove(at: i)
        t.web.removeFromSuperview(); t.teardown()
        if current === t { current = nil; selectTab(tabs[min(i, tabs.count - 1)]) } else { strip.reload() }
    }
    func closeOtherTabs(than keep: SheetTab) { for t in tabs where t !== keep { closeTab(t) } }
    func tabChanged(_ t: SheetTab) { strip.reload(); if t === current { updateWindow() } }
    private func updateWindow() {
        guard let t = current, let w = window else { return }
        w.title = t.displayName                         // used by the Window menu and Mission Control
        w.representedURL = t.filePath.map { URL(fileURLWithPath: $0) }
        w.isDocumentEdited = t.edited
    }

    // MARK: menu actions (reach here through the responder chain)
    @objc func msCmd(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        current?.run("msMenu(\(jsString(cmd)))")
    }
    @objc func closeCurrentTab(_ s: Any?) { if let t = current { closeTab(t) } }
    @objc func nextTab(_ s: Any?) { step(1) }
    @objc func previousTab(_ s: Any?) { step(-1) }
    @objc func tabNumber(_ s: NSMenuItem) {
        let n = s.tag
        if n == 9 { if let last = tabs.last { selectTab(last) } } else if n - 1 < tabs.count { selectTab(tabs[n - 1]) }
    }
    private func step(_ d: Int) {
        guard let c = current, let i = tabs.firstIndex(of: c), tabs.count > 1 else { return }
        selectTab(tabs[(i + d + tabs.count) % tabs.count])
    }
    @objc func zoomIn(_ s: Any?) { if let w = current?.web { w.pageZoom = min(2.5, w.pageZoom + 0.1) } }
    @objc func zoomOut(_ s: Any?) { if let w = current?.web { w.pageZoom = max(0.5, w.pageZoom - 0.1) } }
    @objc func zoomReset(_ s: Any?) { current?.web.pageZoom = 1 }

    // MARK: window
    func windowDidBecomeKey(_ n: Notification) { if let w = current?.web { window?.makeFirstResponder(w) } }
    func windowWillEnterFullScreen(_ n: Notification) { strip.leadingInset = 10 }
    func windowWillExitFullScreen(_ n: Notification) { strip.leadingInset = 80 }
    func windowWillClose(_ n: Notification) {
        tabs.forEach { $0.teardown() }
        AppDelegate.shared.windows.removeAll { $0 === self }
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var shared: AppDelegate!
    var windows: [MainWindowController] = []
    var allTabs: [SheetTab] { windows.flatMap { $0.tabs } }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        applyAppearance(UserDefaults.standard.string(forKey: "theme") ?? "")
        NSApp.mainMenu = buildMenu()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), args.count > i + 2 { runSelfTest(input: args[i + 1], output: args[i + 2]); return }
        if let i = args.firstIndex(of: "--tabtest"), args.count > i + 3 { runTabTest(Array(args[(i + 1)...])); return }
        if let i = args.firstIndex(of: "--settingsshot"), args.count > i + 1 { SettingsWindowController.shared.snapshot(to: args[i + 1]); exit(0) }
        if args.contains("--vercompare") {
            let shuffled = ["0.2.0", "0.1.0-alpha.10", "1.0.0-rc.1", "0.1.0-beta.1", "0.1.0", "0.1.0-alpha.2", "0.1.0-rc.1", "0.1.0-alpha.1", "0.2.0-alpha.1"]
            say("SORTED " + shuffled.sorted { Updater.compare($0, $1) < 0 }.joined(separator: " < "))
            exit(0)
        }
        if args.contains("--checkupdate") { Updater.shared.check(userInitiated: false, report: { self.say($0); exit(0) }); return }
        if args.contains("--updatetest") { Updater.shared.check(userInitiated: false, autoInstall: true, report: { self.say($0) }); return }
        DispatchQueue.main.async { if self.windows.isEmpty { self.newWindow(nil) } }
        // quiet background check, at most once a day, only when the user allows it
        if Pref.autoUpdate, Date().timeIntervalSince(Pref.lastUpdateCheck ?? .distantPast) > 20 * 3600 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Updater.shared.check(userInitiated: false) }
        }
    }
    func application(_ app: NSApplication, open urls: [URL]) { urls.forEach(openURL) }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
        if !visible { newWindow(nil) }
        return true
    }

    func applyAppearance(_ mode: String) {
        NSApp.appearance = mode == "dark" ? NSAppearance(named: .darkAqua) : mode == "light" ? NSAppearance(named: .aqua) : nil
    }
    /// Change the appearance everywhere: window chrome, every open sheet, and Settings.
    func setTheme(_ mode: String, from source: SheetTab? = nil) {
        Pref.theme = mode == "auto" ? "" : mode
        applyAppearance(mode)
        for t in allTabs where t !== source { t.run("msApplyTheme(\(jsString(mode)))") }
        SettingsWindowController.shared.refresh()
    }
    @objc func showSettings(_ s: Any?) { SettingsWindowController.shared.show() }
    @objc func checkForUpdates(_ s: Any?) { Updater.shared.check(userInitiated: true) }
    func keyWindowController() -> MainWindowController? {
        let kw = NSApp.keyWindow ?? NSApp.mainWindow
        return windows.first { $0.window === kw } ?? windows.last
    }

    /// Open a spreadsheet: switch to it if already open, reuse an empty tab, otherwise add a tab.
    func openURL(_ url: URL) {
        if let t = allTabs.first(where: { $0.filePath == url.path }), let o = t.owner {
            o.selectTab(t); o.window?.makeKeyAndOrderFront(nil); return
        }
        var w = keyWindowController() ?? newWindow(nil, blankTab: false)
        if Pref.openIn == "window", w.current?.isBlank != true { w = newWindow(nil) }   // Settings: open files in a new window
        let t = (w.current?.isBlank == true) ? w.current! : w.addTab()
        t.openFile(url)
        w.selectTab(t)
        w.window?.makeKeyAndOrderFront(nil)
    }

    @objc func newTab(_ s: Any?) {
        if let w = keyWindowController() { w.addTab(); w.window?.makeKeyAndOrderFront(nil) } else { newWindow(nil) }
    }
    @objc func newWindowAction(_ s: Any?) { newWindow(nil) }
    @discardableResult
    func newWindow(_ s: Any?, blankTab: Bool = true) -> MainWindowController {
        let w = MainWindowController()
        let win = w.window!
        if let prev = windows.last?.window {
            win.setFrame(prev.frame, display: false)
            win.setFrameTopLeftPoint(NSPoint(x: prev.frame.minX + 28, y: prev.frame.maxY - 28))
        } else {
            win.setFrameAutosaveName("MiniSheetWindow")
            if !win.setFrameUsingName("MiniSheetWindow") { win.center() }
        }
        windows.append(w)
        if blankTab { w.addTab() }
        win.makeKeyAndOrderFront(nil)
        return w
    }
    @objc func openFromMenu(_ s: Any?) {
        if let t = keyWindowController()?.current { t.run("msMenu('open')"); return }
        let p = NSOpenPanel(); p.allowedContentTypes = openTypes; p.allowsMultipleSelection = true
        if p.runModal() == .OK { p.urls.forEach(openURL) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(MainWindowController.msCmd(_:)), let cmd = item.representedObject as? String, cmd.hasPrefix("theme-") {
            let cur = UserDefaults.standard.string(forKey: "theme") ?? ""
            item.state = (cmd == "theme-" + (cur.isEmpty ? "auto" : cur)) ? .on : .off
        }
        return true
    }

    // MARK: menus
    private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = [.command], cmd: String? = nil, tag: Int = 0) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.representedObject = cmd
        it.tag = tag
        return it
    }
    private func page(_ title: String, _ cmd: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        item(title, #selector(MainWindowController.msCmd(_:)), key, mods, cmd: cmd)
    }
    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title); items.forEach(m.addItem); top.submenu = m
        return top
    }
    func buildMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(menu("MiniSheet", [
            item("About MiniSheet", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            item("Check for Updates…", #selector(checkForUpdates(_:)), ""),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ","),
            .separator(),
            item("Hide MiniSheet", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit MiniSheet", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu("File", [
            item("New Tab", #selector(newTab(_:)), "t"),
            item("New Window", #selector(newWindowAction(_:)), "n"),
            item("Open…", #selector(openFromMenu(_:)), "o"),
            .separator(),
            item("Close Tab", #selector(MainWindowController.closeCurrentTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            .separator(),
            page("Save", "save", "s"),
            page("Save As Excel…", "saveAs", "s", [.command, .shift]),
            page("Save As CSV…", "saveCsv"),
        ]))
        main.addItem(menu("Edit", [
            page("Undo", "undo", "z"),
            page("Redo", "redo", "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            page("Select All", "selectAll", "a"),
            .separator(),
            page("Find…", "find", "f"),
        ]))
        main.addItem(menu("View", [
            page("Notes & Comments", "panel", "m", [.command, .option]),
            page("Freeze First Row", "freeze"),
            .separator(),
            menu("Appearance", [page("System", "theme-auto"), page("Light", "theme-light"), page("Dark", "theme-dark")]),
            .separator(),
            item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(MainWindowController.zoomReset(_:)), "0"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        var tabNumbers: [NSMenuItem] = []
        for n in 1...9 {
            let it = item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(MainWindowController.tabNumber(_:)), "\(n)", tag: n)
            it.isHidden = true; it.allowsKeyEquivalentWhenHidden = true
            tabNumbers.append(it)
        }
        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Show Next Tab", #selector(MainWindowController.nextTab(_:)), "\t", [.control]),
            item("Show Previous Tab", #selector(MainWindowController.previousTab(_:)), "\t", [.control, .shift]),
            item("Next Tab", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift]),
            item("Previous Tab", #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift]),
        ] + tabNumbers + [
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return main
    }

    // MARK: self-tests used during development (no effect on normal launches)
    private func say(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    func runSelfTest(input: String, output: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.say("TIMEOUT"); exit(2) }
        let w = newWindow(nil)
        let t = w.current!
        t.onTitle = { d in self.say("TITLE \(d["title"] ?? "") | file=\(d["file"] ?? "") edited=\(d["edited"] ?? "")") }
        openURL(URL(fileURLWithPath: input))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            t.web.evaluateJavaScript("JSON.stringify({native:NATIVE,file:fileName,title:book.title,sheets:book.sheets.length,cells:Object.keys(S().cells).length,a2:cellText(1,0),styles:!!book.styles})") { r, e in
                self.say("STATE \(r ?? "nil") \(e.map { "\($0)" } ?? "")")
                t.web.callAsyncJavaScript("fileHandle={nativePath:p}; fileType='xlsx'; book.fmtOk=true; S().cells['30,0']={v:'saved by selftest'}; dirty=true; await save(); return JSON.stringify({dirty, fileName})",
                                          arguments: ["p": output], in: nil, in: .page) { res in
                    self.say("SAVE \(res)")
                    self.say("OUTFILE \((try? FileManager.default.attributesOfItem(atPath: output)[.size]) ?? "missing")")
                    exit(0)
                }
            }
        }
    }

    /// --tabtest <file>... <png prefix>: open files, report tabs, render the tab bar to PNGs (light + dark).
    func runTabTest(_ args: [String]) {
        let files = args.dropLast(), prefix = args.last!
        newWindow(nil)
        files.forEach { openURL(URL(fileURLWithPath: $0)) }
        openURL(URL(fileURLWithPath: files.first!))      // already open → just switches to it
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let w = self.windows.first, let win = w.window else { exit(3) }
            win.setContentSize(NSSize(width: 900, height: 500))
            w.strip.layoutSubtreeIfNeeded()
            self.say("TABS count=\(w.tabs.count) selected=\(w.current?.displayName ?? "-")")
            for v in w.strip.items {
                self.say("  tab '\(v.label.stringValue)' width=\(Int(v.frame.width)) tooltip=\(v.toolTip ?? "none") edited=\(v.tab.edited)")
            }
            for mode in ["light", "dark"] {
                win.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
                w.strip.items.forEach { $0.needsDisplay = true }
                let r = w.strip.bounds
                if let rep = w.strip.bitmapImageRepForCachingDisplay(in: r) {
                    w.strip.cacheDisplay(in: r, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(mode).png"))
                    }
                }
            }
            exit(0)
        }
    }
}

// MARK: - Settings window (MiniSheet → Settings…, ⌘,)

extension Notification.Name { static let msUpdateChecked = Notification.Name("msUpdateChecked") }

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private let appearance = NSSegmentedControl(labels: ["System", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
    private let openIn = NSPopUpButton()
    private let zoom = NSPopUpButton()
    private let freeze = NSButton(checkboxWithTitle: "Freeze the first row when opening a file", target: nil, action: nil)
    private let autoUpdate = NSButton(checkboxWithTitle: "Check for updates automatically (once a day)", target: nil, action: nil)
    private let checkNow = NSButton(title: "Check Now", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let zooms: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 280), styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Settings"
        win.isReleasedWhenClosed = false
        super.init(window: win)

        for c in [appearance, openIn, zoom, freeze, autoUpdate] as [NSControl] { c.target = self; c.action = #selector(changed(_:)) }
        checkNow.target = self; checkNow.action = #selector(checkNowClicked)
        openIn.addItems(withTitles: ["New tab", "New window"])
        zoom.addItems(withTitles: zooms.map { "\(Int(($0 * 100).rounded()))%" })
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)

        func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
        let updateRow = NSStackView(views: [checkNow, status]); updateRow.spacing = 10
        let grid = NSGridView(views: [
            [label("Appearance:"), appearance],
            [label("Open files in:"), openIn],
            [label("Default zoom:"), zoom],
            [NSGridCell.emptyContentView, freeze],
            [label("Updates:"), autoUpdate],
            [NSGridCell.emptyContentView, updateRow],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.row(at: 4).topPadding = 14
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -32),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        win.contentView = content
        win.setContentSize(content.fittingSize)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .msUpdateChecked, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func refresh() {
        appearance.selectedSegment = ["light": 1, "dark": 2][Pref.theme] ?? 0
        openIn.selectItem(at: Pref.openIn == "window" ? 1 : 0)
        zoom.selectItem(at: zooms.firstIndex { abs($0 - Pref.zoom) < 0.01 } ?? 2)
        freeze.state = Pref.freezeOnOpen ? .on : .off
        autoUpdate.state = Pref.autoUpdate ? .on : .off
        let last = Pref.lastUpdateCheck.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "never"
        status.stringValue = "Version \(appVersion) · last checked \(last)"
    }
    @objc func changed(_ sender: Any?) {
        if (sender as AnyObject) === appearance { AppDelegate.shared.setTheme(["auto", "light", "dark"][max(0, appearance.selectedSegment)]) }
        Pref.openIn = openIn.indexOfSelectedItem == 1 ? "window" : "tab"
        let z = zooms[max(0, zoom.indexOfSelectedItem)]
        if abs(z - Pref.zoom) > 0.001 { Pref.zoom = z; AppDelegate.shared.allTabs.forEach { $0.web.pageZoom = z } }
        if Pref.freezeOnOpen != (freeze.state == .on) {
            Pref.freezeOnOpen = freeze.state == .on
            AppDelegate.shared.allTabs.forEach { $0.run("window.__msPrefs = {freezeOnOpen: \(Pref.freezeOnOpen)}") }
        }
        Pref.autoUpdate = autoUpdate.state == .on
    }
    @objc func checkNowClicked() { Updater.shared.check(userInitiated: true) }
    func show() {
        refresh()
        if !window!.isVisible { window!.center() }
        window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Development aid: render the settings window to a PNG.
    func snapshot(to path: String) {
        refresh()
        let v = window!.contentView!
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Updates from GitHub Releases (github.com/aibyos/minisheet)

final class Updater: NSObject {
    static let shared = Updater()
    private var busy = false
    private var progress: NSPanel?

    /// Ask GitHub for the latest release. `report` is only used by the command-line self-tests.
    func check(userInitiated: Bool, autoInstall: Bool = false, report: ((String) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        // MiniSheet ships pre-releases (alpha/beta/rc), which GitHub's /releases/latest ignores,
        // so list recent releases and pick the highest version ourselves.
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(updateRepo)/releases?per_page=30")!, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MiniSheet/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                self.busy = false
                Pref.lastUpdateCheck = Date()
                NotificationCenter.default.post(name: .msUpdateChecked, object: nil)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let releases = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]] ?? [])
                    .filter { ($0["draft"] as? Bool) != true && $0["tag_name"] is String }
                let newest = releases.max { Self.compare(Self.version(of: $0), Self.version(of: $1)) < 0 }
                guard err == nil, code == 200, let j = newest, let tag = j["tag_name"] as? String else {
                    let why = err?.localizedDescription ?? (code == 200 || code == 404 ? "No release has been published yet." : "GitHub returned status \(code).")
                    report?("CHECK failed: \(why)")
                    if userInitiated { self.info("Couldn't check for updates", why) }
                    return
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard Self.isNewer(latest, than: appVersion) else {
                    report?("CHECK up-to-date installed=\(appVersion) latest=\(latest)")
                    if userInitiated { self.info("MiniSheet is up to date", "You have version \(appVersion), the latest release.") }
                    return
                }
                let assets = j["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                    .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
                report?("CHECK newer installed=\(appVersion) latest=\(latest) zip=\(zip?.absoluteString ?? "none")")
                if autoInstall, let zip = zip { self.install(zip, version: latest, report: report); return }
                if !userInitiated && Pref.skippedVersion == latest { return }
                self.offer(latest, notes: j["body"] as? String ?? "", zip: zip, page: (j["html_url"] as? String).flatMap(URL.init(string:)))
            }
        }.resume()
    }

    static func version(of release: [String: Any]) -> String {
        ((release["tag_name"] as? String) ?? "0").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }
    static func isNewer(_ a: String, than b: String) -> Bool { compare(a, b) > 0 }

    /// Semantic-version ordering: 0.1.0-alpha.1 < 0.1.0-alpha.2 < 0.1.0-beta.1 < 0.1.0-rc.1 < 0.1.0 < 0.2.0-alpha.1
    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> ([Int], [String]) {
            let s = v.split(separator: "+", maxSplits: 1).first.map(String.init) ?? v      // ignore build metadata
            let halves = s.split(separator: "-", maxSplits: 1).map(String.init)
            return (halves[0].split(separator: ".").map { Int($0) ?? 0 },
                    halves.count > 1 ? halves[1].split(separator: ".").map(String.init) : [])
        }
        let (ca, pa) = parts(a), (cb, pb) = parts(b)
        for i in 0..<max(ca.count, cb.count) {
            let x = i < ca.count ? ca[i] : 0, y = i < cb.count ? cb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        if pa.isEmpty || pb.isEmpty { return pa.count == pb.count ? 0 : (pa.isEmpty ? 1 : -1) }   // a final release outranks its pre-releases
        for i in 0..<max(pa.count, pb.count) {
            if i >= pa.count { return -1 }
            if i >= pb.count { return 1 }
            let x = pa[i], y = pb[i]
            switch (Int(x), Int(y)) {
            case let (xi?, yi?): if xi != yi { return xi < yi ? -1 : 1 }
            case (.some, .none): return -1
            case (.none, .some): return 1
            default: if x != y { return x < y ? -1 : 1 }
            }
        }
        return 0
    }

    private func info(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func offer(_ v: String, notes: String, zip: URL?, page: URL?) {
        let a = NSAlert()
        a.messageText = "MiniSheet \(v) is available"
        let n = notes.count > 500 ? String(notes.prefix(500)) + "…" : notes
        a.informativeText = "You have version \(appVersion)." + (n.isEmpty ? "" : "\n\n" + n)
        a.addButton(withTitle: zip != nil ? "Install and Relaunch" : "Open Download Page")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if let z = zip { install(z, version: v) } else if let p = page { NSWorkspace.shared.open(p) }
        case .alertThirdButtonReturn:
            Pref.skippedVersion = v
        default: break
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    private func install(_ url: URL, version: String, report: ((String) -> Void)? = nil) {
        showProgress("Downloading MiniSheet \(version)…")
        URLSession.shared.downloadTask(with: url) { tmp, resp, err in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("MiniSheetUpdate-\(UUID().uuidString)")
            var newApp: URL?, problem: String?
            if let tmp = tmp, (resp as? HTTPURLResponse)?.statusCode == 200 {
                do {
                    try fm.createDirectory(at: work, withIntermediateDirectories: true)
                    let zipPath = work.appendingPathComponent("update.zip")
                    try fm.moveItem(at: tmp, to: zipPath)
                    let out = work.appendingPathComponent("unpacked")
                    if Self.run("/usr/bin/ditto", ["-x", "-k", zipPath.path, out.path]) != 0 {
                        problem = "Couldn't unpack the download."
                    } else if let app = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
                              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier {
                        Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
                        newApp = app
                    } else {
                        problem = "The download didn't contain MiniSheet."
                    }
                } catch { problem = error.localizedDescription }
            } else {
                problem = err?.localizedDescription ?? "The download failed."
            }
            DispatchQueue.main.async {
                self.hideProgress()
                if let app = newApp { report?("INSTALL staged \(app.path)"); self.relaunch(into: app, report: report) }
                else if let report = report { report("INSTALL failed: \(problem ?? "")"); exit(1) }
                else { self.info("Update failed", problem ?? "Unknown error.") }
            }
        }.resume()
    }

    /// Swap the app bundle once MiniSheet has quit, then start the new version.
    private func relaunch(into newApp: URL, report: ((String) -> Void)?) {
        let dest = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            info("Almost done", "MiniSheet can't replace itself in “\(dest.deletingLastPathComponent().path)”. Drag the new MiniSheet shown in Finder into that folder to finish updating.")
            return
        }
        let script = """
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        BAK="$DEST.old-$$"
        if mv "$DEST" "$BAK"; then
          if mv "$NEW" "$DEST"; then rm -rf "$BAK"; else mv "$BAK" "$DEST"; fi
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1
        open "$DEST"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["PID": "\(ProcessInfo.processInfo.processIdentifier)", "DEST": dest.path, "NEW": newApp.path,
                         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        do { try p.run() } catch { info("Update failed", error.localizedDescription); return }
        report?("RELAUNCH scheduled")
        NSApp.terminate(nil)
    }

    private func showProgress(_ text: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Updating MiniSheet"
        let spin = NSProgressIndicator(); spin.style = .spinning; spin.controlSize = .small; spin.startAnimation(nil)
        let stack = NSStackView(views: [spin, NSTextField(labelWithString: text)])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
        panel.center(); panel.orderFront(nil)
        progress = panel
    }
    private func hideProgress() { progress?.orderOut(nil); progress = nil }
}

let app = NSApplication.shared
let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
