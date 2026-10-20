import SwiftUI

struct RiverThemeGalleryView: View {
    @EnvironmentObject private var themeStore: RiverThemeStore
    @Environment(\.riverTheme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    RiverSystemSignature()
                    Text("让阅读舒服一点").font(theme.titleFont)
                    Text("同一段生活，选择适合此刻的阅读方式。")
                        .font(theme.textFont(15)).foregroundStyle(theme.secondaryInk).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(RiverThemeID.allCases) { id in
                    themePreview(id)
                }
                if let error = themeStore.errorMessage { Text(error).font(theme.textFont(14)).foregroundStyle(theme.danger) }
                Text("外观偏好保存在这台设备。随时切换，日记与记忆都会保留。")
                    .font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, theme.pageGutter).padding(.top, 24).padding(.bottom, 32)
        }
        .foregroundStyle(theme.ink).background(theme.canvas).accessibilityIdentifier("river.theme.gallery.scroll")
        .navigationTitle("阅读与外观").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
    private func themePreview(_ id: RiverThemeID) -> some View {
        let preview = RiverThemeContext(id: id, colorScheme: id.colorScheme)
        let selected = themeStore.selectedThemeID == id
        return Button {
            if themeStore.applyTheme(id) { RiverHaptics.selection() }
        } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(id.name).font(preview.sectionFont)
                    Spacer()
                    if selected {
                        Label("正在使用", systemImage: "checkmark.circle.fill")
                            .font(preview.textFont(12, relativeTo: .footnote)).foregroundStyle(preview.accentText)
                    } else {
                        Image(systemName: id.symbol).font(.system(size: 17)).foregroundStyle(preview.accentText)
                    }
                }
                Divider().overlay(preview.separator)
                VStack(alignment: .leading, spacing: 10) {
                    Text("一个普通的星期日").font(preview.textFont(12, relativeTo: .footnote)).foregroundStyle(preview.secondaryInk)
                    Text("慢慢走，也在向前。")
                        .font(preview.id == .nightDashboard ? preview.textFont(24, relativeTo: .title2, weight: .medium) : .custom("SongtiSC-Regular", size: 24, relativeTo: .title2))
                    Text("今天留下的文字，日后会带你回到此刻。\n不必急着总结，先好好生活。")
                        .font(preview.textFont(15)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                }
                Text(id.summary).font(preview.textFont(12, relativeTo: .footnote)).foregroundStyle(preview.secondaryInk)
            }
            .foregroundStyle(preview.ink).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(preview.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? preview.accent : preview.separator, lineWidth: selected ? 1.5 : 0.5) }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain).accessibilityIdentifier("river.theme.\(id.rawValue)")
        .accessibilityLabel("\(id.name)，\(selected ? "正在使用" : "使用此主题")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
