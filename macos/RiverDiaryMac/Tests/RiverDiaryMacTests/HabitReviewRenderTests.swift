import AppKit
import SwiftUI
import XCTest

@testable import RiverDiaryMac

/// 离屏渲染习惯回顾页，输出整页 PNG 供视觉核对，并做基础冒烟断言。
/// 注意：ImageRenderer 不布局 ScrollView 视口（整页空白），所以这里把页面
/// 装进一个隐藏的 NSWindow 用 NSHostingView 做真实布局后缓存显示。
@MainActor
final class HabitReviewRenderTests: XCTestCase {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        return cal
    }()

    func testRendersFullPageWithBatch() throws {
        let (store, activity, v2) = try makeSeededContext()
        let evalNow = Date()
        let sessions = seedSessions(into: v2)

        store.evaluateIfNeeded(sessions: sessions, now: evalNow, allowManualGeneration: true)
        XCTAssertEqual(store.pendingCards.count, 2, "两个 bundle 各生成一张规律卡")

        let page = HabitReviewView(habit: store, activity: activity, onOpenTimeline: {}, animatesEntrance: false)
            .environment(\.riverDensity, .standard)
            .frame(width: 1280, height: 940)

        let image = try renderOffscreen(page, appearance: .aqua)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("habit-review-render.png")
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output)
        print("习惯回顾整页渲染已写入：\(output.path)")

        XCTAssertGreaterThan(image.width, 2000, "整页渲染应有实际内容")
        XCTAssertGreaterThan(image.height, 1500)
    }

    /// 回答第一张卡后的收起态：保留用户答案与生成的规则。
    func testRendersAnsweredState() throws {
        let (store, activity, v2) = try makeSeededContext()
        store.evaluateIfNeeded(sessions: seedSessions(into: v2), now: Date(), allowManualGeneration: true)
        let first = try XCTUnwrap(store.pendingCards.first)
        store.answer(first, kind: .longTermRule)

        let page = HabitReviewView(habit: store, activity: activity, onOpenTimeline: {}, animatesEntrance: false)
            .environment(\.riverDensity, .standard)
            .frame(width: 1280, height: 940)
        let image = try renderOffscreen(page, appearance: .aqua)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("habit-review-answered.png")
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output)
        print("习惯回顾已回答态渲染已写入：\(output.path)")

        // This fixture uses the retired local-only generator. Opening the view
        // intentionally expires legacy cards without AI-authored context.
        XCTAssertTrue(store.pendingCards.isEmpty, "旧版候选卡会在进入新版回顾页时退役")
        XCTAssertEqual(store.cards.first(where: { $0.id == first.id })?.status, .answered)
        XCTAssertEqual(store.rules.count, 1)
    }

    /// 空态：没有问题包时的安静提示。
    func testRendersEmptyState() throws {
        let (store, activity, _) = try makeSeededContext()
        let page = HabitReviewView(habit: store, activity: activity, onOpenTimeline: {}, animatesEntrance: false)
            .environment(\.riverDensity, .standard)
            .frame(width: 1280, height: 700)
        let image = try renderOffscreen(page, appearance: .aqua)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("habit-review-empty.png")
        let bitmap = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output)
        print("习惯回顾空态渲染已写入：\(output.path)")
    }

    /// 隐藏窗口 + NSHostingView：让 ScrollView 参与真实布局，再缓存位图。
    private func renderOffscreen(_ view: some View, appearance: NSAppearance.Name) throws -> CGImage {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 940),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderOut(nil)
        hosting.layoutSubtreeIfNeeded()
        let bounds = hosting.bounds
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.cacheDisplay(in: bounds, to: rep)
        window.close()
        return try XCTUnwrap(rep.cgImage, "离屏渲染未产出位图")
    }

    // MARK: Fixture

    private func makeSeededContext() throws -> (HabitReviewStore, ActivityStore, V2Store) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-habit-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let v2 = V2Store(databaseURL: directory.appendingPathComponent("habit.db"))
        let store = HabitReviewStore(v2Store: v2, calendar: calendar)
        store.setCadence(.manual)
        // 独立的 activity 目录：绝不读取本机真实活动数据。
        let activityDirectory = directory.appendingPathComponent("activity", isDirectory: true)
        try FileManager.default.createDirectory(at: activityDirectory, withIntermediateDirectories: true)
        let activity = ActivityStore(
            activityDirectory: activityDirectory,
            userDefaults: UserDefaults(suiteName: "habit-render-\(UUID().uuidString)")!,
            v2Store: v2
        )
        return (store, activity, v2)
    }

    private func seedSessions(into v2: V2Store) -> [ActivitySession] {
        var sessions: [ActivitySession] = []
        for offset in [-1, -3, -5] {
            let dayDate = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date()))!
            let codex = makeSession("com.openai.codex", "Codex", dayDate, 10, 84)
            sessions.append(codex)
            sessions.append(makeSession("com.google.Chrome", "Chrome", dayDate, 14, 66))
            let event = RawEvent(
                timestamp: codex.start.addingTimeInterval(600),
                source: .location,
                kind: .locationUpdate,
                payload: RawEventPayload(latitude: 30.0, longitude: 120.0, horizontalAccuracy: 20, locationName: "宿舍")
            )
            _ = v2.insertRawEvent(event)
        }
        return sessions
    }

    private func makeSession(_ bundleID: String, _ appName: String, _ day: Date, _ hour: Int, _ minutes: Int) -> ActivitySession {
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: calendar.startOfDay(for: day))!
        return ActivitySession(
            appName: appName,
            bundleID: bundleID,
            windowTitle: nil,
            category: ActivityClassifier.category(appName: appName, title: nil),
            start: start,
            end: start.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }
}
