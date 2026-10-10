import Combine
import Foundation
import NaturalLanguage

private actor HistoryPreparationWorker {
    nonisolated struct Prepared: Sendable {
        nonisolated struct Row: Sendable {
            let visit: Visit
            let day: Date
        }
        let visits: [Visit]
        let rows: [Row]
        let dayTitles: [Date: String]
        let groups: [Range<Int>]
        let ordered: [UUID]
    }
    func prepare(_ visits: [Visit], calendar: Calendar, locale: Locale, now: Date) throws -> Prepared {
        try Task.checkCancellation()
        let sorted = visits.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
        try Task.checkCancellation()
        var rows: [Prepared.Row] = []
        var titles: [Date: String] = [:]
        var groups: [Range<Int>] = []
        var ordered: [UUID] = []
        rows.reserveCapacity(sorted.count)
        ordered.reserveCapacity(sorted.count)
        var interval: DateInterval?
        var previousDay: Date?
        var groupStart = 0
        var format = Date.FormatStyle().weekday(.wide).month(.wide).day()

        format.locale = locale
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        for (index, visit) in sorted.enumerated() {
            if index % 128 == 0 { try Task.checkCancellation() }
            if interval == nil || visit.date < interval!.start || visit.date >= interval!.end {
                interval = calendar.dateInterval(of: .day, for: visit.date)
            }
            let day = interval?.start ?? calendar.startOfDay(for: visit.date)
            if previousDay != day {
                if previousDay != nil { groups.append(groupStart..<index) }
                groupStart = index
                previousDay = day
                let prefix =
                    calendar.isDate(day, inSameDayAs: now)
                    ? "today — " : yesterday.map { calendar.isDate(day, inSameDayAs: $0) } == true ? "yesterday — " : ""
                titles[day] = prefix + day.formatted(format).lowercased()
            }
            rows.append(Prepared.Row(visit: visit, day: day))
            ordered.append(visit.id)
        }
        if previousDay != nil { groups.append(groupStart..<rows.count) }
        return Prepared(visits: sorted, rows: rows, dayTitles: titles, groups: groups, ordered: ordered)
    }
}

private actor HistorySearchWorker {
    private var revision: UInt64?
    private var minimumRevision: UInt64 = 0
    private var texts: [LocalPageSearch.Document] = []
    private lazy var embedding = NLEmbedding.wordEmbedding(for: .english)

    func discard(before revision: UInt64) {
        minimumRevision = max(minimumRevision, revision)
        if let cached = self.revision, cached < revision {
            texts = []
            self.revision = nil
        }
    }
    func matches(_ visits: [Visit], revision: UInt64, query: String) -> [Int]? {
        guard !Task.isCancelled, revision >= minimumRevision else { return nil }
        if self.revision != revision {
            var prepared: [LocalPageSearch.Document] = []
            prepared.reserveCapacity(visits.count)
            for (index, visit) in visits.enumerated() {
                if index % 128 == 0, Task.isCancelled { return nil }
                prepared.append(LocalPageSearch.Document(title: visit.title, address: visit.address))
            }
            texts = prepared
            self.revision = revision
        }
        let query = LocalPageSearch.Query(query, embedding: embedding)
        var matches: [Int] = []
        for (index, text) in texts.enumerated() {
            if index % 128 == 0, Task.isCancelled { return nil }
            if text.score(query) != nil {
                matches.append(index)
            }
        }
        return Task.isCancelled ? nil : matches
    }
}

@MainActor final class HistoryPresentation: ObservableObject {
    final class Row: Identifiable {
        let visit: Visit
        let day: Date

        lazy var url = URL(string: visit.address)
        lazy var host = url?.host ?? ""
        lazy var title = visit.title.isEmpty ? BrowserAddress.suggestionLabel(url) : BrowserAddress.visible(visit.title)
        lazy var dateText = "visited: " + visit.date.formatted(date: .numeric, time: .shortened)

        private lazy var searchDocument = LocalPageSearch.Document(title: visit.title, address: visit.address)
        func matches(_ query: String) -> Bool { searchDocument.score(LocalPageSearch.Query(query)) != nil }
        func matches(_ query: LocalPageSearch.Query) -> Bool { searchDocument.score(query) != nil }
        var id: UUID { visit.id }
        init(visit: Visit, day: Date) {
            self.visit = visit
            self.day = day
        }
    }
    struct Summary: Identifiable {
        let row: Row
        var visitIDs: Set<UUID>
        var id: UUID { row.id }
    }
    struct Session: Identifiable {
        let id: UUID
        let start: Date
        let end: Date
        let summaries: [Summary]
        var title: String {
            start.formatted(date: .omitted, time: .shortened).lowercased()
                + (end.timeIntervalSince(start) >= 60
                    ? " – " + end.formatted(date: .omitted, time: .shortened).lowercased() : "")
        }
    }
    struct Section: Identifiable {
        let day: Date
        let title: String
        var rows: [Row]
        let sessions: [Session]
        var id: Date { day }
        init(day: Date, title: String, rows: [Row]) {
            self.day = day
            self.title = title
            self.rows = rows
            var result: [Session] = []
            var current: [Row] = []
            func finish() {
                guard let newest = current.first, let oldest = current.last else { return }
                var summaries: [Summary] = []
                var indices: [String: Int] = [:]
                for row in current {
                    if let index = indices[row.visit.address] {
                        summaries[index].visitIDs.insert(row.id)
                    } else {
                        indices[row.visit.address] = summaries.count
                        summaries.append(Summary(row: row, visitIDs: [row.id]))
                    }
                }
                result.append(
                    Session(id: newest.id, start: oldest.visit.date, end: newest.visit.date, summaries: summaries))
            }
            for row in rows {
                if let previous = current.last, previous.visit.date.timeIntervalSince(row.visit.date) >= 1800 {
                    finish()
                    current = []
                }
                current.append(row)
            }
            finish()
            sessions = result
        }
    }
    private struct Source: Equatable {
        let profile: UUID
        let visits: [Visit]
    }
    @Published var query = "" { didSet { if query != oldValue { filter() } } }
    @Published private(set) var sections: [Section] = []
    @Published private(set) var ordered: [UUID] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isPreparing = false
    var isBusy: Bool { isPreparing || isSearching }
    @Published private(set) var cookieDomains: [String: Int] = [:]
    private(set) var profileID: UUID?
    private(set) var rowBuilds = 0
    private var rows: [Row] = []
    private var rowsByID: [UUID: Row] = [:]
    private var dayTitles: [Date: String] = [:]
    private var unfilteredSections: [Section] = []
    private var unfilteredOrdered: [UUID] = []
    private var subscriptions = Set<AnyCancellable>()
    private lazy var embedding = NLEmbedding.wordEmbedding(for: .english)
    private let searchWorker = HistorySearchWorker()
    private let preparationWorker = HistoryPreparationWorker()
    private var searchTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var sourceVisits: [Visit] = []
    private var searchVisits: [Visit] = []
    private var sourceRevision: UInt64 = 0
    private var searchRevision: UInt64 = 0

    init(store: BrowserStore) {
        Publishers.CombineLatest(store.application.$profiles, store.$selectedProfileID)
            .map { profiles, id in Source(profile: id, visits: profiles.first { $0.id == id }?.history ?? []) }
            .removeDuplicates()
            .sink { [weak self] source in self?.replace(source.visits, profile: source.profile) }.store(
                in: &subscriptions)
        for name in [
            Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
            NSLocale.currentLocaleDidChangeNotification,
        ] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshCalendar() }.store(in: &subscriptions)
        }
    }
    deinit {
        searchTask?.cancel()
        preparationTask?.cancel()
    }
    func refreshCalendar() { if let profileID { replace(sourceVisits, profile: profileID, reuseRows: false) } }
    private func replace(_ visits: [Visit], profile: UUID, reuseRows: Bool = true) {

        let previous = reuseRows && profileID == profile ? rowsByID : [:]
        let changedProfile = profileID != profile
        preparationTask?.cancel()
        preparationTask = nil
        searchTask?.cancel()
        searchTask = nil
        searchRevision &+= 1
        sourceRevision &+= 1
        sourceVisits = visits
        if changedProfile {
            cookieDomains = [:]
            rowsByID = [:]
            sections = []
            ordered = []
        }
        profileID = profile
        rowBuilds += 1
        let calendar = Calendar.current
        let searchWorker = searchWorker
        let revision = sourceRevision
        Task { await searchWorker.discard(before: revision) }
        if visits.count > 512 {
            isPreparing = true
            isSearching = false
            if !query.isEmpty {
                sections = []
                ordered = []
            }
            let worker = preparationWorker
            let locale = Locale.current
            let now = Date()
            preparationTask = Task(priority: .userInitiated) { [weak self] in
                guard let prepared = try? await worker.prepare(visits, calendar: calendar, locale: locale, now: now),
                    !Task.isCancelled, let self, self.sourceRevision == revision
                else { return }
                var newRows: [Row] = []
                var newByID: [UUID: Row] = [:]
                newRows.reserveCapacity(prepared.rows.count)
                newByID.reserveCapacity(prepared.rows.count)
                for (index, record) in prepared.rows.enumerated() {
                    if index % 1_024 == 0 {
                        await Task.yield()
                        guard !Task.isCancelled, self.sourceRevision == revision else { return }
                    }
                    let row =
                        previous[record.visit.id].flatMap { $0.visit == record.visit ? $0 : nil }
                        ?? Row(visit: record.visit, day: record.day)
                    newRows.append(row)
                    newByID[row.id] = row
                }
                guard !Task.isCancelled, self.sourceRevision == revision else { return }
                self.rows = newRows
                self.rowsByID = newByID
                self.searchVisits = prepared.visits
                self.dayTitles = prepared.dayTitles
                self.unfilteredOrdered = prepared.ordered
                self.unfilteredSections = prepared.groups.map { range in
                    let day = prepared.rows[range.lowerBound].day
                    return Section(day: day, title: prepared.dayTitles[day] ?? "", rows: Array(newRows[range]))
                }
                self.isPreparing = false
                self.preparationTask = nil
                self.filter()
            }
            return
        }
        isPreparing = false
        var dayInterval: DateInterval?
        searchVisits = visits.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
        rows = searchVisits.map { visit in
            if let row = previous[visit.id], row.visit == visit { return row }
            if dayInterval == nil || visit.date < dayInterval!.start || visit.date >= dayInterval!.end {
                dayInterval = calendar.dateInterval(of: .day, for: visit.date)
            }
            return Row(visit: visit, day: dayInterval?.start ?? calendar.startOfDay(for: visit.date))
        }
        dayTitles = [:]
        for row in rows where dayTitles[row.day] == nil {
            let label = row.day.formatted(.dateTime.weekday(.wide).month(.wide).day()).lowercased()
            dayTitles[row.day] =
                (calendar.isDateInToday(row.day)
                    ? "today — " : calendar.isDateInYesterday(row.day) ? "yesterday — " : "") + label
        }
        unfilteredSections = grouped(rows)
        unfilteredOrdered = rows.map(\.id)
        rowsByID = rows.reduce(into: [:]) { $0[$1.id] = $1 }
        filter()
    }
    private func filter() {
        searchTask?.cancel()
        searchTask = nil
        searchRevision &+= 1
        guard !isPreparing else {
            isSearching = false
            if !query.isEmpty, !ordered.isEmpty {
                sections = []
                ordered = []
            }
            return
        }
        guard !query.isEmpty else {
            isSearching = false
            sections = unfilteredSections
            ordered = unfilteredOrdered
            return
        }
        guard rows.count > 512 else {
            isSearching = false
            let search = LocalPageSearch.Query(query, embedding: embedding)
            publish(rows.filter { $0.matches(search) })
            return
        }
        isSearching = true
        let worker = searchWorker
        let visits = searchVisits
        let source = sourceRevision
        let revision = searchRevision
        let query = query
        searchTask = Task(priority: .userInitiated) { [weak self] in
            guard let indices = await worker.matches(visits, revision: source, query: query), !Task.isCancelled,
                let self, self.searchRevision == revision, self.sourceRevision == source
            else { return }
            if indices.count == self.rows.count {
                self.sections = self.unfilteredSections
                self.ordered = self.unfilteredOrdered
            } else {
                self.publish(indices.map { self.rows[$0] })
            }
            self.isSearching = false
            self.searchTask = nil
        }
    }
    private func publish(_ filtered: [Row]) {
        sections = grouped(filtered)
        ordered = filtered.map(\.id)
    }
    private func grouped(_ filtered: [Row]) -> [Section] {
        var groups: [Section] = []
        var day: Date?
        var dayRows: [Row] = []
        for row in filtered {
            if day != row.day {
                if let day { groups.append(Section(day: day, title: dayTitles[day] ?? "", rows: dayRows)) }
                day = row.day
                dayRows = []
            }
            dayRows.append(row)
        }
        if let day { groups.append(Section(day: day, title: dayTitles[day] ?? "", rows: dayRows)) }
        return groups
    }
    func replaceCookies(_ cookies: [HTTPCookie], profile: UUID) {
        guard profileID == profile else { return }
        var domains: [String: Int] = [:]
        for cookie in cookies {
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !domain.isEmpty { domains[domain, default: 0] += 1 }
        }
        if domains != cookieDomains { cookieDomains = domains }
    }
    func cookieCount(for host: String) -> Int {
        var suffix = host.lowercased()
        var count = 0
        while !suffix.isEmpty {
            count += cookieDomains[suffix] ?? 0
            guard let dot = suffix.firstIndex(of: ".") else { break }
            suffix = String(suffix[suffix.index(after: dot)...])
        }
        return count
    }
}

nonisolated struct HistoryMenuSections {
    struct Group {
        let title: String
        let visits: [Visit]
    }
    let recent: [Visit]
    let sessions: [Group]
    let days: [Group]
    let weeks: [Group]
    init(visits: [Visit], currentSession: UUID, now: Date = Date(), calendar: Calendar = .current) {
        let visits = visits.sorted { $0.date > $1.date }
        var seen = Set<String>()
        recent = Array(visits.filter { seen.insert($0.address).inserted }.prefix(10))
        let recentIDs = Set(recent.map(\.id))
        let remaining = visits.filter { !recentIDs.contains($0.id) }
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var sessionVisits: [[Visit]] = []
        for visit in remaining where visit.date >= today {
            if let last = sessionVisits.last?.last,
                (visit.sessionID != nil
                    ? visit.sessionID == last.sessionID : last.date.timeIntervalSince(visit.date) < 1800)
            {
                sessionVisits[sessionVisits.count - 1].append(visit)
            } else {
                sessionVisits.append([visit])
            }
        }
        sessions = sessionVisits.prefix(8).map { group in
            Group(
                title: group[0].sessionID == currentSession
                    ? "earlier this session" : group[0].date.formatted(date: .omitted, time: .shortened), visits: group)
        }
        let byDay = Dictionary(grouping: remaining.filter { $0.date < today && $0.date >= weekAgo }) {
            calendar.startOfDay(for: $0.date)
        }
        days = byDay.keys.sorted(by: >).map { day in
            Group(
                title: calendar.isDateInYesterday(day)
                    ? "yesterday" : day.formatted(.dateTime.weekday(.wide).month().day()), visits: byDay[day]!)
        }
        let byWeek = Dictionary(grouping: remaining.filter { $0.date < weekAgo }) {
            calendar.dateInterval(of: .weekOfYear, for: $0.date)?.start ?? calendar.startOfDay(for: $0.date)
        }
        weeks = byWeek.keys.sorted(by: >).prefix(12).map { week in
            Group(title: "week of " + week.formatted(.dateTime.month().day()), visits: byWeek[week]!)
        }
    }
}
