import SwiftUI

nonisolated struct StartChecklistItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var complete = false
}

extension Personalization {
    var boundedChecklist: [StartChecklistItem] {
        var seen = Set<UUID>()
        return (checklistItems ?? []).prefix(100).compactMap { item in
            var item = item
            item.text = String(item.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            guard !item.text.isEmpty, seen.insert(item.id).inserted else { return nil }
            return item
        }
    }
    mutating func appendChecklistItem(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, boundedChecklist.count < 100 else { return }
        checklistItems = boundedChecklist + [StartChecklistItem(text: String(text.prefix(200)))]
    }
}

struct StartChecklistWidget: View {
    @ObservedObject var store: BrowserStore
    let options: StartWidgetOptions
    var showsHeader = true
    @State private var draft = ""
    private var items: [StartChecklistItem] { (store.profile.personalization ?? Personalization()).boundedChecklist }
    private func update(_ edit: (inout Personalization) -> Void) {
        store.updateCurrent { profile in
            var value = profile.personalization ?? Personalization()
            edit(&value)
            profile.personalization = value
        }
    }
    private func add() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, items.count < 100 else { return }
        update { $0.appendChecklistItem(draft) }
        draft = ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                HStack {
                    GolzheimIcon(icon: .check, size: 14)
                    Text("checklist").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(items.filter { !$0.complete }.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            ForEach(Array(items.filter { options.hideCompleted != true || !$0.complete }.prefix(options.limit))) {
                item in
                WidgetTaskRow(
                    complete: item.complete,
                    toggle: {
                        update { p in
                            var items = p.boundedChecklist
                            if let index = items.firstIndex(where: { $0.id == item.id }) {
                                items[index].complete.toggle()
                            }
                            p.checklistItems = items
                        }
                    }, remove: { update { p in p.checklistItems = p.boundedChecklist.filter { $0.id != item.id } } }
                ) {
                    Toggle(
                        isOn: Binding(
                            get: { item.complete },
                            set: { value in
                                update { p in
                                    var items = p.boundedChecklist
                                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                                        items[index].complete = value
                                    }
                                    p.checklistItems = items
                                }
                            })
                    ) {
                        Text(item.text).font(.system(size: 13)).strikethrough(item.complete).foregroundStyle(
                            item.complete ? .secondary : .primary
                        ).lineLimit(2)
                    }.toggleStyle(.checkbox)
                        .contextMenu {
                            Button("remove item") {
                                update { p in p.checklistItems = p.boundedChecklist.filter { $0.id != item.id } }
                            }
                        }
                }
            }
            if items.isEmpty { Text("keep a few things in view").font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                TextField("add an item…", text: $draft).textFieldStyle(.plain).font(.system(size: 12)).onSubmit(add)
                    .accessibilityLabel("new checklist item")
                    .onChange(of: draft) { _, value in if value.count > 200 { draft = String(value.prefix(200)) } }
                Button(action: add) { GolzheimIcon(icon: .plus, size: 12).frame(width: 20, height: 20) }.buttonStyle(
                    .plain
                ).accessibilityLabel("add checklist item")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || items.count >= 100)
            }.padding(7).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

enum StartWorldClock {
    static let defaults = ["America/Los_Angeles", "Europe/London", "Asia/Tokyo"]
    static let available = TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") && !$0.hasPrefix("Etc/") }
        .sorted()
    static func zones(_ values: [String]?) -> [TimeZone] {
        var seen = Set<String>()
        return (values ?? defaults).compactMap { id -> TimeZone? in
            guard seen.insert(id).inserted else { return nil }
            return TimeZone(identifier: id)
        }.prefix(4).map { $0 }
    }
    static func city(_ zone: TimeZone) -> String {
        zone.identifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ")
            ?? zone.identifier
    }
    static func day(_ date: Date, zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated)
        style.timeZone = zone
        return date.formatted(style)
    }
    static func time(_ date: Date, zone: TimeZone, hour24: Bool = false) -> String {
        var style = Date.FormatStyle.dateTime.hour(
            hour24 ? .twoDigits(amPM: .omitted) : .defaultDigits(amPM: .abbreviated)
        ).minute()
        style.timeZone = zone
        if hour24 { style.locale = Locale(identifier: "en_GB") }
        return date.formatted(style)
    }
}

struct StartWorldClockWidget: View {
    let options: StartWidgetOptions
    var showsHeader = true
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                if showsHeader {
                    HStack(spacing: 8) {
                        GolzheimIcon(icon: .globe, size: 14)
                        Text("world clock").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                ForEach(StartWorldClock.zones(options.timeZones), id: \.identifier) { zone in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(StartWorldClock.city(zone)).font(.system(size: 12))
                            Text(StartWorldClock.day(context.date, zone: zone)).font(.system(size: 10)).foregroundStyle(
                                .secondary)
                        }
                        Spacer(minLength: 8)
                        Text(StartWorldClock.time(context.date, zone: zone, hour24: options.clock24Hour == true)).font(
                            .system(size: 18, weight: .light)
                        ).monospacedDigit().lineLimit(1)
                    }
                }
                if StartWorldClock.zones(options.timeZones).isEmpty {
                    Text("choose places in widget settings").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StartWorldClockSettings: View {
    @Binding var zones: [String]?
    var body: some View {
        Menu("places") {
            ForEach(StartWorldClock.zones(zones), id: \.identifier) { zone in
                Button("remove " + StartWorldClock.city(zone)) {
                    zones = StartWorldClock.zones(zones).map(\.identifier).filter { $0 != zone.identifier }
                }
            }
            if StartWorldClock.zones(zones).count < 4 {
                Divider()

                ForEach(["America", "Europe", "Asia", "Australia", "Africa", "Pacific"], id: \.self) { region in
                    Menu(region.lowercased()) {
                        ForEach(
                            StartWorldClock.available.filter {
                                $0.hasPrefix(region + "/")
                                    && !StartWorldClock.zones(zones).map(\.identifier).contains($0)
                            }, id: \.self
                        ) { id in
                            Button(id.dropFirst(region.count + 1).replacingOccurrences(of: "_", with: " ")) {
                                zones = StartWorldClock.zones(zones).map(\.identifier) + [id]
                            }
                        }
                    }
                }
            }
        }
    }
}
