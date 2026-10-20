import Foundation

/// Available only to a Debug QA bundle launched with an isolated temporary Home.
enum MacSoftVisualSession {
    static var isActive: Bool {
        #if DEBUG
        Bundle.main.bundleIdentifier == MacQAStorageIsolation.qaBundleIdentifier
            && (ProcessInfo.processInfo.arguments.contains("--river-soft-ui-preview")
                || ProcessInfo.processInfo.environment["RIVER_SOFT_VISUAL_SESSION"] == "1")
            && ProcessInfo.processInfo.environment["RIVER_DIARY_MAC_QA_HOME"] != nil
        #else
        false
        #endif
    }

    #if DEBUG
    static var date: Date { DiaryEntry.dateFormatter.date(from: "2026-10-15")! }
    static var placeMarkers: [ActivityTimelinePlaceMarker] {
        [(8, 45, "隔离验收地点 A", 31.2304, 121.4737),
         (17, 15, "隔离验收地点 B", 31.2350, 121.4810)].enumerated().map { index, point in
            ActivityTimelinePlaceMarker(
                id: UUID(uuidString: "B1F76036-20D1-47A9-AFE6-00000000010\(index)")!,
                time: Calendar.current.date(bySettingHour: point.0, minute: point.1, second: 0, of: date)!,
                title: point.2, detail: "仅供隔离界面验收的坐标", originDeviceID: "qa-preview",
                latitude: point.3, longitude: point.4
            )
        }
    }
    static var sessions: [ActivitySession] {
        [("Xcode", "com.apple.dt.Xcode", "桌面设计与功能整合", "工作", 9, 30, 115),
         ("Books", "com.apple.iBooksX", "阅读与整理笔记", "学习", 13, 30, 150),
         ("Safari", "com.apple.Safari", "休息与阅读", "休息", 16, 30, 35)].enumerated().map { index, value in
            let start = Calendar.current.date(bySettingHour: value.4, minute: value.5, second: 0, of: date)!
            return ActivitySession(id: UUID(uuidString: "B1F76036-20D1-47A9-AFE6-00000000000\(index + 1)")!,
                                   appName: value.0, bundleID: value.1, windowTitle: value.2, category: value.3,
                                   start: start, end: start.addingTimeInterval(TimeInterval(value.6 * 60)))
        }
    }
    #endif
}
