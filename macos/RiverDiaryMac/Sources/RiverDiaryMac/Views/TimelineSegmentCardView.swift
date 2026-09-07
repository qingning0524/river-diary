import SwiftUI

struct TimelineSegmentCardView: View {
    let date: Date
    let sessions: [ActivitySession]
    var quickCaptures: [QuickCapture] = []

    var body: some View {
        let segments = TimelineSegmentEngine.segments(
            for: date,
            sessions: sessions,
            quickCaptures: quickCaptures
        )
        let activeSegments = segments.filter { !$0.isEmpty }

        SoftCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 10) {
                    Label("生活段落", systemImage: "square.split.2x2")
                        .font(.headline)

                    Spacer()

                    Text("自动归纳 · 原始片段仍在下方")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if activeSegments.isEmpty {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "leaf")
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        Text("这一天暂时没有实时足迹。留白也没关系，以后想补一句仍然可以。")
                            .font(.caption)
                            .lineSpacing(5)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(spacing: 9) {
                        ForEach(activeSegments) { segment in
                            TimelineSegmentRow(segment: segment)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 1280)
    }
}

struct TimelineSegmentRow: View {
    let segment: TimelineSegment
    @State private var showsSessions = false
    @State private var customName = ""

    private var displayName: String {
        customName.isEmpty ? segment.period.title : customName
    }

    private var accent: Color { Color(hex: segment.period.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: segment.period.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 31, height: 31)
                    .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)

                        Text(segment.timeRangeText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)

                        TextField("给这段时间命名", text: $customName)
                            .textFieldStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .onSubmit {
                                TimelineSegmentNameStore.save(customName, for: segment.date, period: segment.period)
                            }
                    }

                    Text(segment.appSummary.isEmpty ? "应用信息不完整" : segment.appSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(ActivityFormatter.time(segment.totalDuration))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .monospacedDigit()

                    Text("切换 \(segment.switchCount) 次")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.border)

                    Capsule()
                        .fill(LinearGradient(
                            colors: [accent.opacity(0.85), accent.opacity(0.45)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: max(5, proxy.size.width * segment.focusRatio))
                }
            }
            .frame(height: 5)
            .accessibilityLabel("专注比例")

            HStack(spacing: 6) {
                metricChip(
                    "专注",
                    "\(Int((segment.focusRatio * 100).rounded()))%",
                    color: segment.focusRatio >= 0.5 ? Color(hex: "#2C8158") : Color.secondaryInk
                )

                if segment.sessions.count > 1 {
                    metricChip("片段", "\(segment.sessions.count)", color: Color.secondaryInk)
                }

                if !segment.captures.isEmpty {
                    metricChip("快记", "\(segment.captures.count)", color: Color(hex: "#B26B00"))
                }

                if segment.primaryApp != nil || !segment.captures.isEmpty {
                    Spacer(minLength: 8)

                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showsSessions.toggle()
                        }
                    } label: {
                        Label(showsSessions ? "收起" : "查看片段", systemImage: showsSessions ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.secondaryInk)
                    }
                    .buttonStyle(.plain)
                }
            }

            if showsSessions {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(segment.captures) { capture in
                        captureRow(capture)
                    }

                    ForEach(segment.sessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.top, 2)
            }

            if !showsSessions {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(segment.captures.prefix(1)) { capture in
                        captureRow(capture)
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(13)
        .background(Color.strongSurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.border, lineWidth: 1)
        )
        .onAppear {
            customName = TimelineSegmentNameStore.name(for: segment.date, period: segment.period)
        }
        .onChange(of: segment.id) {
            customName = TimelineSegmentNameStore.name(for: segment.date, period: segment.period)
        }
    }

    private func metricChip(_ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(color)
        }
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.chip, in: Capsule())
    }

    private func captureRow(_ capture: QuickCapture) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "quote.opening")
                .font(.caption2)
                .foregroundStyle(Color(hex: "#B26B00"))
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(capture.text)
                    .font(.caption)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    if let tag = capture.tag {
                        Text(tag)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.ctaText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.ctaBackground, in: Capsule())
                    }

                    Text(DateFormatter.segmentClock.string(from: capture.createdAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.32)
        }
    }

    private func sessionRow(_ session: ActivitySession) -> some View {
        HStack(spacing: 9) {
            AppIconBadge(app: session.appName, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.appName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)

                if let title = session.windowTitle, !title.isEmpty {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(DateFormatter.segmentClock.string(from: session.start) + "–" + DateFormatter.segmentClock.string(from: session.end))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.32)
        }
    }
}

private extension DateFormatter {
    static let segmentClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
