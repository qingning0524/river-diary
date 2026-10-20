import SwiftUI
import AppKit

// MARK: - 滚动指示器
//
// 系统的 NSScroller 与这套设计语言不搭：粗、灰、在"始终显示滚动条"偏好下
// 永久驻留，SwiftUI 的 `.scrollIndicators(.hidden)` 也压不住它。
// 这里做两件事：
//
// 1. `NativeScrollbarSuppressor` 从 AppKit 层面把祖先 NSScrollView 的
//    滚动条关掉（滚轮/触控板滚动不受影响）。
// 2. macOS 15+ 上用 `onScrollGeometry` 画应用自己的指示器：
//    一枚 3pt 发丝滑块，滚动时浮现、停止后淡出，颜色取自墨色 token。

/// 关掉最近祖先 NSScrollView 的原生滚动条。
/// 挂在 ScrollView 的内容 `.background` 上，使它的父链正好命中目标。
struct NativeScrollbarSuppressor: NSViewRepresentable {
    final class SuppressingView: NSView {
        private var attempts = 0
        private var retry: DispatchWorkItem?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            suppress()
        }

        func refresh() {
            retry?.cancel()
            attempts = 0
            suppress()
        }

        private func suppress() {
            guard window != nil, attempts < 12 else { return }
            attempts += 1
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                if let scrollView = self.enclosingScrollView {
                    self.hideScrollers(in: scrollView)
                } else {
                    // SwiftUI may mount a representable beside, rather than inside,
                    // its NSScrollView. Search the nearest hosting ancestor only.
                    var ancestor = self.superview
                    while let candidate = ancestor {
                        let scrollViews = self.descendantScrollViews(in: candidate)
                        if !scrollViews.isEmpty {
                            scrollViews.forEach { self.hideScrollers(in: $0) }
                            break
                        }
                        ancestor = candidate.superview
                    }
                }
                // SwiftUI can reapply the system's legacy scroller preference on
                // the next layout pass. Reassert during the short mounting window.
                self.retry?.cancel()
                let next = DispatchWorkItem { [weak self] in self?.suppress() }
                self.retry = next
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: next)
            }
        }

        private func hideScrollers(in scrollView: NSScrollView) {
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
            if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
        }

        private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
            if let scrollView = view as? NSScrollView { return [scrollView] }
            return view.subviews.flatMap { descendantScrollViews(in: $0) }
        }

    }

    func makeNSView(context: Context) -> NSView {
        SuppressingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SuppressingView)?.refresh()
    }
}

extension View {
    /// 应用统一滚动指示器：原生滚动条彻底关闭，位置反馈由
    /// 发丝滑块承担（macOS 15+；更早系统上仅隐藏原生条）。
    func riverScrollIndicators() -> some View {
        modifier(RiverScrollIndicatorModifier())
    }
}

/// 一次滚动几何快照：只取画滑块需要的三个数。
private struct ScrollState: Equatable {
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let offset: CGFloat
}

struct RiverScrollIndicatorModifier: ViewModifier {
    /// 像素测试用 ImageRenderer 离屏渲染：AppKit 挂载与几何回调在离屏
    /// 环境里不会运行，还会撑宽画布。测试环境直接退化为纯视图。
    /// swift test 的进程不设 XCTestConfigurationFilePath，改查 XCTest 类是否已加载。
    private static let isTesting = NSClassFromString("XCTestCase") != nil

    @State private var thumbOffsetY: CGFloat = 0
    @State private var thumbHeight: CGFloat = 28
    @State private var trackHeight: CGFloat = 0
    @State private var opacity: Double = 0
    @State private var fadeTask: Task<Void, Never>?
    /// 首次几何回调发生在布局阶段，不是用户在滚动。那时如果也 reveal，
    /// 每个页面一打开就会闪出一条滚动条并一直挂着（只有滚动相位变化才会排淡出）。
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        if Self.isTesting {
            content
        } else {
            realBody(content: content)
        }
    }

    @ViewBuilder
    private func realBody(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .scrollIndicators(.hidden)
                .background(NativeScrollbarSuppressor())
                .onScrollGeometryChange(for: ScrollState.self) { geometry in
                    ScrollState(
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height,
                        offset: geometry.contentOffset.y
                    )
                } action: { _, state in
                    guard state.containerHeight > 0,
                          state.contentHeight > state.containerHeight + 1 else {
                        fadeNow()
                        return
                    }
                    trackHeight = state.containerHeight
                    thumbHeight = max(state.containerHeight * min(state.containerHeight / state.contentHeight, 1), 28)
                    let maxScroll = state.contentHeight - state.containerHeight
                    let offset = min(max(state.offset, 0), maxScroll)
                    thumbOffsetY = maxScroll > 0 ? (offset / maxScroll) * (state.containerHeight - thumbHeight) : 0
                    // 首次只是布局：记下几何但不显示，避免打开页面时闪一条滚动条。
                    guard hasAppeared else {
                        hasAppeared = true
                        return
                    }
                    reveal()
                    // 每次几何变化都重排淡出：连续滚动时它一直在（每次被取消重排），
                    // 停手 0.7 秒后淡出。这样不必依赖滚动相位回调也能收敛。
                    scheduleFade()
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .idle {
                        scheduleFade()
                    } else {
                        reveal()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if opacity > 0.01, trackHeight > 0 {
                        Capsule()
                            .fill(Color.ink.opacity(0.22))
                            .frame(width: 3, height: thumbHeight)
                            .offset(y: thumbOffsetY)
                            .padding(.trailing, 3)
                            .frame(height: trackHeight, alignment: .top)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
        } else {
            content
                .scrollIndicators(.hidden)
                .background(NativeScrollbarSuppressor())
        }
    }

    private func reveal() {
        fadeTask?.cancel()
        if opacity < 1 {
            withAnimation(.easeIn(duration: 0.1)) { opacity = 1 }
        }
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        fadeTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            fadeNow()
        }
    }

    private func fadeNow() {
        withAnimation(.easeOut(duration: 0.35)) { opacity = 0 }
    }
}
