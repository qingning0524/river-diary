import SwiftUI

struct DayTimelineView: View {
    let sessions: [ActivitySession]
    let date: Date

    @State private var selectedSession: ActivitySession?
    @State private var hoveredSessionID: UUID?

    private var hasSessions: Bool { !sessions.isEmpty }

    private var totalActiveTime: TimeInterval {
        sessions.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                header
                if hasSessions {
                    timelineStrip
                    hourRuler
                    if let session = selectedSession {
                        sessionDetail(session)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    sessionList
                } else {
                    emptyState
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedSession)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("时间轴", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Spacer()
            if hasSessions {
                Text("\(ActivityFormatter.time(totalActiveTime)) 活跃 · \(sessions.count) 段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Timeline Strip

    private var timelineStrip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let stripHeight: CGFloat = 46

            ZStack(alignment: .topLeading) {
                // Background track
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.chip)
                    .frame(height: stripHeight)

                // Session blocks
                ForEach(sessions) { session in
                    sessionBlock(session, containerWidth: width, stripHeight: stripHeight)
                }

                // "Now" indicator
                if Calendar.current.isDateInToday(date) {
                    nowIndicator(containerWidth: width, stripHeight: stripHeight)
                }
            }
        }
        .frame(height: 46)
    }

    private func sessionBlock(_ session: ActivitySession, containerWidth: CGFloat, stripHeight: CGFloat) -> some View {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let dayDuration: Double = 24 * 3600

        let startFraction = session.start.timeIntervalSince(startOfDay) / dayDuration
        let endFraction = min(1.0, session.end.timeIntervalSince(startOfDay) / dayDuration)
        let x = startFraction * containerWidth
        let blockWidth = max(4, (endFraction - startFraction) * containerWidth)

        let isSelected = selectedSession?.id == session.id
        let isHovered = hoveredSessionID == session.id
        let color = Color(hex: ActivityClassifier.color(for: session.category))

        let displayText = blockWidth > 52 ? session.appName : ""

        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.opacity(isHovered && !isSelected ? 0.75 : 1.0))
            .frame(width: blockWidth, height: stripHeight - 10)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.8) : .clear, lineWidth: 2)
            )
            .overlay(
                Text(displayText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                    .allowsHitTesting(false)
            )
            .shadow(color: color.opacity(0.3), radius: isSelected ? 6 : 2, y: isSelected ? 3 : 1)
            .offset(x: x, y: 5)
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedSession = isSelected ? nil : session
                }
            }
            .onHover { hovering in
                hoveredSessionID = hovering ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID)
            }
            .help("\(session.appName) \(timeRange(session))")
    }

    private func nowIndicator(containerWidth: CGFloat, stripHeight: CGFloat) -> some View {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let nowFraction = Date().timeIntervalSince(startOfDay) / (24 * 3600)
        let x = nowFraction * containerWidth

        return VStack(spacing: 0) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.red.opacity(0.7))
                .frame(width: 1.5)
        }
        .offset(x: x - 0.75, y: 0)
        .allowsHitTesting(false)
    }

    // MARK: - Hour Ruler

    private var hourRuler: some View {
        HStack(spacing: 0) {
            ForEach(0..<25) { hour in
                if hour < 24 {
                    VStack(spacing: 3) {
                        Rectangle()
                            .fill(Color.border)
                            .frame(height: hour % 2 == 0 ? 6 : 3)
                            .frame(width: 1)
                        if hour % 2 == 0 {
                            Text(String(format: "%02d", hour))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(" ")
                                .font(.system(size: 9))
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("24")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Session Detail

    private func sessionDetail(_ session: ActivitySession) -> some View {
        HStack(spacing: 12) {
            // App icon placeholder
            Image(systemName: ActivityClassifier.symbol(for: session.appName))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(hex: ActivityClassifier.color(for: session.category)))
                .frame(width: 36, height: 36)
                .background(
                    Color(hex: ActivityClassifier.color(for: session.category)).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(session.appName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)

                if let title = session.windowTitle, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(timeRange(session))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(hex: ActivityClassifier.color(for: session.category)))
                        .frame(width: 6, height: 6)
                    Text(ActivityFormatter.time(session.duration))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ink)
                }
            }
        }
        .padding(12)
        .background(
            Color.strongSurface,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.border, lineWidth: 1)
        )
    }

    // MARK: - Session List

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("全部片段")
                .font(.caption.smallCaps())
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(sessions.reversed()) { session in
                        sessionRow(session)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private func sessionRow(_ session: ActivitySession) -> some View {
        let isSelected = selectedSession?.id == session.id
        let isHovered = hoveredSessionID == session.id
        let color = Color(hex: ActivityClassifier.color(for: session.category))

        return HStack(spacing: 10) {
            // Time
            Text(timeRange(session))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            // Category dot
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            // App name
            Text(session.appName)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.ink)
                .lineLimit(1)

            // Window title
            if let title = session.windowTitle, !title.isEmpty {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            Text(ActivityFormatter.time(session.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.strongSurface : isHovered ? Color.chip : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedSession = isSelected ? nil : session
            }
        }
        .onHover { hovering in
            hoveredSessionID = hovering ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("这一天还没有记录到实时片段")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("开启实时记录后，切换应用时会自动在这里生成时间轴。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Helpers

    private func timeRange(_ session: ActivitySession) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: session.start)) – \(formatter.string(from: session.end))"
    }
}
