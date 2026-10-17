import Combine
import SwiftUI
import UniformTypeIdentifiers

extension BrowserWindowState {
    var canShowSideChat: Bool {
        preferences.aiFeaturesEnabled != false && selectedTab != nil && selectedTab?.isDisposed == false
    }
    var canSummarizePage: Bool {
        canShowSideChat && selectedTab?.page == .web && selectedTab?.url != nil
            && selectedTab?.existingSideChat?.session.searching != true
            && selectedTab?.existingSideChat?.capturing != true
    }
    func summarizePage() {
        guard canSummarizePage, let tab = selectedTab else { return }
        sideChatOpeningTask?.cancel()
        sideChatOpeningTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            defer { if !Task.isCancelled { self.sideChatOpeningTask = nil } }
            guard
                await self.application.sideChatAccess.unlock(
                    requiresPassword: self.preferences.requireSideChatPassword == true),
                !Task.isCancelled, self.selectedTab === tab, self.canSummarizePage
            else { return }
            self.sideChatVisible = true
            self.sideChatFocusID = UUID()
            tab.sideChat.summarize()
        }
    }
    func sideChatReservedWidth(in windowWidth: CGFloat) -> CGFloat {
        guard sideChatVisible, canShowSideChat else { return 0 }
        let available = windowWidth - pageLeadingInset - pageEdgeInset
        let pageMinimum: CGFloat = visibleSplit == nil ? 320 : 500
        guard available >= pageMinimum + 328 else { return 0 }
        return min(520, max(320, sideChatWidth), available - pageMinimum - 8) + 8
    }
    func toggleSideChat() {
        if sideChatVisible || sideChatOpeningTask != nil {
            closeSideChat()
            return
        }
        guard canShowSideChat, let tab = selectedTab else { return }
        sideChatOpeningTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            guard
                await self.application.sideChatAccess.unlock(
                    requiresPassword: self.preferences.requireSideChatPassword == true),
                !Task.isCancelled, self.selectedTab === tab, self.canShowSideChat
            else {
                if !Task.isCancelled { self.sideChatOpeningTask = nil }
                return
            }
            await tab.sideChat.captureSelection()
            guard !Task.isCancelled, self.selectedTab === tab, self.canShowSideChat else {
                if !Task.isCancelled { self.sideChatOpeningTask = nil }
                return
            }
            self.sideChatOpeningTask = nil
            self.sideChatVisible = true
            self.sideChatFocusID = UUID()
        }
    }
    func cancelSideChatOpening() {
        guard sideChatOpeningTask != nil else { return }
        sideChatOpeningTask?.cancel()
        sideChatOpeningTask = nil
        if application.sideChatAccess.authenticating { application.sideChatAccess.lock() }
    }
    func closeSideChat(_ tab: BrowserTab? = nil) {
        let target = tab ?? selectedTab
        guard target == nil || target?.store === self else { return }
        if tab == nil || target === selectedTab { cancelSideChatOpening() }
        objectWillChange.send()
        target?.existingSideChat?.saveChat()
        target?.sideChatVisible = false
        if target === selectedTab { focusPage() }
    }
}

struct SideChatToggle: View {
    @ObservedObject var store: BrowserStore
    var body: some View {
        if store.preferences.aiFeaturesEnabled != false {
            Button {
                store.toggleSideChat()
            } label: {
                GolzheimIcon(icon: .chat, size: 14)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(LoafButtonStyle()).focusable(false).disabled(!store.canShowSideChat)
                .help("side chat (⇧⌘L)").accessibilityLabel("toggle side chat")
                .accessibilityValue(store.sideChatVisible ? "open" : "closed")
                .contextMenu {
                    Button("summarize page") { store.summarizePage() }.disabled(!store.canSummarizePage)
                }
        }
    }
}

struct SideChatResizeHandle: View {
    @ObservedObject var store: BrowserStore
    @State private var startWidth: CGFloat?
    var body: some View {
        Rectangle().fill(.clear).frame(width: 8).contentShape(Rectangle())
            .overlay { Capsule().fill(.secondary.opacity(0.25)).frame(width: 2, height: 28) }
            .onHover { inside in if inside { NSCursor.resizeLeftRight.set() } }
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    if startWidth == nil { startWidth = store.sideChatWidth }
                    store.sideChatWidth = min(520, max(320, (startWidth ?? 380) - value.translation.width))
                }.onEnded { _ in startWidth = nil }
            )
            .accessibilityLabel("chat width")
            .accessibilityAdjustableAction { direction in
                store.sideChatWidth = min(520, max(320, store.sideChatWidth + (direction == .increment ? 20 : -20)))
            }
    }
}

@MainActor final class SideChatState: ObservableObject {
    let session: ChatSession
    private weak var tab: BrowserTab?
    @Published var attachedTabIDs: [UUID] = []
    @Published var images: [ChatImageAttachment] = []
    @Published var savedChatID = UUID()
    var attachedTabs: [BrowserTab] {
        guard let tab, let store = tab.store else { return [] }
        return store.application.windows.flatMap { $0.tabs }.filter {
            attachedTabIDs.contains($0.id) && $0.profileID == tab.profileID && $0.page == .web && !$0.isDisposed
        }
    }
    func attachImage() {
        guard session.acceptsImages else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            guard images.count + panel.urls.count <= ChatImageAttachment.maximumCount else {
                throw ChatGPTFailure.message("attach up to 4 images.")
            }
            let attachments = try panel.urls.map(ChatImageAttachment.read)
            guard (images + attachments).reduce(0, { $0 + $1.jpeg.count }) <= ChatImageAttachment.maximumTotalBytes
            else { throw ChatGPTFailure.message("attachments must total less than 20 MB.") }
            images += attachments
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func saveChat() -> Bool {
        guard let tab, let store = tab.store else { return session.turns.isEmpty }
        guard !store.profileFor(tab.profileID).privateMode else { return true }
        do {
            try store.application.chatArchive.save(id: savedChatID, profileID: tab.profileID, turns: session.turns)
            store.persistSoon()
            return true
        } catch {
            self.error = "chat couldn’t be saved. your conversation is still here. " + error.localizedDescription
            return false
        }
    }
    func restoreChat(_ chat: SavedChat) {
        guard clear() else { return }
        savedChatID = chat.id
        session.restore(chat.turns)
        includePage = false
    }
    @Published var includePage = true
    @Published var cloudSharingAllowed = false {
        didSet { permittedCloudProvider = cloudSharingAllowed ? session.provider : nil }
    }
    private var permittedCloudProvider: AIProvider?
    @Published private(set) var summaryPending = false
    @Published private(set) var capturing = false
    @Published private(set) var preview: TabChatContext?
    @Published private(set) var error: String?
    @Published private(set) var selection: String?
    private var selectionNavigation: UUID?
    private var selectionURL: URL?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var observations = Set<AnyCancellable>()
    private var disconnectError: String?

    init(tab: BrowserTab, account: ChatGPTAccount) {
        self.tab = tab
        includePage = tab.page == .web && tab.url != nil
        session = ChatSession(
            account: account,
            provider: { [weak tab] in tab?.store?.preferences.aiProvider },
            accounts: tab.store?.application.chatGPTAccounts,
            accountID: { [weak tab] in tab?.store?.preferences.sideChatAccountID },
            selectedModelID: { [weak tab] in tab?.store?.preferences.sideChatModelID },
            searchEngine: { [weak tab] in tab?.store?.preferences.aiSearchEngine ?? .google },
            claudeAccount: tab.store?.application.claudeAccount,
            enabled: { [weak tab] in
                guard let tab, !tab.isDisposed, let store = tab.store else { return false }
                return store.preferences.aiFeaturesEnabled != false
                    && store.application.sideChatAccess.allowsAccess(
                        requiresPassword: store.preferences.requireSideChatPassword == true)
            },
            isSideChat: true,
            capturePage: { [weak tab] target in
                guard let tab else { throw CancellationError() }
                return try await TabChatCaptureService.capture(tab, target: target)
            })
        account.$disconnecting.dropFirst().sink { [weak self] value in
            if self?.session.account === account && value { self?.providerDisconnected(.chatgpt) }
        }.store(
            in: &observations)
        account.$connected.dropFirst().sink { [weak self] value in
            if self?.session.account === account {
                if !value { self?.providerDisconnected(.chatgpt) } else { self?.providerReconnected(.chatgpt) }
            }
        }.store(
            in: &observations)
        tab.store?.application.chatGPTAccounts.didChange.sink { [weak self] in
            guard let self, self.session.provider == .chatgpt else { return }
            if !self.session.account.connected || self.session.account.disconnecting {
                self.providerDisconnected(.chatgpt)
            } else {
                self.providerReconnected(.chatgpt)
            }
        }.store(in: &observations)
        session.claudeAccount?.$connected.dropFirst().sink { [weak self] value in
            if !value { self?.providerDisconnected(.claude) } else { self?.providerReconnected(.claude) }
        }.store(in: &observations)
        session.$turns.dropFirst().debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveChat() }.store(in: &observations)
        tab.$url.dropFirst().removeDuplicates().sink { [weak self] _ in self?.pageChanged() }.store(in: &observations)
    }
    private func providerDisconnected(_ provider: AIProvider) {
        guard session.provider == provider else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        capturing = false
        summaryPending = false
        cloudSharingAllowed = false
        disconnectError = "\(provider.title) disconnected. reconnect in intelligence settings to send again."
        error = disconnectError
        saveChat()
    }
    private func providerReconnected(_ provider: AIProvider) {
        guard session.provider == provider else { return }
        if error == disconnectError { error = nil }
        disconnectError = nil
    }
    var hasEarlierAttachments: Bool {
        session.turns.contains {
            $0.context != nil || $0.capture != nil || !$0.attachedPages.isEmpty || !$0.images.isEmpty
        }
    }
    var needsCloudPermission: Bool {
        (summaryPending || includePage || !attachedTabIDs.isEmpty || !images.isEmpty || hasEarlierAttachments)
            && session.provider.usesCloud && (!cloudSharingAllowed || permittedCloudProvider != session.provider)
    }
    var canSubmit: Bool {
        !capturing && !session.searching && session.available && !needsCloudPermission
            && (summaryPending
                || (!session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && session.draft.utf8.count <= 8_000
                    && (images.isEmpty
                        || session.acceptsImages)))
    }
    func captureSelection() async {
        guard let tab else { return }
        let navigation = tab.navigationID
        let url = tab.url
        let value = await TabChatContextService.selection(from: tab)
        guard !tab.isDisposed, navigation == tab.navigationID, url == tab.url else { return }
        selection = value
        selectionNavigation = navigation
        selectionURL = url
    }
    func removeSelection() {
        selection = nil
        selectionNavigation = nil
        selectionURL = nil
    }
    func pageChanged() {
        preview = nil
        removeSelection()
    }
    func showPreview() { capture(send: false) }
    func useAutomatic() {
        guard !capturing, !session.searching else { return }
        cloudSharingAllowed = false
        session.useAutomatic()
    }
    func useProvider(_ provider: AIProvider) {
        guard !capturing, !session.searching else { return }
        if tab?.store?.preferences.aiProvider != provider {
            cloudSharingAllowed = false
            tab?.store?.preferences.sideChatModelID = nil
            tab?.store?.preferences.aiProvider = provider
            tab?.store?.persistSoon()
        }
        session.use(provider: provider)
    }
    func summarize() {
        guard !capturing, !session.searching, let tab, let store = tab.store,
            tab.page == .web, tab.url != nil, store.preferences.aiFeaturesEnabled != false,
            store.application.sideChatAccess.allowsAccess(
                requiresPassword: store.preferences.requireSideChatPassword == true)
        else { return }
        guard saveChat() else { return }
        let draft = session.draft
        session.clear()
        session.draft = draft
        savedChatID = UUID()
        preview = nil
        error = nil
        cloudSharingAllowed = false
        let provider = PageSummary.provider(preferences: store.preferences)
        session.use(
            provider: provider, model: PageSummary.model(preferences: store.preferences, provider: provider),
            accountID: store.preferences.summaryAccountID, accountRule: true)
        summaryPending = true
        if canSubmit { submit() }
    }
    func allowCloudSharing() {
        cloudSharingAllowed = true
        if summaryPending && canSubmit { submit() }
    }
    func submit() {
        guard canSubmit else { return }
        capture(send: true)
    }

    private func capture(send: Bool) {
        guard !capturing, let tab, !tab.isDisposed, let store = tab.store,
            store.application.sideChatAccess.allowsAccess(
                requiresPassword: store.preferences.requireSideChatPassword == true)
        else { return }
        error = nil
        let summary = summaryPending
        let question = summary ? "summarize this page" : session.draft
        let provider = session.provider
        let connectionID = session.account.connectionID
        let modelID = session.modelID
        let sharesPage = summary || includePage
        let extraTabs = summary ? [] : attachedTabs
        let attachedImages = summary ? [] : images
        let captureTarget = sharesPage ? TabChatTarget(tab) : nil
        if send && needsCloudPermission { return }
        generation = UUID()
        let current = generation
        capturing = true
        task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            defer {
                if generation == current {
                    capturing = false
                    task = nil
                }
            }
            do {
                let selected =
                    !summary && selectionNavigation == tab.navigationID && selectionURL == tab.url ? selection : nil
                let context = sharesPage ? try await TabChatContextService.capture(tab, selection: selected) : nil
                var contexts: [TabChatContext] = []
                for other in extraTabs { contexts.append(try await TabChatContextService.capture(other)) }
                try Task.checkCancellation()
                guard generation == current, !tab.isDisposed else { return }
                preview = context
                if send {
                    guard session.provider == provider, session.modelID == modelID,
                        provider != .chatgpt || session.account.connectionID == connectionID,
                        summary || includePage == sharesPage,
                        session.available, !needsCloudPermission,
                        tab.store?.preferences.aiFeaturesEnabled != false
                    else { throw ChatGPTFailure.message("chat settings changed while reading the page. send again.") }
                    let draft = session.draft
                    session.draft = question
                    session.submit(
                        context: context,
                        captureTarget: captureTarget, attachedPages: contexts, images: attachedImages, summary: summary)
                    summaryPending = false
                    if summary { session.draft = draft } else { images = [] }
                }
            } catch is CancellationError {} catch {
                if generation == current { self.error = error.localizedDescription }
            }
        }
    }
    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        capturing = false
        summaryPending = false
        session.stop()
    }
    @discardableResult func clear() -> Bool {
        guard saveChat() else { return false }
        discardCurrentChat()
        return true
    }
    func endSession() {
        saveChat()
        discardCurrentChat()
    }
    func discardCurrentChat() {
        savedChatID = UUID()
        attachedTabIDs = []
        images = []
        stop()
        session.clear()
        preview = nil
        error = nil
        cloudSharingAllowed = false
        summaryPending = false
        removeSelection()
    }
}

struct SideChatPanel: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: BrowserTab
    @ObservedObject var state: SideChatState
    @ObservedObject var session: ChatSession
    @ObservedObject var account: ChatGPTAccount
    @ObservedObject var claude: ClaudeAccount
    @ObservedObject var archive: ChatArchive
    @State private var focused = false
    @State private var previewVisible = false
    @State private var copiedTurnID: UUID?
    @State private var deletingChat: SavedChat?
    @State private var historyVisible = false
    @State private var followsAnswer = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownContext: TabChatContext?
    @State private var shownCapture: TabChatCapture?
    @Environment(\.colorScheme) private var scheme

    init?(store: BrowserStore, tab: BrowserTab) {
        guard !tab.isDisposed, tab.store === store, store.selectedTab === tab else { return nil }
        self.store = store
        self.tab = tab
        let chat = tab.sideChat
        state = chat
        session = chat.session
        account = chat.session.account
        claude = store.application.claudeAccount
        archive = store.application.chatArchive
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("ask loaf").font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Spacer()
                Button {
                    store.summarizePage()
                } label: {
                    Text("tl;dr").padding(.horizontal, 8).frame(height: 28)
                }
                .font(.system(size: 12)).help("summarize this page").accessibilityLabel("summarize page")
                .disabled(!store.canSummarizePage)
                if !store.profile.privateMode {
                    Button {
                        historyVisible.toggle()
                    } label: {
                        GolzheimIcon(icon: .history, size: 16, weight: 220).frame(width: 28, height: 28)
                    }
                    .popover(isPresented: $historyVisible, arrowEdge: .top) {
                        SavedChatHistory(
                            archive: archive, profileID: tab.profileID, selectedID: state.savedChatID,
                            open: { chat in
                                guard !tab.isDisposed, store.selectedTab === tab, chat.profileID == tab.profileID else {
                                    return
                                }
                                state.restoreChat(chat)
                                historyVisible = false
                                focused = true
                            },
                            delete: { chat in
                                historyVisible = false
                                deletingChat = chat
                            })
                    }
                    .accessibilityLabel("saved chats").help("saved chats")
                    .disabled(session.searching || state.capturing)
                }
                Button {
                    state.clear()
                    focused = true
                } label: {
                    GolzheimIcon(icon: .newChat, size: 16, weight: 220).frame(width: 28, height: 28)
                }
                .help("new chat").accessibilityLabel("new chat")
                Button {
                    store.closeSideChat(tab)
                } label: {
                    GolzheimIcon(icon: .close, size: 14, weight: 220).frame(width: 28, height: 28)
                }
                .help("close chat").accessibilityLabel("close chat")
            }.buttonStyle(ChatControlStyle()).foregroundStyle(.secondary)
                .padding(.leading, 20).padding(.trailing, 12).frame(height: 52)
            if let error = archive.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(
                    .bottom, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if session.turns.isEmpty {
                            if session.available {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("what would you like to know?")
                                        .font(.system(size: 23, weight: .medium)).tracking(-0.5)
                                    Text("ask about this page, or start with a question.")
                                        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
                                }.padding(.top, 32).padding(.bottom, 12)
                            } else if session.provider == .chatgpt {
                                ChatGPTConnectionView(account: account)
                            } else if session.provider == .claude {
                                ClaudeConnectionView(account: claude)
                            } else {
                                Text(
                                    AppleIntelligence.unavailableReason(for: session.provider)
                                        ?? "on-device answers are unavailable"
                                )
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(session.turns) { turn in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(turn.query).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 13).padding(.vertical, 10)
                                    .background(
                                        Color.primary.opacity(0.055),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    )
                                    .padding(.leading, 28)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                if let context = turn.context { PageContextReference(context: context) }
                                ForEach(turn.attachedPages) { PageContextReference(context: $0) }
                                ForEach(turn.images) { image in
                                    if let thumbnail = NSImage(data: image.jpeg) {
                                        Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxHeight: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel(image.name)
                                    }
                                }
                                if let capture = turn.capture {
                                    Button {
                                        shownCapture = capture
                                    } label: {
                                        Label {
                                            Text("screenshot · " + capture.title)
                                        } icon: {
                                            GolzheimIcon(icon: .camera, size: 11)
                                        }
                                        .lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }.buttonStyle(.plain).help("view the screenshot shared for this answer")
                                }
                                if let query = turn.webQuery {
                                    Label {
                                        Text(query)
                                    } icon: {
                                        GolzheimIcon(icon: .globe, size: 11)
                                    }.font(.system(size: 11)).foregroundStyle(
                                        .secondary)
                                }
                                if !turn.text.isEmpty { ChatGPTAnswerBody(turn: turn, store: store, compact: true) }
                                if let status = turn.pageReadStatus {
                                    Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                if let status = turn.captureStatus {
                                    Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                if !turn.complete && turn.error == nil {
                                    LiveAnswerProgress(turn: turn, tint: profileTint(store.profile))
                                }
                                if let error = turn.error {
                                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(
                                        .enabled)
                                    Button("retry") { session.retry(turn.id) }.disabled(!session.canRetry(turn.id))
                                }
                                if turn.complete && !turn.text.isEmpty {
                                    HStack(spacing: 4) {
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(
                                                ChatGPTAnswerContent.copyText(turn), forType: .string)
                                            copiedTurnID = turn.id
                                            Task { @MainActor in
                                                try? await Task.sleep(for: .seconds(2))
                                                if copiedTurnID == turn.id { copiedTurnID = nil }
                                            }
                                        } label: {
                                            GolzheimIcon(
                                                icon: copiedTurnID == turn.id ? .check : .copy, size: 14, weight: 220
                                            ).frame(width: 28, height: 28)
                                        }.help(copiedTurnID == turn.id ? "copied" : "copy answer")
                                            .accessibilityLabel("copy answer")
                                        Spacer()
                                        if let model = turn.modelName {
                                            Text(model).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                    }.buttonStyle(ChatControlStyle()).foregroundStyle(.secondary)
                                }
                            }.id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 48)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay(alignment: .bottom) {
                    ChatTranscriptEdge(surface: scheme == .dark ? Color(white: 0.10) : Color(white: 0.985))
                        .frame(height: 48)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 80
                } action: { _, nearBottom in
                    followsAnswer = nearBottom
                }
                .onChange(of: session.turns.last?.id) { _, id in
                    followsAnswer = true
                    if let id { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: session.turns.last?.text) { _, _ in
                    if followsAnswer { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
            }
            composer.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
        }
        .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.985))
        .environment(
            \.openURL,
            OpenURLAction { url in
                if let id = ChatGPTCitation.contextID(url) {
                    if let capture = session.turns.compactMap(\.capture).first(where: { $0.id == id }) {
                        shownCapture = capture
                    } else if let context = session.turns.flatMap({ ($0.context.map { [$0] } ?? []) + $0.attachedPages }
                    ).first(where: { $0.id == id }) {
                        shownContext = context
                    } else {
                        return .discarded
                    }
                    return .handled
                }
                if url == ChatGPTProtocol.usageURL {
                    NSWorkspace.shared.open(url)
                    return .handled
                }
                guard ChatGPTProtocol.safeSourceURL(url.absoluteString) != nil else { return .discarded }
                _ = store.newTab(url: url, showOmnibar: false, activate: false)
                return .handled
            }
        )
        .popover(item: $shownContext) { context in
            PageContextPreview(context: context).padding(16).frame(width: 340)
        }
        .popover(item: $shownCapture) { capture in
            PageCapturePreview(capture: capture).padding(16).frame(width: 380)
        }
        .destructiveConfirmationDialog(
            "delete saved chat?",
            isPresented: Binding(get: { deletingChat != nil }, set: { if !$0 { deletingChat = nil } }),
            titleVisibility: .visible
        ) {
            Button("delete chat", role: .destructive) {
                guard let chat = deletingChat else { return }
                do { try store.application.deleteSavedChat(chat.id) } catch { store.error = error.localizedDescription }
                deletingChat = nil
            }
            Button("cancel", role: .cancel) { deletingChat = nil }
        } message: {
            Text("This deletes \(deletingChat?.title ?? "this chat") from this Mac. It cannot be undone.")
        }
        .onAppear {
            focused = true
            if account.connected && account.models.isEmpty { account.refreshCatalog() }
        }
        .onChange(of: store.sideChatFocusID) { _, _ in focused = true }
        .onChange(of: tab.navigationID) { _, _ in state.pageChanged() }
        .onChange(of: tab.url) { _, _ in state.pageChanged() }
        .onExitCommand { store.closeSideChat(tab) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChatConnectionRecovery(session: session, store: store)
            if let request = session.toolRequest {
                ChatToolApprovalView(request: request) { session.decideTool($0, requestID: request.id) }
            }
            if let request = session.pageReadRequest {
                pageReadApproval(request)
            }
            if let request = session.pageCaptureRequest {
                PageCaptureApprovalView(request: request) { session.decideCapture($0, requestID: request.id) }
            }
            ChatComposerSurface(focused: focused) {
                VStack(alignment: .leading, spacing: 10) {
                    if state.includePage || !state.attachedTabs.isEmpty || !state.images.isEmpty {
                        ChatAttachmentList(
                            count: (state.includePage ? 1 : 0) + state.attachedTabs.count + state.images.count
                        ) {
                            VStack(spacing: 6) {
                                if state.includePage {
                                    ChatAttachmentRow(
                                        title: tab.sidebarTitle,
                                        detail: attachmentDetail(for: tab, selection: state.selection != nil),
                                        icon: state.selection == nil ? .document : .quote,
                                        preview: {
                                            state.showPreview()
                                            previewVisible = true
                                        },
                                        removeLabel: state.selection == nil
                                            ? "remove attached page" : "remove selection",
                                        removeHelp: state.selection == nil
                                            ? "remove page" : "use the page instead of the selection",
                                        canRemove: !state.capturing && !session.searching
                                    ) {
                                        if state.selection != nil {
                                            state.removeSelection()
                                        } else {
                                            state.includePage = false
                                        }
                                    }
                                    .popover(isPresented: $previewVisible) { preview }
                                }
                                ForEach(state.attachedTabs) { attached in
                                    ChatAttachmentRow(
                                        title: attached.sidebarTitle,
                                        detail: attachmentDetail(for: attached),
                                        icon: .document,
                                        removeLabel: "remove " + attached.sidebarTitle,
                                        canRemove: !state.capturing && !session.searching
                                    ) {
                                        state.attachedTabIDs.removeAll { $0 == attached.id }
                                    }
                                }
                                ForEach(state.images) { image in
                                    ChatAttachmentRow(
                                        title: image.name,
                                        detail: "image",
                                        icon: .document,
                                        thumbnail: NSImage(data: image.jpeg),
                                        removeLabel: "remove " + image.name,
                                        canRemove: !state.capturing && !session.searching
                                    ) {
                                        state.images.removeAll { $0.id == image.id }
                                    }
                                }
                            }
                        }
                    }
                    ChatDraftEditor(
                        text: $session.draft,
                        placeholder: session.turns.isEmpty ? "ask anything…" : "ask a follow-up…",
                        focused: Binding(get: { focused }, set: { focused = $0 }),
                        enabled: !state.capturing && !session.searching
                    ) { state.submit() }
                    HStack(spacing: 4) {
                        Menu {
                            Toggle(
                                state.selection == nil ? "include this page" : "include selected text",
                                isOn: $state.includePage
                            )
                            .disabled(tab.page != .web || tab.url == nil)
                            Menu("attach another tab") {
                                ForEach(
                                    store.tabs.filter {
                                        $0.page == .web && $0.url != nil && $0 !== tab
                                            && !state.attachedTabIDs.contains($0.id)
                                    }
                                ) { other in
                                    Button(other.sidebarTitle) {
                                        if state.attachedTabIDs.count < 5 { state.attachedTabIDs.append(other.id) }
                                    }
                                }
                            }.disabled(state.attachedTabIDs.count >= 5)
                            Button("attach images…") { state.attachImage() }
                                .disabled(
                                    !session.acceptsImages
                                        || state.images.count >= 4)
                            Button("reset web permissions") { session.revokeWebTools() }
                            if session.allowsAllPageReads {
                                Button("reset page-read permission") { session.revokePageReads() }
                            }
                            if session.allowsAllCaptures {
                                Button("reset screenshot permission") { session.revokeCaptures() }
                            }
                        } label: {
                            GolzheimIcon(icon: .plus, size: 17, weight: 220).foregroundStyle(.secondary)
                                .frame(width: 32, height: 32).contentShape(Rectangle())
                        }.menuStyle(.button).buttonStyle(ChatControlStyle()).menuIndicator(.hidden).fixedSize()
                            .disabled(state.capturing || session.searching)
                            .help("attach tabs or up to 4 images · 10 MB per file, 20 MB total").accessibilityLabel(
                                "add context")
                        Spacer(minLength: 2)
                        modelSelector
                        ChatSendButton(busy: state.capturing || session.searching, canSend: state.canSubmit) {
                            if state.capturing || session.searching { state.stop() } else { state.submit() }
                        }
                    }
                }
            }
            if state.summaryPending {
                HStack {
                    Text("page summary ready").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("cancel summary") { state.stop() }.buttonStyle(ChatControlStyle()).font(.system(size: 11))
                }
            }
            if state.needsCloudPermission {
                Button {
                    state.allowCloudSharing()
                    focused = true
                } label: {
                    Text("allow sharing this chat’s attachments").padding(.horizontal, 8).padding(.vertical, 6)
                }.buttonStyle(ChatControlStyle(selected: true)).font(.system(size: 11)).foregroundStyle(.secondary)
                Button {
                    state.showPreview()
                    previewVisible = true
                } label: {
                    HStack(spacing: 5) {
                        GolzheimIcon(icon: .lock, size: 10)
                        Text("review chat attachments").font(.system(size: 11))
                        GolzheimIcon(icon: .disclosureDown, size: 8).rotationEffect(.degrees(-90))
                    }.padding(.horizontal, 5).padding(.vertical, 3)
                }.buttonStyle(ChatControlStyle()).foregroundStyle(.secondary)
            }
            if !state.includePage && state.hasEarlierAttachments {
                Text("earlier page context remains in this chat. start a new chat to clear it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            if let error = state.error { Text(error).font(.system(size: 12)).foregroundStyle(.secondary) }
            if state.capturing { Text("reading page…").font(.system(size: 10)).foregroundStyle(.secondary) }
            if session.draft.utf8.count > 8_000 {
                Text("shorten your question to continue").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
    private func attachmentDetail(for tab: BrowserTab, selection: Bool = false) -> String {
        let kind = selection ? "selected text" : "attached tab"
        guard let host = tab.url?.host(), !host.isEmpty else { return kind }
        return kind + " · " + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }
    private func pageReadApproval(_ request: PageReadRequest) -> some View {
        PageReadApprovalView(request: request) { session.decidePageReads($0, requestID: request.id) }
    }
    private var modelSelector: some View {
        ChatModelMenu(
            account: account, claude: claude, provider: session.provider, modelID: session.modelID,
            changeProvider: changeProvider, automatic: session.automatic,
            selectAutomatic: {
                store.preferences.aiProvider = nil
                store.preferences.sideChatModelID = nil
                store.persistSoon()
                state.useAutomatic()
            },
            changeModel: { provider, id in
                state.useProvider(provider)
                store.preferences.sideChatModelID = id
                store.persistSoon()
                session.use(provider: provider, model: id)
            }
        )
        .frame(maxWidth: 170, alignment: .trailing).layoutPriority(-1).disabled(state.capturing || session.searching)
    }
    private func changeProvider(_ value: AIProvider) {
        state.useProvider(value)
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("page context").font(.headline)
            Text(
                session.provider.usesCloud
                    ? "page text and questions go to \(session.provider.serviceName) when you send. chat is saved encrypted on this Mac; private chats stay in memory."
                    : "page text is summarized on this Mac."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            if let context = state.preview {
                PageContextPreview(context: context)
                if state.summaryPending {
                    HStack {
                        Text("page summary ready").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("cancel summary") { state.stop() }.buttonStyle(ChatControlStyle()).font(
                            .system(size: 11))
                    }
                }
                if state.needsCloudPermission {
                    Button("allow page sharing for this chat") {
                        state.allowCloudSharing()
                        previewVisible = false
                        focused = true
                    }
                }
            } else if let error = state.error {
                Text(error).font(.system(size: 12))
            } else if !state.includePage {
                Text("the current page is excluded.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            if state.hasEarlierAttachments {
                Text(
                    "earlier pages and images remain attached to this conversation and are included in follow-up questions."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if state.needsCloudPermission && state.preview == nil {
                Button("allow sharing this chat’s attachments") {
                    state.allowCloudSharing()
                    previewVisible = false
                    focused = true
                }
            }
        }.padding(16).frame(width: 340)
    }
}

struct PageCapturePreview: View {
    let capture: TabChatCapture
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(capture.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Text("visible viewport · " + capture.capturedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let image = NSImage(data: capture.jpeg) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280)
            }
        }
    }
}

struct PageCaptureApprovalView: View {
    let request: PageCaptureRequest
    let decide: (PageReadDecision) -> Void
    @State private var previewVisible = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("allow this screenshot to be shared?").font(.system(size: 12, weight: .medium))
            Text(request.reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            if let image = NSImage(data: request.capture.jpeg) {
                Button {
                    previewVisible = true
                } label: {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 100)
                }.buttonStyle(.plain).help("preview screenshot before sharing")
                    .popover(isPresented: $previewVisible) {
                        PageCapturePreview(capture: request.capture).padding(16).frame(width: 380)
                    }
            }
            Text(
                "\(request.capture.title) · visible viewport only. allow all permits requested screenshots for this chat."
            )
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
            ChatApprovalActions(decide: decide)
        }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)))
    }
}

struct PageContextReference: View {
    let context: TabChatContext
    @State private var visible = false
    var body: some View {
        Button {
            visible = true
        } label: {
            Label {
                Text((context.selection == nil ? "page · " : "selection · ") + context.title)
            } icon: {
                GolzheimIcon(icon: context.selection == nil ? .document : .quote, size: 11)
            }
            .lineLimit(1)
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }.buttonStyle(.plain).help("view the captured page used for this answer")
            .popover(isPresented: $visible) { PageContextPreview(context: context).padding(16).frame(width: 340) }
    }
}
struct PageContextPreview: View {
    let context: TabChatContext
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(context.title).font(.system(size: 13, weight: .medium))
            Text(
                context.selection != nil
                    ? "selected excerpt · captured \(context.capturedAt.formatted(date: .omitted, time: .shortened))"
                    : context.truncated
                        ? "partial page · captured \(context.capturedAt.formatted(date: .omitted, time: .shortened))"
                        : "loaded page · captured \(context.capturedAt.formatted(date: .omitted, time: .shortened))"
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                Text(context.text)
                    .font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
        }
    }
}

struct PageReadApprovalView: View {
    let request: PageReadRequest
    let decide: (PageReadDecision) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("allow loaf to read these pages?").font(.system(size: 12, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(request.sources, id: \.url) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title).font(.system(size: 11)).lineLimit(1)
                            Text(source.url.absoluteString).font(.system(size: 10)).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(130, CGFloat(request.sources.count) * 36))
            Text(
                "readable text is shared with the selected model. allow all applies to this chat; don’t allow uses snippets."
            )
            .font(.system(size: 10)).foregroundStyle(.secondary)
            ChatApprovalActions(decide: decide)
        }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)))
    }
}
