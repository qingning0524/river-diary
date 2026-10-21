import Foundation
import XCTest

@testable import RiverDiaryMac

final class WeatherContextTests: XCTestCase {
    func testConditionMapping() {
        XCTAssertEqual(WeatherContextClient.conditionSummary(0), "晴")
        XCTAssertEqual(WeatherContextClient.conditionSummary(3), "阴")
        XCTAssertEqual(WeatherContextClient.conditionSummary(61), "雨")
        XCTAssertEqual(WeatherContextClient.conditionSummary(95), "雷暴")
        XCTAssertEqual(WeatherContextClient.conditionSummary(999), "天气未知")
    }

    func testDecodeOpenMeteoFixture() throws {
        let json = """
        {"daily":{"time":["2026-10-21"],"weather_code":[3],
        "temperature_2m_max":[18.4],"temperature_2m_min":[10.6],"precipitation_sum":[0.0]}}
        """
        let context = try XCTUnwrap(WeatherContextClient.decode(
            Data(json.utf8),
            dayKey: "2026-10-21",
            latitude: 31.23,
            longitude: 121.47,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        XCTAssertEqual(context.code, 3)
        XCTAssertEqual(context.summary, "阴 11–18°C")
        XCTAssertEqual(context.maxC, 18.4, accuracy: 0.001)
        XCTAssertEqual(context.minC, 10.6, accuracy: 0.001)
    }

    func testDecodeIncludesPrecipitation() throws {
        let json = """
        {"daily":{"time":["2026-10-21"],"weather_code":[61],
        "temperature_2m_max":[16],"temperature_2m_min":[12],"precipitation_sum":[3.2]}}
        """
        let context = try XCTUnwrap(WeatherContextClient.decode(
            Data(json.utf8), dayKey: "2026-10-21", latitude: 31.23, longitude: 121.47
        ))
        XCTAssertTrue(context.summary.contains("降水 3.2mm"))
    }

    func testDecodeRejectsEmptyArrays() {
        let json = #"{"daily":{"time":[],"weather_code":[],"temperature_2m_max":[],"temperature_2m_min":[],"precipitation_sum":[]}}"#
        XCTAssertNil(WeatherContextClient.decode(
            Data(json.utf8), dayKey: "2026-10-21", latitude: 31.23, longitude: 121.47
        ))
    }

    func testLatestCoordinateUsesNewestValidObservation() throws {
        let older = RawEvent(
            timestamp: Date(timeIntervalSince1970: 100),
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(latitude: 30.0, longitude: 120.0)
        )
        let newer = RawEvent(
            timestamp: Date(timeIntervalSince1970: 200),
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(latitude: 31.0, longitude: 121.0)
        )
        let coordinate = try XCTUnwrap(WeatherContextClient.latestCoordinate(from: [older, newer]))
        XCTAssertEqual(coordinate.latitude, 31.0, accuracy: 0.0001)
        XCTAssertEqual(coordinate.longitude, 121.0, accuracy: 0.0001)
    }

    func testLatestCoordinateSkipsInvalidCoordinates() {
        let invalid = RawEvent(
            timestamp: Date(timeIntervalSince1970: 300),
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(latitude: 999, longitude: 999)
        )
        XCTAssertNil(WeatherContextClient.latestCoordinate(from: [invalid]))
    }
}
