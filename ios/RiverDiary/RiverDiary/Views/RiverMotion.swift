import SwiftUI

extension Animation {
    static let riverTouch = Animation.spring(response: 0.28, dampingFraction: 0.8)
    static let riverReveal = Animation.easeOut(duration: 0.32)
}

/// Short, tactile feedback; the existing surface and layout stay intact.
struct RiverTactileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.975 : 1)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.08) : .riverTouch, value: configuration.isPressed)
    }
}

private struct RiverPageEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 8)
            .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .riverReveal) { visible = true } }
            .onDisappear { visible = false }
    }
}

extension View {
    func riverTactile() -> some View { buttonStyle(RiverTactileButtonStyle()) }
    func riverPageEntrance() -> some View { modifier(RiverPageEntrance()) }
}
