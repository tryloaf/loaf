import AppKit
import Combine
import SwiftUI

@MainActor final class LegalAcceptance: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = LegalAcceptance()
    @Published private(set) var documents: [LegalDocument] = []
    @Published private(set) var error: String?
    @Published private(set) var isAccepted = false
    private var window: NSWindow?
    private var completion: (() -> Void)?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private let receiptURL: URL
    private let identifier: String
    private let bundle: Bundle
    var resourceBundle: Bundle { bundle }

    init(bundle: Bundle = .main, receiptURL override: URL? = nil) {
        self.bundle = bundle
        identifier = bundle.bundleIdentifier ?? ""
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = identifier == MarketingLaunch.bundleIdentifier ? "loaf/Studio" : BrowserBrand.supportDirectory
        receiptURL =
            override ?? support.appendingPathComponent(directory).appendingPathComponent("Legal/acceptance.json")
        super.init()

        guard [BrowserBrand.bundleIdentifier, MarketingLaunch.bundleIdentifier].contains(identifier) else {
            isAccepted = true
            return
        }
        do {
            documents = try Self.loadDocuments(bundle: bundle)
            let agreements = documents.filter { $0.id != "privacy" }
            isAccepted =
                LegalAgreementRecord.load(from: receiptURL)?.matches(agreements, bundleIdentifier: identifier) == true
        } catch {
            self.error = "loaf couldn’t load its included terms. reinstall an official copy before continuing."
        }
    }
    static func loadDocuments(bundle: Bundle = .main) throws -> [LegalDocument] {
        try [
            ("EULA", "terms", "end user license agreement"),
            ("LICENSE", "license", "proprietary license"),
            ("PRIVACY", "privacy", "privacy policy"),
        ].map { file, id, title in
            guard
                let url = bundle.url(forResource: file, withExtension: "txt", subdirectory: "Legal")
                    ?? bundle.url(forResource: file, withExtension: "txt")
            else { throw CocoaError(.fileNoSuchFile) }
            let body = try String(contentsOf: url, encoding: .utf8)
            guard !body.isEmpty, let range = body.range(of: "version "),
                let version = body[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).first
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return LegalDocument(id: id, title: title, version: String(version), body: body)
        }
    }
    func waitUntilAccepted() async -> Bool {
        if isAccepted { return true }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func showExistingWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    func present(completion: @escaping () -> Void) {
        if isAccepted {
            completion()
            return
        }
        if window != nil {
            showExistingWindow()
            return
        }
        self.completion = completion
        let view = LegalAcceptanceView(agreement: self)
        let window = LegalAcceptanceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "loaf"
        window.collectionBehavior = [.fullScreenNone]
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.minSize = NSSize(width: 520, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(NSSize(width: 680, height: 720))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    func agree() {
        guard !documents.isEmpty else { return }
        do {
            let receipt = LegalAgreementRecord(
                documents: documents.filter { $0.id != "privacy" },
                appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                bundleIdentifier: identifier)
            try receipt.save(to: receiptURL)
            isAccepted = true
            window?.close()
            window = nil
            let action = completion
            completion = nil
            waiters.forEach { $0.resume(returning: true) }
            waiters.removeAll()
            action?()
        } catch {
            self.error =
                "loaf couldn’t save your agreement on this Mac. check that your support folder is writable, then try again."
        }
    }
    func decline() {
        waiters.forEach { $0.resume(returning: false) }
        waiters.removeAll()
        NSApp.terminate(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isAccepted { return true }
        decline()
        return false
    }
}

@MainActor final class LegalAcceptanceWindow: NSWindow {
    override func toggleFullScreen(_ sender: Any?) {}
    override func zoom(_ sender: Any?) {}
    override func performZoom(_ sender: Any?) {}
}

struct LegalAcceptanceView: View {
    @ObservedObject var agreement: LegalAcceptance
    @State private var selection = "terms"
    private var document: LegalDocument? { agreement.documents.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image("loaf-lockup", bundle: agreement.resourceBundle).resizable().scaledToFit().frame(
                    width: 100, height: 36
                ).accessibilityLabel("loaf")
                Spacer()
                Text("before you browse").font(.title2.weight(.medium))
            }
            Text("loaf is free to use. please review the terms before continuing.")
                .font(.body).foregroundStyle(.secondary)
            Picker("document", selection: $selection) {
                Text("terms").tag("terms")
                Text("license").tag("license")
                Text("privacy").tag("privacy")
            }.pickerStyle(.segmented).labelsHidden()
            if let document {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(document.title).font(.title2.weight(.semibold))
                        ForEach(Array(document.body.components(separatedBy: "\n\n").enumerated()), id: \.offset) {
                            _, block in
                            if block.hasPrefix("## ") {
                                Text(String(block.dropFirst(3))).font(.headline).padding(.top, 10)
                            } else {
                                Text(
                                    (try? AttributedString(
                                        markdown: block,
                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                                        ?? AttributedString(block)
                                )
                                .font(.system(size: 13)).lineSpacing(4)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20).textSelection(.enabled)
                }.id(selection).background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
            } else {
                Spacer()
            }
            if let error = agreement.error {
                Text(error).font(.callout).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "choosing “agree and continue” accepts the end user license agreement and proprietary license above. the privacy policy explains how data is handled; optional permissions are requested separately."
                )
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("quit loaf") { agreement.decline() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("agree and continue") { agreement.agree() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(agreement.documents.count != 3)
                }.controlSize(.large)
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(
                \.openURL,
                OpenURLAction { url in
                    if url.host == "tryloaf.app",
                        let target = ["/terms": "terms", "/license": "license", "/privacy": "privacy"][url.path]
                    {
                        selection = target
                        return .handled
                    }
                    return .systemAction
                })
    }
}
