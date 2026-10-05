import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// What's on screen in any app, as text: the window's words through Accessibility (web pages included), or,
/// when an app draws everything itself, the words read off a picture of the window.
@MainActor
enum Screen {
    struct Seen {
        let app: String
        let bundleID: String
        let window: String
        let text: String
        let url: URL?
    }

    private static var lastUsed: NSRunningApplication?

    /// Remembers the last app you were in, for when VibeNotch itself is in front (you clicked the notch).
    static func track() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated { lastUsed = app }
        }
    }

    /// The app you're using (not VibeNotch), or the one named.
    static func target(_ bundleID: String? = nil) -> NSRunningApplication? {
        if let bundleID { return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID } }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { return front }
        return lastUsed.flatMap { $0.isTerminated ? nil : $0 }
    }

    static func read(_ bundleID: String? = nil, limit: Int = 20000) async -> Seen? {
        guard let app = target(bundleID), Hands.accessibilityGranted() else { return nil }
        let pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        // Chrome, Electron apps (Slack, Cursor, Notion…) only build their page tree when a reader asks for it.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var text = await Task.detached(priority: .userInitiated) { collect(root, limit: limit) }.value
        if text.window.isEmpty || text.body.count < 80 {
            try? await Task.sleep(for: .milliseconds(600))
            text = await Task.detached(priority: .userInitiated) { collect(root, limit: limit) }.value
        }
        var body = text.body
        if body.count < 120, let seen = await ocr(pid: pid) { body = seen }
        let url = Page.browsers.contains(app.bundleIdentifier ?? "") ? Page.tab()?.url : nil
        return Seen(app: app.localizedName ?? "la app", bundleID: app.bundleIdentifier ?? "", window: text.window, text: body, url: url)
    }

    /// Clicks the first button, link or row whose words include `words`: «ábrelo», «dale clic a Enviar».
    static func press(_ words: String, in bundleID: String? = nil) async -> Bool {
        guard let app = target(bundleID), Hands.accessibilityGranted() else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let wanted = People.fold(words)
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let window = element(root, kAXFocusedWindowAttribute) ?? children(root).first else { return false }
            var queue = [find(window, role: "AXWebArea") ?? window], seen = 0
            while !queue.isEmpty, seen < 6000 {
                let e = queue.removeFirst()
                seen += 1
                // The search box holds the same words; typing fields are never the target.
                if ["AXTextField", "AXSearchField", "AXComboBox", "AXTextArea"].contains(string(e, kAXRoleAttribute)) { continue }
                let label = People.fold([string(e, kAXTitleAttribute), string(e, kAXDescriptionAttribute), string(e, kAXValueAttribute)].joined(separator: " "))
                if label.contains(wanted), actions(e).contains(kAXPressAction as String) {
                    return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
                }
                if label.contains(wanted), let parent = pressableAncestor(e) {
                    return AXUIElementPerformAction(parent, kAXPressAction as CFString) == .success
                }
                queue.append(contentsOf: children(e))
            }
            return false
        }.value
    }

    /// Presses a button whose name is exactly one of `names` («Enviar», «Send»): a message that merely
    /// contains the word must never be what gets clicked.
    static func pressButton(_ names: [String], in bundleID: String? = nil) async -> Bool {
        guard let app = target(bundleID), Hands.accessibilityGranted() else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let wanted = Set(names.map { People.fold($0) })
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let window = element(root, kAXFocusedWindowAttribute) ?? children(root).first else { return false }
            var queue = [window], seen = 0
            while !queue.isEmpty, seen < 6000 {
                let e = queue.removeFirst()
                seen += 1
                if string(e, kAXRoleAttribute) == "AXButton", actions(e).contains(kAXPressAction as String),
                   [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { wanted.contains(People.fold(string(e, $0))) }) {
                    return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
                }
                queue.append(contentsOf: children(e))
            }
            return false
        }.value
    }

    // MARK: - Accessibility

    nonisolated private static func collect(_ root: AXUIElement, limit: Int) -> (window: String, body: String) {
        guard let window = element(root, kAXFocusedWindowAttribute) ?? element(root, kAXMainWindowAttribute) ?? children(root).first else {
            return ("", "")
        }
        let title = string(window, kAXTitleAttribute)
        // In a browser, the page is what matters, not the tabs and toolbar.
        let start = find(window, role: "AXWebArea") ?? window
        var lines: [String] = []
        var total = 0, visited = 0
        let deadline = Date().addingTimeInterval(2.5)
        func walk(_ e: AXUIElement, depth: Int) {
            guard total < limit, visited < 12000, depth < 60, Date() < deadline else { return }
            visited += 1
            let role = string(e, kAXRoleAttribute)
            if ["AXScrollBar", "AXMenuBar", "AXMenu", "AXImage"].contains(role) { return }
            var piece = ""
            switch role {
            case "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXCell":
                piece = string(e, kAXValueAttribute)
                if piece.isEmpty { piece = string(e, kAXTitleAttribute) }
                if piece.isEmpty { piece = string(e, kAXDescriptionAttribute) }
            case "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton", "AXTab":
                piece = string(e, kAXTitleAttribute)
                if piece.isEmpty { piece = string(e, kAXDescriptionAttribute) }
                if piece.count < 3 { piece = "" }
            default: break
            }
            piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty, lines.last != piece {
                lines.append(piece)
                total += piece.count + 1
            }
            // A text area's words are already in its value.
            if role == "AXTextArea" || role == "AXStaticText" { return }
            for child in children(e) { walk(child, depth: depth + 1) }
        }
        walk(start, depth: 0)
        return (title, String(lines.joined(separator: "\n").prefix(limit)))
    }

    nonisolated private static func find(_ e: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 25 else { return nil }
        if string(e, kAXRoleAttribute) == role { return e }
        for child in children(e) { if let hit = find(child, role: role, depth: depth + 1) { return hit } }
        return nil
    }

    nonisolated private static func pressableAncestor(_ e: AXUIElement) -> AXUIElement? {
        var current = e
        for _ in 0..<6 {
            guard let parent = element(current, kAXParentAttribute) else { return nil }
            if actions(parent).contains(kAXPressAction as String) { return parent }
            current = parent
        }
        return nil
    }

    nonisolated private static func string(_ e: AXUIElement, _ attr: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return "" }
        return v as? String ?? ""
    }

    nonisolated private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    nonisolated private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    nonisolated private static func actions(_ e: AXUIElement) -> [String] {
        var v: CFArray?
        guard AXUIElementCopyActionNames(e, &v) == .success else { return [] }
        return v as? [String] ?? []
    }

    // MARK: - Picture of the window

    /// Needs Screen Recording; asked once, the first time an app shows nothing readable.
    private static var askedForScreen = false

    private static func ocr(pid: pid_t) async -> String? {
        if !CGPreflightScreenCaptureAccess() {
            if !askedForScreen { askedForScreen = true; CGRequestScreenCaptureAccess() }
            return nil
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 200 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                     configuration: config) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["es-MX", "en-US"]
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.value
    }
}
