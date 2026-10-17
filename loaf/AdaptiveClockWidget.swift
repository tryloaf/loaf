import SwiftUI

struct StartWidgetMetrics {
    let size: CGSize
    var tiny: Bool { size.width < 120 || size.height < 110 }
    var tall: Bool { size.height >= 250 }
    var expanded: Bool { size.width >= 260 && size.height >= 235 }
    func numberSize(minimum: CGFloat = 28, maximum: CGFloat = 76, characters: CGFloat = 4.5) -> CGFloat {
        min(maximum, max(minimum, min(size.width / characters, size.height * 0.42)))
    }
}

struct StartClockWidget: View {
    let options: StartWidgetOptions
    var previewDate: Date?
    static func time(_ date: Date, options: StartWidgetOptions) -> String {
        var style = Date.FormatStyle.dateTime.hour(
            options.clock24Hour == true ? .twoDigits(amPM: .omitted) : .defaultDigits(amPM: .abbreviated)
        ).minute()
        if options.clock24Hour == true { style = style.locale(Locale(identifier: "en_GB")) }
        if options.clockSeconds == true { style = style.second() }
        return date.formatted(style)
    }
    static func parts(_ date: Date, options: StartWidgetOptions) -> (time: String, period: String?, periodFirst: Bool) {
        let formatted = time(date, options: options)
        guard options.clock24Hour != true else { return (formatted, nil, false) }
        let formatter = DateFormatter()
        formatter.locale = .current
        let symbols = [formatter.amSymbol, formatter.pmSymbol].compactMap { $0 }.filter { !$0.isEmpty }
        for period in symbols {
            if let range = formatted.range(of: period, options: .caseInsensitive) {
                var digits = formatted
                digits.removeSubrange(range)
                return (
                    digits.trimmingCharacters(in: .whitespacesAndNewlines), period,
                    range.lowerBound == formatted.startIndex
                )
            }
        }
        return (formatted, nil, false)
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: options.clockSeconds == true ? 1 : 30)) { context in
            GeometryReader { geometry in
                let date = previewDate ?? MarketingLaunch.displayDate(context.date)
                let metrics = StartWidgetMetrics(size: geometry.size)
                let month = geometry.size.height >= 240 && geometry.size.width >= 126
                VStack(alignment: .leading, spacing: month ? 14 : 8) {
                    VStack(alignment: .leading, spacing: metrics.tiny ? 4 : 8) {
                        let parts = Self.parts(date, options: options)
                        let widthUnits = CGFloat(parts.time.count) * 0.58 + (parts.period == nil ? 0 : 0.9)
                        let font = min(
                            88,
                            max(
                                24,
                                min(
                                    geometry.size.width / max(1, widthUnits),
                                    geometry.size.height * (month ? 0.42 : 0.36))))
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if let period = parts.period, parts.periodFirst { periodLabel(period, size: font) }
                            Text(parts.time).font(.system(size: font, weight: .light)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.65).allowsTightening(true).layoutPriority(1)
                            if let period = parts.period, !parts.periodFirst { periodLabel(period, size: font) }
                        }.accessibilityElement(children: .ignore).accessibilityLabel(Self.time(date, options: options))
                        if geometry.size.height >= 70 {
                            Text(
                                date,
                                format: metrics.tiny
                                    ? .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                                    : .dateTime.weekday(.wide).month(.wide).day()
                            )
                            .textCase(.lowercase).font(.system(size: metrics.expanded ? 15 : metrics.tiny ? 11 : 13))
                            .foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if month {
                        StartMonthGrid(date: date).frame(maxHeight: .infinity)
                    } else if geometry.size.width >= 280 && geometry.size.height >= 115 {
                        StartWeekStrip(date: date).padding(.top, 6)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: month ? .topLeading : .leading)
            }
        }
    }
    private func periodLabel(_ text: String, size: CGFloat) -> some View {
        Text(text.lowercased()).font(.system(size: size * 0.40)).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
    }

}

struct StartMonthGrid: View {
    let date: Date
    var calendar = Calendar.current
    static func dates(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date),
            let start = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start,
            let last = calendar.date(byAdding: .day, value: -1, to: month.end),
            let lastWeek = calendar.dateInterval(of: .weekOfYear, for: last),
            let days = calendar.dateComponents([.day], from: start, to: lastWeek.end).day
        else { return [] }
        return (0..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    var body: some View {
        GeometryReader { geometry in
            let dates = Self.dates(containing: date, calendar: calendar)
            let rows = max(1, dates.count / 7)
            let rowHeight = max(14, min(28, (geometry.size.height - 22 - CGFloat(rows - 1) * 3) / CGFloat(rows)))
            let font = min(14, max(10, geometry.size.width / 25))
            VStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(0..<7) { index in
                        Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                            .font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                    ForEach(dates, id: \.self) { day in
                        let selected = calendar.isDate(day, inSameDayAs: date)
                        let currentMonth = calendar.isDate(day, equalTo: date, toGranularity: .month)
                        Text(day, format: .dateTime.day()).font(
                            .system(size: font, weight: selected ? .medium : .regular)
                        )
                        .foregroundStyle(currentMonth ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(maxWidth: .infinity).frame(height: rowHeight)
                        .background {
                            if selected { Circle().fill(Color.accentColor.opacity(0.14)).frame(width: rowHeight) }
                        }
                        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityLabel("month calendar")
    }
}

struct StartWeekStrip: View {
    let date: Date
    var body: some View {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        HStack(spacing: 2) {
            ForEach(0..<7) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                let selected = calendar.isDate(day, inSameDayAs: date)
                VStack(spacing: 4) {
                    Text(day, format: .dateTime.weekday(.narrow)).foregroundStyle(.tertiary)
                    Text(day, format: .dateTime.day()).foregroundStyle(selected ? .primary : .secondary)
                        .frame(width: 20, height: 20)
                        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: Circle())
                }.font(.system(size: 10)).frame(maxWidth: .infinity)
            }
        }.accessibilityLabel("this week")
    }
}

struct StartClockDial: View {
    let date: Date
    let zone: TimeZone
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 1
            context.stroke(
                Path(ellipseIn: CGRect(x: 1, y: 1, width: radius * 2, height: radius * 2)),
                with: .color(.primary.opacity(0.12)), lineWidth: 1)
            for tick in 0..<12 {
                let angle = Double(tick) * .pi / 6 - .pi / 2
                var path = Path()
                path.move(to: CGPoint(x: center.x + cos(angle) * (radius - 3), y: center.y + sin(angle) * (radius - 3)))
                path.addLine(
                    to: CGPoint(x: center.x + cos(angle) * (radius - 1), y: center.y + sin(angle) * (radius - 1)))
                context.stroke(path, with: .color(.primary.opacity(0.25)), lineWidth: 1)
            }
            var calendar = Calendar.current
            calendar.timeZone = zone
            let values = calendar.dateComponents([.hour, .minute], from: date)
            let minute = Double(values.minute ?? 0)
            for (value, length, width) in [
                (Double((values.hour ?? 0) % 12) / 12 + minute / 720, 0.48, 1.8), (minute / 60, 0.73, 1.2),
            ] {
                let angle = value * .pi * 2 - .pi / 2
                var hand = Path()
                hand.move(to: center)
                hand.addLine(
                    to: CGPoint(x: center.x + cos(angle) * radius * length, y: center.y + sin(angle) * radius * length))
                context.stroke(
                    hand, with: .color(.primary.opacity(0.65)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }.accessibilityHidden(true)
    }
}
