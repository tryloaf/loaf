import AppKit
import SwiftUI

struct WeatherWidgetLayout {
    let size: CGSize
    var tiny: Bool { size.height < 110 || size.width < 120 }
    var horizontal: Bool { size.width >= 280 && size.height < 225 }
    var verticalForecast: Bool { size.width < 230 && size.height >= 260 }
    var showsForecast: Bool { horizontal || size.height >= 200 }
    var showsTrend: Bool { size.width >= 230 && size.height >= 250 }
    var forecastCount: Int {
        if verticalForecast { return max(3, min(6, Int((size.height - 125) / 28))) }
        let width = horizontal ? size.width * 0.60 - 16 : size.width
        return max(3, min(8, Int(width / 43)))
    }
    var temperatureSize: CGFloat {
        if tiny { return max(18, min(34, min(size.width / 3.8, size.height * 0.5))) }
        return horizontal ? min(56, size.height * 0.42) : showsTrend ? 66 : min(54, size.width / 3)
    }
}

struct StartWeatherWidget: View {
    let store: BrowserStore
    @ObservedObject var weather: WeatherService
    let privateMode: Bool
    @Environment(\.colorScheme) private var scheme
    private var place: String {
        if !weather.city.isEmpty { return weather.city }
        return store.preferences.hasWeatherLocation ? store.preferences.weatherLocationLabel : "weather"
    }
    var body: some View {
        GeometryReader { geometry in
            let layout = WeatherWidgetLayout(size: geometry.size)
            VStack(alignment: .leading, spacing: layout.tiny ? 4 : 12) {
                if weather.temperature == nil {
                    empty(layout)
                } else if layout.horizontal {
                    HStack(alignment: .center, spacing: 16) {
                        current(layout).frame(width: geometry.size.width * 0.36, alignment: .leading)
                        hourly(layout, vertical: false)
                    }.frame(maxHeight: .infinity)
                } else {
                    current(layout)
                    if layout.showsTrend && weather.hours.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(weather.hours.count >= 20 ? "next 24 hours" : "hourly outlook")
                                Spacer()
                                if let low = weather.hours.map(\.temperature).min(),
                                    let high = weather.hours.map(\.temperature).max()
                                {
                                    Text("\(low)° – \(high)°").monospacedDigit()
                                }
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                            WeatherTemperatureTrend(hours: weather.hours).frame(
                                height: min(58, geometry.size.height * 0.18))
                        }.padding(.top, 2)
                    }
                    if layout.showsForecast && !weather.hours.isEmpty {
                        hourly(layout, vertical: layout.verticalForecast)
                    }
                    Spacer(minLength: 0)
                }
                if weather.temperature != nil { attribution }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.modifier(WeatherRefresh(store: store))
    }
    private func current(_ layout: WeatherWidgetLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.tiny ? 3 : 5) {
            if layout.size.height >= 70 {
                Text(place).font(.system(size: layout.showsTrend ? 15 : layout.tiny ? 10 : 12, weight: .medium))
                    .lineLimit(1).truncationMode(.tail).help(place)
            }
            HStack(spacing: layout.tiny ? 6 : 10) {
                Text(weather.temperature.map { "\($0)°" } ?? "—")
                    .font(.system(size: layout.temperatureSize, weight: .light)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                GolzheimIcon(icon: weather.icon, size: layout.temperatureSize * 0.52)
                    .foregroundStyle(.secondary).accessibilityLabel(weather.condition)
            }
            if !layout.tiny {
                Text(weather.error ?? weather.condition).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func hourly(_ layout: WeatherWidgetLayout, vertical: Bool) -> some View {
        let hours = Array(weather.hours.prefix(layout.forecastCount))
        if vertical {
            VStack(spacing: 8) {
                ForEach(hours) { hour in
                    HStack(spacing: 8) {
                        Text(hour.date, format: .dateTime.hour()).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if let icon = hour.icon { GolzheimIcon(icon: icon, size: 16).foregroundStyle(.secondary) }
                        Text("\(hour.temperature)°").font(.system(size: 13, weight: .medium)).monospacedDigit().frame(
                            minWidth: 30, alignment: .trailing)
                    }.frame(height: 20).accessibilityElement(children: .combine)
                }
            }.padding(.top, 4).accessibilityLabel("hourly forecast")
        } else {
            let precipitation = hours.contains { ($0.precipitationChance ?? 0) >= 0.1 }
            HStack(spacing: 4) {
                ForEach(hours) { hour in
                    VStack(spacing: 7) {
                        Text(hour.date, format: .dateTime.hour()).font(.system(size: 10)).foregroundStyle(.secondary)
                        if let icon = hour.icon { GolzheimIcon(icon: icon, size: 18).foregroundStyle(.secondary) }
                        Text("\(hour.temperature)°").font(.system(size: 13, weight: .medium)).monospacedDigit()
                        if precipitation {
                            Text(hour.precipitationChance.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                .accessibilityLabel(
                                    hour.precipitationChance.map {
                                        "\(Int(($0 * 100).rounded())) percent chance of precipitation"
                                    } ?? "precipitation unavailable")
                        }
                    }.lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                }
            }.padding(.top, layout.horizontal ? 0 : 6).accessibilityLabel("hourly forecast")
        }
    }
    private func empty(_ layout: WeatherWidgetLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.tiny ? 5 : 10) {
            HStack(spacing: 8) {
                GolzheimIcon(icon: .partlyCloudy, size: layout.tiny ? 20 : 30).foregroundStyle(.tertiary)
                if weather.loading { ProgressView().controlSize(.small) }
            }
            Text(weather.loading ? "loading weather…" : weather.error ?? "your local forecast")
                .font(.system(size: layout.tiny ? 10 : 12)).foregroundStyle(.secondary)
                .lineLimit(layout.tiny ? 2 : 3).help(weather.error ?? "weather")
            if !store.preferences.hasWeatherLocation && !weather.loading {
                Button("choose location…") {
                    store.application.coordinator?.showSettings(for: store, section: "sidebar")
                }
                .buttonStyle(.plain).font(.system(size: layout.tiny ? 10 : 12)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private var attribution: some View {
        Button {
            NSWorkspace.shared.open(weather.attributionURL)
        } label: {
            if let mark = scheme == .dark ? weather.attributionMarkDark : weather.attributionMarkLight {
                Image(nsImage: mark).resizable().scaledToFit().frame(maxWidth: 100, maxHeight: 12)
            } else {
                Text(weather.attribution).font(.system(size: 9)).foregroundStyle(
                    privateMode ? PrivateChrome.accent : .secondary)
            }
        }.buttonStyle(.plain).accessibilityLabel(weather.attribution)
    }
}

struct WeatherTemperatureTrend: View {
    let hours: [WeatherHour]
    var body: some View {
        GeometryReader { geometry in
            let values = hours.prefix(24).map { Double($0.temperature) }
            let low = values.min() ?? 0
            let span = max(4, (values.max() ?? low) - low)
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: geometry.size.width * Double(index) / Double(max(1, values.count - 1)),
                    y: 4 + (geometry.size.height - 8) * (1 - (value - low) / span))
            }
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }.stroke(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }.accessibilityLabel(
            hours.count >= 20 ? "temperature trend over the next 24 hours" : "hourly temperature trend")
    }
}
