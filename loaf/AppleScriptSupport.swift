import AppKit
import WebKit

@MainActor enum BrowserScripting {
    private static let javaScriptHandler = LoafJavaScriptEventHandler()
    static weak var coordinator: WindowCoordinator? {
        didSet {
            _ = NSScriptSuiteRegistry.shared()
            NSAppleEventManager.shared().setEventHandler(
                javaScriptHandler,
                andSelector: #selector(LoafJavaScriptEventHandler.handle(_:withReplyEvent:)),
                forEventClass: 0x4C6F6166, andEventID: 0x446F4A53)
        }
    }
}

extension NSApplication {
    @objc func handleBrowserScriptCommand(_ command: NSScriptCommand) -> Any? { command.performDefaultImplementation() }
    @objc dynamic var scriptWindows: [LoafScriptWindow] {
        BrowserScripting.coordinator?.application.windows.filter { $0.nativeWindow != nil }.map { LoafScriptWindow($0) }
            ?? []
    }
    @objc(valueInScriptWindowsWithUniqueID:) func scriptWindow(id: String) -> LoafScriptWindow? {
        scriptWindows.first { $0.scriptID == id }
    }
}

@objc(LoafScriptWindow) final class LoafScriptWindow: NSObject {
    let store: BrowserStore
    init(_ store: BrowserStore) { self.store = store }
    @objc func handleBrowserScriptCommand(_ command: NSScriptCommand) -> Any? { command.performDefaultImplementation() }
    @objc dynamic var scriptID: String { store.id.uuidString }
    @objc dynamic var name: String { store.nativeWindow?.title ?? "loaf" }
    @objc dynamic var tabs: [LoafScriptTab] { store.tabs.map { LoafScriptTab($0) } }
    @objc dynamic var activeTab: LoafScriptTab? {
        get { store.selectedTab.map { LoafScriptTab($0) } }
        set { if let tab = newValue?.tab, tab.store === store { store.select(tab) } }
    }
    @objc dynamic var visible: Bool {
        get { store.nativeWindow?.isVisible == true }
        set { if newValue { store.nativeWindow?.makeKeyAndOrderFront(nil) } else { store.nativeWindow?.orderOut(nil) } }
    }
    @objc dynamic var bounds: [Int] {
        get {
            guard let frame = store.nativeWindow?.frame else { return [0, 0, 0, 0] }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return [
                Int(frame.minX.rounded()), Int((top - frame.maxY).rounded()), Int(frame.maxX.rounded()),
                Int((top - frame.minY).rounded()),
            ]
        }
        set {
            guard newValue.count == 4, let window = store.nativeWindow else { return }
            let width = newValue[2] - newValue[0]
            let height = newValue[3] - newValue[1]
            guard width > 0, height > 0, width <= 20_000, height <= 20_000 else { return }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            window.setFrame(
                NSRect(
                    x: newValue[0], y: Int(top) - newValue[3], width: max(width, Int(window.minSize.width)),
                    height: max(height, Int(window.minSize.height))), display: true)
        }
    }
    @objc(valueInTabsWithUniqueID:) func scriptTab(id: String) -> LoafScriptTab? { tabs.first { $0.scriptID == id } }
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let description = NSApp.classDescription as? NSScriptClassDescription else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: description, containerSpecifier: nil, key: "scriptWindows", uniqueID: scriptID)
    }
}

@objc(LoafScriptTab) final class LoafScriptTab: NSObject {
    let tab: BrowserTab
    init(_ tab: BrowserTab) { self.tab = tab }
    @objc func handleBrowserScriptCommand(_ command: NSScriptCommand) -> Any? { command.performDefaultImplementation() }
    @objc dynamic var scriptID: String { tab.id.uuidString }
    @objc dynamic var name: String { tab.sidebarTitle }
    @objc dynamic var URL: String {
        get { tab.url?.absoluteString ?? tab.page.address }
        set { if let url = BrowserAddress.resolve(newValue), ["https", "http"].contains(url.scheme) { tab.load(url) } }
    }
    @objc dynamic var muted: Bool {
        get { !tab.media.isEmpty && tab.media.allSatisfy(\.muted) }
        set { if muted != newValue { tab.store?.toggleMute(tab) } }
    }
    @objc dynamic var loading: Bool { tab.loading }
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let store = tab.store else { return nil }
        let parent = LoafScriptWindow(store)
        guard let description = parent.classDescription as? NSScriptClassDescription else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: description, containerSpecifier: parent.objectSpecifier, key: "tabs",
            uniqueID: scriptID)
    }
}

@objc(LoafBrowserScriptCommand) final class LoafBrowserScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let coordinator = BrowserScripting.coordinator else {
            scriptErrorNumber = -1712
            scriptErrorString = "loaf is not ready"
            return nil
        }
        let action = commandDescription.commandName
        let direct = directParameter
        let target =
            (direct as? LoafScriptTab)?.tab ?? (evaluatedArguments?["tab"] as? LoafScriptTab)?.tab
            ?? coordinator.commandState?.selectedTab
        switch action {
        case "open location", "open tab":
            let owner =
                (evaluatedArguments?["window"] as? LoafScriptWindow)?.store ?? coordinator.commandState
                ?? coordinator.newWindow()
            let input = direct as? String ?? ""
            guard input.isEmpty || BrowserAddress.resolve(input).map({ ["https", "http"].contains($0.scheme) }) == true
            else {
                fail("use an HTTP or HTTPS URL")
                return nil
            }
            return LoafScriptTab(
                owner.newTab(url: input.isEmpty ? nil : BrowserAddress.resolve(input), showOmnibar: input.isEmpty))
        case "close":
            if let window = direct as? LoafScriptWindow {
                window.store.nativeWindow?.performClose(nil)
            } else if let target {
                target.store?.close(target)
            }
        case "reload": target?.reload()
        case "select":
            if let target, let owner = target.store {
                owner.select(target)
                owner.nativeWindow?.makeKeyAndOrderFront(nil)
            }
        case "go back": target?.existingWebView?.goBack()
        case "go forward": target?.existingWebView?.goForward()
        default: fail("unsupported browser command")
        }
        return nil
    }
    private func fail(_ message: String) {
        scriptErrorNumber = -1708
        scriptErrorString = message
    }
}

@MainActor private final class LoafJavaScriptEventHandler: NSObject {
    @objc func handle(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        func fail(_ message: String) {
            reply.setParam(NSAppleEventDescriptor(int32: -1708), forKeyword: 0x6572726E)
            reply.setParam(NSAppleEventDescriptor(string: message), forKeyword: 0x65727273)
        }
        guard let coordinator = BrowserScripting.coordinator else {
            fail("loaf is not ready")
            return
        }
        guard coordinator.application.preferences.allowsScriptJavaScript == true else {
            fail("enable JavaScript from AppleScript in advanced settings")
            return
        }
        let target: BrowserTab?
        if let reference = event.paramDescriptor(forKeyword: 0x57686572) {
            guard let specifier = NSScriptObjectSpecifier(descriptor: reference),
                let tab = specifier.objectsByEvaluatingSpecifier as? LoafScriptTab
            else {
                fail("choose a live web tab")
                return
            }
            target = tab.tab
        } else {
            target = coordinator.commandState?.selectedTab
        }
        guard let script = event.paramDescriptor(forKeyword: 0x2D2D2D2D)?.stringValue,
            script.utf8.count <= 100_000, let target, target.page == .web, !target.isDisposed
        else {
            fail("choose a live web tab and a script under 100 KB")
            return
        }
        let manager = NSAppleEventManager.shared()
        guard let suspension = manager.suspendCurrentAppleEvent() else {
            fail("unable to start JavaScript execution")
            return
        }

        target.webView.evaluateJavaScript(script) { result, error in
            let response = manager.replyAppleEvent(forSuspensionID: suspension)
            if let error {
                response.setParam(NSAppleEventDescriptor(int32: -1708), forKeyword: 0x6572726E)
                response.setParam(NSAppleEventDescriptor(string: error.localizedDescription), forKeyword: 0x65727273)
            } else {
                response.setParam(Self.scriptValue(result), forKeyword: 0x2D2D2D2D)
            }
            manager.resume(withSuspensionID: suspension)
        }
    }
    private static func scriptValue(_ value: Any?, depth: Int = 0) -> NSAppleEventDescriptor {
        guard depth < 32, let value else { return .null() }
        if let text = value as? String { return NSAppleEventDescriptor(string: text) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return NSAppleEventDescriptor(boolean: number.boolValue) }
            if number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max)
            {
                return NSAppleEventDescriptor(int32: number.int32Value)
            }
            return NSAppleEventDescriptor(double: number.doubleValue)
        }
        if let values = value as? [Any] {
            let list = NSAppleEventDescriptor.list()
            for (index, item) in values.enumerated() { list.insert(scriptValue(item, depth: depth + 1), at: index + 1) }
            return list
        }
        if let values = value as? [String: Any] {
            let record = NSAppleEventDescriptor.record()
            let fields = NSAppleEventDescriptor.list()
            for (index, key) in values.keys.sorted().enumerated() {
                fields.insert(NSAppleEventDescriptor(string: key), at: index * 2 + 1)
                fields.insert(scriptValue(values[key], depth: depth + 1), at: index * 2 + 2)
            }
            record.setDescriptor(fields, forKeyword: 0x75737266)
            return record
        }
        return .null()
    }
}

@objc(LoafCreateScriptCommand) final class LoafCreateScriptCommand: NSCreateCommand {
    override func performDefaultImplementation() -> Any? {
        guard let coordinator = BrowserScripting.coordinator else {
            scriptErrorNumber = -1712
            return nil
        }

        let classArgument = arguments?["ObjectClass"] ?? evaluatedArguments?["ObjectClass"]
        let classCode =
            (classArgument as? NSNumber)?.uint32Value ?? (classArgument as? NSScriptClassDescription)?.appleEventCode
            ?? (classArgument as? NSAppleEventDescriptor)?.typeCodeValue
        if classCode == 0x6377696E {
            let result = LoafScriptWindow(coordinator.newWindow())
            return result.objectSpecifier
        }
        guard classCode == 0x63746162 else {
            scriptErrorNumber = -2710
            return nil
        }
        let location = evaluatedArguments?["Location"] as? NSPositionalSpecifier
        location?.evaluate()
        let owner =
            (location?.insertionContainer as? LoafScriptWindow)?.store ?? coordinator.commandState
            ?? coordinator.newWindow()
        let properties = resolvedKeyDictionary
        let input = properties["URL"] as? String ?? properties["pURL"] as? String ?? ""
        guard input.isEmpty || BrowserAddress.resolve(input).map({ ["https", "http"].contains($0.scheme) }) == true
        else {
            scriptErrorNumber = -1708
            scriptErrorString = "use an HTTP or HTTPS URL"
            return nil
        }
        return LoafScriptTab(owner.newTab(url: input.isEmpty ? nil : BrowserAddress.resolve(input), showOmnibar: false))
            .objectSpecifier
    }
}
