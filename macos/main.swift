// MiniSheet — native macOS shell around the MiniSheet web page (index.html).
// One window holds several spreadsheets, each in its own compact tab drawn in the title bar.
// Build with ./build.sh — it compiles this file and assembles ~/Applications/MiniSheet.app.

import Cocoa
import WebKit
import UniformTypeIdentifiers
import Darwin

let webDir = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
let pageURL = webDir.appendingPathComponent("index.html")
let openTypes: [UTType] = ["csv", "tsv", "txt", "xlsx", "xlsm", "xls", "ods"].compactMap { UTType(filenameExtension: $0) }
let updateRepo = "aibyos/minisheet"
let debugLog = ProcessInfo.processInfo.environment["MINISHEET_DEBUG"] != nil
func dlog(_ s: String) { if debugLog { FileHandle.standardError.write(("DEBUG " + s + "\n").data(using: .utf8)!) } }
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
    /// Files opened or saved in MiniSheet, newest first: [(path, when)]. Shown in the File Browser.
    static var recents: [(path: String, opened: Date)] {
        get { (d.array(forKey: "recents") as? [[String: Any]] ?? []).compactMap { e in
            guard let p = e["path"] as? String, let t = e["opened"] as? Date else { return nil }
            return (p, t) } }
        set { d.set(newValue.prefix(300).map { ["path": $0.path, "opened": $0.opened] }, forKey: "recents") }
    }
    static func noteRecent(_ path: String) {
        var r = recents.filter { $0.path != path }
        r.insert((path, Date()), at: 0)
        recents = r
        NotificationCenter.default.post(name: .msRecentsChanged, object: nil)
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


/// Development aid: capture one of our own windows exactly as the window server composites it.
/// (CGWindowListCreateImage is hidden from Swift in the macOS 15 SDK, so it is looked up at runtime.)
func captureWindow(_ win: NSWindow, to path: String) -> Bool {
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return false }
    let fn = unsafeBitCast(sym, to: Fn.self)
    guard let img = fn(.null, 1 << 3 /* including window */, UInt32(win.windowNumber), 1 << 0 /* ignore framing */)?.takeRetainedValue() else { return false }
    let rep = NSBitmapImageRep(cgImage: img)
    return (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
}

// MARK: - One spreadsheet (one tab)

final class SheetTab: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private(set) var web: WKWebView
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
        web = Self.makeWebView()
        super.init()
        attach()
        startLoad()
    }

    private static func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: Pref.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.pageZoom = Pref.zoom
        if #available(macOS 13.3, *) { w.isInspectable = true }
        return w
    }
    private func attach() {
        web.configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "ms")
        web.navigationDelegate = self
        web.uiDelegate = self
    }

    /// Load the sheet page. If it hasn't finished within 5 s (WebKit's page process didn't come up —
    /// the blank-window bug in 0.1.0-alpha.1), the tab recovers with a fresh web view (up to 3 times in a row).
    private var loadAttempts = 0
    private func startLoad() {
        loadAttempts += 1
        loaded = false
        let attempt = loadAttempts
        web.loadFileURL(pageURL, allowingReadAccessTo: webDir)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, !self.loaded, self.loadAttempts == attempt, attempt < 4, self.owner != nil else { return }
            dlog("load watchdog fired (attempt \(attempt))")
            self.reloadAfterFailure(keepAttempts: true)
        }
    }

    func teardown() {
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }

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
        Pref.noteRecent(url.path)
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
                    Pref.noteRecent(url.path)
                    replyHandler(["path": url.path, "name": url.lastPathComponent], nil)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: win)
                    replyHandler(nil, nil)
                }
            }

        case "newTab":
            AppDelegate.shared.newTab(nil); replyHandler(true, nil)

        case "about":
            AppDelegate.shared.showAbout(nil); replyHandler(true, nil)

        case "settings":
            AppDelegate.shared.showSettings(nil); replyHandler(true, nil)

        case "browse":
            AppDelegate.shared.showFileBrowser(nil); replyHandler(true, nil)

        case "appearance":
            AppDelegate.shared.setTheme((d["mode"] as? String) ?? "auto", from: self)
            replyHandler(true, nil)

        default:
            replyHandler(nil, "unknown command")
        }
    }

    // MARK: web view plumbing
    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        dlog("didFinish")
        loaded = true
        loadAttempts = 0
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
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { dlog("processDidTerminate"); reloadAfterFailure() }
    func webView(_ w: WKWebView, didFail nav: WKNavigation!, withError e: Error) { if !loaded { reloadAfterFailure() } }
    func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) { reloadAfterFailure() }
    /// Bring a dead or stuck page back. A WKWebView whose page process died can refuse to load again, so swap in a
    /// fresh web view, then reload and reopen the tab's file (unsaved edits in a crashed page are gone anyway).
    private var lastRecovery = Date.distantPast
    private func reloadAfterFailure(keepAttempts: Bool = false) {
        dlog("reloadAfterFailure")
        guard keepAttempts || Date().timeIntervalSince(lastRecovery) > 4 else { return }      // don't thrash
        lastRecovery = Date()
        let file = filePath.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        DispatchQueue.main.async {
            let old = self.web, shown = old.superview != nil
            self.teardown()
            old.removeFromSuperview()
            self.web = Self.makeWebView()
            self.attach()
            if shown { self.owner?.showWebView(of: self) }
            self.pending.removeAll()
            if !keepAttempts { self.loadAttempts = 0 }
            self.pingOutstanding = false
            self.startLoad()
            if let url = file { self.openFile(url) }
        }
    }

    /// WebKit doesn't always report a page process that died, so the visible tab is pinged regularly
    /// (and whenever its window comes forward); no answer within 3 s means the page is dead → recover.
    private var pingOutstanding = false
    func healthCheck() {
        dlog("healthCheck loaded=\(loaded) outstanding=\(pingOutstanding)")
        guard loaded, !pingOutstanding else { return }
        pingOutstanding = true
        var answered = false
        web.evaluateJavaScript("1") { [weak self] _, err in
            dlog("ping answered err=\(err.map { "\($0)" } ?? "none")")
            answered = true
            self?.pingOutstanding = false
            if let e = err as? WKError, e.code == .webContentProcessTerminated { self?.reloadAfterFailure() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, !answered else { return }
            self.pingOutstanding = false
            self.reloadAfterFailure()
        }
    }

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
        clipsToBounds = true
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
    // Fill our own bounds, never the dirty rect: since macOS 14 the dirty rect can extend beyond a view's bounds,
    // and filling it painted over the whole window (the blank-window bug in 0.1.0-alpha.1).
    override func draw(_ r: NSRect) { chromeBG.setFill(); bounds.fill() }
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
        if select { selectTab(t) } else { strip.reload() }
        return t
    }
    /// Only the selected sheet's web view is in the window. (Toggling isHidden instead left WebKit
    /// believing the page was invisible, so it never painted — the blank-window bug in 0.1.0-alpha.1.)
    func selectTab(_ t: SheetTab) {
        guard tabs.contains(t) else { return }
        if current !== t || t.web.superview !== content {
            current?.web.removeFromSuperview()
            current = t
            showWebView(of: t)
        }
        updateWindow(); strip.reload()
        window?.makeFirstResponder(t.web)
    }
    /// Put a tab's web view into the window, filling the area under the tab bar.
    func showWebView(of t: SheetTab) {
        let w = t.web
        w.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(w)
        NSLayoutConstraint.activate([
            w.topAnchor.constraint(equalTo: content.topAnchor),
            w.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            w.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            w.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        if t === current { window?.makeFirstResponder(w) }
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
    func windowDidBecomeKey(_ n: Notification) {
        if let w = current?.web { window?.makeFirstResponder(w) }
        _ = healthTimer
        current?.healthCheck()
    }
    private lazy var healthTimer: Timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
        guard let self = self, let w = self.window, w.isVisible, w.occlusionState.contains(.visible) else { return }
        self.current?.healthCheck()
    }
    func windowDidChangeOcclusionState(_ n: Notification) { _ = healthTimer; if window?.occlusionState.contains(.visible) == true { current?.healthCheck() } }
    func windowWillEnterFullScreen(_ n: Notification) { strip.leadingInset = 10 }
    func windowWillExitFullScreen(_ n: Notification) { strip.leadingInset = 80 }
    func windowWillClose(_ n: Notification) {
        healthTimer.invalidate()
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
        if args.contains("--layoutdump") {   // development aid: report where the sheet view ends up
            NSApp.activate(ignoringOtherApps: true)
            let w = newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let web = w.current!.web
                self.say("LAYOUT occlusionVisible=\(w.window!.occlusionState.contains(.visible)) active=\(NSApp.isActive) window=\(w.window!.frame.size) content=\(web.superview?.frame ?? .zero) web=\(web.frame) hidden=\(web.isHidden) strip=\(w.strip.frame)")
                web.evaluateJavaScript("JSON.stringify({w:innerWidth,h:innerHeight,body:document.body.getBoundingClientRect().height,cells:document.querySelectorAll('#grid td').length,vis:document.visibilityState,hidden:document.hidden})") { r, e in
                    self.say("PAGE \(r ?? "nil") \(e.map { "\($0)" } ?? "")")
                    web.takeSnapshot(with: nil) { img, err in
                        if let img = img, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "/tmp/minisheet-web.png")); self.say("SNAPSHOT ok \(img.size)")
                        } else { self.say("SNAPSHOT failed \(err.map { "\($0)" } ?? "")") }
                        exit(0)
                    }
                }
            }
            return
        }
        if args.contains("--crashtest") {   // development aid: kill only this tab's own page process, expect recovery
            NSApp.activate(ignoringOtherApps: true)
            let w = newWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.say("STEP killing page process")
                w.current!.web.perform(Selector(("_killWebContentProcess")))
                self.say("STEP killed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    self.say("STEP evaluating")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.say("CRASHTEST no answer from page after 5s"); exit(1) }
                    let web = w.current!.web
                    self.say("STEP web view replaced=\(web.superview != nil) frame=\(web.frame.size)")
                    web.evaluateJavaScript("JSON.stringify({cells:document.querySelectorAll('#grid td').length,vis:document.visibilityState})") { r, e in
                        self.say("CRASHTEST page=\(r ?? "nil") \(e.map { "\($0)" } ?? "")"); exit(0)
                    }
                }
            }
            return
        }
        if let i = args.firstIndex(of: "--windowshot"), args.count > i + 1 {   // development aid
            NSApp.activate(ignoringOtherApps: true)
            let w = newWindow(nil), path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.say("WINDOWSHOT \(captureWindow(w.window!, to: path))"); exit(0) }
            return
        }
        if let i = args.firstIndex(of: "--aboutshot"), args.count > i + 1 {   // development aid: render the About panel
            NSApp.activate(ignoringOtherApps: true)
            showAbout(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let panel = NSApp.windows.first { $0.isVisible && !($0.windowController is MainWindowController) }
                self.say("ABOUTSHOT \(panel.map { captureWindow($0, to: args[i + 1]) } ?? false)"); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--browsertest"), args.count > i + 4 {   // development aid: <recent|mac> <list|tree> <filter|-> <png>
            FileBrowserWindowController.shared.selfTest(scope: args[i + 1] == "mac" ? 1 : 0, tree: args[i + 2] == "tree",
                                                        filter: args[i + 3] == "-" ? "" : args[i + 3], shot: args[i + 4]) { self.say($0); exit(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.say("BROWSER timeout"); exit(2) }
            return
        }
        if args.contains("--vercompare") {
            let shuffled = ["0.2.0", "0.1.0-alpha.10", "1.0.0-rc.1", "0.1.0-beta.1", "0.1.0", "0.1.0-alpha.2", "0.1.0-rc.1", "0.1.0-alpha.1", "0.2.0-alpha.1"]
            say("SORTED " + shuffled.sorted { Updater.compare($0, $1) < 0 }.joined(separator: " < "))
            exit(0)
        }
        if args.contains("--checkupdate") { Updater.shared.check(userInitiated: false, report: { self.say($0); exit(0) }); return }
        if args.contains("--updatetest") { Updater.shared.check(userInitiated: false, autoInstall: true, report: { self.say($0) }); return }
        if debugLog {   // MINISHEET_DEBUG=1: report window/view geometry and page state every 2 s
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                for w in self.windows {
                    guard let win = w.window, let t = w.current else { continue }
                    let web = t.web
                    if let shot = ProcessInfo.processInfo.environment["MINISHEET_SHOT"] { _ = captureWindow(win, to: shot) }
                    dlog("GEOM win=\(win.frame) contentView=\(win.contentView?.frame ?? .zero) webSuper=\(web.superview.map { "\($0.frame)" } ?? "nil") web=\(web.frame) hidden=\(web.isHiddenOrHasHiddenAncestor) alpha=\(web.alphaValue) layer=\(web.layer != nil) occl=\(win.occlusionState.contains(.visible))")
                    web.evaluateJavaScript("JSON.stringify({vis:document.visibilityState,w:innerWidth,h:innerHeight,cells:document.querySelectorAll('#grid td').length,file:typeof fileName!=='undefined'?fileName:null})") { r, e in dlog("PAGESTATE \(r ?? "nil") \(e.map { "\($0)" } ?? "")") }
                }
            }
        }
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

    // MARK: About / links
    static let orgURL = URL(string: "https://github.com/aibyos")!
    static let repoURL = URL(string: "https://github.com/aibyos/minisheet")!
    static let releasesURL = URL(string: "https://github.com/aibyos/minisheet/releases")!
    static let issuesURL = URL(string: "https://github.com/aibyos/minisheet/issues/new")!

    @objc func showAbout(_ s: Any?) {
        let body = NSMutableAttributedString()
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
        func text(_ t: String, _ extra: [NSAttributedString.Key: Any] = [:]) { body.append(NSAttributedString(string: t, attributes: base.merging(extra) { $1 })) }
        func link(_ t: String, _ u: URL) { text(t, [.link: u]) }
        text("Made by "); link("aibyos", Self.orgURL); text("\n")
        text("A small, fast spreadsheet app for CSV and Excel files.\n", [.foregroundColor: NSColor.secondaryLabelColor])
        link("GitHub", Self.repoURL); text("  ·  "); link("Release notes", Self.releasesURL); text("  ·  "); link("Report an issue", Self.issuesURL); text("\n")
        text("Excel support by ", [.foregroundColor: NSColor.secondaryLabelColor])
        link("SheetJS", URL(string: "https://sheetjs.com")!)
        text(" (Apache-2.0)", [.foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MiniSheet",
            .applicationVersion: appVersion,
            .version: "",
            .credits: body,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 aibyos · MIT License",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func openRepo(_ s: Any?) { NSWorkspace.shared.open(Self.repoURL) }
    @objc func openReleases(_ s: Any?) { NSWorkspace.shared.open(Self.releasesURL) }
    @objc func openIssues(_ s: Any?) { NSWorkspace.shared.open(Self.issuesURL) }
    @objc func openOrg(_ s: Any?) { NSWorkspace.shared.open(Self.orgURL) }
    @objc func showFileBrowser(_ s: Any?) { FileBrowserWindowController.shared.show() }
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
            item("About MiniSheet", #selector(showAbout(_:)), ""),
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
            item("Browse Files…", #selector(showFileBrowser(_:)), "o", [.command, .shift]),
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
        let help = menu("Help", [
            item("About MiniSheet", #selector(showAbout(_:)), ""),
            .separator(),
            item("MiniSheet on GitHub", #selector(openRepo(_:)), ""),
            item("Release Notes", #selector(openReleases(_:)), ""),
            item("Report an Issue…", #selector(openIssues(_:)), ""),
            .separator(),
            item("More from aibyos", #selector(openOrg(_:)), ""),
        ])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
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

// MARK: - File Browser (File → Browse Files…, ⇧⌘O; also Settings → History)
// Two sources: files opened in MiniSheet ("Recent") and every spreadsheet Spotlight knows about ("This Mac").
// Shown as a sortable list or as a folder tree; double-click opens in MiniSheet.

final class FileItem: NSObject {
    let url: URL
    let name: String
    let ext: String
    var size: Int64 = 0
    var modified: Date?
    var created: Date?
    var openedInApp: Date?
    var lastOpened: Date?          // newest of: opened in MiniSheet, macOS "last used"
    init(url: URL) { self.url = url; name = url.lastPathComponent; ext = url.pathExtension.lowercased() }
    var folder: String { url.deletingLastPathComponent().path }
}

final class FolderNode: NSObject {
    var name: String
    var path: String
    var folders: [FolderNode] = []
    var files: [FileItem] = []
    init(name: String, path: String) { self.name = name; self.path = path }
    var childCount: Int { folders.count + files.count }
    func child(_ i: Int) -> Any { i < folders.count ? folders[i] : files[i - folders.count] }
    var totalFiles: Int { files.count + folders.reduce(0) { $0 + $1.totalFiles } }
}

/// Table and outline views that open the selection on Return.
final class BrowserTableView: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with e: NSEvent) { if e.keyCode == 36 || e.keyCode == 76 { onReturn?() } else { super.keyDown(with: e) } }
}
final class BrowserOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    override func keyDown(with e: NSEvent) { if e.keyCode == 36 || e.keyCode == 76 { onReturn?() } else { super.keyDown(with: e) } }
}

final class FileBrowserWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                         NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    static let shared = FileBrowserWindowController()

    private static let extensions: Set<String> = ["csv", "tsv", "xlsx", "xlsm", "xls"]
    private static let utis = ["public.comma-separated-values-text", "public.tab-separated-values-text",
                               "org.openxmlformats.spreadsheetml.sheet", "org.openxmlformats.spreadsheetml.sheet.macroenabled",
                               "com.microsoft.excel.xls"]
    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("name", "Name", 250), ("kind", "Kind", 52), ("folder", "Folder", 270), ("size", "Size", 72),
        ("opened", "Last Opened", 150), ("modified", "Modified", 150), ("created", "Created", 150),
    ]

    private let scope = NSSegmentedControl(labels: ["Recent", "This Mac"], trackingMode: .selectOne, target: nil, action: nil)
    private let mode = NSSegmentedControl()
    private let search = NSSearchField()
    private let refreshButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let table = BrowserTableView()
    private let outline = BrowserOutlineView()
    private let tableScroll = NSScrollView()
    private let outlineScroll = NSScrollView()

    private var all: [FileItem] = []
    private var shown: [FileItem] = []
    private var roots: [FolderNode] = []
    private var query: NSMetadataQuery?
    private var started = Date()
    private var lastSearchSummary = ""
    var onSearchFinished: (() -> Void)?        // used by the development self-test

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f
    }()
    private var iconCache: [String: NSImage] = [:]

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 600),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "Browse Files"
        win.minSize = NSSize(width: 720, height: 360)
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.setFrameAutosaveName("MiniSheetBrowser")
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(recentsChanged), name: .msRecentsChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout
    private func buildUI() {
        scope.selectedSegment = 0
        scope.target = self; scope.action = #selector(scopeChanged)
        scope.setToolTip("Files you opened in MiniSheet", forSegment: 0)
        scope.setToolTip("Every CSV/TSV/Excel file Spotlight finds on this Mac", forSegment: 1)

        mode.segmentCount = 2
        mode.trackingMode = .selectOne
        mode.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List"), forSegment: 0)
        mode.setImage(NSImage(systemSymbolName: "folder", accessibilityDescription: "Tree"), forSegment: 1)
        mode.setToolTip("List view", forSegment: 0)
        mode.setToolTip("Folder tree", forSegment: 1)
        mode.selectedSegment = 0
        mode.target = self; mode.action = #selector(modeChanged)

        search.placeholderString = "Filter by name or path"
        search.sendsSearchStringImmediately = true
        search.target = self; search.action = #selector(filterChanged)

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.toolTip = "Search again"
        refreshButton.target = self; refreshButton.action = #selector(refresh)

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor; pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.lineBreakMode = .byTruncatingMiddle; pathLabel.isSelectable = true
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openButton.target = self; openButton.action = #selector(openSelected)
        openButton.keyEquivalent = ""
        openButton.isEnabled = false

        // list
        configure(table, outline: false)
        table.onReturn = { [weak self] in self?.openSelected() }
        tableScroll.documentView = table
        // tree
        configure(outline, outline: true)
        outline.onReturn = { [weak self] in self?.openSelected() }
        outlineScroll.documentView = outline
        outlineScroll.isHidden = true
        for s in [tableScroll, outlineScroll] { s.hasVerticalScroller = true; s.hasHorizontalScroller = true; s.autohidesScrollers = true; s.borderType = .noBorder }

        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [scope, mode, spacer, search, refreshButton])
        top.spacing = 10
        search.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let bottom = NSStackView(views: [spinner, status, pathLabel, openButton])
        bottom.spacing = 10
        status.setContentHuggingPriority(.required, for: .horizontal)

        let root = NSView()
        for v in [top, tableScroll, outlineScroll, bottom] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        let sep1 = NSBox(), sep2 = NSBox()
        for s in [sep1, sep2] { s.boxType = .separator; s.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(s) }
        var cs: [NSLayoutConstraint] = [
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            sep1.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            sep1.leadingAnchor.constraint(equalTo: root.leadingAnchor), sep1.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep2.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            sep2.leadingAnchor.constraint(equalTo: root.leadingAnchor), sep2.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ]
        for s in [tableScroll, outlineScroll] {
            cs += [s.topAnchor.constraint(equalTo: sep1.bottomAnchor), s.bottomAnchor.constraint(equalTo: sep2.topAnchor),
                   s.leadingAnchor.constraint(equalTo: root.leadingAnchor), s.trailingAnchor.constraint(equalTo: root.trailingAnchor)]
        }
        NSLayoutConstraint.activate(cs)
        window?.contentView = root
    }

    private func configure(_ tv: NSTableView, outline isOutline: Bool) {
        tv.style = .fullWidth
        tv.rowHeight = 22
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsMultipleSelection = true
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        for c in Self.columns where !(isOutline && c.id == "folder") {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = 44
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: ["name", "kind", "folder"].contains(c.id))
            tv.addTableColumn(col)
            if isOutline && c.id == "name" { (tv as? NSOutlineView)?.outlineTableColumn = col }
        }
        tv.dataSource = self
        tv.delegate = self
        tv.target = self
        tv.doubleAction = #selector(openSelected)
        let m = NSMenu(); m.delegate = self; tv.menu = m
        tv.autosaveName = isOutline ? "MiniSheetBrowserTree" : "MiniSheetBrowserList"
        tv.autosaveTableColumns = true
    }

    // MARK: showing & loading
    func show() {
        if !window!.isVisible { window!.center() }
        window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }
    func select(scope s: Int) { scope.selectedSegment = s; refresh() }

    @objc func scopeChanged() { refresh() }
    @objc func recentsChanged() { if scope.selectedSegment == 0 && window?.isVisible == true { refresh() } }
    @objc func refresh() {
        let sortKey = scope.selectedSegment == 0 ? "opened" : "modified"
        if table.sortDescriptors.first?.key == nil || [ "opened", "modified" ].contains(table.sortDescriptors.first?.key ?? "") {
            table.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: false)]
        }
        scope.selectedSegment == 0 ? loadRecents() : runSpotlight()
    }

    private func attributes(_ f: FileItem) {
        let a = try? FileManager.default.attributesOfItem(atPath: f.url.path)
        f.size = (a?[.size] as? NSNumber)?.int64Value ?? 0
        f.modified = a?[.modificationDate] as? Date
        f.created = a?[.creationDate] as? Date
    }

    private func loadRecents() {
        stopQuery()
        let fm = FileManager.default
        all = Pref.recents.compactMap { r in
            guard fm.fileExists(atPath: r.path) else { return nil }
            let f = FileItem(url: URL(fileURLWithPath: r.path))
            attributes(f)
            f.openedInApp = r.opened
            f.lastOpened = r.opened
            return f
        }
        lastSearchSummary = all.isEmpty ? "No recently opened files yet. Open a spreadsheet, or switch to “This Mac”."
                                        : "\(all.count) recently opened file\(all.count == 1 ? "" : "s")"
        applyFilter()
    }

    private func runSpotlight() {
        stopQuery()
        all = []; applyFilter()
        spinner.startAnimation(nil)
        status.stringValue = "Searching this Mac…"
        started = Date()
        let q = NSMetadataQuery()
        // Spotlight's own query language (same as `mdfind`): match by content type or by file extension.
        let terms = Self.utis.map { "kMDItemContentType == '\($0)'" } + Self.extensions.sorted().map { "kMDItemFSName == '*.\($0)'c" }
        guard let predicate = NSPredicate(fromMetadataQueryString: terms.joined(separator: " || ")) else {
            spinner.stopAnimation(nil); status.stringValue = "Couldn't build the Spotlight search."; return
        }
        q.predicate = predicate
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        NotificationCenter.default.addObserver(self, selector: #selector(queryProgress), name: .NSMetadataQueryGatheringProgress, object: q)
        NotificationCenter.default.addObserver(self, selector: #selector(queryFinished), name: .NSMetadataQueryDidFinishGathering, object: q)
        query = q
        dlog("spotlight start")
        if !q.start() {
            spinner.stopAnimation(nil)
            status.stringValue = "Spotlight search isn't available on this Mac."
        }
    }
    @objc private func queryProgress() { dlog("spotlight progress \(query?.resultCount ?? -1)"); if let q = query { status.stringValue = "Searching this Mac… \(q.resultCount) found" } }
    @objc private func queryFinished() {
        dlog("spotlight finished \(query?.resultCount ?? -1)")
        guard let q = query else { return }
        q.disableUpdates()
        let opened = Dictionary(Pref.recents.map { ($0.path, $0.opened) }, uniquingKeysWith: { a, _ in a })
        var items: [FileItem] = []
        var seen = Set<String>()
        for i in 0..<q.resultCount {
            guard let r = q.result(at: i) as? NSMetadataItem,
                  let path = r.value(forAttribute: NSMetadataItemPathKey) as? String, !seen.contains(path) else { continue }
            // skip copies buried inside apps, system folders and caches — not files people work on
            if path.contains(".app/") || path.contains("/Library/") || path.hasPrefix("/System/") || path.hasPrefix("/private/")
                || path.hasPrefix("/usr/") || path.hasPrefix("/opt/") { continue }
            let f = FileItem(url: URL(fileURLWithPath: path))
            guard Self.extensions.contains(f.ext) else { continue }
            seen.insert(path)
            f.size = (r.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
            f.modified = r.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            f.created = r.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date
            f.openedInApp = opened[path]
            f.lastOpened = [r.value(forAttribute: "kMDItemLastUsedDate") as? Date, f.openedInApp].compactMap { $0 }.max()
            items.append(f)
        }
        stopQuery()
        spinner.stopAnimation(nil)
        all = items
        lastSearchSummary = String(format: "%@ spreadsheet%@ on this Mac · searched in %.1f s",
                                   NumberFormatter.localizedString(from: NSNumber(value: items.count), number: .decimal),
                                   items.count == 1 ? "" : "s", Date().timeIntervalSince(started))
        applyFilter()
        onSearchFinished?()
    }
    private func stopQuery() {
        guard let q = query else { return }
        q.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryGatheringProgress, object: q)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
        query = nil
        spinner.stopAnimation(nil)
    }

    // MARK: filter, sort, tree
    @objc private func filterChanged() { applyFilter() }
    @objc private func modeChanged() {
        tableScroll.isHidden = mode.selectedSegment != 0
        outlineScroll.isHidden = mode.selectedSegment == 0
        updatePath()
    }

    private func applyFilter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var list = q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) || $0.url.path.lowercased().contains(q) }
        if let sd = table.sortDescriptors.first, let key = sd.key { list.sort { ordered($0, $1, by: key, ascending: sd.ascending) } }
        shown = list
        table.reloadData()
        roots = buildTree(list)
        outline.reloadData()
        if list.count <= 300 { outline.expandItem(nil, expandChildren: true) } else { roots.forEach { outline.expandItem($0) } }
        if query == nil {
            status.stringValue = q.isEmpty || all.isEmpty ? lastSearchSummary : "\(list.count) of \(all.count) match “\(search.stringValue)”"
        }
        updatePath()
    }

    private func ordered(_ a: FileItem, _ b: FileItem, by key: String, ascending asc: Bool) -> Bool {
        func text(_ x: String, _ y: String) -> Bool { let r = x.localizedStandardCompare(y); return asc ? r == .orderedAscending : r == .orderedDescending }
        func date(_ x: Date?, _ y: Date?) -> Bool {      // files without a date always go last
            switch (x, y) {
            case let (x?, y?): return asc ? x < y : x > y
            case (nil, .some): return false
            case (.some, nil): return true
            default: return text(a.name, b.name)
            }
        }
        switch key {
        case "kind": return text(a.ext, b.ext)
        case "folder": return text(a.folder, b.folder)
        case "size": return asc ? a.size < b.size : a.size > b.size
        case "opened": return date(a.lastOpened, b.lastOpened)
        case "modified": return date(a.modified, b.modified)
        case "created": return date(a.created, b.created)
        default: return text(a.name, b.name)
        }
    }

    /// Group files by folder: “~/…” for the home folder, “/…” elsewhere; chains of single subfolders are merged.
    private func buildTree(_ files: [FileItem]) -> [FolderNode] {
        let home = NSHomeDirectory()
        let top = FolderNode(name: "", path: "")
        var index: [String: FolderNode] = [:]
        for f in files {
            let dir = f.folder
            let inHome = dir == home || dir.hasPrefix(home + "/")
            let rest = inHome ? String(dir.dropFirst(home.count)) : dir
            var node = top
            var path = inHome ? home : ""
            let first = inHome ? "~" : "/"
            if let n = index[first] { node = n } else { let n = FolderNode(name: first, path: inHome ? home : "/"); top.folders.append(n); index[first] = n; node = n }
            for c in rest.split(separator: "/") {
                path += "/" + c
                if let n = index[path] { node = n }
                else { let n = FolderNode(name: String(c), path: path); node.folders.append(n); index[path] = n; node = n }
            }
            node.files.append(f)
        }
        func tidy(_ n: FolderNode) {
            while n.files.isEmpty, n.folders.count == 1 {
                let c = n.folders[0]
                n.name = n.name == "/" ? "/" + c.name : n.name + "/" + c.name
                n.path = c.path; n.files = c.files; n.folders = c.folders
            }
            n.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            n.folders.forEach(tidy)
        }
        top.folders.forEach(tidy)
        return top.folders.sorted { $0.name == "~" && $1.name != "~" }
    }

    // MARK: cells
    private func icon(for f: FileItem) -> NSImage {
        if let i = iconCache[f.ext] { return i }
        let i = UTType(filenameExtension: f.ext).map { NSWorkspace.shared.icon(for: $0) } ?? NSWorkspace.shared.icon(for: .data)
        i.size = NSSize(width: 16, height: 16)
        iconCache[f.ext] = i
        return i
    }
    private lazy var folderIcon: NSImage = { let i = NSWorkspace.shared.icon(for: .folder); i.size = NSSize(width: 16, height: 16); return i }()

    private func cell(_ tv: NSTableView, _ column: String, text: String, image: NSImage? = nil, dim: Bool = false) -> NSView {
        let ident = NSUserInterfaceItemIdentifier("cell-\(column)")
        let v = (tv.makeView(withIdentifier: ident, owner: self) as? NSTableCellView) ?? {
            let v = NSTableCellView(); v.identifier = ident
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: 12)
            tf.lineBreakMode = column == "folder" ? .byTruncatingHead : .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(tf); v.textField = tf
            if column == "name" {
                let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(iv); v.imageView = iv
                NSLayoutConstraint.activate([iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                                             iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                             iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                                             tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6)])
            } else {
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2).isActive = true
            }
            if ["size"].contains(column) { tf.alignment = .right }
            NSLayoutConstraint.activate([tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
                                         tf.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
            return v
        }()
        v.textField?.stringValue = text
        v.textField?.textColor = dim ? .secondaryLabelColor : .labelColor
        v.imageView?.image = image
        return v
    }
    private func text(_ f: FileItem, _ column: String) -> String {
        switch column {
        case "name": return f.name
        case "kind": return f.ext.uppercased()
        case "folder": return (f.folder as NSString).abbreviatingWithTildeInPath
        case "size": return ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)
        case "opened": return f.lastOpened.map { dateFormatter.string(from: $0) } ?? "—"
        case "modified": return f.modified.map { dateFormatter.string(from: $0) } ?? "—"
        case "created": return f.created.map { dateFormatter.string(from: $0) } ?? "—"
        default: return ""
        }
    }

    // MARK: table data
    func numberOfRows(in tv: NSTableView) -> Int { tv === table ? shown.count : 0 }
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let id = col?.identifier.rawValue, row < shown.count else { return nil }
        let f = shown[row]
        return cell(tv, id, text: text(f, id), image: id == "name" ? icon(for: f) : nil, dim: id != "name")
    }
    func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        if tv === outline { table.sortDescriptors = outline.sortDescriptors }
        applyFilter()
    }
    func tableViewSelectionDidChange(_ n: Notification) { updatePath() }

    // MARK: outline data
    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let n = item as? FolderNode { return n.childCount }
        return item == nil ? roots.count : 0
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FolderNode)?.child(index) ?? roots[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { item is FolderNode }
    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let id = col?.identifier.rawValue else { return nil }
        if let n = item as? FolderNode {
            return id == "name" ? cell(ov, id, text: "\(n.name)  (\(n.totalFiles))", image: folderIcon) : cell(ov, id, text: "")
        }
        guard let f = item as? FileItem else { return nil }
        return cell(ov, id, text: text(f, id), image: id == "name" ? icon(for: f) : nil, dim: id != "name")
    }
    func outlineViewSelectionDidChange(_ n: Notification) { updatePath() }

    // MARK: selection, open, context menu
    private var activeView: NSTableView { mode.selectedSegment == 0 ? table : outline }
    private func files(at rows: IndexSet) -> [FileItem] {
        rows.compactMap { r in activeView === table ? (r < shown.count ? shown[r] : nil) : outline.item(atRow: r) as? FileItem }
    }
    private func selectedFiles() -> [FileItem] { files(at: activeView.selectedRowIndexes) }
    private func clickedFiles() -> [FileItem] {
        let v = activeView, r = v.clickedRow
        if r >= 0 && !v.selectedRowIndexes.contains(r) { return files(at: IndexSet(integer: r)) }
        return selectedFiles()
    }
    private func updatePath() {
        let sel = selectedFiles()
        openButton.isEnabled = !sel.isEmpty
        if sel.count == 1 { pathLabel.stringValue = sel[0].url.path; pathLabel.toolTip = sel[0].url.path }
        else if sel.count > 1 { pathLabel.stringValue = "\(sel.count) files selected"; pathLabel.toolTip = nil }
        else if activeView === outline, outline.selectedRow >= 0, let n = outline.item(atRow: outline.selectedRow) as? FolderNode {
            pathLabel.stringValue = n.path; pathLabel.toolTip = n.path
        } else { pathLabel.stringValue = ""; pathLabel.toolTip = nil }
    }

    @objc func openSelected() {
        var files = activeView.clickedRow >= 0 && activeView.selectedRowIndexes.isEmpty ? clickedFiles() : selectedFiles()
        if files.isEmpty, activeView === outline, outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? FolderNode {
            outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n); return
        }
        files = files.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        files.prefix(20).forEach { AppDelegate.shared.openURL($0.url) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let files = clickedFiles()
        guard !files.isEmpty else { return }
        func add(_ title: String, _ sel: Selector) { menu.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self }
        add(files.count == 1 ? "Open" : "Open \(files.count) Files", #selector(menuOpen))
        menu.addItem(.separator())
        add("Show in Finder", #selector(menuReveal))
        add(files.count == 1 ? "Copy Path" : "Copy Paths", #selector(menuCopyPath))
        if scope.selectedSegment == 0 { menu.addItem(.separator()); add("Remove from Recent", #selector(menuForget)) }
    }
    @objc private func menuOpen() { clickedFiles().prefix(20).forEach { AppDelegate.shared.openURL($0.url) } }
    @objc private func menuReveal() { NSWorkspace.shared.activateFileViewerSelecting(clickedFiles().map { $0.url }) }
    @objc private func menuCopyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clickedFiles().map { $0.url.path }.joined(separator: "\n"), forType: .string)
    }
    @objc private func menuForget() {
        let gone = Set(clickedFiles().map { $0.url.path })
        Pref.recents = Pref.recents.filter { !gone.contains($0.path) }
        NotificationCenter.default.post(name: .msRecentsChanged, object: nil)
    }

    // development aid: report what's shown and capture the window
    func selfTest(scope s: Int, tree: Bool, filter: String, shot: String, done: @escaping (String) -> Void) {
        show()
        mode.selectedSegment = tree ? 1 : 0; modeChanged()
        search.stringValue = filter
        let finish = { [weak self] in
            guard let self = self else { return }
            self.applyFilter()
            if self.shown.count > 0 { self.activeView.selectRowIndexes(IndexSet(integer: tree ? min(1, self.outline.numberOfRows - 1) : 0), byExtendingSelection: false); self.updatePath() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let ok = captureWindow(self.window!, to: shot)
                done("BROWSER scope=\(s == 0 ? "recent" : "mac") tree=\(tree) all=\(self.all.count) shown=\(self.shown.count) roots=\(self.roots.map { "\($0.name)(\($0.totalFiles))" }.joined(separator: ",")) status='\(self.status.stringValue)' path='\(self.pathLabel.stringValue)' shot=\(ok)")
            }
        }
        if s == 1 { onSearchFinished = { finish() }; select(scope: 1) } else { select(scope: 0); finish() }
    }
}

// MARK: - Settings window (MiniSheet → Settings…, ⌘,)

extension Notification.Name {
    static let msUpdateChecked = Notification.Name("msUpdateChecked")
    static let msRecentsChanged = Notification.Name("msRecentsChanged")
}

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
        let browse = NSButton(title: "Browse Files…", target: AppDelegate.shared, action: #selector(AppDelegate.showFileBrowser(_:)))
        let clear = NSButton(title: "Clear Recent Files", target: self, action: #selector(clearRecents))
        historyLabel.textColor = .secondaryLabelColor
        historyLabel.font = .systemFont(ofSize: 11)
        let historyRow = NSStackView(views: [browse, clear]); historyRow.spacing = 8
        let about = NSButton(title: "About MiniSheet", target: AppDelegate.shared, action: #selector(AppDelegate.showAbout(_:)))
        let gh = NSButton(title: "GitHub", target: AppDelegate.shared, action: #selector(AppDelegate.openRepo(_:)))
        let issue = NSButton(title: "Report an Issue…", target: AppDelegate.shared, action: #selector(AppDelegate.openIssues(_:)))
        let aboutRow = NSStackView(views: [about, gh, issue]); aboutRow.spacing = 8
        let credit = NSTextField(labelWithAttributedString: {
            let a = NSMutableAttributedString(string: "Made by ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            a.append(NSAttributedString(string: "aibyos", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: AppDelegate.orgURL]))
            a.append(NSAttributedString(string: " · MIT License · ", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            a.append(NSAttributedString(string: "github.com/aibyos/minisheet", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: AppDelegate.repoURL]))
            return a
        }())
        credit.isSelectable = true; credit.allowsEditingTextAttributes = true
        let grid = NSGridView(views: [
            [label("Appearance:"), appearance],
            [label("Open files in:"), openIn],
            [label("Default zoom:"), zoom],
            [NSGridCell.emptyContentView, freeze],
            [label("History:"), historyRow],
            [NSGridCell.emptyContentView, historyLabel],
            [label("Updates:"), autoUpdate],
            [NSGridCell.emptyContentView, updateRow],
            [label("About:"), aboutRow],
            [NSGridCell.emptyContentView, credit],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.row(at: 4).topPadding = 14
        grid.row(at: 6).topPadding = 14
        grid.row(at: 8).topPadding = 14
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
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .msRecentsChanged, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private let historyLabel = NSTextField(labelWithString: "")

    @objc func clearRecents() {
        Pref.recents = []
        NotificationCenter.default.post(name: .msRecentsChanged, object: nil)
    }

    @objc func refresh() {
        let n = Pref.recents.count
        historyLabel.stringValue = n == 0 ? "No recently opened files yet" : "\(n) recently opened file\(n == 1 ? "" : "s") remembered"
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
