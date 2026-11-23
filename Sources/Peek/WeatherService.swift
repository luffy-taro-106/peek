import CoreLocation
import Foundation

struct WeatherNow {
    let temperature: Double
    let feelsLike: Double
    let humidity: Int
    let wind: Double
    let code: Int
    let isDay: Bool
}

struct WeatherHour: Identifiable {
    var id: Date { time }
    let time: Date
    let temperature: Double
    let code: Int
    let precipChance: Int
}

struct WeatherDay: Identifiable {
    var id: Date { date }
    let date: Date
    let high: Double
    let low: Double
    let code: Int
    let sunrise: Date?
    let sunset: Date?
}

struct PlaceResult: Identifiable, Hashable {
    var id: String { "\(lat),\(lon)" }
    let name: String
    let detail: String
    let lat: Double
    let lon: Double
}

enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func text(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61, 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71, 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80, 81: return "Showers"
        case 82: return "Violent showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "—"
        }
    }
}

@MainActor
final class WeatherService: NSObject, ObservableObject {
    @Published private(set) var now: WeatherNow?
    @Published private(set) var hours: [WeatherHour] = []
    @Published private(set) var days: [WeatherDay] = []
    @Published private(set) var place = ""
    @Published private(set) var status: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var timer: Timer?
    private var coordinate: CLLocationCoordinate2D?

    var useFahrenheit: Bool { UserDefaults.standard.string(forKey: "weatherUnit") == "f" }
    var manualMode: Bool { UserDefaults.standard.string(forKey: "weatherMode") == "manual" }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorization = manager.authorizationStatus
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let d = UserDefaults.standard
        if manualMode, d.object(forKey: "manualLat") != nil {
            let c = CLLocationCoordinate2D(latitude: d.double(forKey: "manualLat"), longitude: d.double(forKey: "manualLon"))
            place = d.string(forKey: "manualCity") ?? ""
            fetch(c, needsName: false)
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            status = "Allow location to see local weather"
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = "Location is off — pick a city in Settings"
        default:
            manager.requestLocation()
        }
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func setManual(_ p: PlaceResult?) {
        let d = UserDefaults.standard
        if let p {
            d.set("manual", forKey: "weatherMode")
            d.set(p.lat, forKey: "manualLat")
            d.set(p.lon, forKey: "manualLon")
            d.set(p.name, forKey: "manualCity")
        } else {
            d.set("auto", forKey: "weatherMode")
        }
        refresh()
    }

    func format(_ celsius: Double) -> String {
        let v = useFahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(v.rounded()))°"
    }

    // MARK: Network

    private func fetch(_ c: CLLocationCoordinate2D, needsName: Bool) {
        coordinate = c
        let lat = String(format: "%.2f", c.latitude)
        let lon = String(format: "%.2f", c.longitude)
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: lat),
            .init(name: "longitude", value: lon),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "6"),
            .init(name: "timeformat", value: "unixtime"),
        ]
        let url = comps.url!
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try self.apply(data)
                self.status = nil
                self.lastUpdated = Date()
            } catch {
                self.status = "Weather unavailable (\(error.localizedDescription))"
            }
        }
        if needsName {
            CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)) { marks, _ in
                let name = marks?.first.flatMap { $0.locality ?? $0.subAdministrativeArea ?? $0.name } ?? ""
                Task { @MainActor in if !name.isEmpty { self.place = name } }
            }
        }
    }

    private func apply(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let c = root["current"] as? [String: Any] {
            now = WeatherNow(
                temperature: num(c["temperature_2m"]),
                feelsLike: num(c["apparent_temperature"]),
                humidity: Int(num(c["relative_humidity_2m"])),
                wind: num(c["wind_speed_10m"]),
                code: Int(num(c["weather_code"])),
                isDay: Int(num(c["is_day"])) == 1
            )
        }
        if let h = root["hourly"] as? [String: Any],
           let times = h["time"] as? [Double],
           let temps = h["temperature_2m"] as? [Any],
           let codes = h["weather_code"] as? [Any] {
            let precip = (h["precipitation_probability"] as? [Any]) ?? []
            let start = Date().addingTimeInterval(-3600)
            var out: [WeatherHour] = []
            for (i, t) in times.enumerated() {
                let d = Date(timeIntervalSince1970: t)
                guard d >= start, i < temps.count, i < codes.count else { continue }
                out.append(WeatherHour(time: d, temperature: num(temps[i]), code: Int(num(codes[i])),
                                       precipChance: i < precip.count ? Int(num(precip[i])) : 0))
                if out.count >= 12 { break }
            }
            hours = out
        }
        if let d = root["daily"] as? [String: Any],
           let times = d["time"] as? [Double],
           let hi = d["temperature_2m_max"] as? [Any],
           let lo = d["temperature_2m_min"] as? [Any],
           let codes = d["weather_code"] as? [Any] {
            let rise = (d["sunrise"] as? [Double]) ?? []
            let set = (d["sunset"] as? [Double]) ?? []
            days = times.enumerated().compactMap { i, t in
                guard i < hi.count, i < lo.count, i < codes.count else { return nil }
                return WeatherDay(date: Date(timeIntervalSince1970: t), high: num(hi[i]), low: num(lo[i]),
                                  code: Int(num(codes[i])),
                                  sunrise: i < rise.count ? Date(timeIntervalSince1970: rise[i]) : nil,
                                  sunset: i < set.count ? Date(timeIntervalSince1970: set[i]) : nil)
            }
        }
    }

    private func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    /// City search for manual location (Open-Meteo geocoding).
    static func search(_ query: String) async -> [PlaceResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [.init(name: "name", value: q), .init(name: "count", value: "6"), .init(name: "language", value: "en")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let name = r["name"] as? String, let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
            let detail = [r["admin1"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")
            return PlaceResult(name: name, detail: detail, lat: lat, lon: lon)
        }
    }
}

extension WeatherService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedAlways || status == .authorized {
                if !self.manualMode { manager.requestLocation() }
            } else if status == .denied || status == .restricted {
                if !self.manualMode { self.status = "Location is off — pick a city in Settings" }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let c = loc.coordinate
        Task { @MainActor in
            guard !self.manualMode else { return }
            self.fetch(c, needsName: true)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in
            if let c = self.coordinate { self.fetch(c, needsName: false) }
            else if self.now == nil { self.status = "Can't get location (\(msg))" }
        }
    }
}

extension WeatherService {
    func loadPreviewData() {
        now = WeatherNow(temperature: 22, feelsLike: 21, humidity: 48, wind: 11, code: 2, isDay: true)
        place = "Lisbon"
        let cal = Calendar.current
        let h0 = cal.date(bySetting: .minute, value: 0, of: Date())!
        let codes = [2, 1, 0, 0, 1, 2, 3, 61, 61, 3, 2, 1]
        hours = (0..<12).map { i in WeatherHour(time: h0.addingTimeInterval(Double(i) * 3600), temperature: 22 + sin(Double(i) / 2) * 3,
                                                code: codes[i], precipChance: [61].contains(codes[i]) ? 60 : 0) }
        let day0 = cal.startOfDay(for: Date())
        let dcodes = [2, 61, 3, 0, 1, 95]
        days = (0..<6).map { i in WeatherDay(date: day0.addingTimeInterval(Double(i) * 86400), high: 24 - Double(i % 3), low: 15 + Double(i % 2),
                                             code: dcodes[i], sunrise: nil, sunset: nil) }
        status = nil
    }
}
