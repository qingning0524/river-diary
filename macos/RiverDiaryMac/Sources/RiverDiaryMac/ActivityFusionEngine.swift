import Foundation

// MARK: - Fusion engine

enum ActivityFusionEngine {
    static func dayStats(
        dateKey: String,
        entry: DiaryEntry?,
        liveSessions: [ActivitySession]
    ) -> FusedDayStats {
        let live = liveSessions.filter {
            ActivityClassifier.isRecordable(appName: $0.appName, bundleID: $0.bundleID)
        }.sorted { $0.start < $1.start }
        let pipelineTotal = Double(entry?.screenMinutes ?? 0) * 60
        let liveTotal = live.reduce(0) { $0 + $1.duration }
        let appItems = fusedAppUsage(entry: entry, live: live, pipelineTotal: pipelineTotal)

        var categories: [String: UsageItem] = [:]
        for app in appItems {
            var item = categories[app.category] ?? UsageItem(
                name: app.category,
                duration: 0,
                count: 0,
                category: app.category,
                source: .pipeline
            )
            item.duration += app.duration
            item.count += 1
            item.source = strongestSource(item.source, app.source)
            categories[app.category] = item
        }

        let categoryUsage = categories.values.sorted { $0.duration > $1.duration }
        let timeline = hourlyTimeline(live)
        let focusSessions = live.filter { ActivityClassifier.isFocus($0.category) }
        let focusTotal = focusSessions.reduce(0) { $0 + $1.duration }
        let conflicts = dataConflicts(entry: entry, pipelineTotal: pipelineTotal, liveTotal: liveTotal)
        let confidence = ActivityConfidenceEngine.day(entry: entry, liveSessions: live)
        let fragmentation = fragmentationScore(live)

        return FusedDayStats(
            dateKey: dateKey,
            pipelineAvailable: entry?.hasProjectSignals == true,
            pipelineTotal: pipelineTotal,
            liveTotal: liveTotal,
            focusTotal: focusTotal,
            appUsage: appItems,
            categoryUsage: categoryUsage,
            browseUsage: browseUsage(entry),
            timeline: timeline,
            liveSessions: live,
            focusSessions: focusSessions,
            longestSession: live.max { $0.duration < $1.duration },
            health: entry?.health,
            conflicts: conflicts,
            fragmentation: fragmentation,
            confidence: confidence.score,
            confidenceFactors: confidence.factors,
            headline: dayHeadline(pipelineTotal: pipelineTotal, appUsage: appItems, live: live),
            narrative: dayNarrative(entry: entry, pipelineTotal: pipelineTotal, appUsage: appItems, live: live)
        )
    }

    private static func fusedAppUsage(
        entry: DiaryEntry?,
        live: [ActivitySession],
        pipelineTotal: TimeInterval
    ) -> [UsageItem] {
        var appItems: [UsageItem] = []
        var matchedLiveIDs = Set<UUID>()
        let pipelineApps = entry?.screenApps ?? []

        for app in pipelineApps {
            let identity = ActivityClassifier.identity(appName: app.app)
            let matchedLive = live.filter {
                ActivityClassifier.identity(appName: $0.appName, bundleID: $0.bundleID) == identity
            }
            matchedLiveIDs.formUnion(matchedLive.map(\.id))
            let duration = Double(app.minutes ?? 0) * 60
            if duration > 0 {
                appItems.append(
                    UsageItem(
                        name: app.app,
                        duration: duration,
                        count: 1,
                        category: ActivityClassifier.category(appName: app.app, title: nil),
                        source: matchedLive.isEmpty ? .pipeline : .fused
                    )
                )
            }
        }

        let unmatched = live.filter { !matchedLiveIDs.contains($0.id) }
        let unmatchedTotal = unmatched.reduce(0) { $0 + $1.duration }
        let pipelineAppTotal = Double(pipelineApps.reduce(0) { $0 + ($1.minutes ?? 0) }) * 60
        let unattributedPipelineTotal = max(0, pipelineTotal - pipelineAppTotal)

        // 管道是每日总量的权威来源。实时片段只填补管道未归属的时间；
        // 如果管道明细已完整，就绝不把实时时长再叠加到应用列表上。
        if unmatchedTotal > 0 && unattributedPipelineTotal > 0 {
            let scale = min(1, unattributedPipelineTotal / unmatchedTotal)
            for session in unmatched {
                let duration = session.duration * scale
                guard duration >= 1 else { continue }
                if let index = appItems.firstIndex(where: {
                    ActivityClassifier.identity(appName: $0.name, bundleID: session.bundleID)
                        == ActivityClassifier.identity(appName: session.appName, bundleID: session.bundleID)
                }) {
                    appItems[index].duration += duration
                    appItems[index].source = .fused
                } else {
                    appItems.append(
                        UsageItem(
                            name: session.appName,
                            duration: duration,
                            count: 1,
                            category: session.category,
                            source: pipelineTotal > 0 ? .fused : .live
                        )
                    )
                }
            }
        } else if unmatchedTotal > 0 && pipelineApps.isEmpty {
            // 管道只有屏幕总量、没有应用明细时，用实时片段分配总量，而不是额外相加。
            let scale = pipelineTotal > 0 && unmatchedTotal > 0 ? min(1, pipelineTotal / unmatchedTotal) : 1
            for session in unmatched {
                let duration = session.duration * scale
                guard duration >= 1 else { continue }
                appItems.append(
                    UsageItem(
                        name: session.appName,
                        duration: duration,
                        count: 1,
                        category: session.category,
                        source: pipelineTotal > 0 ? .fused : .live
                    )
                )
            }
        }

        return appItems.sorted { $0.duration > $1.duration }
    }

    private static func strongestSource(_ current: ActivitySourceKind, _ candidate: ActivitySourceKind) -> ActivitySourceKind {
        if current == .fused || candidate == .fused { return .fused }
        if current == .live { return .live }
        return candidate
    }

    private static func dataConflicts(
        entry: DiaryEntry?,
        pipelineTotal: TimeInterval,
        liveTotal: TimeInterval
    ) -> [String] {
        var conflicts: [String] = []

        if pipelineTotal > 0 && liveTotal > 0 {
            let difference = abs(pipelineTotal - liveTotal)
            let threshold = max(600, max(pipelineTotal, liveTotal) * 0.2)
            if difference > threshold {
                conflicts.append("双源总时长差异较大：项目管道 \(ActivityFormatter.time(pipelineTotal))，macOS 实时 \(ActivityFormatter.time(liveTotal))。")
            }
        }

        if let entry,
           let apps = entry.screenApps,
           let screenMinutes = entry.screenMinutes {
            let appSum = apps.reduce(0) { $0 + ($1.minutes ?? 0) }
            if appSum > 0 && abs(appSum - screenMinutes) > 15 {
                conflicts.append("项目内部汇总与应用明细相差约 \(abs(appSum - screenMinutes)) 分钟，已按汇总值显示。")
            }
        }

        return conflicts
    }

    static func rangeStats(dayStats: [FusedDayStats], days: Int) -> FusedRangeStats {
        var appGroups: [String: (item: UsageItem, days: Int)] = [:]
        var categoryGroups: [String: UsageItem] = [:]
        var browseGroups: [String: (visits: Int, days: Int)] = [:]
        var hourGroups: [Int: (duration: TimeInterval, categories: [String: TimeInterval])] = [:]
        var sessions: [ActivitySession] = []
        var focusSessions: [ActivitySession] = []
        var conflicts: [String] = []
        var fragmentationSum = 0
        var fragmentationDays = 0

        for day in dayStats {
            for app in day.appUsage {
                let key = ActivityClassifier.identity(appName: app.name)
                var group = appGroups[key] ?? (
                    UsageItem(
                        name: app.name,
                        duration: 0,
                        count: 0,
                        category: app.category,
                        source: app.source
                    ),
                    0
                )
                group.item.duration += app.duration
                group.item.count += 1
                if app.source == .fused { group.item.source = .fused }
                else if group.item.source != .fused { group.item.source = app.source }
                group.days += 1
                appGroups[key] = group
            }

            for category in day.categoryUsage {
                var item = categoryGroups[category.name] ?? UsageItem(name: category.name, duration: 0, count: 0, category: category.name, source: category.source)
                item.duration += category.duration
                item.count += 1
                if category.source == .fused { item.source = .fused }
                categoryGroups[category.name] = item
            }

            for site in day.browseUsage {
                var group = browseGroups[site.site] ?? (0, 0)
                group.visits += site.visits
                group.days += 1
                browseGroups[site.site] = group
            }

            for hour in day.timeline {
                var group = hourGroups[hour.hour] ?? (0, [:])
                group.duration += hour.duration
                if !hour.primaryCategory.isEmpty {
                    group.categories[hour.primaryCategory, default: 0] += hour.duration
                }
                hourGroups[hour.hour] = group
            }

            sessions.append(contentsOf: day.liveSessions)
            focusSessions.append(contentsOf: day.focusSessions)
            conflicts.append(contentsOf: day.conflicts.map { "\(day.dateKey)：\($0)" })

            if day.liveTotal > 0 {
                fragmentationSum += day.fragmentation
                fragmentationDays += 1
            }
        }

        let appUsage = appGroups.values
            .map { $0.item }
            .sorted { $0.duration > $1.duration }
        let categoryUsage = categoryGroups.values
            .sorted { $0.duration > $1.duration }
        let browseUsage = browseGroups
            .map { BrowseUsageItem(site: $0.key, visits: $0.value.visits, days: $0.value.days) }
            .sorted { $0.visits > $1.visits }
        let timeline = (0...23).map { hour -> ActivityHour in
            let group = hourGroups[hour] ?? (0, [:])
            return ActivityHour(
                hour: hour,
                duration: group.duration,
                primaryCategory: group.categories.max { $0.value < $1.value }?.key ?? ""
            )
        }

        let pipelineTotal = dayStats.reduce(0) { $0 + $1.pipelineTotal }
        let liveTotal = dayStats.reduce(0) { $0 + $1.liveTotal }
        let focusTotal = dayStats.reduce(0) { $0 + $1.focusTotal }
        let steps = dayStats.reduce(0) { $0 + ($1.health?.steps ?? 0) }
        let distance = dayStats.reduce(0) { $0 + ($1.health?.distanceKM ?? 0) }
        let energy = dayStats.reduce(0) { $0 + ($1.health?.activeEnergyKcal ?? 0) }
        let rangeConfidence = ActivityConfidenceEngine.range(dayStats: dayStats)

        return FusedRangeStats(
            days: days,
            dateKeys: dayStats.map(\.dateKey),
            pipelineTotal: pipelineTotal,
            liveTotal: liveTotal,
            focusTotal: focusTotal,
            appUsage: appUsage,
            categoryUsage: categoryUsage,
            browseUsage: browseUsage,
            timeline: timeline,
            liveSessions: sessions.sorted { $0.start < $1.start },
            focusSessions: focusSessions,
            healthSteps: steps,
            healthDistance: distance,
            healthEnergy: energy,
            conflicts: conflicts,
            fragmentation: fragmentationDays == 0 ? 0 : Int((Double(fragmentationSum) / Double(fragmentationDays)).rounded()),
            confidence: rangeConfidence.score,
            confidenceFactors: rangeConfidence.factors,
            headline: rangeHeadline(appUsage: appUsage, pipelineTotal: pipelineTotal, days: days),
            narrative: rangeNarrative(dayStats: dayStats, appUsage: appUsage, browseUsage: browseUsage, focusTotal: focusTotal, steps: steps, days: days),
            dayStats: dayStats
        )
    }

    private static func hourlyTimeline(_ sessions: [ActivitySession]) -> [ActivityHour] {
        var groups: [Int: (duration: TimeInterval, categories: [String: TimeInterval])] = [:]

        for session in sessions {
            let calendar = Calendar.current
            var cursor = session.start
            let end = session.end

            while cursor < end {
                let nextHour = calendar.nextDate(
                    after: cursor,
                    matching: DateComponents(minute: 0),
                    matchingPolicy: .nextTimePreservingSmallerComponents
                ) ?? end
                let chunkEnd = min(nextHour, end)
                let duration = chunkEnd.timeIntervalSince(cursor)
                let hour = calendar.component(.hour, from: cursor)

                var group = groups[hour] ?? (0, [:])
                group.duration += duration
                group.categories[session.category, default: 0] += duration
                groups[hour] = group
                cursor = chunkEnd
            }
        }

        return (0...23).map { hour in
            let group = groups[hour] ?? (0, [:])
            return ActivityHour(
                hour: hour,
                duration: group.duration,
                primaryCategory: group.categories.max { $0.value < $1.value }?.key ?? ""
            )
        }
    }

    private static func browseUsage(_ entry: DiaryEntry?) -> [BrowseUsageItem] {
        (entry?.browseSites ?? []).map {
            BrowseUsageItem(site: $0.site, visits: $0.visits ?? 0, days: 1)
        }
        .sorted { $0.visits > $1.visits }
    }

    private static func fragmentationScore(_ sessions: [ActivitySession]) -> Int {
        let total = sessions.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        let switchesPerHour = Double(sessions.count) / max(0.5, total / 3600)
        return min(100, max(0, Int((switchesPerHour - 4) * 9)))
    }

    private static func dayHeadline(
        pipelineTotal: TimeInterval,
        appUsage: [UsageItem],
        live: [ActivitySession]
    ) -> String {
        if let top = appUsage.first {
            return "主要停在 \(top.name)，共 \(ActivityFormatter.time(top.duration))"
        }
        if pipelineTotal > 0 {
            return "屏幕时间约 \(ActivityFormatter.time(pipelineTotal))"
        }
        if let longest = live.max(by: { $0.duration < $1.duration }) {
            return "实时记录到 \(longest.appName) 的连续片段"
        }
        return "这一天缺少活动信号"
    }

    private static func dayNarrative(
        entry: DiaryEntry?,
        pipelineTotal: TimeInterval,
        appUsage: [UsageItem],
        live: [ActivitySession]
    ) -> String {
        var lines: [String] = []

        if let entry, let minutes = entry.screenMinutes, !appUsage.isEmpty {
            let apps = appUsage.prefix(3).map { "\($0.name) \(ActivityFormatter.time($0.duration))" }.joined(separator: "、")
            lines.append("项目管道显示当天屏幕时间约 \(ActivityFormatter.time(Double(minutes) * 60))，主要分布是 \(apps)。")
        } else if pipelineTotal > 0 {
            lines.append("项目管道显示当天屏幕时间约 \(ActivityFormatter.time(pipelineTotal))，暂无应用明细。")
        } else if let top = appUsage.first {
            lines.append("实时足迹显示主要使用 \(top.name)，约 \(ActivityFormatter.time(top.duration))。")
        }

        if let longest = live.max(by: { $0.duration < $1.duration }), longest.duration >= 600 {
            lines.append("macOS 实时记录到最长一段是 \(longest.appName)，约 \(ActivityFormatter.time(longest.duration))。")
        }

        if let site = (entry?.browseSites ?? []).first, let visits = site.visits, visits > 0 {
            lines.append("浏览主题以 \(site.site) 最频繁，共 \(visits) 次。")
        }

        if let health = entry?.health, let steps = health.steps {
            lines.append(steps >= 6000 ? "步数 \(steps)，身体活动较充足。" : "步数 \(steps)，活动量偏轻。")
        }

        if lines.isEmpty {
            lines.append("这一天还没有足够的屏幕或运动信号。")
        }

        return lines.joined()
    }

    private static func rangeHeadline(appUsage: [UsageItem], pipelineTotal: TimeInterval, days: Int) -> String {
        if let top = appUsage.first {
            return "最近 \(days) 天主要停在 \(top.name)，共 \(ActivityFormatter.time(top.duration))"
        }
        return pipelineTotal > 0 ? "累计屏幕时间 \(ActivityFormatter.time(pipelineTotal))" : "当前范围缺少活动信号"
    }

    private static func rangeNarrative(
        dayStats: [FusedDayStats],
        appUsage: [UsageItem],
        browseUsage: [BrowseUsageItem],
        focusTotal: TimeInterval,
        steps: Int,
        days: Int
    ) -> String {
        var lines: [String] = []

        if let top = appUsage.first {
            lines.append("项目管道与实时足迹共同显示，\(top.name) 是这段时间的主线，共 \(ActivityFormatter.time(top.duration))。")
        }

        if focusTotal > 0 {
            lines.append("实时记录到 \(ActivityFormatter.time(focusTotal)) 的专注类活动。")
        }

        if let site = browseUsage.first {
            lines.append("浏览足迹中 \(site.site) 最频繁，共 \(site.visits) 次。")
        }

        if steps > 0 {
            lines.append("累计 \(steps) 步，平均每天 \(Int(Double(steps) / Double(max(1, days)))) 步。")
        }

        let conflictCount = dayStats.filter { !$0.conflicts.isEmpty }.count
        if conflictCount > 0 {
            lines.append("有 \(conflictCount) 天的双源数据差异较大，已标记为低置信度。")
        }

        if lines.isEmpty {
            lines.append("这段时间还没有足够的活动数据。")
        }

        return lines.joined()
    }
}
