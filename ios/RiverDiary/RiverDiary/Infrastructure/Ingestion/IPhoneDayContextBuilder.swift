import CryptoKit
import Foundation
import RiverDiaryCore
import UIKit

/// iPhone 侧的日上下文：把手机上采到的健康、训练、心情、屏幕时间、语音速记
/// 压成一份跨端可读的摘要。原始样本仍留在本机 Event 里。
@MainActor
enum IPhoneDayContextBuilder {
    static func build(
        database: RiverLocalDatabase,
        deviceID: String,
        deviceName: String,
        day: Date = Date()
    ) -> DayContextSnapshot? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let events = (try? database.events(from: start, to: end)) ?? []
        var sections: [DayContextSection] = []
        // 健康摘要若进入 dayContextSnapshot，就会随普通事件复制到 iCloud；
        // 本机模式下必须把 health/workout/stateOfMind 三类一起排除。
        let healthLocalOnly = UserDefaults.standard.object(forKey: "river.health.localOnly") as? Bool ?? true

        let payloads = events.compactMap { event -> (RiverEvent, RiverEventPayload)? in
            guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { return nil }
            return (event, payload)
        }

        if !healthLocalOnly, let health = latestHealthMetrics(from: payloads) {
            var parts: [String] = []
            if let sleep = health.sleepHours { parts.append(String(format: "睡眠 %.1fh", sleep)) }
            if let steps = health.steps { parts.append("步数 \(steps)") }
            if let energy = health.activeEnergyKcal { parts.append("活动 \(Int(energy))kcal") }
            if !parts.isEmpty {
                sections.append(DayContextSection(
                    kind: "health",
                    title: "健康",
                    summary: parts.joined(separator: " · ")
                ))
            }
        }

        let workouts = healthLocalOnly ? [] : payloads.filter { $0.0.kind == "health.workout" }
        if !workouts.isEmpty {
            let items = workouts.prefix(10).map { event, payload in
                DayContextItem(
                    title: payload.text ?? "训练",
                    detail: payload.metrics?.durationMinutes.map { "\($0) 分钟" },
                    at: event.observedAt
                )
            }
            sections.append(DayContextSection(
                kind: "workout",
                title: "训练",
                summary: "\(workouts.count) 次",
                items: items
            ))
        }

        let moods = healthLocalOnly ? [] : payloads.filter { $0.0.kind == "health.stateOfMind" }
        if !moods.isEmpty {
            let valences = moods.compactMap { $0.1.metrics?.valence }
            let average = valences.isEmpty ? nil : valences.reduce(0, +) / Double(valences.count)
            sections.append(DayContextSection(
                kind: "stateOfMind",
                title: "心情",
                summary: average.map { String(format: "%d 条 · 平均效价 %.2f", moods.count, $0) } ?? "\(moods.count) 条",
                items: moods.prefix(10).map { event, payload in
                    DayContextItem(
                        title: payload.text ?? "心情记录",
                        detail: payload.metrics?.valence.map { String(format: "%.2f", $0) },
                        at: event.observedAt
                    )
                }
            ))
        }

        if let screen = payloads.filter({ $0.0.kind == "screenTime.daily" }).max(by: { $0.0.recordedAt < $1.0.recordedAt }),
           let minutes = screen.1.metrics?.screenMinutes {
            sections.append(DayContextSection(
                kind: "screenTime",
                title: "屏幕使用",
                summary: "\(minutes) 分钟"
            ))
        }

        let voices = payloads.filter { $0.0.kind == "manual.voiceMemo" }
        if !voices.isEmpty {
            sections.append(DayContextSection(
                kind: "voice",
                title: "语音速记",
                summary: "\(voices.count) 条",
                items: voices.prefix(5).map { event, payload in
                    DayContextItem(
                        title: String((payload.text ?? "").prefix(120)),
                        at: event.observedAt
                    )
                }
            ))
        }

        let notes = payloads.filter { $0.0.kind == "manual.note" }
            .filter { !($0.1.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !notes.isEmpty {
            sections.append(DayContextSection(
                kind: "notes",
                title: "随手记",
                summary: "\(notes.count) 条",
                items: notes.prefix(5).map { event, payload in
                    DayContextItem(
                        title: String((payload.text ?? "").prefix(120)),
                        at: event.observedAt
                    )
                }
            ))
        }

        let apps = payloads.filter { $0.0.kind.hasPrefix("app.") }
        if !apps.isEmpty {
            sections.append(DayContextSection(
                kind: "apps",
                title: "应用开关",
                summary: "\(apps.count) 次"
            ))
        }

        guard !sections.isEmpty else { return nil }
        return DayContextSnapshot(
            deviceID: deviceID,
            deviceName: deviceName,
            day: RiverDayKey.string(from: day),
            generatedAt: Date(),
            sections: sections
        )
    }

    private static func latestHealthMetrics(
        from payloads: [(RiverEvent, RiverEventPayload)]
    ) -> RiverEventMetrics? {
        payloads
            .filter { $0.0.kind.hasPrefix("health.") }
            .compactMap { event, payload in payload.metrics.map { (event, $0) } }
            .max { $0.0.observedAt < $1.0.observedAt }?
            .1
    }

    /// 写完健康/屏幕/语音事件后调用；内容不变时稳定 ID 会去重。
    @MainActor
    static func publish(database: RiverLocalDatabase, deviceName: String = UIDevice.current.name, day: Date = Date()) {
        guard let snapshot = build(
            database: database,
            deviceID: database.deviceID.rawValue,
            deviceName: deviceName,
            day: day
        ), let json = try? snapshot.encodedJSON() else { return }
        let hash = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
        let id = RiverStableIdentifier.uuid(
            namespace: "ios.dayContext.\(database.deviceID.rawValue)",
            key: "\(snapshot.day)|\(hash)"
        )
        _ = try? database.append(
            id: id,
            source: "day_context",
            kind: "dayContextSnapshot",
            payload: RiverEventPayload(text: snapshot.searchText, contextJSON: json),
            observedAt: Date(),
            sourceHash: hash
        )
    }
}

private enum RiverDayKey {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
