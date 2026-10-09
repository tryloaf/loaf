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
    case pins, clock, weather, recent, notes, calendar, downloads, checklist, worldClock, battery, browsingTime
    var id: String { rawValue }
    var title: String {
        switch self {
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
        }
    }
    var glyph: String {
        switch self {
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
        }
    }
    var detail: String {
        switch self {
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
        }
    }
}

nonisolated enum StartWidgetSize: String, CaseIterable, Codable, Sendable {
    case small, square, wide, tall, large
    var columns: Int { self == .wide || self == .large ? 2 : 1 }
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
        self == .square ? Self.squareSide(columnWidth: columnWidth) : CGFloat(rows) * 192 - 16
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

nonisolated struct StartWidgetOptions: Codable, Sendable {
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
    var gridColumns: Int { columns * (columnWidth >= 16 ? 2 : 1) }
    var gridStride: CGSize {
        CGSize(
            width: StartWidgetSize.squareSide(columnWidth: columnWidth) + 16,
            height: max(176, StartWidgetSize.squareSide(columnWidth: columnWidth)) + 16)
    }
    func position(at point: CGPoint, size: StartWidgetSize) -> StartWidgetPosition {
        let span = size == .square ? 1 : min(columns, size.columns) * (columnWidth >= 16 ? 2 : 1)
        return StartWidgetPosition(
            column: Int(min(CGFloat(gridColumns - span), max(0, (point.x.isFinite ? point.x : 0) / gridStride.width))),
            row: Int(min(128, max(0, (point.y.isFinite ? point.y : 0) / gridStride.height))))
    }
    var positions: [String: StartWidgetPosition] {
        Dictionary(
            uniqueKeysWithValues: placements.map { placement in
                let size: StartWidgetSize =
                    placement.frame.width < columnWidth
                    ? .square : placement.frame.width > columnWidth + 0.5 ? .wide : .small
                return (
                    placement.id,
                    position(
                        at: CGPoint(
                            x: placement.frame.minX + gridStride.width / 2,
                            y: placement.frame.minY + gridStride.height / 2), size: size)
                )
            })
    }
    init(
        widgets: [String], sizes: [String: StartWidgetSize], positions: [String: StartWidgetPosition] = [:],
        width: CGFloat
    ) {
        let width = width.isFinite ? max(0, width) : 0
        let columns = width >= 560 ? 2 : 1
        let columnWidth = max(0, (width - CGFloat(columns - 1) * 16) / CGFloat(columns))
        if !positions.isEmpty {
            let subdivisions = columnWidth >= 16 ? 2 : 1
            let gridColumns = columns * subdivisions
            let side = StartWidgetSize.squareSide(columnWidth: columnWidth)
            let rowStride = max(176, side) + 16
            var seen = Set<String>()
            var occupied = Set<Int>()
            var placed: [String: Placement] = [:]
            let ids = widgets.filter { StartWidgetKind(rawValue: $0) != nil && seen.insert($0).inserted }
            let ordered = ids.enumerated().sorted {
                let lhs = positions[$0.element]
                let rhs = positions[$1.element]
                if (lhs != nil) != (rhs != nil) { return lhs != nil }
                if lhs?.priority != rhs?.priority { return (lhs?.priority ?? 0) > (rhs?.priority ?? 0) }
                return $0.offset < $1.offset
            }.map(\.element)
            for id in ordered {
                let size = sizes[id] ?? .small
                let span = size == .square ? 1 : min(columns, size.columns) * subdivisions
                let height = size.height(columnWidth: columnWidth)
                let rows = max(1, Int(ceil((height + 16) / rowStride)))
                var column = min(gridColumns - span, max(0, positions[id]?.column ?? 0))
                var row = min(128, max(0, positions[id]?.row ?? 0))
                while true {
                    let cells = (0..<rows).flatMap { y in (0..<span).map { x in (row + y) * gridColumns + column + x } }
                    if cells.allSatisfy({ !occupied.contains($0) }) {
                        occupied.formUnion(cells)
                        placed[id] = Placement(
                            id: id,
                            frame: CGRect(
                                x: CGFloat(column) * (side + 16), y: CGFloat(row) * rowStride,
                                width: size.width(columnWidth: columnWidth, columns: columns), height: height))
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
            self.columns = columns
            self.columnWidth = columnWidth
            placements = ids.compactMap { placed[$0] }
            self.height = placements.map(\.frame.maxY).max() ?? 0
            return
        }
        if widgets.contains(where: { sizes[$0] == .square }) {

            let subdivisions = columnWidth >= 16 ? 2 : 1
            let compactColumns = columns * subdivisions
            let side = StartWidgetSize.squareSide(columnWidth: columnWidth)
            var bottoms = Array(repeating: CGFloat.zero, count: compactColumns)
            var seen = Set<String>()
            var result: [Placement] = []
            for id in widgets where StartWidgetKind(rawValue: id) != nil && seen.insert(id).inserted {
                let size = sizes[id] ?? .small
                let span = size == .square ? 1 : min(columns, size.columns) * subdivisions
                let column =
                    stride(from: 0, through: compactColumns - span, by: 1).min { left, right in
                        bottoms[left..<left + span].max()! < bottoms[right..<right + span].max()!
                    } ?? 0
                let y = (column..<column + span).map { bottoms[$0] }.max() ?? 0
                let frame = CGRect(
                    x: CGFloat(column) * (side + 16), y: y,
                    width: size.width(columnWidth: columnWidth, columns: columns),
                    height: size.height(columnWidth: columnWidth))
                result.append(Placement(id: id, frame: frame))
                for index in column..<column + span { bottoms[index] = frame.maxY + 16 }
            }
            self.columns = columns
            self.columnWidth = columnWidth
            placements = result
            height = result.map(\.frame.maxY).max() ?? 0
            return
        }
        var occupied = Set<Int>()
        var result: [Placement] = []
        var cursor = 0
        var bottom = 0
        var seen = Set<String>()
        for id in widgets where StartWidgetKind(rawValue: id) != nil && seen.insert(id).inserted {
            let size = sizes[id] ?? .small
            let span = min(columns, size.columns)
            while true {
                let row = cursor / columns
                let column = cursor % columns
                let cells = (0..<size.rows).flatMap { y in (0..<span).map { x in (row + y) * columns + column + x } }
                if column + span <= columns && cells.allSatisfy({ !occupied.contains($0) }) {
                    occupied.formUnion(cells)
                    let frame = CGRect(
                        x: CGFloat(column) * (columnWidth + 16), y: CGFloat(row) * 192,
                        width: CGFloat(span) * columnWidth + CGFloat(span - 1) * 16,
                        height: CGFloat(size.rows) * 176 + CGFloat(size.rows - 1) * 16)
                    result.append(Placement(id: id, frame: frame))
                    bottom = max(bottom, row + size.rows)
                    cursor += span
                    break
                }
                cursor += 1
            }
        }
        self.columns = columns
        self.columnWidth = columnWidth
        placements = result
        height = bottom == 0 ? 0 : CGFloat(bottom) * 192 - 16
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
