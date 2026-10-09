import AppKit
import WebKit

@MainActor final class SiteJavaScriptDialog {
    enum Kind { case alert, confirm, prompt }
    let alert = NSAlert()
    let field: NSTextField?
    let origin: String

    static func origin(protocol scheme: String, host: String, port: Int) -> String {
        guard !host.isEmpty else { return scheme == "file" ? "local file" : "embedded page · unknown origin" }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if port > 0 && !(scheme == "https" && port == 443) && !(scheme == "http" && port == 80) {
            components.port = port
        }
        return components.url?.absoluteString ?? host
    }

    init(
        kind: Kind, message: String, scheme: String, host: String, port: Int, mainFrame: Bool,
        defaultText: String? = nil, privateMode: Bool = false
    ) {
        origin = Self.origin(protocol: scheme, host: host, port: port)
        field = kind == .prompt ? NSTextField(string: defaultText ?? "") : nil
        let site = host.isEmpty ? (scheme == "file" ? "local file" : "embedded page") : host
        alert.messageText = site + (kind == .alert ? " says" : " asks")
        alert.informativeText = String(message.prefix(2000))
        alert.alertStyle = .informational
        alert.icon = LoafAppIcon.image
        alert.addButton(withTitle: "ok")
        if kind != .alert { alert.addButton(withTitle: "cancel") }
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10

        content.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        let source = NSTextField(wrappingLabelWithString: (mainFrame ? "website" : "embedded website") + " · " + origin)
        source.font = .systemFont(ofSize: 11)
        source.textColor = .secondaryLabelColor
        source.isSelectable = true
        source.setAccessibilityLabel("requesting website: " + origin)
        content.addArrangedSubview(source)
        if let field {
            field.placeholderString = "your response"
            field.font = .systemFont(ofSize: 13)
            field.bezelStyle = .roundedBezel
            field.setAccessibilityLabel("your response to " + site)
            content.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 284).isActive = true
            alert.window.initialFirstResponder = field
        }
        content.frame = NSRect(x: 0, y: 0, width: 296, height: field == nil ? 34 : 68)
        source.preferredMaxLayoutWidth = 284
        alert.accessoryView = content
        alert.window.title = "website prompt"
        if privateMode {
            alert.window.appearance = NSAppearance(named: .darkAqua)
            alert.buttons.first?.bezelColor = NSColor(white: 0.45, alpha: 1)
            alert.buttons.first?.contentTintColor = .white
        }
    }

    convenience init(kind: Kind, message: String, frame: WKFrameInfo, defaultText: String? = nil, privateMode: Bool) {
        let origin = frame.securityOrigin
        self.init(
            kind: kind, message: message, scheme: origin.protocol, host: origin.host, port: origin.port,
            mainFrame: frame.isMainFrame, defaultText: defaultText, privateMode: privateMode)
    }
}
