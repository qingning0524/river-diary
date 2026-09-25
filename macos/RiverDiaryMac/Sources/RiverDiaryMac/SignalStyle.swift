import SwiftUI

struct AppIconBadge: View {
    let app: String
    var size: CGFloat = 30

    var body: some View {
        let symbol = SignalStyle.symbol(for: app)
        let color = SignalStyle.color(for: app)

        return ZStack {
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .fill(color)

            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct SiteIconBadge: View {
    let site: String
    var size: CGFloat = 28

    var body: some View {
        let symbol = SignalStyle.siteSymbol(for: site)
        let color = SignalStyle.siteColor(for: site)

        return ZStack {
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .fill(color.opacity(0.14))
            Image(systemName: symbol)
                .font(.system(size: size * 0.40, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

enum SignalStyle {
    static func symbol(for app: String) -> String {
        let name = app.lowercased()

        if name.contains("chrome") || name.contains("safari") || name.contains("edge") || name.contains("arc") || name.contains("browser") {
            return "globe"
        }
        if name.contains("xcode") || name.contains("codex") || name.contains("terminal") || name.contains("iterm") || name.contains("vs code") || name.contains("visual studio") {
            return "hammer.fill"
        }
        if name.contains("微信") || name.contains("wechat") || name.contains("discord") || name.contains("slack") || name.contains("mail") || name.contains("tavern") || name.contains("telegram") {
            return "bubble.left.and.bubble.right.fill"
        }
        if name.contains("网易云") || name.contains("music") || name.contains("spotify") {
            return "music.note"
        }
        if name.contains("bilibili") || name.contains("b站") || name.contains("youtube") || name.contains("抖音") || name.contains("douyin") || name.contains("爱奇艺") {
            return "play.tv.fill"
        }
        if name.contains("notion") || name.contains("obsidian") || name.contains("word") || name.contains("pages") || name.contains("docs") {
            return "doc.text.fill"
        }
        if name.contains("备忘录") || name.contains("notes") || name.contains("bear") {
            return "note.text"
        }
        if name.contains("figma") || name.contains("keynote") || name.contains("sketch") || name.contains("pixelmator") || name.contains("affinity") {
            return "paintbrush.fill"
        }
        if name.contains("美图") || name.contains("mtxx") || name.contains("photoshop") || name.contains("pixelmator") || name.contains("lightroom") {
            return "photo.fill"
        }
        if name.contains("系统设置") || name.contains("systempreferences") || name.contains("settings") {
            return "gearshape.fill"
        }
        if name.contains("finder") || name.contains("访达") {
            return "folder.fill"
        }
        if name.contains("hermes") || name.contains("app") {
            return "app.fill"
        }
        return "square.grid.2x2.fill"
    }

    static func color(for app: String) -> Color {
        let name = app.lowercased()
        if name.contains("chrome") || name.contains("safari") || name.contains("edge") || name.contains("arc") { return Color(hex: "#5C7CFA") }
        if name.contains("xcode") || name.contains("codex") || name.contains("terminal") || name.contains("iterm") { return Color(hex: "#3F8CFF") }
        if name.contains("微信") || name.contains("wechat") || name.contains("discord") || name.contains("slack") || name.contains("tavern") { return Color(hex: "#55B58A") }
        if name.contains("网易云") || name.contains("music") || name.contains("spotify") { return Color(hex: "#E86A7C") }
        if name.contains("bilibili") || name.contains("b站") || name.contains("youtube") || name.contains("抖音") || name.contains("douyin") { return Color(hex: "#F0A75C") }
        if name.contains("notion") || name.contains("word") || name.contains("obsidian") || name.contains("docs") { return Color(hex: "#7A7FF0") }
        if name.contains("备忘录") || name.contains("notes") { return Color(hex: "#FFC15C") }
        if name.contains("figma") || name.contains("keynote") || name.contains("sketch") { return Color(hex: "#9C6CF5") }
        if name.contains("美图") || name.contains("mtxx") || name.contains("photoshop") { return Color(hex: "#F2788D") }
        if name.contains("系统设置") || name.contains("systempreferences") || name.contains("settings") { return Color(hex: "#8E99AE") }
        if name.contains("hermes") { return Color(hex: "#4FB6A9") }
        return Color(hex: "#7787FF")
    }

    static func siteSymbol(for site: String) -> String {
        let name = site.lowercased()
        if name.contains("github") || name.contains("gitlab") || name.contains("juejin") || name.contains("csdn") || name.contains("apple.com") || name.contains("developer") { return "chevron.left.forwardslash.chevron.right" }
        if name.contains("bilibili") || name.contains("youtube") || name.contains("douyin") || name.contains("xiaohongshu") { return "play.rectangle.fill" }
        if name.contains("notion") || name.contains("docs") || name.contains("zhihu") { return "doc.text.fill" }
        if name.contains("music.163") || name.contains("music") { return "music.note" }
        if name.contains("mail") || name.contains("gmail") { return "envelope.fill" }
        if name.contains("icloud") { return "cloud.fill" }
        return "globe"
    }

    static func siteColor(for site: String) -> Color {
        let name = site.lowercased()
        if name.contains("github") || name.contains("gitlab") { return Color(hex: "#3F8CFF") }
        if name.contains("bilibili") || name.contains("youtube") || name.contains("douyin") { return Color(hex: "#F0A75C") }
        if name.contains("notion") || name.contains("docs") || name.contains("zhihu") { return Color(hex: "#7A7FF0") }
        if name.contains("music.163") || name.contains("music") { return Color(hex: "#E86A7C") }
        if name.contains("apple.com") || name.contains("icloud") { return Color(hex: "#4FB6A9") }
        return Color(hex: "#5C7CFA")
    }
}
