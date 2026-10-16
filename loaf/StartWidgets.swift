import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct StartWidgetGrid<Content: View>: View {
    let layout: StartWidgetLayout
    let width: CGFloat
    @ViewBuilder let content: (StartWidgetLayout.Placement) -> Content
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.placements) { placement in
                content(placement).frame(width: placement.frame.width, height: placement.frame.height)
                    .offset(x: placement.frame.minX, y: placement.frame.minY)
            }
        }.frame(width: width, height: layout.height, alignment: .topLeading)
    }
}

nonisolated enum StartWidgetKind: String, CaseIterable, Identifiable, Sendable {
    case search, pins, clock, weather, recent, notes, calendar, downloads, checklist, worldClock, timer, stopwatch,
        battery,
        browsingTime
    var id: String { rawValue }
    var title: String {
        switch self {
        case .search: "search or surf…"
        case .battery: "battery"
        case .browsingTime: "browsing time"
        case .pins: "favorites"
        case .clock: "clock"
        case .weather: "weather"
        case .recent: "recent tabs"
        case .notes: "notes"
        case .calendar: "today"
        case .downloads: "downloads"
        case .checklist: "checklist"
        case .worldClock: "world clock"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        }
    }
    var glyph: String {
        switch self {
        case .search: "⌕"
        case .battery: "🔋"
        case .browsingTime: "⌛"
        case .pins: "★"
        case .clock, .recent: "🕐"
        case .weather: "⛅"
        case .notes: "📖"
        case .calendar: "🗓"
        case .downloads: "↓"
        case .checklist: "☑"
        case .worldClock: "🪐"
        case .timer: "⏲"
        case .stopwatch: "⏱"
        }
    }
    var detail: String {
        switch self {
        case .search: "open the wonderbar"
        case .battery: "battery level and power saver status"
        case .browsingTime: "opt-in site totals, kept on this Mac"
        case .pins: "saved websites"
        case .clock: "time and date at a glance"
        case .weather: "a forecast for your chosen city"
        case .recent: "pick up an open page"
        case .notes: "a small, local scratchpad"
        case .calendar: "the week around today"
        case .downloads: "recent transfers in this profile"
        case .checklist: "a few things to get done, kept locally"
        case .worldClock: "the time in places you choose"
        case .timer: "a countdown with a chime while loaf is open"
        case .stopwatch: "keep track of elapsed time"
        }
    }
    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .pins: "star"
        case .clock: "clock"
        case .weather: "cloud.sun"
        case .recent: "clock.arrow.circlepath"
        case .notes: "note.text"
        case .calendar: "calendar"
        case .downloads: "arrow.down.circle"
        case .checklist: "checklist"
        case .worldClock: "globe"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        case .battery: "battery.75percent"
        case .browsingTime: "hourglass"
        }
    }
}

nonisolated enum StartWidgetSize: String, CaseIterable, Codable, Equatable, Sendable {
    case small, square, wide, tall, large, banner
    var columns: Int { self == .banner ? 2 : self == .wide || self == .large ? 2 : 1 }
    var rows: Int { self == .tall || self == .large ? 2 : 1 }
    static func squareSide(columnWidth: CGFloat) -> CGFloat {
        columnWidth >= 16 ? (columnWidth - 16) / 2 : max(0, columnWidth)
    }
    func width(columnWidth: CGFloat, columns: Int) -> CGFloat {
        if self == .square { return Self.squareSide(columnWidth: columnWidth) }
        let span = min(columns, self.columns)
        return CGFloat(span) * columnWidth + CGFloat(span - 1) * 16
    }
    func height(columnWidth: CGFloat) -> CGFloat {
        self == .banner ? 56 : self == .square ? Self.squareSide(columnWidth: columnWidth) : CGFloat(rows) * 192 - 16
    }
    static func resized(from size: Self, translation: CGSize, columnWidth: CGFloat, columns: Int) -> Self {
        let width = size.width(columnWidth: columnWidth, columns: columns) + translation.width
        let height = size.height(columnWidth: columnWidth) + translation.height
        let wide = columns > 1 && width >= columnWidth * 1.5 + 8
        let tall = height >= 272
        if !wide, !tall, width < (squareSide(columnWidth: columnWidth) + columnWidth) / 2 { return .square }
        return wide ? (tall ? .large : .wide) : (tall ? .tall : .small)
    }
}

struct StartWidgetResizeSession {
    let original: StartWidgetSize
    let columnWidth: CGFloat
    let columns: Int
    private(set) var preview: StartWidgetSize
    init(size: StartWidgetSize, columnWidth: CGFloat, columns: Int) {
        original = size
        preview = size
        self.columnWidth = columnWidth
        self.columns = columns
    }
    mutating func update(translation: CGSize) -> StartWidgetSize {
        let width = original.width(columnWidth: columnWidth, columns: columns) + translation.width
        let height = original.height(columnWidth: columnWidth) + translation.height

        let wide = columns > 1 && width >= columnWidth * 1.5 + 8 + (preview.columns == 2 ? -8 : 8)
        let tall = height >= 272 + (preview.rows == 2 ? -8 : 8)
        let compact =
            width < (StartWidgetSize.squareSide(columnWidth: columnWidth) + columnWidth) / 2
            + (preview == .square ? 8 : -8)
        preview = wide ? (tall ? .large : .wide) : tall ? .tall : compact ? .square : .small
        return preview
    }
}

nonisolated struct StartWidgetOptions: Codable, Equatable, Sendable {
    var clock24Hour: Bool?
    var clockSeconds: Bool?
    var itemLimit: Int?
    var largerNotes: Bool?
    var hideCompleted: Bool?
    var timeZones: [String]?
    var limit: Int { min(12, max(2, itemLimit ?? 4)) }
}

nonisolated struct StartWidgetPosition: Codable, Equatable, Sendable {
    var column: Int
    var row: Int
    var priority = 0
}

struct StartWidgetLayout {
    struct Placement: Identifiable {
        let id: String
        let frame: CGRect
    }
    let placements: [Placement]
    let columns: Int
    let columnWidth: CGFloat
    let height: CGFloat
    private let rowOrigins: [CGFloat]
    let positions: [String: StartWidgetPosition]
    var gridColumns: Int { columns * (columnWidth >= 16 ? 2 : 1) }
    var gridStride: CGSize {
        CGSize(
            width: StartWidgetSize.squareSide(columnWidth: columnWidth) + 16,
            height: max(176, StartWidgetSize.squareSide(columnWidth: columnWidth)) + 16)
    }
    func rowOrigin(_ row: Int) -> CGFloat {
        let row = max(0, row)
        if row < rowOrigins.count { return rowOrigins[row] }
        return (rowOrigins.last ?? 0) + CGFloat(row - max(0, rowOrigins.count - 1)) * gridStride.height
    }
    var rowCount: Int { max(0, rowOrigins.count - 1) }
    func rowHeight(_ row: Int) -> CGFloat { max(0, rowOrigin(row + 1) - rowOrigin(row) - 16) }
    func position(at point: CGPoint, size: StartWidgetSize) -> StartWidgetPosition {
        let span = size == .square ? 1 : min(columns, size.columns) * (columnWidth >= 16 ? 2 : 1)
        let y = point.y.isFinite ? max(0, point.y) : 0

        let row = (0...128).last { rowOrigin($0) <= y + 0.5 } ?? 0
        return StartWidgetPosition(
            column: Int(min(CGFloat(gridColumns - span), max(0, (point.x.isFinite ? point.x : 0) / gridStride.width))),
            row: row)
    }
    init(
        widgets: [String], sizes: [String: StartWidgetSize], positions: [String: StartWidgetPosition] = [:],
        width: CGFloat
    ) {
        let width = width.isFinite ? max(0, width) : 0
        let columns = width >= 560 ? 2 : 1
        let columnWidth = max(0, (width - CGFloat(columns - 1) * 16) / CGFloat(columns))
        let subdivisions = columnWidth >= 16 ? 2 : 1
        let gridColumns = columns * subdivisions
        let side = StartWidgetSize.squareSide(columnWidth: columnWidth)
        let rowHeight = max(176, side)
        var seen = Set<String>()
        let ids = widgets.filter { StartWidgetKind(rawValue: $0) != nil && seen.insert($0).inserted }
        let ordered = ids.enumerated().sorted {
            let lhs = positions[$0.element]
            let rhs = positions[$1.element]
            if (lhs != nil) != (rhs != nil) { return lhs != nil }
            if lhs?.priority != rhs?.priority { return (lhs?.priority ?? 0) > (rhs?.priority ?? 0) }
            return $0.offset < $1.offset
        }.map(\.element)
        var occupied = Set<Int>()
        var resolved: [String: StartWidgetPosition] = [:]
        var rowHeights: [Int: CGFloat] = [:]
        var effectiveSizes: [String: StartWidgetSize] = [:]
        for id in ordered {
            let size: StartWidgetSize = id == "search" ? .banner : sizes[id] ?? .small
            effectiveSizes[id] = size
            let span = size == .square ? 1 : min(columns, size.columns) * subdivisions
            let rows = size.rows
            var column = min(gridColumns - span, max(0, positions[id]?.column ?? 0))
            var row = min(128, max(0, positions[id]?.row ?? 0))
            while true {
                let cells = (0..<rows).flatMap { y in (0..<span).map { x in (row + y) * gridColumns + column + x } }
                if cells.allSatisfy({ !occupied.contains($0) }) {
                    occupied.formUnion(cells)
                    resolved[id] = StartWidgetPosition(column: column, row: row, priority: positions[id]?.priority ?? 0)
                    for y in row..<row + rows {
                        let requiredHeight = size == .banner ? 56 : size == .square ? side : 176
                        rowHeights[y] = max(rowHeights[y] ?? 0, requiredHeight)
                    }
                    break
                }
                if positions[id] != nil {
                    row += 1
                } else {
                    column += 1
                    if column + span > gridColumns {
                        column = 0
                        row += 1
                    }
                }
            }
        }
        var origins: [CGFloat] = [0]
        for row in 0..<((rowHeights.keys.max() ?? -1) + 1) {
            origins.append(origins.last! + (rowHeights[row] ?? rowHeight) + 16)
        }
        self.columns = columns
        self.columnWidth = columnWidth
        self.rowOrigins = origins
        self.positions = resolved
        placements = ids.compactMap { id in
            guard let position = resolved[id], let size = effectiveSizes[id] else { return nil }
            return Placement(
                id: id,
                frame: CGRect(
                    x: CGFloat(position.column) * (side + 16), y: origins[position.row],
                    width: size.width(columnWidth: columnWidth, columns: columns),
                    height: size.height(columnWidth: columnWidth)))
        }
        height = placements.map(\.frame.maxY).max() ?? 0
    }
}

struct StartWidgetDrag: Codable {
    let window: UUID
    let profile: UUID
    let widget: String
    func valid(windowID: UUID, profileID: UUID, visibleWidgets: [String]) -> Bool {
        window == windowID && profile == profileID && StartWidgetKind(rawValue: widget) != nil
            && visibleWidgets.contains(widget)
    }
}
extension UTType { static let loafWidget = UTType(exportedAs: "app.tryloaf.loaf.start-widget", conformingTo: .data) }

extension Personalization {
    mutating func placeWidget(
        _ id: String, at position: StartWidgetPosition, currentPositions: [String: StartWidgetPosition]
    ) {
        guard visibleStartWidgets.contains(id) else { return }
        var positions = currentPositions.filter { visibleStartWidgets.contains($0.key) }
        var value = position
        value.column = min(3, max(0, value.column))
        value.row = min(128, max(0, value.row))
        value.priority = min(1_000_000, (widgetPositions?.values.map(\.priority).max() ?? 0)) + 1
        positions[id] = value
        widgetPositions = positions
    }
    var visibleStartWidgets: [String] {
        var seen = Set<String>()
        return widgets.filter {
            StartWidgetKind(rawValue: $0) != nil && !hiddenWidgets.contains($0) && seen.insert($0).inserted
        }
    }
    mutating func showWidget(_ id: String) {
        guard StartWidgetKind(rawValue: id) != nil else { return }
        if !widgets.contains(id) { widgets.append(id) }
        hiddenWidgets.removeAll { $0 == id }
    }
    mutating func moveWidget(_ id: String, relativeTo target: String, after: Bool) {
        guard id != target, visibleStartWidgets.contains(id), visibleStartWidgets.contains(target) else { return }
        widgets.removeAll { $0 == id }
        guard let index = widgets.firstIndex(of: target) else { return }
        widgets.insert(id, at: index + (after ? 1 : 0))
    }
}
