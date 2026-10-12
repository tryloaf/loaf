import JavaScriptCore
import WebKit

@MainActor final class ExtensionUserScripts: NSObject, WKScriptMessageHandlerWithReply {
    private struct Page {
        weak var view: WKWebView?
        var scripts: [WKUserScript] = []
    }
    private struct Client {
        weak var view: WKWebView?
        let frame: WKFrameInfo
        let world: WKContentWorld
        let sender: [String: Any]
        let documentID: String
    }
    private struct Connection {
        let client: Client
        let localID: String
    }
    let record: InstalledExtension
    let context: WKWebExtensionContext
    private let root: URL
    private var scripts: [[String: Any]] = []
    private var configurations: [[String: Any]] = []
    private var worlds: [String: WKContentWorld] = [:]
    private var preparedScripts: [WKUserScript]?
    private var pages: [ObjectIdentifier: Page] = [:]
    private var clients: [String: Client] = [:]
    private var connections: [String: Connection] = [:]
    private var port: WKWebExtension.MessagePort?
    private var pending: [String: (Any?, String?) -> Void] = [:]
    private var active = true
    private let generation = UUID()
    private var handlerName: String { "loafUserscripts" + record.id.uuidString.replacingOccurrences(of: "-", with: "") }

    init(record: InstalledExtension, context: WKWebExtensionContext, root: URL) throws {
        self.record = record
        self.context = context
        self.root = root
        super.init()
        let file = root.appendingPathComponent("userscripts.json")
        if FileManager.default.fileExists(atPath: file.path) {
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 25_000_000,
                let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                let registered = saved["scripts"] as? [[String: Any]], registered.count <= 1000,
                let configs = saved["worlds"] as? [[String: Any]], configs.count <= 32
            else { throw PackageError(reason: "Invalid saved user script registrations.") }
            scripts = try registered.map(validate)
            guard Set(scripts.compactMap { $0["id"] as? String }).count == scripts.count else {
                throw PackageError(reason: "Duplicate saved user script IDs.")
            }
            configurations = try configs.map(validateWorld)
        }
        for name in [
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(permissionsChanged), name: name, object: context)
        }
    }

    @objc private func permissionsChanged() { if active { refresh() } }

    func handle(_ operation: String, args: [String: Any]) throws -> Any {
        guard active, record.permissions.contains("userScripts")
        else {
            throw PackageError(reason: "userScripts permission was not granted.")
        }
        switch operation {
        case "getScripts":
            let ids = try filter(args)
            return scripts.filter { ids == nil || ids!.contains($0["id"] as! String) }
        case "getWorldConfigurations": return configurations
        case "register", "update":
            guard let incoming = args["scripts"] as? [[String: Any]], !incoming.isEmpty, incoming.count <= 1000 else {
                throw PackageError(reason: "Expected a nonempty list of user scripts.")
            }
            var next = scripts
            var seen = Set<String>()
            for entry in incoming {
                guard let id = entry["id"] as? String, seen.insert(id).inserted else {
                    throw PackageError(reason: "Duplicate or missing user script ID.")
                }
                let index = next.firstIndex { $0["id"] as? String == id }
                if operation == "register" {
                    guard index == nil else { throw PackageError(reason: "User script already registered: " + id) }
                    next.append(try validate(entry))
                } else {
                    guard let index else { throw PackageError(reason: "Unknown user script: " + id) }
                    next[index] = try validate(next[index].merging(entry) { _, new in new })
                }
            }
            try save(next, worlds: configurations)
            scripts = next
        case "unregister":
            let ids = try filter(args)
            let next = scripts.filter { ids != nil && !ids!.contains($0["id"] as! String) }
            try save(next, worlds: configurations)
            scripts = next
        case "configureWorld":
            let id = args["worldId"] as? String ?? ""
            let existing = configurations.first { ($0["worldId"] as? String ?? "") == id } ?? [:]
            let config = try validateWorld(existing.merging(args) { _, new in new })
            var next = configurations.filter { ($0["worldId"] as? String ?? "") != id }
            next.append(config)
            try save(scripts, worlds: next)
            configurations = next
        case "resetWorldConfiguration":
            let id = try validateWorld(args)["worldId"] as? String ?? ""
            let next = configurations.filter { ($0["worldId"] as? String ?? "") != id }
            try save(scripts, worlds: next)
            configurations = next
        default: throw PackageError(reason: "Unsupported userScripts method: " + operation)
        }
        refresh()
        return NSNull()
    }

    private func filter(_ args: [String: Any]) throws -> Set<String>? {
        guard let raw = args["ids"] else { return nil }
        guard let ids = raw as? [String] else { throw PackageError(reason: "Invalid user script IDs.") }
        return Set(ids)
    }

    private func validateWorld(_ raw: [String: Any]) throws -> [String: Any] {
        var value: [String: Any] = [:]
        if let id = raw["worldId"] {
            guard let id = id as? String, !id.hasPrefix("_"), id.utf8.count <= 256 else {
                throw PackageError(reason: "Invalid user script world ID.")
            }
            value["worldId"] = id
        }
        if let messaging = raw["messaging"] {
            guard let messaging = messaging as? Bool else { throw PackageError(reason: "Invalid messaging setting.") }
            value["messaging"] = messaging
        }
        if let csp = raw["csp"] {
            guard let csp = csp as? String, csp.utf8.count <= 8192 else {
                throw PackageError(reason: "Invalid user script content security policy.")
            }

            guard
                ["script-src 'self' 'unsafe-inline' *", "script-src 'self' 'unsafe-inline' 'unsafe-eval' *"].contains(
                    csp)
            else { throw PackageError(reason: "Custom restrictive user script CSP is unsupported by WebKit.") }
            value["csp"] = csp
        }
        return value
    }

    private func validate(_ raw: [String: Any]) throws -> [String: Any] {
        guard let id = raw["id"] as? String, !id.isEmpty, !id.hasPrefix("_"), id.utf8.count <= 1024,
            let matches = raw["matches"] as? [String], !matches.isEmpty, matches.count <= 1000,
            let sources = raw["js"] as? [[String: Any]], !sources.isEmpty, sources.count <= 1000
        else { throw PackageError(reason: "Invalid user script ID, matches, or JavaScript sources.") }
        var result: [String: Any] = ["id": id, "matches": matches, "js": sources]
        for name in ["matches", "excludeMatches"] {
            if let rawValue = raw[name] {
                guard let patterns = rawValue as? [String], patterns.count <= 1000 else {
                    throw PackageError(reason: "Invalid user script match patterns.")
                }
                for pattern in patterns { _ = try WKWebExtension.MatchPattern(string: pattern) }
                result[name] = patterns
            }
        }
        for name in ["includeGlobs", "excludeGlobs"] {
            if let rawValue = raw[name] {
                guard let globs = rawValue as? [String], globs.count <= 1000,
                    globs.allSatisfy({ $0.utf8.count <= 8192 })
                else { throw PackageError(reason: "Invalid user script globs.") }
                result[name] = globs
            }
        }
        if let frames = raw["allFrames"] {
            guard let frames = frames as? Bool else { throw PackageError(reason: "Invalid allFrames setting.") }
            result["allFrames"] = frames
        }
        let runAt = raw["runAt"] as? String ?? "document_idle"
        let world = raw["world"] as? String ?? "USER_SCRIPT"
        guard ["document_start", "document_end", "document_idle"].contains(runAt),
            ["USER_SCRIPT", "MAIN"].contains(world)
        else { throw PackageError(reason: "Invalid user script execution time or world.") }
        result["runAt"] = runAt
        result["world"] = world
        if let id = raw["worldId"] {
            guard world == "USER_SCRIPT" else { throw PackageError(reason: "MAIN scripts cannot specify worldId.") }
            result["worldId"] = try validateWorld(["worldId": id])["worldId"]
        }
        let code = try source(sources)
        let compiler = JSContext()!
        let compile = compiler.evaluateScript("(source => { new Function(source); })")!
        _ = compile.call(withArguments: [code])
        if let error = compiler.exception {
            throw PackageError(reason: "User script syntax error: " + error.toString())
        }
        return result
    }

    private func source(_ sources: [[String: Any]]) throws -> String {
        var code = ""
        for entry in sources {
            guard (entry["code"] == nil) != (entry["file"] == nil) else {
                throw PackageError(reason: "Each user script source needs exactly one of code or file.")
            }
            let value: String
            if let raw = entry["code"] {
                guard let text = raw as? String else { throw PackageError(reason: "Invalid user script source.") }
                value = text
            } else {
                guard let name = entry["file"] as? String, let path = ExtensionCompatibility.workerResource(name) else {
                    throw PackageError(reason: "Unsafe user script resource path.")
                }
                let runtime = root.appendingPathComponent("runtime").resolvingSymlinksInPath()
                let file = runtime.appendingPathComponent(path).resolvingSymlinksInPath()
                guard file.path.hasPrefix(runtime.path + "/"),
                    (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2_000_000
                else { throw PackageError(reason: "Unsafe or oversized user script resource.") }
                value = try String(contentsOf: file, encoding: .utf8)
            }
            guard code.utf8.count + value.utf8.count <= 2_000_000 else {
                throw PackageError(reason: "User script exceeds the source size limit.")
            }
            code += value + "\n"
        }
        return code
    }

    private func save(_ scripts: [[String: Any]], worlds: [[String: Any]]) throws {
        guard scripts.count <= 1000, worlds.count <= 32,
            Set(scripts.map { $0["worldId"] as? String ?? "" }).count <= 32
        else { throw PackageError(reason: "User script registration limit exceeded.") }
        let data = try JSONSerialization.data(withJSONObject: ["scripts": scripts, "worlds": worlds])
        guard data.count <= 25_000_000 else { throw PackageError(reason: "User script storage limit exceeded.") }
        try data.write(to: root.appendingPathComponent("userscripts.json"), options: .atomic)
    }

    func attach(_ view: WKWebView) {
        guard active else { return }
        if pages[ObjectIdentifier(view)] == nil { pages[ObjectIdentifier(view)] = Page(view: view) }
        rebuild(view)
    }

    func detach(_ view: WKWebView) {
        pages.removeValue(forKey: ObjectIdentifier(view))
        for world in worlds.values {
            view.configuration.userContentController.removeScriptMessageHandler(
                forName: handlerName, contentWorld: world)
        }
        let removed = connections.filter { $0.value.client.view === view }
        for (id, _) in removed {
            send(["operation": "disconnect", "portID": id])
            connections.removeValue(forKey: id)
        }
        clients = clients.filter { $0.value.view !== view }
    }

    private func refresh() {
        preparedScripts = nil

        for (id, connection) in connections where !messaging(connection.client.world) {
            deliver(connection, operation: "portDisconnect", message: NSNull())
            send(["operation": "disconnect", "portID": id])
            connections.removeValue(forKey: id)
        }
        for page in pages.values { if let view = page.view { rebuild(view) } }
    }

    private func world(_ id: String) -> WKContentWorld {
        if let existing = worlds[id] { return existing }
        let world = WKContentWorld.world(name: "loaf.userscripts.\(record.id).\(generation).\(id)")
        worlds[id] = world
        return world
    }

    private func messaging(_ world: WKContentWorld) -> Bool {
        guard let id = worlds.first(where: { $0.value === world })?.key else { return false }
        return configurations.first { ($0["worldId"] as? String ?? "") == id }?["messaging"] as? Bool == true
    }

    private func rebuild(_ view: WKWebView) {
        let controller = view.configuration.userContentController
        let owned = Set((pages[ObjectIdentifier(view)]?.scripts ?? []).map(ObjectIdentifier.init))
        let other = controller.userScripts.filter { !owned.contains(ObjectIdentifier($0)) }
        controller.removeAllUserScripts()
        for script in other { controller.addUserScript(script) }
        for world in worlds.values {
            controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
        }
        pages[ObjectIdentifier(view)]?.scripts = []
        if let preparedScripts {
            for world in worlds.values {
                controller.addScriptMessageHandler(self, contentWorld: world, name: handlerName)
            }
            for script in preparedScripts { add(script, to: controller, view: view) }
            return
        }
        let hosts = context.grantedPermissionMatchPatterns.keys.map(\.string)
        let access = Self.accessGate(context)
        var bootstrapped = Set<String>()
        for registered in scripts {
            guard let code = try? source(registered["js"] as! [[String: Any]]) else { continue }
            let main = registered["world"] as? String == "MAIN"
            let id = registered["worldId"] as? String ?? ""
            let contentWorld: WKContentWorld = main ? .page : world(id)
            let gate = access + " && " + Self.gate(registered, hosts: hosts)
            if !main, bootstrapped.insert(id).inserted {
                controller.addScriptMessageHandler(self, contentWorld: contentWorld, name: handlerName)
                if messaging(contentWorld) {
                    #if arch(arm64)
                        let arch = "arm"
                    #else
                        let arch = "x86-64"
                    #endif
                    let config: [String: Any] = [
                        "handler": handlerName, "id": context.uniqueIdentifier,
                        "baseURL": context.baseURL.absoluteString, "arch": arch,
                    ]
                    let bootstrap = ExtensionUserScriptBridge.runtime.replacingOccurrences(
                        of: "__LOAF_CONFIG__", with: Self.json(config))
                    add(
                        WKUserScript(
                            source: "if (" + access + " && " + Self.gate(["matches": hosts], hosts: hosts) + ") {\n"
                                + bootstrap + "\n}",
                            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: contentWorld), to: controller,
                        view: view)
                }
            }
            let runAt = registered["runAt"] as? String ?? "document_idle"

            add(
                WKUserScript(
                    source: "if (\(gate)) {\n\(code)\n}",
                    injectionTime: runAt == "document_start" ? .atDocumentStart : .atDocumentEnd,
                    forMainFrameOnly: registered["allFrames"] as? Bool != true, in: contentWorld), to: controller,
                view: view)
        }
        preparedScripts = pages[ObjectIdentifier(view)]?.scripts ?? []
    }

    private func add(_ script: WKUserScript, to controller: WKUserContentController, view: WKWebView) {
        pages[ObjectIdentifier(view)]?.scripts.append(script)
        controller.addUserScript(script)
    }

    private static func json(_ value: Any) -> String {
        String(
            decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
            as: UTF8.self)
    }

    private static func gate(_ script: [String: Any], hosts: [String]) -> String {
        let patterns = script["matches"] as? [String] ?? []
        func match(_ value: String) -> String {
            if value == "<all_urls>" { return "/^(https?|file|ftp):$/.test(location.protocol)" }
            guard let separator = value.range(of: "://"), let slash = value[separator.upperBound...].firstIndex(of: "/")
            else { return "false" }
            let scheme = String(value[..<separator.lowerBound]).lowercased()
            let host = String(value[separator.upperBound..<slash]).lowercased()
            let path = String(value[slash...])
            let schemes =
                scheme == "*" ? "/^https?:$/.test(location.protocol)" : "location.protocol === " + json(scheme + ":")
            let hostMatch =
                host == "*" || scheme == "file"
                ? "true"
                : host.hasPrefix("*.")
                    ? "(location.hostname === \(json(String(host.dropFirst(2)))) || location.hostname.endsWith(\(json(String(host.dropFirst())))))"
                    : "location.hostname === " + json(host)
            let regex =
                "^" + NSRegularExpression.escapedPattern(for: path).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return
                "(\(schemes) && \(hostMatch) && new RegExp(\(json(regex))).test(location.pathname + location.search))"
        }
        func any(_ patterns: [String]) -> String {
            "(" + (patterns.isEmpty ? ["false"] : patterns.map(match)).joined(separator: " || ") + ")"
        }
        func globs(_ values: [String]) -> String {
            "("
                + values.map { value in
                    let expression =
                        "^"
                        + NSRegularExpression.escapedPattern(for: value)
                        .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
                    return "new RegExp(\(json(expression))).test(location.href)"
                }.joined(separator: " || ") + ")"
        }
        var result = any(hosts) + " && " + any(patterns)
        if let excluded = script["excludeMatches"] as? [String], !excluded.isEmpty { result += " && !" + any(excluded) }
        if let included = script["includeGlobs"] as? [String], !included.isEmpty { result += " && " + globs(included) }
        if let excluded = script["excludeGlobs"] as? [String], !excluded.isEmpty { result += " && !" + globs(excluded) }
        return result
    }

    private static func accessGate(_ context: WKWebExtensionContext) -> String {
        func rules(_ patterns: [WKWebExtension.MatchPattern: Date]) -> String {
            let clauses = patterns.map { pattern, expiration in
                "(Date.now() < \(expiration.timeIntervalSince1970 * 1000) && "
                    + gate(["matches": [pattern.string]], hosts: [pattern.string]) + ")"
            }
            return "(" + (clauses.isEmpty ? ["false"] : clauses).joined(separator: " || ") + ")"
        }
        return rules(context.grantedPermissionMatchPatterns) + " && !" + rules(context.deniedPermissionMatchPatterns)
    }

    func connect(_ port: WKWebExtension.MessagePort) {
        self.port?.disconnect()
        self.port = port
        port.messageHandler = { [weak self] message, _ in
            guard let self, let message = message as? [String: Any] else { return }
            if let id = message["requestID"] as? String, let completion = self.pending.removeValue(forKey: id) {
                completion(message["value"], message["error"] as? String)
            } else if let id = message["portID"] as? String, let connection = self.connections[id],
                let operation = message["operation"] as? String
            {
                self.deliver(connection, operation: operation, message: message["message"] ?? NSNull())
                if operation == "portDisconnect" { self.connections.removeValue(forKey: id) }
            }
        }
        port.disconnectHandler = { [weak self, weak port] _ in
            guard let self, self.port === port else { return }
            self.port = nil
            let callbacks = self.pending.values
            self.pending.removeAll()
            for callback in callbacks { callback(nil, "The user script manager disconnected.") }
            for connection in self.connections.values {
                self.deliver(connection, operation: "portDisconnect", message: NSNull())
            }
            self.connections.removeAll()
        }
    }

    private func send(_ message: [String: Any]) { port?.sendMessage(message) { _ in } }

    private func request(_ message: [String: Any]) async throws -> Any {
        guard let port, !port.isDisconnected, pending.count < 256 else {
            throw PackageError(reason: "The user script manager is unavailable.")
        }
        let id = UUID().uuidString
        var message = message
        message["requestID"] = id
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = { value, error in
                if let error {
                    continuation.resume(throwing: PackageError(reason: error))
                } else {
                    continuation.resume(returning: value ?? NSNull())
                }
            }
            port.sendMessage(message) { [weak self] error in
                if let error { self?.pending.removeValue(forKey: id)?(nil, error.localizedDescription) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.pending.removeValue(forKey: id)?(nil, "User script message timed out.")
            }
        }
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            do { replyHandler(try await handleMessage(message), nil) } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    private func handleMessage(_ message: WKScriptMessage) async throws -> Any {
        guard active, let view = message.webView, pages[ObjectIdentifier(view)] != nil,
            messaging(message.world),
            let url = message.frameInfo.request.url,
            context.hasAccess(to: url), ["http", "https", "file", "ftp"].contains(url.scheme),
            let body = message.body as? [String: Any],
            let documentID = body["documentID"] as? String, documentID.count <= 128,
            let operation = body["operation"] as? String,
            JSONSerialization.isValidJSONObject(body),
            try JSONSerialization.data(withJSONObject: body).count <= 2_000_000
        else { throw PackageError(reason: "User script access denied.") }
        let key = "\(ObjectIdentifier(view)).\(message.world.name ?? "").\(documentID)"
        if operation == "closeDocument" {
            for (id, connection) in connections
            where connection.client.documentID == documentID && connection.client.view === view {
                send(["operation": "disconnect", "portID": id])
                connections.removeValue(forKey: id)
            }
            clients.removeValue(forKey: key)
            return NSNull()
        }
        let client: Client
        if let existing = clients[key], existing.frame.request.url == url {
            client = existing
        } else {
            guard clients.count < 2048 else { throw PackageError(reason: "User script frame limit exceeded.") }
            let marker = "__loaf_frame_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            _ = try await view.callAsyncJavaScript(
                "globalThis[marker] = true;", arguments: ["marker": marker],
                in: message.frameInfo, contentWorld: .page)
            let result: Any
            do {
                result = try await request(["operation": "resolveSender", "marker": marker, "url": url.absoluteString])
            } catch {
                view.callAsyncJavaScript(
                    "delete globalThis[marker];", arguments: ["marker": marker],
                    in: message.frameInfo, in: .page
                ) { _ in }
                throw error
            }
            _ = try await view.callAsyncJavaScript(
                "delete globalThis[marker];", arguments: ["marker": marker],
                in: message.frameInfo, contentWorld: .page)
            guard active, messaging(message.world), let sender = result as? [String: Any] else {
                throw PackageError(reason: "The userscript frame is unavailable.")
            }
            client = Client(
                view: view, frame: message.frameInfo, world: message.world, sender: sender, documentID: documentID)
            clients[key] = client
        }
        switch operation {
        case "sendMessage":
            return try await request([
                "operation": operation, "sender": client.sender, "message": body["message"] ?? NSNull(),
            ])
        case "connect":
            guard let localID = body["portID"] as? String, localID.count <= 128,
                connections.count < 2048, let name = body["name"] as? String, name.utf8.count <= 8192
            else { throw PackageError(reason: "Invalid userscript port.") }
            let id = key + "." + localID
            connections[id] = Connection(client: client, localID: localID)
            send(["operation": operation, "sender": client.sender, "portID": id, "name": name])
        case "postMessage", "disconnect":
            guard let localID = body["portID"] as? String, let connection = connections[key + "." + localID],
                connection.client.view === view
            else { throw PackageError(reason: "Unknown userscript port.") }
            let id = key + "." + localID
            send(["operation": operation, "portID": id, "message": body["message"] ?? NSNull()])
            if operation == "disconnect" { connections.removeValue(forKey: id) }
        default: throw PackageError(reason: "Unsupported userscript message.")
        }
        return NSNull()
    }

    private func deliver(_ connection: Connection, operation: String, message: Any) {
        guard let view = connection.client.view, active, messaging(connection.client.world),
            let url = connection.client.frame.request.url, context.hasAccess(to: url)
        else { return }
        view.callAsyncJavaScript(
            "globalThis.__loafUserScriptRuntime?.receive(operation, portID, message);",
            arguments: ["operation": operation, "portID": connection.localID, "message": message],
            in: connection.client.frame, in: connection.client.world
        ) { _ in }
    }

    func stop() {
        guard active else { return }
        for page in pages.values {
            guard let view = page.view else { continue }
            let owned = Set(page.scripts.map(ObjectIdentifier.init))
            detach(view)
            let controller = view.configuration.userContentController
            let other = controller.userScripts.filter { !owned.contains(ObjectIdentifier($0)) }
            controller.removeAllUserScripts()
            for script in other { controller.addUserScript(script) }
        }
        active = false
        NotificationCenter.default.removeObserver(self)
        port?.disconnect()
        port = nil
        let callbacks = pending.values
        pending.removeAll()
        for callback in callbacks { callback(nil, "The user script manager was disabled.") }
        clients.removeAll()
        connections.removeAll()
        pages.removeAll()
        preparedScripts = nil
    }
}
