import SwiftUI

struct ChatGPTConnectionView: View {
    @ObservedObject var account: ChatGPTAccount
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if account.connected {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.email ?? "ChatGPT account").font(.system(size: 13, weight: .medium)).textSelection(
                            .enabled)
                        Text("using ChatGPT plan").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SettingsActionButton("disconnect", busy: account.disconnecting, disabled: account.connecting) {
                        account.disconnect()
                    }
                }
                ChatModelPicker(account: account).controlSize(.small)
                HStack(spacing: 12) {
                    Link("manage usage", destination: ChatGPTProtocol.usageURL)
                    SettingsActionButton(
                        "refresh models", busy: account.checkingModels, disabled: account.disconnecting
                    ) {
                        account.refreshCatalog()
                    }
                    if !account.checkingModels && !account.models.isEmpty {
                        Text("\(account.models.count) models").foregroundStyle(.secondary)
                    }
                }.font(.caption)
            } else {
                Text("use your ChatGPT plan for answers and web sources").foregroundStyle(.secondary)
            }
            if account.connecting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("finish connecting in your browser").foregroundStyle(.secondary)
                    Spacer()
                    Button("cancel") { account.cancelConnection() }
                }
            } else {
                Button(account.connected ? "reconnect with ChatGPT" : "Continue with ChatGPT") { account.connect() }
                    .disabled(account.disconnecting)
            }
            if let error = account.error {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !account.connected { Link("manage usage", destination: ChatGPTProtocol.usageURL).font(.caption) }
            }
            Text(
                "queries, follow-ups, and any page context you allow go to OpenAI when submitted. if built-in web search is unavailable, loaf fetches web results from Google, or DuckDuckGo if Google is unavailable, and sends those excerpts to OpenAI. Plus usage is shared with Codex and other connected apps. saved chats are encrypted on this Mac; optional iCloud sync omits image attachments."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .alert("you’re using your ChatGPT plan", isPresented: $account.showPlanWelcome) {
            Button("got it") { account.dismissWelcome() }
        } message: {
            Text(
                "eligible searches in loaf use your ChatGPT plan or available credits. manage access and limits in ChatGPT settings."
            )
        }
    }
}

struct ChatGPTSearchView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var search: ChatGPTSearch
    @ObservedObject var account: ChatGPTAccount
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focused = false
    @State private var connectionVisible = false
    @State private var expandedSources = Set<UUID>()
    @State private var editingTurnID: UUID?
    @State private var editedQuery = ""
    @State private var copiedTurnID: UUID?
    @State private var followsAnswer = true
    @FocusState private var editingFocused: Bool

    private var surface: Color { scheme == .dark ? Color(white: 0.09) : Color(white: 0.985) }
    private var fieldSurface: Color { scheme == .dark ? Color(white: 0.13) : .white }
    private var canSubmit: Bool {
        editingTurnID == nil && search.available && !search.searching
            && !search.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && search.draft.utf8.count <= 8_000
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 32) {
                            if account.connected && connectionVisible {
                                ChatGPTConnectionView(account: account)
                                    .padding(20).background(fieldSurface, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
                            }
                            if search.turns.isEmpty {
                                introduction.frame(maxWidth: .infinity)
                                    .frame(minHeight: max(260, geometry.size.height - 240))
                            } else {
                                ForEach(Array(search.turns.enumerated()), id: \.element.id) { index, turn in
                                    if index > 0 { Divider().padding(.vertical, 4) }
                                    answer(turn, first: index == 0).id(turn.id)
                                }
                            }
                            Color.clear.frame(height: 1).id("chat-bottom")
                        }
                        .padding(.bottom, search.turns.isEmpty ? 0 : 24)
                        .padding(.vertical, search.turns.isEmpty ? 12 : 28)
                        .frame(maxWidth: 760)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .overlay(alignment: .bottom) { ChatTranscriptEdge(surface: surface).frame(height: 56) }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentSize.height - geometry.visibleRect.maxY < 90
                    } action: { _, nearBottom in
                        followsAnswer = nearBottom
                    }
                    .onChange(of: search.turns.last?.id) { _, id in
                        followsAnswer = true
                        if let id {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                    .onChange(of: search.turns.last?.text) { _, _ in
                        if followsAnswer { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    }
                }
                composer.frame(maxWidth: 760).padding(.horizontal, 32)
                    .padding(.top, 10).padding(.bottom, 14).frame(maxWidth: .infinity)
            }
            .background(surface)
        }
        .environment(
            \.openURL,
            OpenURLAction { url in
                if url == ChatGPTProtocol.usageURL {
                    NSWorkspace.shared.open(url)
                    return .handled
                }
                guard ChatGPTProtocol.safeSourceURL(url.absoluteString) != nil else { return .discarded }
                openSource(url)
                return .handled
            }
        )
        .onAppear {
            focused = search.turns.isEmpty
            if account.connected { account.refreshCatalog() }
        }
        .onChange(of: account.connected) { _, connected in
            if connected {
                connectionVisible = false
                focused = true
            }
        }
        .onExitCommand { focused = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            GolzheimIcon(icon: .search, size: 16).foregroundStyle(.secondary)
            Text("ask loaf").font(.system(size: 13, weight: .medium))
            Spacer()
            if account.connected {
                Button {
                    connectionVisible.toggle()
                } label: {
                    GolzheimIcon(icon: .profile, size: 14).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(connectionVisible ? .primary : .secondary)
                .help("ChatGPT account").accessibilityLabel("ChatGPT account")
            }
            if !search.turns.isEmpty {
                if !store.profile.privateMode {
                    Button("save to chats") {
                        do {
                            try store.application.chatArchive.save(
                                id: search.archiveID, profileID: store.selectedProfileID, turns: search.turns)
                            store.feedback.show(.copied, icon: .check, text: "saved to chats")
                            store.persistSoon()
                        } catch { store.error = error.localizedDescription }
                    }.buttonStyle(ChatControlStyle()).font(.system(size: 11))
                }
                Button {
                    search.clear()
                    expandedSources = []
                    focused = true
                } label: {
                    GolzheimIcon(icon: .edit, size: 16, weight: 220).frame(width: 28, height: 28)
                }.buttonStyle(ChatControlStyle()).help("start a new search").accessibilityLabel("new search")
            }
        }
        .padding(.horizontal, 28).frame(height: 48)
        .overlay(alignment: .bottom) { Color.primary.opacity(0.06).frame(height: 1) }
    }

    private var introduction: some View {
        VStack(spacing: 20) {
            GolzheimIcon(icon: .search, size: 26)
                .foregroundStyle(.secondary).frame(width: 60, height: 60)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("search, with an answer").font(.system(size: 32, weight: .medium)).tracking(-0.8)
                Text(
                    search.provider == .chatgpt
                        ? "web answers, with the sources attached."
                        : search.provider == .claude
                            ? "answers from Claude, with the sources attached." : "web sources, summarized on this Mac."
                )
                .font(.system(size: 14)).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center)
            if search.available {
                HStack(spacing: 10) {
                    suggestion("how do passkeys work?")
                    suggestion("what’s new in macOS?")
                }.padding(.top, 8)
            } else if search.provider == .claude {
                ClaudeConnectionView(account: store.application.claudeAccount).frame(maxWidth: 460)
            } else if search.provider != .chatgpt {
                Text(AppleIntelligence.unavailableReason(for: search.provider) ?? "Apple Intelligence is unavailable")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: 400)
            } else {
                ChatGPTConnectionView(account: account).frame(maxWidth: 460)
                    .padding(20).background(fieldSurface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
                    .padding(.top, 8)
            }
        }.padding(.vertical, 20)
    }

    private func suggestion(_ query: String) -> some View {
        Button {
            search.draft = query
            focused = true
        } label: {
            HStack(spacing: 8) {
                Text(query).font(.system(size: 12))
                GolzheimIcon(icon: .external, size: 10).scaleEffect(x: -1, y: 1).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(fieldSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }.buttonStyle(.plain).help("use this question")
    }

    private func answer(_ turn: ChatGPTSearchTurn, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if editingTurnID == turn.id {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("edit your question", text: $editedQuery, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: first ? 28 : 23, weight: .medium))
                        .lineLimit(2...8).focused($editingFocused)
                    HStack(spacing: 12) {
                        Button("cancel") { editingTurnID = nil }.keyboardShortcut(.escape, modifiers: [])
                        Button("save & submit") {
                            let query = editedQuery
                            editingTurnID = nil
                            search.edit(turn.id, query: query)
                        }.keyboardShortcut(.return, modifiers: .command)
                            .disabled(
                                !search.canEdit(turn.id)
                                    || editedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || editedQuery.utf8.count > 8_000)
                    }.font(.system(size: 12))
                }.padding(14).background(fieldSurface, in: RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Text(turn.query).font(.system(size: first ? 28 : 23, weight: .medium))
                        .tracking(first ? -0.6 : -0.3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        editedQuery = turn.query
                        editingTurnID = turn.id
                        editingFocused = true
                    } label: {
                        GolzheimIcon(icon: .edit, size: 12)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, first ? 9 : 6)
                    .help("edit question").accessibilityLabel("edit question")
                    .disabled(!search.canEdit(turn.id))
                }
            }
            let branch = search.branchPosition(turn.id)
            if branch.count > 1 {
                HStack(spacing: 10) {
                    Button {
                        editingTurnID = nil
                        search.selectBranch(turn.id, offset: -1)
                    } label: {
                        GolzheimIcon(icon: .back, size: 10)
                    }
                    .disabled(search.searching || branch.index == 0).help("previous question version")
                    Text("\(branch.index + 1) / \(branch.count)").monospacedDigit()
                    Button {
                        editingTurnID = nil
                        search.selectBranch(turn.id, offset: 1)
                    } label: {
                        GolzheimIcon(icon: .forward, size: 10)
                    }
                    .disabled(search.searching || branch.index + 1 == branch.count).help("next question version")
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                GolzheimIcon(icon: .chat, size: 12)
                Text("quick answer").font(.system(size: 12, weight: .medium))
                Text("· " + (turn.modelName ?? turn.provider.title))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.foregroundStyle(.secondary)
            if !turn.text.isEmpty {
                ChatGPTAnswerBody(turn: turn, store: store)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
            if search.searching && turn.id == search.activeTurnID {
                LiveAnswerProgress(turn: turn, tint: profileTint(store.profile)).transition(.opacity)
            }
            if turn.provider == .chatgpt && turn.externalSources {
                Text(
                    turn.complete && turn.citations.isEmpty
                        ? "web sources · no source citations returned" : "web sources retrieved by loaf"
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if turn.provider != .chatgpt && !turn.sources.isEmpty {
                Text(
                    turn.provider == .onDevice ? "generated on this Mac · web sources" : "web sources retrieved by loaf"
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !turn.citations.isEmpty { sources(turn).transition(.opacity) }
            if turn.complete && !turn.text.isEmpty {
                HStack(spacing: 16) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ChatGPTAnswerContent.copyText(turn), forType: .string)
                        copiedTurnID = turn.id
                        store.feedback.show(.copied, icon: .check, text: "answer copied")
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            if copiedTurnID == turn.id { copiedTurnID = nil }
                        }
                    } label: {
                        Label {
                            Text(copiedTurnID == turn.id ? "copied" : "copy answer")
                        } icon: {
                            GolzheimIcon(icon: copiedTurnID == turn.id ? .check : .copy, size: 12)
                        }
                    }.accessibilityLabel("copy answer")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                    .buttonStyle(AnswerControlStyle()).transition(.opacity)
            }
            if let error = turn.error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack(spacing: 16) {
                        Button("retry") {
                            search.retry(turn.id)
                        }
                        .disabled(!search.canRetry(turn.id))
                        if turn.provider == .chatgpt { Link("manage usage", destination: ChatGPTProtocol.usageURL) }
                        if let url = store.resolveAddress(turn.query) {
                            Button("open in search engine") { openSource(url) }
                        }
                    }
                }.font(.system(size: 12)).padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: turn.text.isEmpty)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: turn.complete)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: expandedSources.contains(turn.id))
    }

    private func sources(_ turn: ChatGPTSearchTurn) -> some View {
        var seen = Set<URL>()
        let all = Array(turn.citations.enumerated()).filter { seen.insert($0.element.url).inserted }
        let visible = expandedSources.contains(turn.id) ? all : Array(all.prefix(4))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("sources").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if all.count > 4 {
                    Button(expandedSources.contains(turn.id) ? "show fewer" : "show all \(all.count)") {
                        if expandedSources.contains(turn.id) {
                            expandedSources.remove(turn.id)
                        } else {
                            expandedSources.insert(turn.id)
                        }
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(visible, id: \.element.id) { index, citation in
                    Button {
                        openSource(citation.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                ChatGPTSourceIcon(url: citation.url, store: store)
                                Text(ChatGPTAnswerContent.siteName(citation.url))
                                    .font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 2)
                                GolzheimIcon(icon: .external, size: 9)
                            }.foregroundStyle(.secondary)
                            Text(citation.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12).frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                        .background(fieldSurface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(AnswerControlStyle(cornerRadius: 10)).help(citation.url.absoluteString)
                        .accessibilityLabel("source \(index + 1): \(citation.title)")
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            ChatConnectionRecovery(session: search, store: store)
            ChatComposerSurface(focused: focused) {
                VStack(alignment: .leading, spacing: 10) {
                    if let request = search.toolRequest {
                        ChatToolApprovalView(request: request) { search.decideTool($0, requestID: request.id) }
                    }
                    if let request = search.pageReadRequest {
                        PageReadApprovalView(request: request) { search.decidePageReads($0, requestID: request.id) }
                    }
                    ChatDraftEditor(
                        text: $search.draft,
                        placeholder: search.turns.isEmpty ? "search the web…" : "ask a follow-up…",
                        focused: Binding(get: { focused }, set: { focused = $0 }),
                        enabled: editingTurnID == nil
                    ) { search.submit() }
                    HStack(spacing: 6) {
                        Label {
                            Text("web search")
                        } icon: {
                            GolzheimIcon(icon: .globe, size: 11)
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 9).frame(height: 28)
                        .background(Color.primary.opacity(0.045), in: Capsule())
                        Spacer(minLength: 8)
                        ChatModelMenu(
                            account: account, claude: store.application.claudeAccount, provider: search.provider,
                            modelID: search.modelID
                        ) { value in
                            if value != search.provider {
                                search.clear()
                                store.preferences.aiProvider = value
                                store.persistSoon()
                            }
                            search.use(provider: value)
                        }.frame(maxWidth: 240).disabled(search.searching)
                        ChatSendButton(busy: search.searching, canSend: canSubmit) {
                            if search.searching {
                                search.stop()
                                focused = true
                            } else {
                                search.submit()
                            }
                        }
                    }
                }
            }
            HStack {
                Text(
                    search.draft.utf8.count > 8_000
                        ? "shorten your question to continue"
                        : search.provider == .claude
                            ? "using Anthropic API"
                            : search.provider != .chatgpt
                                ? "generated on this Mac"
                                : account.connected ? "using ChatGPT plan" : "connect ChatGPT to search")
                Spacer()
                if search.provider == .chatgpt && account.connected {
                    Link("manage usage", destination: ChatGPTProtocol.usageURL)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 6)
        }
    }

    private func openSource(_ url: URL) {
        guard ChatGPTProtocol.safeSourceURL(url.absoluteString) != nil else { return }
        _ = store.newTab(url: url, showOmnibar: false)
    }
    static func citedText(_ turn: ChatGPTSearchTurn) -> AttributedString {
        ChatGPTAnswerContent.attributed(turn.text, start: 0, citations: turn.citations)
    }
}

private struct AnswerControlStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(hovered ? 0.04 : 0), in: RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
