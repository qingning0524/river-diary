import Foundation

/// 日级天气上下文。它不是事实证据，只是解释一天的氛围；没有位置时宁可不采，
/// 也不按城市名猜。使用 Open-Meteo 的公开预报接口，不需要 API Key。
struct WeatherContext: Codable, Equatable {
    var dateKey: String
    var code: Int
    var summary: String
    var maxC: Double
    var minC: Double
    var precipitationMm: Double
    var latitude: Double
    var longitude: Double
    var fetchedAt: Date
}

enum WeatherContextClient {
    static let sourceLabel = "Open-Meteo"
    private static let cacheKey = "ingestion.weatherCache"
    private static let maximumCacheAge: TimeInterval = 6 * 3600
    private static let maximumCoordinateDistance = 0.1

    /// 从 V2 事件里找最近一次带坐标的观测（包括复制过来的 iPhone 位置）。
    static func latestCoordinate(from events: [RawEvent]) -> (latitude: Double, longitude: Double)? {
        let candidates: [(Date, Double, Double)] = events.compactMap { event in
            guard let latitude = event.payload.latitude,
                  let longitude = event.payload.longitude,
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude) else { return nil }
            return (event.timestamp, latitude, longitude)
        }
        guard let latest = candidates.max(by: { $0.0 < $1.0 }) else { return nil }
        return (latest.1, latest.2)
    }

    static func fetchIfNeeded(
        dayKey: String,
        latitude: Double,
        longitude: Double,
        now: Date = Date()
    ) async -> WeatherContext? {
        if let cached = cached(dayKey: dayKey, latitude: latitude, longitude: longitude, now: now) {
            return cached
        }
        guard let context = await fetch(dayKey: dayKey, latitude: latitude, longitude: longitude, now: now) else {
            return nil
        }
        if let data = try? JSONEncoder().encode(context) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        return context
    }

    static func cached(
        dayKey: String,
        latitude: Double,
        longitude: Double,
        now: Date = Date()
    ) -> WeatherContext? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let context = try? JSONDecoder().decode(WeatherContext.self, from: data),
              context.dateKey == dayKey,
              now.timeIntervalSince(context.fetchedAt) >= 0,
              now.timeIntervalSince(context.fetchedAt) < maximumCacheAge,
              abs(context.latitude - latitude) < maximumCoordinateDistance,
              abs(context.longitude - longitude) < maximumCoordinateDistance else {
            return nil
        }
        return context
    }

    static func fetch(
        dayKey: String,
        latitude: Double,
        longitude: Double,
        now: Date = Date()
    ) async -> WeatherContext? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("RiverDiary/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return decode(data, dayKey: dayKey, latitude: latitude, longitude: longitude, fetchedAt: now)
        } catch {
            return nil
        }
    }

    static func decode(
        _ data: Data,
        dayKey: String,
        latitude: Double,
        longitude: Double,
        fetchedAt: Date = Date()
    ) -> WeatherContext? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let code = response.daily.weather_code.first,
              let maxC = response.daily.temperature_2m_max.first,
              let minC = response.daily.temperature_2m_min.first,
              let precipitation = response.daily.precipitation_sum.first,
              maxC.isFinite, minC.isFinite, precipitation.isFinite else {
            return nil
        }
        let condition = conditionSummary(code)
        var summary = "\(condition) \(Int(minC.rounded()))–\(Int(maxC.rounded()))°C"
        if precipitation > 0.05 {
            summary += " · 降水 \(String(format: "%.1f", precipitation))mm"
        }
        return WeatherContext(
            dateKey: dayKey,
            code: code,
            summary: summary,
            maxC: maxC,
            minC: minC,
            precipitationMm: precipitation,
            latitude: latitude,
            longitude: longitude,
            fetchedAt: fetchedAt
        )
    }

    /// WMO weather code 的常用中文摘要；未知代码退回到“天气未知”，不猜测。
    static func conditionSummary(_ code: Int) -> String {
        switch code {
        case 0: "晴"
        case 1: "大致晴朗"
        case 2: "局部多云"
        case 3: "阴"
        case 45, 48: "有雾"
        case 51, 53, 55: "毛毛雨"
        case 56, 57: "冻毛毛雨"
        case 61, 63, 65: "雨"
        case 66, 67: "冻雨"
        case 71, 73, 75: "雪"
        case 77: "米雪"
        case 80, 81, 82: "阵雨"
        case 85, 86: "阵雪"
        case 95: "雷暴"
        case 96, 99: "雷暴伴冰雹"
        default: "天气未知"
        }
    }

    private struct Response: Decodable {
        struct Daily: Decodable {
            var weather_code: [Int]
            var temperature_2m_max: [Double]
            var temperature_2m_min: [Double]
            var precipitation_sum: [Double]
        }
        var daily: Daily
    }
}
