import AppKit
import Combine
import CoreLocation
import Foundation
import SwiftUI
import WeatherKit

nonisolated struct WeatherHour: Identifiable {
    let date: Date
    let temperature: Int
    var id: Date { date }
}
nonisolated struct WeatherPlace: Codable {
    let name: String
    let latitude: Double
    let longitude: Double
    var valid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    var key: String { "\(latitude),\(longitude)" }
}
nonisolated struct WeatherSnapshot: Codable {
    struct Hour: Codable {
        let date: Date
        let celsius: Double
    }
    enum Source: String, Codable { case apple, openMeteo }
    var updated: Date
    let celsius: Double
    let hours: [Hour]
    let condition: String
    let icon: String
    let source: Source
    let attributionURL: URL
    var lightMark: Data? = nil
    var darkMark: Data? = nil
    var valid: Bool {
        (-120...80).contains(celsius)
            && hours.allSatisfy { (-120...80).contains($0.celsius) && $0.date.timeIntervalSince1970.isFinite }
            && attributionURL.scheme == "https"
    }
}

@MainActor final class WeatherService: ObservableObject {
    @Published var temperature: Int?
    @Published var hours: [WeatherHour] = []
    @Published var city = ""
    @Published var condition = ""
    @Published var icon: LoafIcon = .sun
    @Published var error: String?
    @Published var loading = false
    @Published var updated: Date?
    @Published var attribution = "Open-Meteo"
    @Published var attributionURL = URL(string: "https://open-meteo.com/")!
    @Published var attributionMarkLight: NSImage?
    @Published var attributionMarkDark: NSImage?
    static let freshness: TimeInterval = 15 * 60
    static let staleLifetime: TimeInterval = 6 * 60 * 60
    typealias ForecastLoader = (WeatherPlace) async throws -> WeatherSnapshot
    private struct Located: Codable {
        let place: WeatherPlace
        let updated: Date
    }
    private struct Cache: Codable {
        var version = 1
        var places: [String: Located] = [:]
        var forecasts: [String: WeatherSnapshot] = [:]
        var appleRetryAfter: Date?
    }
    private let cacheURL: URL?
    private var cache = Cache()
    private let now: () -> Date
    private let appleAvailable: () -> Bool
    private let geocode: (String) async throws -> WeatherPlace
    private let appleForecast: ForecastLoader
    private let openForecast: ForecastLoader
    private var locationRequests: [String: Task<WeatherPlace, Error>] = [:]
    private var forecasts: [String: Task<WeatherSnapshot, Error>] = [:]
    private var retries: [String: Date] = [:]
    private var requestID = UUID()

    init(
        cacheURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("app.tryloaf.loaf/weather-v1.json"),
        now: @escaping () -> Date = Date.init,
        appleAvailable: @escaping () -> Bool = { MainActor.assumeIsolated { SecurityStatus.weatherKit } },
        geocode: ((String) async throws -> WeatherPlace)? = nil,
        appleForecast: ForecastLoader? = nil, openForecast: ForecastLoader? = nil
    ) {
        self.cacheURL = cacheURL
        self.now = now
        self.appleAvailable = appleAvailable
        self.geocode = geocode ?? Self.locate
        self.appleForecast = appleForecast ?? Self.loadApple
        self.openForecast = openForecast ?? Self.loadOpenMeteo
        if let cacheURL, let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
            (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 4 * 1024 * 1024,
            let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(Cache.self, from: data),
            saved.version == 1
        {
            cache = saved
            prune()
        }
    }
    static func normalizedCity(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ").folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func fetch(city query: String, fahrenheit: Bool, preferredProvider: String = "automatic") async {
        let token = UUID()
        requestID = token
        let query = Self.normalizedCity(query)
        guard !query.isEmpty else {
            temperature = nil
            hours = []
            city = ""
            condition = ""
            updated = nil
            loading = false
            error = nil
            return
        }
        loading = true
        error = nil
        defer { if requestID == token { loading = false } }
        do {
            if let retry = retries[query], retry > now() { throw URLError(.resourceUnavailable) }
            let place = try await resolve(query)
            try await load(place, fahrenheit: fahrenheit, preferredProvider: preferredProvider, token: token)
        } catch {
            fail(token)
        }
    }
    func fetch(location: CLLocation, fahrenheit: Bool, preferredProvider: String = "automatic") async {
        let token = UUID()
        requestID = token
        let coordinate = location.coordinate
        let place = WeatherPlace(name: "current location", latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard place.valid else {
            fail(token)
            return
        }
        loading = true
        error = nil
        defer { if requestID == token { loading = false } }
        do {
            try await load(place, fahrenheit: fahrenheit, preferredProvider: preferredProvider, token: token)
        } catch {
            fail(token)
        }
    }
    private func load(_ place: WeatherPlace, fahrenheit: Bool, preferredProvider: String, token: UUID) async throws {
        let key = place.key + (preferredProvider == "open-meteo" ? ":open" : ":automatic")
        let snapshot: WeatherSnapshot
        if let saved = cache.forecasts[key], fresh(saved.updated, for: Self.freshness) {
            snapshot = saved
        } else {
            do {
                snapshot = try await forecast(place, key: key, automatic: preferredProvider != "open-meteo")
            } catch {
                if let saved = cache.forecasts[key], fresh(saved.updated, for: Self.staleLifetime) {
                    guard requestID == token else { return }
                    apply(saved, place: place, fahrenheit: fahrenheit)
                    self.error = "showing saved weather · couldn’t refresh"
                    return
                }
                throw error
            }
        }
        guard requestID == token, !Task.isCancelled else { return }
        apply(snapshot, place: place, fahrenheit: fahrenheit)
    }
    private func fail(_ token: UUID) {
        guard requestID == token, !Task.isCancelled else { return }
        error = "weather unavailable. check the location and try again."
        temperature = nil
        hours = []
        city = ""
        condition = ""
        updated = nil
    }
    private func fresh(_ date: Date, for age: TimeInterval) -> Bool {
        (0..<age).contains(now().timeIntervalSince(date))
    }
    private func resolve(_ query: String) async throws -> WeatherPlace {
        if let saved = cache.places[query], fresh(saved.updated, for: 30 * 24 * 60 * 60) { return saved.place }
        if let running = locationRequests[query] { return try await running.value }
        let task = Task { try await geocode(query) }
        locationRequests[query] = task
        defer { locationRequests[query] = nil }
        do {
            let place = try await task.value
            guard place.valid else { throw URLError(.cannotFindHost) }
            cache.places[query] = Located(place: place, updated: now())
            persist()
            return place
        } catch {
            retries[query] = now().addingTimeInterval(5 * 60)
            throw error
        }
    }
    private func forecast(_ place: WeatherPlace, key: String, automatic: Bool) async throws -> WeatherSnapshot {
        if let running = forecasts[key] { return try await running.value }
        if let retry = retries[key], retry > now() { throw URLError(.resourceUnavailable) }
        let task = Task { () throws -> WeatherSnapshot in
            var value: WeatherSnapshot?
            if automatic, appleAvailable(), (cache.appleRetryAfter ?? .distantPast) <= now() {
                do {
                    value = try await appleForecast(place)
                    cache.appleRetryAfter = nil
                } catch {
                    if error is CancellationError { throw error }
                    cache.appleRetryAfter = now().addingTimeInterval(Self.freshness)
                    persist()
                }
            }
            if value == nil { value = try await openForecast(place) }
            guard var value, value.valid else { throw URLError(.cannotParseResponse) }
            value.updated = now()
            cache.forecasts[key] = value
            retries[key] = nil
            persist()
            return value
        }
        forecasts[key] = task
        defer { forecasts[key] = nil }
        do { return try await task.value } catch {
            retries[key] = now().addingTimeInterval(5 * 60)
            throw error
        }
    }
    private func apply(_ value: WeatherSnapshot, place: WeatherPlace, fahrenheit: Bool) {
        func degrees(_ celsius: Double) -> Int { Int((fahrenheit ? celsius * 9 / 5 + 32 : celsius).rounded()) }
        temperature = degrees(value.celsius)
        city = place.name
        condition = value.condition
        hours = value.hours.filter { $0.date > now() }.prefix(3).map {
            WeatherHour(date: $0.date, temperature: degrees($0.celsius))
        }
        icon = LoafIcon(rawValue: value.icon) ?? .sun
        updated = value.updated
        attribution = value.source == .apple ? "Apple Weather" : "Open-Meteo"
        attributionURL = value.attributionURL
        attributionMarkLight = value.lightMark.flatMap(NSImage.init(data:))
        attributionMarkDark = value.darkMark.flatMap(NSImage.init(data:))
    }
    private func prune() {
        cache.places = Dictionary(
            uniqueKeysWithValues: cache.places.filter {
                $0.value.place.valid && fresh($0.value.updated, for: 30 * 24 * 60 * 60)
            }.sorted { $0.value.updated > $1.value.updated }.prefix(24).map { ($0.key, $0.value) })
        cache.forecasts = Dictionary(
            uniqueKeysWithValues: cache.forecasts.filter {
                $0.value.valid && fresh($0.value.updated, for: Self.staleLifetime)
            }.sorted { $0.value.updated > $1.value.updated }.prefix(8).map { ($0.key, $0.value) })
    }
    private func persist() {
        prune()
        guard let cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
    private static func locate(_ query: String) async throws -> WeatherPlace {
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [
            .init(name: "name", value: query), .init(name: "count", value: "1"), .init(name: "language", value: "en"),
        ]
        let data = try await AssetRequest.data(url.url!, limit: 512 * 1024)
        struct Geocode: Decodable { let results: [WeatherPlace]? }
        guard let place = try JSONDecoder().decode(Geocode.self, from: data).results?.first, place.valid else {
            throw URLError(.cannotFindHost)
        }
        return place
    }
    private struct AppleMarks {
        let legal: URL
        let light: Data
        let dark: Data
    }
    @MainActor private static var appleMarks: (date: Date, task: Task<AppleMarks, Error>)?
    @MainActor private static func marks() async throws -> AppleMarks {
        if let saved = appleMarks, Date().timeIntervalSince(saved.date) < 24 * 60 * 60 {
            return try await saved.task.value
        }
        let task = Task {
            let attribution = try await WeatherKit.WeatherService.shared.attribution
            async let light = AssetRequest.data(attribution.combinedMarkLightURL, limit: 128 * 1024)
            async let dark = AssetRequest.data(attribution.combinedMarkDarkURL, limit: 128 * 1024)
            return try await AppleMarks(legal: attribution.legalPageURL, light: light, dark: dark)
        }
        appleMarks = (Date(), task)
        do { return try await task.value } catch {
            appleMarks = nil
            throw error
        }
    }
    @MainActor private static func loadApple(_ place: WeatherPlace) async throws -> WeatherSnapshot {
        let result = try await WeatherKit.WeatherService.shared.weather(
            for: CLLocation(latitude: place.latitude, longitude: place.longitude), including: .current, .hourly)
        let mark = try await marks()
        let current = result.0
        let symbol = current.symbolName
        let icon: LoafIcon =
            symbol.contains("snow")
            ? .snow
            : symbol.contains("rain")
                ? .rain
                : symbol.contains("bolt")
                    ? .storm
                    : symbol.contains("fog")
                        ? .fog : symbol.contains("cloud.sun") ? .partlyCloudy : symbol.contains("cloud") ? .cloud : .sun
        return WeatherSnapshot(
            updated: Date(), celsius: current.temperature.converted(to: .celsius).value,
            hours: result.1.forecast.prefix(48).map {
                .init(date: $0.date, celsius: $0.temperature.converted(to: .celsius).value)
            },
            condition: current.condition.description, icon: icon.rawValue, source: .apple, attributionURL: mark.legal,
            lightMark: mark.light, darkMark: mark.dark)
    }
    private static func loadOpenMeteo(_ place: WeatherPlace) async throws -> WeatherSnapshot {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "hourly", value: "temperature_2m"), .init(name: "timeformat", value: "unixtime"),
            .init(name: "forecast_days", value: "2"),
        ]
        struct Forecast: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let weather_code: Int
            }
            struct Hourly: Decodable {
                let time: [Double]
                let temperature_2m: [Double]
            }
            let current: Current
            let hourly: Hourly?
        }
        let value = try JSONDecoder().decode(Forecast.self, from: await AssetRequest.data(url.url!, limit: 512 * 1024))
        let current = value.current
        let icon: LoafIcon
        let condition: String
        switch current.weather_code {
        case 0:
            icon = .sun
            condition = "clear skies"
        case 1, 2:
            icon = .partlyCloudy
            condition = "partly cloudy"
        case 3:
            icon = .cloud
            condition = "overcast"
        case 45, 48:
            icon = .fog
            condition = "foggy"
        case 71...77, 85, 86:
            icon = .snow
            condition = "snow"
        case 95...99:
            icon = .storm
            condition = "thunderstorms"
        default:
            icon = .rain
            condition = "rain"
        }
        return WeatherSnapshot(
            updated: Date(), celsius: current.temperature_2m,
            hours: zip(value.hourly?.time ?? [], value.hourly?.temperature_2m ?? []).map {
                .init(date: Date(timeIntervalSince1970: $0.0), celsius: $0.1)
            },
            condition: condition, icon: icon.rawValue, source: .openMeteo,
            attributionURL: URL(string: "https://open-meteo.com/")!)
    }
}

struct WeatherRefresh: ViewModifier {
    let store: BrowserStore
    private var identity: String {
        "\(store.preferences.weatherCity):\(store.preferences.fahrenheit):\(store.preferences.weatherProvider ?? "automatic")"
    }
    private func refresh() async {
        if store.preferences.weatherUsesCurrentLocation == true {
            await store.application.weatherLocation.refreshWeather()
        } else {
            await store.weather.fetch(
                city: store.preferences.weatherCity, fahrenheit: store.preferences.fahrenheit,
                preferredProvider: store.preferences.weatherProvider ?? "automatic")
        }
    }
    func body(content: Content) -> some View {
        content.task(id: identity) {
            do {
                while !Task.isCancelled {
                    if NSApp.isActive { await refresh() }
                    try await Task.sleep(for: .seconds(WeatherService.freshness))
                }
            } catch {}
        }.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }
}

@MainActor final class WeatherLocationRefreshBudget {
    static let maximumDailyRefreshes = 3
    static let minimumDistance: CLLocationDistance = 1_000
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let prefix: String

    init(defaults: UserDefaults = .standard, calendar: Calendar = .autoupdatingCurrent, prefix: String = "loaf.weather.location") {
        self.defaults = defaults
        self.calendar = calendar
        self.prefix = prefix
    }
    func establishBaseline(_ location: CLLocation) {
        defaults.set(location.coordinate.latitude, forKey: prefix + ".latitude")
        defaults.set(location.coordinate.longitude, forKey: prefix + ".longitude")
    }
    func consumeIfChanged(to location: CLLocation, now: Date = Date()) -> Bool {
        let day = calendar.startOfDay(for: now).timeIntervalSince1970
        if defaults.double(forKey: prefix + ".day") != day {
            defaults.set(day, forKey: prefix + ".day")
            defaults.set(0, forKey: prefix + ".count")
        }
        let hasBaseline = defaults.object(forKey: prefix + ".latitude") != nil
            && defaults.object(forKey: prefix + ".longitude") != nil
        if hasBaseline {
            let previous = CLLocation(
                latitude: defaults.double(forKey: prefix + ".latitude"),
                longitude: defaults.double(forKey: prefix + ".longitude"))
            guard location.distance(from: previous) >= Self.minimumDistance else { return false }
        }
        let count = defaults.integer(forKey: prefix + ".count")
        guard count < Self.maximumDailyRefreshes else { return false }
        defaults.set(count + 1, forKey: prefix + ".count")
        establishBaseline(location)
        return true
    }
}

@MainActor final class WeatherLocationMonitor: NSObject, CLLocationManagerDelegate {
    private weak var application: BrowserApplication?
    private let manager = CLLocationManager()
    private let budget: WeatherLocationRefreshBudget
    private var lastLocation: CLLocation?
    private var awaitingInitialLocation = false
    private var monitoring = false

    init(application: BrowserApplication, defaults: UserDefaults = .standard) {
        self.application = application
        budget = WeatherLocationRefreshBudget(defaults: defaults)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }
    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            manager.stopMonitoringSignificantLocationChanges()
            monitoring = false
            awaitingInitialLocation = false
            lastLocation = nil
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            requestInitialLocation()
        default:
            break
        }
    }
    func refreshWeather() async {
        guard application?.preferences.weatherUsesCurrentLocation == true else { return }
        if let lastLocation {
            await fetch(lastLocation)
        } else {
            setEnabled(true)
        }
    }
    private func requestInitialLocation() {
        guard !awaitingInitialLocation else { return }
        awaitingInitialLocation = true
        manager.requestLocation()
    }
    private func beginMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        manager.startMonitoringSignificantLocationChanges()
    }
    private func fetch(_ location: CLLocation) async {
        guard let application else { return }
        await application.weather.fetch(
            location: location, fahrenheit: application.preferences.fahrenheit,
            preferredProvider: application.preferences.weatherProvider ?? "automatic")
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard application?.preferences.weatherUsesCurrentLocation == true else { return }
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            requestInitialLocation()
        default:
            break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard application?.preferences.weatherUsesCurrentLocation == true,
            let location = locations.last(where: { $0.horizontalAccuracy >= 0 })
        else { return }
        lastLocation = location
        if awaitingInitialLocation {
            awaitingInitialLocation = false
            budget.establishBaseline(location)
            beginMonitoring()
            Task { await fetch(location) }
            return
        }
        beginMonitoring()
        if budget.consumeIfChanged(to: location) {
            Task { await fetch(location) }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if awaitingInitialLocation { awaitingInitialLocation = false }
    }
}
