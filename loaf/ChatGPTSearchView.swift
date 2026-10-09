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
                    Button(account.disconnecting ? "disconnecting…" : "disconnect") { account.disconnect() }.disabled(
                        account.disconnecting || account.connecting)
                }
                HStack(spacing: 12) {
                    Link("manage usage", destination: ChatGPTProtocol.usageURL)
                    Button("check Luna access") { account.refreshCatalog() }.disabled(
                        account.checkingModels || account.disconnecting)
                    if account.checkingModels {
                        ProgressView().controlSize(.mini)
                    } else if account.lunaAvailable {
                        Text("\(account.lunaName) available").foregroundStyle(.secondary)
                    }
                }.font(.caption)
            } else {
                Text("use your ChatGPT plan for answers with Luna and web sources").foregroundStyle(.secondary)
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
                "queries and follow-ups go to OpenAI when submitted. if built-in web search is unavailable, loaf fetches Google results for your question and sends those excerpts to OpenAI. Plus usage is shared with Codex and other connected apps. answers stay in memory on this Mac."
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
    @FocusState private var focused: Bool
    @State private var connectionVisible = false
    @State private var expandedSources = Set<UUID>()
    @State private var editingTurnID: UUID?
    @State private var editedQuery = ""
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
                        }
                        .padding(.vertical, search.turns.isEmpty ? 12 : 28)
                        .frame(maxWidth: 760)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: search.activeTurnID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .top) }
                    }
                    .onChange(of: search.turns.last?.id) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .top) }
                    }
                }
                composer.frame(maxWidth: 680).padding(.horizontal, 32)
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
            Picker(
                "AI provider",
                selection: Binding(
                    get: { search.provider },
                    set: { value in
                        search.clear()
                        store.preferences.aiProvider = value
                        store.persistSoon()
                    })
            ) { ForEach(AppleIntelligence.visibleProviders, id: \.self) { Text($0.title).tag($0) } }
            .labelsHidden().fixedSize().controlSize(.small)
            if search.provider == .chatgpt {
                Text(account.lunaName).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if account.connected {
                Button {
                    connectionVisible.toggle()
                } label: {
                    Image(systemName: "person.crop.circle").font(.system(size: 16)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(connectionVisible ? .primary : .secondary)
                .help("ChatGPT account").accessibilityLabel("ChatGPT account")
            }
            if !search.turns.isEmpty {
                Button {
                    search.clear()
                    expandedSources = []
                    focused = true
                } label: {
                    Label("new search", systemImage: "square.and.pencil").font(.system(size: 11))
                }.buttonStyle(.plain).padding(.leading, 6).help("start a new search")
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
                        : "web sources, summarized on this Mac."
                )
                .font(.system(size: 14)).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center)
            if search.available {
                HStack(spacing: 10) {
                    suggestion("how do passkeys work?")
                    suggestion("what’s new in macOS?")
                }.padding(.top, 8)
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
                Image(systemName: "arrow.up.left").font(.system(size: 10)).foregroundStyle(.tertiary)
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
                        Image(systemName: "pencil").font(.system(size: 12))
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
                        Image(systemName: "chevron.left")
                    }
                    .disabled(search.searching || branch.index == 0).help("previous question version")
                    Text("\(branch.index + 1) / \(branch.count)").monospacedDigit()
                    Button {
                        editingTurnID = nil
                        search.selectBranch(turn.id, offset: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(search.searching || branch.index + 1 == branch.count).help("next question version")
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12))
                Text("AI overview").font(.system(size: 12, weight: .medium))
                Text("· " + (turn.provider == .chatgpt ? account.lunaName : "Apple Intelligence"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.foregroundStyle(.secondary)
            if !turn.text.isEmpty {
                ChatGPTAnswerBody(turn: turn, store: store)
            }
            if search.searching && turn.id == search.activeTurnID {
                LiveAnswerProgress(turn: turn, tint: profileTint(store.profile))
            }
            if turn.provider == .chatgpt && turn.externalSources {
                Text(
                    turn.complete && turn.citations.isEmpty
                        ? "web results from Google · no source citations returned" : "web results from Google"
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if turn.provider != .chatgpt {
                Text("generated on this Mac · sources from Google")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !turn.citations.isEmpty { sources(turn) }
            if let error = turn.error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack(spacing: 16) {
                        Button("retry") {
                            search.retry(turn.id)
                        }
                        .disabled(!search.canRetry(turn.id))
                        if turn.provider == .chatgpt { Link("manage usage", destination: ChatGPTProtocol.usageURL) }
                        if let url = SearchEngine.google.url(for: turn.query) {
                            Button("search in Google") { openSource(url) }
                        }
                    }
                }.font(.system(size: 12)).padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sources(_ turn: ChatGPTSearchTurn) -> some View {
        var seen = Set<URL>()
        let all = Array(turn.citations.enumerated()).filter { seen.insert($0.element.url).inserted }
        let visible = expandedSources.contains(turn.id) ? all : Array(all.prefix(4))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("sources").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if turn.complete {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ChatGPTAnswerContent.copyText(turn), forType: .string)
                    } label: {
                        Label("copy answer", systemImage: "doc.on.doc").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("copy this answer")
                }
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
                                Image(systemName: "arrow.up.right").font(.system(size: 9))
                            }.foregroundStyle(.secondary)
                            Text(citation.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12).frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                        .background(fieldSurface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).help(citation.url.absoluteString)
                        .accessibilityLabel("source \(index + 1): \(citation.title)")
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    search.turns.isEmpty ? "search the web…" : "ask a follow-up…", text: $search.draft, axis: .vertical
                )
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...5)
                .focused($focused).onSubmit { search.submit() }
                .disabled(search.searching || editingTurnID != nil).padding(.vertical, 4)
                .accessibilityLabel(search.turns.isEmpty ? "search the web" : "ask a follow-up")
                Button {
                    if search.searching {
                        search.stop()
                        focused = true
                    } else {
                        search.submit()
                    }
                } label: {
                    Image(systemName: search.searching ? "stop.fill" : "arrow.up")
                        .font(.system(size: search.searching ? 10 : 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(search.searching || canSubmit ? surface : Color.secondary.opacity(0.6))
                        .background(
                            search.searching || canSubmit ? Color.primary : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(!search.searching && !canSubmit)
                    .help(search.searching ? "stop search" : "search")
                    .accessibilityLabel(search.searching ? "stop search" : "search")
            }
            .padding(.horizontal, 12).padding(.vertical, 7).background(
                fieldSurface, in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(focused ? 0.22 : 0.1)))
            HStack {
                Text(
                    search.draft.utf8.count > 8_000
                        ? "shorten your question to continue"
                        : search.provider != .chatgpt
                            ? search.provider.title
                            : account.connected ? "using ChatGPT plan" : "connect ChatGPT to search")
                Spacer()
                if search.provider == .chatgpt && account.connected {
                    Link("manage usage", destination: ChatGPTProtocol.usageURL)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 4)
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
