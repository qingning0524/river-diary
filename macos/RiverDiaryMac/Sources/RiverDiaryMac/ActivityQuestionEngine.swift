import Foundation

struct ActivityQuestionScope {
    var days: Int
    var around: Date
    var label: String

    static func parse(
        _ question: String,
        fallbackDays: Int,
        around date: Date = Date()
    ) -> ActivityQuestionScope {
        let calendar = Calendar.current
        let lower = question.lowercased()
        let today = calendar.startOfDay(for: date)

        func scope(days: Int, around: Date, label: String) -> ActivityQuestionScope {
            ActivityQuestionScope(days: max(1, days), around: around, label: label)
        }

        if lower.contains("今天") || lower.contains("今日") {
            return scope(days: 1, around: today, label: "今天")
        }
        if lower.contains("昨天") || lower.contains("昨日") {
            let day = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return scope(days: 1, around: day, label: "昨天")
        }
        if lower.contains("前天") {
            let day = calendar.date(byAdding: .day, value: -2, to: today) ?? today
            return scope(days: 1, around: day, label: "前天")
        }
        if lower.contains("上周") || lower.contains("上个星期") || lower.contains("上星期") {
            let around = calendar.date(byAdding: .day, value: -7, to: today) ?? today
            return scope(days: 7, around: around, label: "上周")
        }
        if lower.contains("本周") || lower.contains("这周") || lower.contains("这个星期") || lower.contains("这星期") {
            return scope(days: 7, around: today, label: "本周")
        }
        if lower.contains("上个月") {
            let previous = calendar.date(byAdding: .month, value: -1, to: today) ?? today
            let days = calendar.range(of: .day, in: .month, for: previous)?.count ?? 30
            let end = calendar.dateInterval(of: .month, for: previous)?.end ?? previous
            let around = calendar.date(byAdding: .day, value: -1, to: end) ?? previous
            return scope(days: days, around: around, label: "上个月")
        }
        if lower.contains("本月") || lower.contains("这个月") {
            let days = calendar.range(of: .day, in: .month, for: today)?.count ?? 30
            return scope(days: days, around: today, label: "本月")
        }

        if let match = firstNumber(in: lower) {
            let number = match.value
            let context = lower
            if context.contains("天") || context.contains("日") {
                return scope(days: number, around: today, label: "最近 \(number) 天")
            }
            if context.contains("周") {
                return scope(days: number * 7, around: today, label: "最近 \(number) 周")
            }
            if context.contains("月") {
                return scope(days: number * 30, around: today, label: "最近 \(number) 个月")
            }
        }

        if lower.contains("一周") || lower.contains("最近一周") {
            return scope(days: 7, around: today, label: "最近 7 天")
        }
        if lower.contains("两周") {
            return scope(days: 14, around: today, label: "最近 14 天")
        }
        if lower.contains("一个月") || lower.contains("30天") || lower.contains("30 天") {
            return scope(days: 30, around: today, label: "最近 30 天")
        }
        if lower.contains("三个月") || lower.contains("90天") || lower.contains("90 天") {
            return scope(days: 90, around: today, label: "最近 90 天")
        }

        let label = fallbackDays == 1 ? "当前选择的一天" : "当前选择的 \(fallbackDays) 天"
        return scope(days: fallbackDays, around: today, label: label)
    }

    private static func firstNumber(in text: String) -> (value: Int, range: Range<String.Index>)? {
        let pattern = "[0-9]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return (Int(text[swiftRange]) ?? 0, swiftRange)
    }
}
