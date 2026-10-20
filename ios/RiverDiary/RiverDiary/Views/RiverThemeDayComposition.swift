import SwiftUI

struct RiverThemeReadingLead: View {
    @Environment(\.riverTheme) private var theme
    let title: String
    let timestamp: String
    let source: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(timestamp).font(.footnote.monospacedDigit()).foregroundStyle(theme.secondaryInk)
            Text(title).font(theme.titleFont).foregroundStyle(theme.ink)
            Text(source).font(.footnote).foregroundStyle(theme.secondaryInk)
            Divider().overlay(theme.separator)
        }.padding(16)
    }
}
