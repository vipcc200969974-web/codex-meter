import AppKit
import AVFoundation
import Combine
import SwiftUI
import UserNotifications

@main
struct CodexMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private enum PanelMetrics {
    static let cardWidth: CGFloat = 360
    static let cardHeight: CGFloat = 340
    static let windowPadding: CGFloat = 14
    static let width: CGFloat = cardWidth + windowPadding * 2
    static let height: CGFloat = cardHeight + windowPadding * 2
    static let verticalGap: CGFloat = 14
    static let screenPadding: CGFloat = 8
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let usageStore = UsageStore()
    private var statusItem: NSStatusItem?
    private var statusView: CompactStatusItemView?
    private var panelWindow: NSPanel?
    private var outsideClickMonitor: Any?
    private var snapshotCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePanelWindow()
        configureWakeRefreshObservers()
        usageStore.start()

        snapshotCancellable = usageStore.$snapshot.sink { [weak self] snapshot in
            self?.updateStatusItem(with: snapshot)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageStore.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stopOutsideClickMonitor()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let view = CompactStatusItemView()
        view.onClick = { [weak self] in
            self?.togglePanel()
        }
        item.view = view
        statusView = view

        updateStatusItem(with: usageStore.snapshot)
    }

    private func configurePanelWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(
            rootView: StatusPanelView(store: usageStore)
                .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        )
        self.panelWindow = panel
    }

    private func configureWakeRefreshObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(refreshAfterSleepOrUnlock),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(refreshAfterSleepOrUnlock),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(refreshAfterSleepOrUnlock),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    private func updateStatusItem(with snapshot: UsageSnapshot) {
        let quota = snapshot.quota
        let title = quota.isUnavailable ? "未同步" : "\(quota.percentText) | \(quota.shortResetText)"
        let tooltip = quota.isUnavailable
            ? "正在等待 Codex 会话额度数据"
            : "\(quota.mainQuotaSpokenName)剩余 \(quota.remainingPercent)% ，距离额度恢复 \(quota.resetText)"
        statusView?.update(
            title: title,
            color: quota.tagTextColor,
            backgroundColor: quota.tagBackgroundColor,
            tooltip: tooltip
        )
        statusItem?.length = statusView?.frame.width ?? NSStatusItem.variableLength
    }

    private func togglePanel() {
        guard let statusView, let panelWindow else { return }

        if panelWindow.isVisible {
            closePanel()
        } else {
            positionPanel(relativeTo: statusView)
            panelWindow.orderFrontRegardless()
            startOutsideClickMonitor()
            usageStore.refresh()
        }
    }

    private func closePanel() {
        panelWindow?.orderOut(nil)
        stopOutsideClickMonitor()
    }

    private func positionPanel(relativeTo anchorView: NSView) {
        guard let window = anchorView.window else { return }
        let anchorRectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorRect = window.convertToScreen(anchorRectInWindow)
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let proposedX = anchorRect.midX - PanelMetrics.width / 2
        let x = min(
            max(proposedX, visibleFrame.minX + PanelMetrics.screenPadding),
            visibleFrame.maxX - PanelMetrics.width - PanelMetrics.screenPadding
        )
        let y = anchorRect.minY - PanelMetrics.height - PanelMetrics.verticalGap
        panelWindow?.setFrame(
            NSRect(x: x, y: y, width: PanelMetrics.width, height: PanelMetrics.height),
            display: true
        )
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    @objc private func refreshAfterSleepOrUnlock(_ notification: Notification) {
        usageStore.refreshAfterWakeOrUnlock()
    }
}

final class CompactStatusItemView: NSView {
    var onClick: (() -> Void)?

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private let horizontalPadding: CGFloat = 5
    private var title = ""
    private var color = NSColor.labelColor
    private var backgroundColor = NSColor.clear

    func update(title: String, color: NSColor, backgroundColor: NSColor, tooltip: String) {
        self.title = title
        self.color = color
        self.backgroundColor = backgroundColor
        self.toolTip = tooltip

        let width = ceil(attributedTitle.size().width + horizontalPadding * 2)
        frame = NSRect(x: 0, y: 0, width: width, height: NSStatusBar.system.thickness)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let size = attributedTitle.size()
        let tagRect = NSRect(
            x: 0,
            y: floor((bounds.height - 17) / 2),
            width: bounds.width,
            height: 17
        )
        backgroundColor.setFill()
        NSBezierPath(roundedRect: tagRect, xRadius: 5, yRadius: 5).fill()

        color.set()
        let rect = NSRect(
            x: horizontalPadding,
            y: floor((bounds.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
        attributedTitle.draw(in: rect)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    private var attributedTitle: NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: -0.2
            ]
        )
    }
}

struct StatusPanelView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        ZStack {
            ZStack {
                PanelGlassBackground()

                VStack(alignment: .leading, spacing: 12) {
                    header
                    quotaOverview
                    dailyTokenOverview
                }
                .padding(18)
            }
            .frame(width: PanelMetrics.cardWidth, height: PanelMetrics.cardHeight)
            .padding(PanelMetrics.windowPadding)
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(headerStatusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(headerStatusColor)
                .lineLimit(1)

            Spacer()

            RefreshIconButton {
                store.refresh()
            }

            MoreActionsMenu(store: store)
        }
    }

    private var headerStatusText: String {
        let quota = store.snapshot.quota
        let status = "\(quota.sourceName) · \(quota.lastUpdatedText)"
        return store.snapshot.freshness == .stale ? "\(status) · 暂未更新" : status
    }

    private var headerStatusColor: Color {
        if store.snapshot.quota.isUnavailable { return .red }
        if store.snapshot.freshness == .stale { return .orange }
        return .secondary
    }

    private var quotaOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.snapshot.quota.percentText)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(store.snapshot.quota.mainQuotaLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(store.snapshot.quota.shortResetText)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(store.snapshot.quota.resetClockText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            QuotaProgressBar(percent: store.snapshot.quota.displayRemainingPercent, tint: store.snapshot.quota.tint)

            if store.snapshot.quota.showsWeeklySecondary {
                Divider()
                    .padding(.vertical, 1)

                SecondaryQuotaRow(
                    title: "周额度",
                    percentText: store.snapshot.quota.weeklyPercentText,
                    trailing: store.snapshot.quota.weeklyResetDateText
                )
            }
        }
        .padding(14)
        .notificationInsetSurface(cornerRadius: 12)
    }

    private var dailyTokenOverview: some View {
        DailyTokenUsageCard(usage: store.snapshot.dailyTokens)
            .padding(14)
            .notificationInsetSurface(cornerRadius: 12)
    }
}

struct DailyTokenUsageCard: View {
    let usage: DailyTokenUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日 Token")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(usage.totalTokens == 0 ? "今日暂无使用" : TokenCountFormatter.compact(usage.totalTokens))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            TokenCompositionBar(usage: usage)

            HStack(spacing: 12) {
                TokenMetric(label: "缓存", value: usage.cachedInputTokens, color: .cyan)
                TokenMetric(label: "非缓存", value: usage.nonCachedInputTokens, color: .purple)
                TokenMetric(label: "输出", value: usage.outputTokens, color: .orange)
            }

            Text("推理 \(TokenCountFormatter.compact(usage.reasoningOutputTokens))（已包含在输出中）")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("今日 Token 使用")
    }
}

struct TokenCompositionBar: View {
    let usage: DailyTokenUsage

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width.isFinite ? max(geometry.size.width, 0) : 0

            if usage.totalTokens > 0 {
                ZStack(alignment: .leading) {
                    Color.secondary.opacity(0.15)

                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.cyan)
                            .frame(width: availableWidth * usage.cachedFraction)
                        Rectangle()
                            .fill(Color.purple)
                            .frame(width: availableWidth * usage.nonCachedFraction)
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: availableWidth * usage.outputFraction)
                    }
                }
                .clipShape(Capsule())
            } else {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(height: 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token 构成")
        .accessibilityValue(compositionAccessibilityValue)
    }

    private var compositionAccessibilityValue: String {
        "缓存 \(TokenCountFormatter.compact(usage.cachedInputTokens))，非缓存 \(TokenCountFormatter.compact(usage.nonCachedInputTokens))，输出 \(TokenCountFormatter.compact(usage.outputTokens))"
    }
}

struct TokenMetric: View {
    let label: String
    let value: Int64
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(TokenCountFormatter.compact(value))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(TokenCountFormatter.compact(value))
    }
}

struct PanelGlassBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        ZStack {
            shape
                .fill(.ultraThinMaterial)

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.64),
                            Color(red: 0.82, green: 0.94, blue: 1.0).opacity(0.48),
                            Color.white.opacity(0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.84),
                            Color(red: 0.90, green: 0.98, blue: 1.0).opacity(0.32),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 82
                    )
                )
                .frame(width: 130, height: 150)
                .offset(x: 130, y: -56)
                .blur(radius: 4)

            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.68),
                            Color.white.opacity(0.38),
                            Color(red: 0.42, green: 0.70, blue: 0.88).opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            shape
                .stroke(Color.white.opacity(0.22), lineWidth: 0.7)
                .padding(1.2)
        }
        .clipShape(shape)
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
    }
}

private extension View {
    func notificationInsetSurface(cornerRadius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.28))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
        )
    }

    func glassSurface(cornerRadius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.028),
                            Color.white.opacity(0.006)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.20),
                            Color.white.opacity(0.05),
                            Color.white.opacity(0.012)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    func glassIconSurface(cornerRadius: CGFloat = 4, isPressed: Bool = false, isHovered: Bool = false) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isPressed ? 0.12 : (isHovered ? 0.54 : 0.40)),
                            Color.white.opacity(isPressed ? 0.04 : (isHovered ? 0.24 : 0.15)),
                            Color.black.opacity(isPressed ? 0.14 : 0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isPressed ? 0.22 : (isHovered ? 0.68 : 0.52)),
                            Color.white.opacity(isPressed ? 0.10 : (isHovered ? 0.42 : 0.30)),
                            Color.black.opacity(isPressed ? 0.20 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                .stroke(Color.white.opacity(isPressed ? 0.04 : 0.10), lineWidth: 0.6)
                .padding(1.25)
        )
        .shadow(color: Color.white.opacity(isPressed ? 0.04 : (isHovered ? 0.16 : 0.08)), radius: 0, x: 0, y: -0.6)
        .shadow(color: Color.black.opacity(isPressed ? 0.06 : (isHovered ? 0.13 : 0.10)), radius: isPressed ? 1 : (isHovered ? 3 : 2), x: 0, y: isPressed ? 0.4 : (isHovered ? 1.6 : 1.2))
        .shadow(color: Color.black.opacity(isPressed ? 0.03 : (isHovered ? 0.07 : 0.05)), radius: isPressed ? 1 : (isHovered ? 5 : 3), x: 0, y: isPressed ? 0.8 : (isHovered ? 3 : 2))
        .offset(y: isPressed ? 0.75 : (isHovered ? -0.6 : 0))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

}

struct RefreshIconButton: View {
    let action: () -> Void
    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            PanelIconFrame(systemImage: "arrow.clockwise", isPressed: isPressed, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.08)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if isPressed == false {
                        withAnimation(.easeOut(duration: 0.035)) {
                            isPressed = true
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.12, dampingFraction: 0.72)) {
                        isPressed = false
                    }
                }
        )
        .help("刷新")
    }
}

struct PanelIconFrame: View {
    let systemImage: String
    var isPressed = false
    var isHovered = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .foregroundStyle(.secondary)
            .glassIconSurface(isPressed: isPressed, isHovered: isHovered)
    }
}

struct MoreActionsMenu: View {
    @ObservedObject var store: UsageStore
    @State private var isShowingActions = false
    @State private var isPressed = false
    @State private var isHovered = false
    
    var body: some View {
        Button {
            isShowingActions.toggle()
        } label: {
            PanelIconFrame(systemImage: "ellipsis", isPressed: isPressed || isShowingActions, isHovered: isHovered || isShowingActions)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.08)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if isPressed == false {
                        withAnimation(.easeOut(duration: 0.035)) {
                            isPressed = true
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.12, dampingFraction: 0.72)) {
                        isPressed = false
                    }
                }
        )
        .popover(isPresented: $isShowingActions, arrowEdge: .top) {
            ActionsPopover(store: store)
                .frame(width: 224)
        }
        .help("更多")
    }
}

struct ActionsPopover: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                store.toggleVoiceBroadcast()
            } label: {
                ActionMenuRow(
                    systemImage: store.voiceBroadcastEnabled ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: store.voiceBroadcastEnabled ? "关闭播报" : "开启播报",
                    trailing: store.voiceBroadcastEnabled ? nil : "\(store.voiceBroadcastIntervalMinutes) 分钟"
                )
            }
            .buttonStyle(.plain)

            if store.voiceBroadcastEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("播报间隔")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)

                    BroadcastIntervalButton(minutes: 1, store: store)
                    BroadcastIntervalButton(minutes: 5, store: store)
                    BroadcastIntervalButton(minutes: 10, store: store)
                }
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                ActionMenuRow(systemImage: "power", title: "退出应用", trailing: nil)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(PanelGlassBackground())
    }
}

struct BroadcastIntervalButton: View {
    let minutes: Int
    @ObservedObject var store: UsageStore

    var body: some View {
        Button {
            store.setVoiceBroadcastInterval(minutes: minutes)
        } label: {
            ActionMenuRow(
                systemImage: store.voiceBroadcastIntervalMinutes == minutes ? "checkmark.circle.fill" : "circle",
                title: "\(minutes) 分钟",
                trailing: nil
            )
        }
        .buttonStyle(.plain)
    }
}

struct ActionMenuRow: View {
    let systemImage: String
    let title: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .glassSurface(cornerRadius: 6)
    }
}

struct QuotaProgressBar: View {
    let percent: Int
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(Color(nsColor: .separatorColor).opacity(0.16))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(0.78),
                                tint
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, proxy.size.width * min(max(Double(percent) / 100, 0), 1)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.white.opacity(0.24), lineWidth: 0.6)
                    )
            }
        }
        .frame(height: 8)
    }
}

struct SecondaryQuotaRow: View {
    let title: String
    let percentText: String
    let trailing: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(percentText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(trailing)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .trailing)
        }
    }
}

enum UsageFreshness: Equatable, Sendable {
    case live
    case stale
    case unavailable
}

struct UsageSnapshot: Sendable {
    let quota: QuotaSnapshot
    let dailyTokens: DailyTokenUsage
    let freshness: UsageFreshness

    static let unavailable = UsageSnapshot(
        quota: .unavailable(),
        dailyTokens: .zero,
        freshness: .unavailable
    )
}

struct UsageLoadResult: Sendable {
    let quota: QuotaSnapshot?
    let dailyTokens: DailyTokenUsage?

    static let empty = UsageLoadResult(quota: nil, dailyTokens: nil)
}

protocol UsageLoading: Sendable {
    func load(now: Date) -> UsageLoadResult
}

final class LocalUsageLoader: UsageLoading, @unchecked Sendable {
    private let quotaProvider: CompositeQuotaProvider
    private let tokenProvider: any DailyTokenUsageProviding

    init(
        quotaProvider: CompositeQuotaProvider = CompositeQuotaProvider(),
        tokenProvider: any DailyTokenUsageProviding = DailyTokenUsageProvider()
    ) {
        self.quotaProvider = quotaProvider
        self.tokenProvider = tokenProvider
    }

    func load(now: Date) -> UsageLoadResult {
        let quota = quotaProvider.currentObservation(now: now).map(QuotaSnapshot.init(observation:))
        let tokens = try? tokenProvider.currentUsage(now: now)
        return UsageLoadResult(quota: quota, dailyTokens: tokens)
    }
}

protocol UsageScheduledTask: AnyObject, Sendable {
    func cancel()
}

@MainActor
protocol UsageScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        action: @escaping @MainActor () -> Void
    ) -> any UsageScheduledTask
}

private final class FoundationUsageScheduledTask: UsageScheduledTask, @unchecked Sendable {
    private let lock = NSLock()
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        lock.lock()
        let timerToInvalidate = timer
        timer = nil
        lock.unlock()
        timerToInvalidate?.invalidate()
    }

    deinit {
        cancel()
    }
}

@MainActor
private final class FoundationUsageScheduler: UsageScheduling {
    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        action: @escaping @MainActor () -> Void
    ) -> any UsageScheduledTask {
        let timer = Timer(
            fire: Date().addingTimeInterval(delay),
            interval: interval ?? 0,
            repeats: interval != nil
        ) { _ in
            Task { @MainActor in
                action()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return FoundationUsageScheduledTask(timer: timer)
    }
}

typealias UsageWatcherFactory = (_ onChange: @escaping () -> Void) -> any CodexActivityWatching

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot
    @Published var voiceBroadcastEnabled = false
    @Published var voiceBroadcastIntervalMinutes: Int

    private var fallbackTask: (any UsageScheduledTask)?
    private var debounceTask: (any UsageScheduledTask)?
    private var midnightTask: (any UsageScheduledTask)?
    private var voiceTimer: Timer?
    private var isRefreshing = false
    private var refreshPending = false
    private var isStarted = false
    private var lifecycleGeneration: UInt = 0
    private var debounceGeneration: UInt = 0
    private var speakAfterRefresh = false
    private let refreshQueue = DispatchQueue(label: "com.codexmeter.refresh", qos: .utility)
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var notifiedLevels = Set<Int>()
    private let loader: any UsageLoading
    private var watcher: CodexActivityWatching?
    private let createsWatcher: Bool
    private let debounceInterval: TimeInterval
    private let fallbackInterval: TimeInterval
    private let scheduler: any UsageScheduling
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let watcherFactory: UsageWatcherFactory

    init(
        loader: any UsageLoading = LocalUsageLoader(),
        watcher: CodexActivityWatching? = nil,
        debounceInterval: TimeInterval = 0.8,
        fallbackInterval: TimeInterval = 60,
        scheduler: any UsageScheduling = FoundationUsageScheduler(),
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = Date.init,
        watcherFactory: @escaping UsageWatcherFactory = {
            CodexActivityWatcher(onChange: $0)
        }
    ) {
        self.loader = loader
        self.watcher = watcher
        self.createsWatcher = watcher == nil
        self.debounceInterval = debounceInterval
        self.fallbackInterval = fallbackInterval
        self.scheduler = scheduler
        self.calendar = calendar
        self.now = now
        self.watcherFactory = watcherFactory
        let cachedQuota = QuotaSnapshot.cached() ?? .unavailable()
        self.snapshot = UsageSnapshot(
            quota: cachedQuota,
            dailyTokens: .zero,
            freshness: cachedQuota.isUnavailable ? .unavailable : .stale
        )
        let savedInterval = UserDefaults.standard.integer(forKey: CacheKey.voiceBroadcastIntervalMinutes)
        self.voiceBroadcastIntervalMinutes = Self.allowedVoiceBroadcastIntervals.contains(savedInterval) ? savedInterval : 1
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration

        if watcher == nil {
            watcher = watcherFactory { [weak self] in
                DispatchQueue.main.async {
                    guard let self,
                          self.isStarted,
                          self.lifecycleGeneration == generation else {
                        return
                    }
                    self.scheduleRefresh()
                }
            }
        }
        watcher?.start()
        refresh()
        requestNotificationPermission()
        fallbackTask = scheduler.schedule(
            after: fallbackInterval,
            repeating: fallbackInterval
        ) { [weak self] in
            guard let self,
                  self.isStarted,
                  self.lifecycleGeneration == generation else {
                return
            }
            self.refreshAfterWakeOrUnlock()
        }
        scheduleNextLocalMidnight(generation: generation)
    }

    func stop() {
        let wasStarted = isStarted
        lifecycleGeneration &+= 1
        debounceGeneration &+= 1
        isStarted = false
        isRefreshing = false
        refreshPending = false
        debounceTask?.cancel()
        debounceTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        midnightTask?.cancel()
        midnightTask = nil
        voiceTimer?.invalidate()
        voiceTimer = nil
        speakAfterRefresh = false
        voiceBroadcastEnabled = false
        speechSynthesizer.stopSpeaking(at: .immediate)
        if wasStarted {
            watcher?.stop()
        }
        if createsWatcher {
            watcher = nil
        }
    }

    func scheduleRefresh() {
        debounceTask?.cancel()
        let generation = lifecycleGeneration
        debounceGeneration &+= 1
        let scheduledDebounceGeneration = debounceGeneration
        debounceTask = scheduler.schedule(after: debounceInterval, repeating: nil) { [weak self] in
            guard let self,
                  self.lifecycleGeneration == generation,
                  self.debounceGeneration == scheduledDebounceGeneration else {
                return
            }
            self.debounceTask = nil
            self.refresh()
        }
    }

    func refreshAfterWakeOrUnlock() {
        watcher?.rebind()
        refresh()
        if isStarted {
            scheduleNextLocalMidnight(generation: lifecycleGeneration)
        }
    }

    func refresh() {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        let loader = loader
        let loadDate = now()
        let generation = lifecycleGeneration

        refreshQueue.async { [weak self] in
            let result = loader.load(now: loadDate)

            DispatchQueue.main.async {
                guard let self, self.lifecycleGeneration == generation else { return }
                let old = self.snapshot
                let quota = result.quota ?? old.quota
                let tokens = result.dailyTokens ?? old.dailyTokens
                let hasFreshQuota = result.quota != nil
                let hasFreshTokens = result.dailyTokens != nil
                self.snapshot = UsageSnapshot(
                    quota: quota,
                    dailyTokens: tokens,
                    freshness: hasFreshQuota && hasFreshTokens ? .live : (quota.isUnavailable ? .unavailable : .stale)
                )
                if let freshQuota = result.quota {
                    freshQuota.cache()
                }
                self.isRefreshing = false
                self.finishRefreshSideEffects()
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    private func scheduleNextLocalMidnight(generation: UInt) {
        midnightTask?.cancel()
        let current = now()
        let startOfToday = calendar.startOfDay(for: current)
        guard let nextMidnight = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            midnightTask = nil
            return
        }
        let delay = max(nextMidnight.timeIntervalSince(current), 0)
        midnightTask = scheduler.schedule(after: delay, repeating: nil) { [weak self] in
            guard let self,
                  self.isStarted,
                  self.lifecycleGeneration == generation else {
                return
            }
            self.midnightTask = nil
            self.refresh()
            self.scheduleNextLocalMidnight(generation: generation)
        }
    }

    isolated deinit {
        debounceTask?.cancel()
        fallbackTask?.cancel()
        midnightTask?.cancel()
        voiceTimer?.invalidate()
        if isStarted {
            watcher?.stop()
        }
    }

    private func finishRefreshSideEffects() {
        let shouldSpeak = speakAfterRefresh
        speakAfterRefresh = false
        evaluateNotifications(snapshot.quota)
        if shouldSpeak, voiceBroadcastEnabled {
            speak(snapshot.quota)
        }
    }

    func toggleVoiceBroadcast() {
        if voiceBroadcastEnabled {
            stopVoiceBroadcast()
        } else {
            startVoiceBroadcast()
        }
    }

    private func startVoiceBroadcast() {
        voiceBroadcastEnabled = true
        requestVoiceBroadcast()
        scheduleVoiceTimer()
    }

    private func scheduleVoiceTimer() {
        voiceTimer?.invalidate()
        let generation = lifecycleGeneration
        voiceTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(voiceBroadcastIntervalMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.lifecycleGeneration == generation,
                      self.voiceBroadcastEnabled else {
                    return
                }
                self.requestVoiceBroadcast()
            }
        }
    }

    private func stopVoiceBroadcast() {
        voiceBroadcastEnabled = false
        speakAfterRefresh = false
        voiceTimer?.invalidate()
        voiceTimer = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    func setVoiceBroadcastInterval(minutes: Int) {
        guard Self.allowedVoiceBroadcastIntervals.contains(minutes) else { return }
        voiceBroadcastIntervalMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: CacheKey.voiceBroadcastIntervalMinutes)
        if voiceBroadcastEnabled {
            scheduleVoiceTimer()
        }
    }

    private func requestVoiceBroadcast() {
        speakAfterRefresh = true
        refresh()
    }

    private func speak(_ snapshot: QuotaSnapshot) {
        guard !snapshot.isUnavailable else { return }
        let text = "Codex \(snapshot.mainQuotaSpokenName)剩余 \(snapshot.remainingPercent)%，距离额度恢复 \(snapshot.resetText)。"
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(utterance)
    }

    private func evaluateNotifications(_ snapshot: QuotaSnapshot) {
        guard !snapshot.isUnavailable else { return }
        let remaining = snapshot.remainingPercent

        if remaining <= 10 {
            notifyOnce(
                level: 10,
                title: "Codex 额度接近耗尽",
                body: "当前 \(snapshot.mainQuotaSpokenName)剩余 \(remaining)%，建议放慢高消耗任务。"
            )
        } else if remaining <= 20 {
            notifyOnce(
                level: 20,
                title: "Codex 额度偏低",
                body: "当前 \(snapshot.mainQuotaSpokenName)剩余 \(remaining)%，距离额度恢复 \(snapshot.resetText)。"
            )
        }
    }

    private func notifyOnce(level: Int, title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard notifiedLevels.insert(level).inserted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "codex-meter-\(level)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationPermission() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static let allowedVoiceBroadcastIntervals = [1, 5, 10]
}

struct ObservedRateLimitWindow: Sendable {
    let window: RateLimitWindow
    let observedAt: Date
    let sourceName: String
}

struct QuotaObservation: Sendable {
    let windowSet: RateLimitWindowSet
    let observedAt: Date
    let sourceName: String
}

protocol QuotaObservationProviding: Sendable {
    func currentWindowObservations() -> [ObservedRateLimitWindow]
}

struct CompositeQuotaProvider: Sendable {
    private let providers: [any QuotaObservationProviding]

    init(providers: [any QuotaObservationProviding] = [
        CodexLogQuotaProvider(),
        CodexSessionQuotaProvider()
    ]) {
        self.providers = providers
    }

    func currentObservation(now: Date = Date()) -> QuotaObservation? {
        Self.merge(providers.flatMap { $0.currentWindowObservations() }, now: now)
    }

    static func merge(_ candidates: [ObservedRateLimitWindow], now: Date) -> QuotaObservation? {
        let selected = RateLimitWindowReducer.bestWindows(from: candidates, now: now)
        guard let newest = selected.max(by: RateLimitWindowReducer.observationPrecedes) else {
            return nil
        }
        let sourceNames = Set(selected.map(\.sourceName))
        return QuotaObservation(
            windowSet: RateLimitWindowSet(windows: selected.map(\.window), now: now),
            observedAt: newest.observedAt,
            sourceName: sourceNames.count == 1 ? newest.sourceName : "本机日志"
        )
    }
}

struct CodexLogQuotaProvider: QuotaObservationProviding {
    private let databaseURL: URL

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/logs_2.sqlite")
    ) {
        self.databaseURL = databaseURL
    }

    func currentWindowObservations() -> [ObservedRateLimitWindow] {
        let now = Date()
        return RateLimitWindowReducer.bestWindows(
            from: RateLimitWindowReducer.observations(
                from: recentHeaderRateLimitRecords(now: now),
                sourceName: "Codex 日志"
            ),
            now: now
        )
    }

    private func recentHeaderRateLimitRecords(now: Date) -> [RateLimitRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        let lowerBound = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            QuotaHistoryBounds.lowerBound(for: now).timeIntervalSince1970
        )
        let query = """
        select ts, feedback_log_body from logs
        where target = 'codex_http_client::client'
          and ts >= \(lowerBound)
          and (
            feedback_log_body like '%x-codex-primary-used-percent%'
            or feedback_log_body like '%x-codex-secondary-used-percent%'
          )
        order by ts desc, ts_nanos desc, id desc;
        """
        guard let rows = runSQLiteRows(databasePath: databaseURL.path, query: query) else {
            return []
        }

        return rows.compactMap { row in
            Self.parseHeaderRecord(
                timestamp: row.ts,
                text: row.feedbackLogBody,
                now: now
            )
        }
    }

    static func parseHeaderRecord(
        timestamp: TimeInterval,
        text: String,
        now: Date
    ) -> RateLimitRecord? {
        let windows = [
            headerWindow(prefix: "primary", in: text),
            headerWindow(prefix: "secondary", in: text)
        ].compactMap { $0 }
        let windowSet = RateLimitWindowSet(windows: windows, now: now)
        guard !windowSet.isEmpty else { return nil }

        let date = Date(timeIntervalSince1970: timestamp)
        return RateLimitRecord(
            timestamp: date,
            fileModifiedAt: date,
            windowSet: windowSet
        )
    }

    private static func headerWindow(prefix: String, in text: String) -> RateLimitWindow? {
        guard let usedPercent = headerDouble("x-codex-\(prefix)-used-percent", in: text),
              let resetsAt = headerDouble("x-codex-\(prefix)-reset-at", in: text),
              let windowMinutes = headerInt("x-codex-\(prefix)-window-minutes", in: text) else {
            return nil
        }

        return RateLimitWindow(
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes
        )
    }

    private func runSQLiteRows(databasePath: String, query: String) -> [SQLiteLogRow]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", databasePath, query]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode([SQLiteLogRow].self, from: data)
    }

    private static func headerDouble(_ name: String, in text: String) -> Double? {
        guard let value = headerValue(name, in: text) else { return nil }
        return Double(value)
    }

    private static func headerInt(_ name: String, in text: String) -> Int? {
        guard let value = headerValue(name, in: text) else { return nil }
        return Int(value)
    }

    private static func headerValue(_ name: String, in text: String) -> String? {
        let marker = "\"\(name)\": \""
        guard let markerRange = text.range(of: marker) else {
            return nil
        }
        let valueStart = markerRange.upperBound
        guard let valueEnd = text[valueStart...].firstIndex(of: "\"") else {
            return nil
        }
        return String(text[valueStart..<valueEnd])
    }

    private struct SQLiteLogRow: Decodable {
        let ts: Double
        let feedbackLogBody: String

        private enum CodingKeys: String, CodingKey {
            case ts
            case feedbackLogBody = "feedback_log_body"
        }
    }
}

struct CodexSessionQuotaProvider: QuotaObservationProviding {
    private let roots: [URL]
    private let maxBytesPerFile: UInt64
    private let maxTotalBytes: UInt64
    private let now: @Sendable () -> Date

    init(
        roots: [URL]? = nil,
        maxBytesPerFile: UInt64 = 64 * 1_024 * 1_024,
        maxTotalBytes: UInt64 = 256 * 1_024 * 1_024,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.roots = roots ?? [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions")
        ]
        self.maxBytesPerFile = maxBytesPerFile
        self.maxTotalBytes = maxTotalBytes
        self.now = now
    }

    func currentWindowObservations() -> [ObservedRateLimitWindow] {
        let currentDate = now()
        guard let records = recentRateLimitRecords(now: currentDate) else {
            return []
        }
        return RateLimitWindowReducer.bestWindows(
            from: RateLimitWindowReducer.observations(
                from: records,
                sourceName: "Codex 会话"
            ),
            now: currentDate
        )
    }

    private func recentRateLimitRecords(now: Date) -> [RateLimitRecord]? {
        let lowerBound = QuotaHistoryBounds.lowerBound(for: now)
        let files = deduplicatedSessionFiles(overlapping: lowerBound)
        guard filesFitScanBudget(files) else { return nil }

        var records: [RateLimitRecord] = []
        for file in files {
            guard let fileRecords = rateLimitRecords(
                in: file.url,
                expectedByteCount: file.byteCount,
                fileModifiedAt: file.modifiedAt,
                now: now,
                lowerBound: lowerBound
            ) else {
                return nil
            }
            records.append(contentsOf: fileRecords)
        }

        return records
    }

    private func filesFitScanBudget(_ files: [SessionFile]) -> Bool {
        var totalBytes: UInt64 = 0
        for file in files {
            guard file.byteCount <= maxBytesPerFile,
                  totalBytes <= maxTotalBytes,
                  file.byteCount <= maxTotalBytes - totalBytes else {
                return false
            }
            totalBytes += file.byteCount
        }
        return true
    }

    private func deduplicatedSessionFiles(overlapping lowerBound: Date) -> [SessionFile] {
        let candidates = roots.flatMap { recentJSONLFiles(under: $0) }
            .filter { $0.modifiedAt >= lowerBound }
        var filesByRolloutName: [String: SessionFile] = [:]

        for candidate in candidates {
            let rolloutName = candidate.url.lastPathComponent
            guard let existing = filesByRolloutName[rolloutName] else {
                filesByRolloutName[rolloutName] = candidate
                continue
            }
            if candidate.modifiedAt > existing.modifiedAt
                || (candidate.modifiedAt == existing.modifiedAt
                    && candidate.url.path < existing.url.path) {
                filesByRolloutName[rolloutName] = candidate
            }
        }

        return filesByRolloutName.values.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.url.path < rhs.url.path
        }
    }

    private func recentJSONLFiles(under root: URL) -> [SessionFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [SessionFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
            ),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  let fileSize = values.fileSize,
                  fileSize >= 0 else {
                continue
            }
            files.append(SessionFile(
                url: url,
                modifiedAt: modifiedAt,
                byteCount: UInt64(fileSize)
            ))
        }
        return files
    }

    private func rateLimitRecords(
        in url: URL,
        expectedByteCount: UInt64,
        fileModifiedAt: Date,
        now: Date,
        lowerBound: Date
    ) -> [RateLimitRecord]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let chunkSize = 64 * 1_024
        var records: [RateLimitRecord] = []
        var earlierOffset: UInt64
        do {
            earlierOffset = try handle.seekToEnd()
        } catch {
            return nil
        }
        guard earlierOffset == expectedByteCount else { return nil }
        var laterFragment = Data()

        while earlierOffset > 0 {
            let byteCount = Int(min(UInt64(chunkSize), earlierOffset))
            earlierOffset -= UInt64(byteCount)

            let chunk: Data
            do {
                try handle.seek(toOffset: earlierOffset)
                chunk = try handle.read(upToCount: byteCount) ?? Data()
            } catch {
                return nil
            }
            guard chunk.count == byteCount else { return nil }

            var combined = chunk
            combined.append(laterFragment)
            let fragments = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
            let firstCompleteIndex: Int
            if earlierOffset > 0 {
                if let firstFragment = fragments.first {
                    laterFragment = Data(firstFragment)
                } else {
                    laterFragment = Data()
                }
                firstCompleteIndex = 1
            } else {
                laterFragment = Data()
                firstCompleteIndex = 0
            }

            guard firstCompleteIndex < fragments.count else { continue }
            for fragment in fragments[firstCompleteIndex...].reversed() {
                guard !fragment.isEmpty else { continue }
                guard fragment.range(of: rateLimitsMarker) != nil else { continue }
                let line = String(decoding: fragment, as: UTF8.self)
                guard let record = Self.parseRecord(
                    line: line,
                    fileModifiedAt: fileModifiedAt,
                    now: now
                ), record.sortDate >= lowerBound else { continue }
                records.append(record)
            }
        }

        return records
    }

    static func parseRecord(
        line: String,
        fileModifiedAt: Date,
        now: Date
    ) -> RateLimitRecord? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any],
              isAggregateCodexLimit(rateLimits) else {
            return nil
        }

        let windows = [
            parseWindow(rateLimits["primary"]),
            parseWindow(rateLimits["secondary"])
        ].compactMap { $0 }
        let windowSet = RateLimitWindowSet(windows: windows, now: now)
        guard !windowSet.isEmpty else { return nil }

        return RateLimitRecord(
            timestamp: parseDate(object["timestamp"] as? String),
            fileModifiedAt: fileModifiedAt,
            windowSet: windowSet
        )
    }

    static func bestRateLimitRecord(
        from records: [RateLimitRecord],
        now: Date
    ) -> RateLimitRecord? {
        let selected = RateLimitWindowReducer.bestWindows(
            from: RateLimitWindowReducer.observations(
                from: records,
                sourceName: "Codex 会话"
            ),
            now: now
        )
        let windowSet = RateLimitWindowSet(windows: selected.map(\.window), now: now)
        guard !windowSet.isEmpty,
              let newest = selected.max(by: RateLimitWindowReducer.observationPrecedes) else {
            return nil
        }

        return RateLimitRecord(
            timestamp: newest.observedAt,
            fileModifiedAt: newest.observedAt,
            windowSet: windowSet
        )
    }

    private let rateLimitsMarker = Data("\"rate_limits\"".utf8)

    private static func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let dictionary = value as? [String: Any],
              let usedPercent = Self.double(dictionary["used_percent"]),
              let resetsAt = Self.double(dictionary["resets_at"]) else {
            return nil
        }
        return RateLimitWindow(
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            windowMinutes: Self.int(dictionary["window_minutes"])
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func isAggregateCodexLimit(_ rateLimits: [String: Any]) -> Bool {
        (rateLimits["limit_id"] as? String) == "codex"
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}

private enum QuotaHistoryBounds {
    static let tolerance: TimeInterval = 6 * 60 * 60
    static let maximumWindowDuration = TimeInterval(QuotaWindowKind.weekly.rawValue * 60)

    static func lowerBound(for now: Date) -> Date {
        now.addingTimeInterval(-(maximumWindowDuration + tolerance))
    }
}

private enum RateLimitWindowReducer {
    static func observations(
        from records: [RateLimitRecord],
        sourceName: String
    ) -> [ObservedRateLimitWindow] {
        records.flatMap { record in
            [record.windowSet.fiveHour, record.windowSet.weekly].compactMap { window in
                window.map {
                    ObservedRateLimitWindow(
                        window: $0,
                        observedAt: record.sortDate,
                        sourceName: sourceName
                    )
                }
            }
        }
    }

    static func bestWindows(
        from candidates: [ObservedRateLimitWindow],
        now: Date
    ) -> [ObservedRateLimitWindow] {
        let active = candidates.filter {
            $0.window.kind != nil
                && $0.window.canonicalResetEpochSecond != nil
                && $0.window.resetsAt > now.timeIntervalSince1970
        }

        return QuotaWindowKind.allCases.compactMap { kind in
            let candidatesForKind = active.filter { $0.window.kind == kind }
            guard let newestReset = candidatesForKind.compactMap({
                $0.window.canonicalResetEpochSecond
            }).max() else {
                return nil
            }
            let sameReset = candidatesForKind.filter {
                $0.window.canonicalResetEpochSecond == newestReset
            }
            guard let highestUsage = sameReset.max(by: usagePrecedes),
                  let latestObservation = sameReset.max(by: observationPrecedes) else {
                return nil
            }
            return ObservedRateLimitWindow(
                window: RateLimitWindow(
                    usedPercent: highestUsage.window.usedPercent,
                    resetsAt: Double(newestReset),
                    windowMinutes: highestUsage.window.windowMinutes
                ),
                observedAt: latestObservation.observedAt,
                sourceName: latestObservation.sourceName
            )
        }
    }

    static func observationPrecedes(
        _ lhs: ObservedRateLimitWindow,
        _ rhs: ObservedRateLimitWindow
    ) -> Bool {
        if lhs.observedAt != rhs.observedAt {
            return lhs.observedAt < rhs.observedAt
        }
        if lhs.window.canonicalResetEpochSecond != rhs.window.canonicalResetEpochSecond {
            return (lhs.window.canonicalResetEpochSecond ?? .min)
                < (rhs.window.canonicalResetEpochSecond ?? .min)
        }

        let lhsPriority = sourcePriority(lhs.sourceName)
        let rhsPriority = sourcePriority(rhs.sourceName)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.sourceName != rhs.sourceName {
            return lhs.sourceName < rhs.sourceName
        }
        return lhs.window.usedPercent < rhs.window.usedPercent
    }

    private static func usagePrecedes(
        _ lhs: ObservedRateLimitWindow,
        _ rhs: ObservedRateLimitWindow
    ) -> Bool {
        if lhs.window.usedPercent != rhs.window.usedPercent {
            return lhs.window.usedPercent < rhs.window.usedPercent
        }
        return observationPrecedes(lhs, rhs)
    }

    private static func sourcePriority(_ sourceName: String) -> Int {
        switch sourceName {
        case "Codex 日志":
            return 2
        case "Codex 会话":
            return 1
        default:
            return 0
        }
    }
}

private struct SessionFile {
    let url: URL
    let modifiedAt: Date
    let byteCount: UInt64
}

struct RateLimitRecord {
    let timestamp: Date?
    let fileModifiedAt: Date
    let windowSet: RateLimitWindowSet

    init(timestamp: Date?, fileModifiedAt: Date, windowSet: RateLimitWindowSet) {
        self.timestamp = timestamp
        self.fileModifiedAt = fileModifiedAt
        self.windowSet = windowSet
    }

    init(
        timestamp: Date?,
        fileModifiedAt: Date,
        primary: RateLimitWindow,
        secondary: RateLimitWindow
    ) {
        self.init(
            timestamp: timestamp,
            fileModifiedAt: fileModifiedAt,
            windowSet: RateLimitWindowSet(windows: [primary, secondary], now: Date())
        )
    }

    var primary: RateLimitWindow {
        windowSet.fiveHour ?? windowSet.weekly!
    }

    var secondary: RateLimitWindow {
        windowSet.weekly ?? windowSet.fiveHour!
    }

    var sortDate: Date {
        timestamp ?? fileModifiedAt
    }
}

enum QuotaWindowKind: Int, CaseIterable, Sendable {
    case fiveHour = 300
    case weekly = 10_080

    var displayLabel: String {
        switch self {
        case .fiveHour:
            return "5 小时剩余"
        case .weekly:
            return "7 天剩余"
        }
    }

    var spokenName: String {
        switch self {
        case .fiveHour:
            return "五小时额度"
        case .weekly:
            return "七天额度"
        }
    }
}

struct RateLimitWindow: Sendable {
    let usedPercent: Double
    let resetsAt: Double
    let windowMinutes: Int?

    var kind: QuotaWindowKind? {
        windowMinutes.flatMap { QuotaWindowKind(rawValue: $0) }
    }

    var canonicalResetEpochSecond: Int64? {
        let maximumExactlyRepresentableInteger = 9_007_199_254_740_991.0
        guard resetsAt.isFinite,
              resetsAt >= 0,
              resetsAt <= maximumExactlyRepresentableInteger else {
            return nil
        }
        return Int64(resetsAt.rounded(.toNearestOrAwayFromZero))
    }
}

struct RateLimitWindowSet: Sendable {
    let fiveHour: RateLimitWindow?
    let weekly: RateLimitWindow?

    init(windows: [RateLimitWindow], now: Date) {
        let active = windows.filter { $0.resetsAt > now.timeIntervalSince1970 }
        fiveHour = active.last { $0.kind == .fiveHour }
        weekly = active.last { $0.kind == .weekly }
    }

    var isEmpty: Bool {
        fiveHour == nil && weekly == nil
    }
}

struct QuotaWindowSnapshot: Sendable {
    let kind: QuotaWindowKind
    let remainingPercent: Int
    let resetDate: Date

    init(kind: QuotaWindowKind, remainingPercent: Int, resetDate: Date) {
        self.kind = kind
        self.remainingPercent = max(0, min(100, remainingPercent))
        self.resetDate = resetDate
    }

    init?(window: RateLimitWindow) {
        guard let kind = window.kind else { return nil }
        let usedPercent = Int(window.usedPercent.rounded())
        self.init(
            kind: kind,
            remainingPercent: 100 - usedPercent,
            resetDate: Date(timeIntervalSince1970: window.resetsAt)
        )
    }
}

struct QuotaSnapshot: Sendable {
    let mainWindow: QuotaWindowSnapshot?
    let weeklyWindow: QuotaWindowSnapshot?
    let lastUpdated: Date
    let sourceName: String

    init(record: RateLimitRecord, sourceName: String, lastUpdated: Date) {
        let fiveHour = record.windowSet.fiveHour.flatMap(QuotaWindowSnapshot.init(window:))
        let weekly = record.windowSet.weekly.flatMap(QuotaWindowSnapshot.init(window:))

        self.mainWindow = fiveHour ?? weekly
        self.weeklyWindow = fiveHour == nil ? nil : weekly
        self.lastUpdated = lastUpdated
        self.sourceName = sourceName
    }

    init(observation: QuotaObservation) {
        self.init(
            record: RateLimitRecord(
                timestamp: observation.observedAt,
                fileModifiedAt: observation.observedAt,
                windowSet: observation.windowSet
            ),
            sourceName: observation.sourceName,
            lastUpdated: observation.observedAt
        )
    }

    private init(
        mainWindow: QuotaWindowSnapshot?,
        weeklyWindow: QuotaWindowSnapshot?,
        lastUpdated: Date,
        sourceName: String
    ) {
        self.mainWindow = mainWindow
        self.weeklyWindow = weeklyWindow
        self.lastUpdated = lastUpdated
        self.sourceName = sourceName
    }

    var isUnavailable: Bool {
        mainWindow == nil
    }

    var remainingPercent: Int {
        mainWindow?.remainingPercent ?? 0
    }

    var weeklyRemainingPercent: Int {
        weeklyWindow?.remainingPercent ?? 0
    }

    var mainQuotaLabel: String {
        mainWindow?.kind.displayLabel ?? "额度未获取"
    }

    var mainQuotaSpokenName: String {
        mainWindow?.kind.spokenName ?? "Codex 额度"
    }

    var showsWeeklySecondary: Bool {
        mainWindow?.kind == .fiveHour && weeklyWindow != nil
    }

    var percentText: String {
        guard let mainWindow else { return "—" }
        return "\(mainWindow.remainingPercent)%"
    }

    var weeklyPercentText: String {
        guard let weeklyWindow else { return "—" }
        return "\(weeklyWindow.remainingPercent)%"
    }

    var displayRemainingPercent: Int {
        mainWindow?.remainingPercent ?? 0
    }

    var usedPercent: Int {
        100 - remainingPercent
    }

    var weeklyUsedPercent: Int {
        100 - weeklyRemainingPercent
    }

    static func cached() -> QuotaSnapshot? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: CacheKey.mainKind) != nil,
              defaults.object(forKey: CacheKey.mainRemainingPercent) != nil,
              defaults.object(forKey: CacheKey.mainResetDate) != nil,
              let mainKind = QuotaWindowKind(rawValue: defaults.integer(forKey: CacheKey.mainKind)) else {
            return nil
        }

        let mainWindow = QuotaWindowSnapshot(
            kind: mainKind,
            remainingPercent: defaults.integer(forKey: CacheKey.mainRemainingPercent),
            resetDate: Date(timeIntervalSince1970: defaults.double(forKey: CacheKey.mainResetDate))
        )
        let weeklyWindow: QuotaWindowSnapshot?
        if defaults.object(forKey: CacheKey.weeklyRemainingPercent) != nil,
           defaults.object(forKey: CacheKey.weeklyResetDate) != nil {
            weeklyWindow = QuotaWindowSnapshot(
                kind: .weekly,
                remainingPercent: defaults.integer(forKey: CacheKey.weeklyRemainingPercent),
                resetDate: Date(timeIntervalSince1970: defaults.double(forKey: CacheKey.weeklyResetDate))
            )
        } else {
            weeklyWindow = nil
        }

        return QuotaSnapshot(
            mainWindow: mainWindow,
            weeklyWindow: mainKind == .fiveHour ? weeklyWindow : nil,
            lastUpdated: Date(timeIntervalSince1970: defaults.double(forKey: CacheKey.lastUpdated)),
            sourceName: "本机缓存"
        )
    }

    func cache() {
        guard let mainWindow else { return }

        let defaults = UserDefaults.standard
        defaults.set(mainWindow.kind.rawValue, forKey: CacheKey.mainKind)
        defaults.set(mainWindow.remainingPercent, forKey: CacheKey.mainRemainingPercent)
        defaults.set(mainWindow.resetDate.timeIntervalSince1970, forKey: CacheKey.mainResetDate)
        defaults.set(lastUpdated.timeIntervalSince1970, forKey: CacheKey.lastUpdated)

        if let weeklyWindow {
            defaults.set(weeklyWindow.remainingPercent, forKey: CacheKey.weeklyRemainingPercent)
            defaults.set(weeklyWindow.resetDate.timeIntervalSince1970, forKey: CacheKey.weeklyResetDate)
        } else {
            defaults.removeObject(forKey: CacheKey.weeklyRemainingPercent)
            defaults.removeObject(forKey: CacheKey.weeklyResetDate)
        }
    }

    var tint: Color {
        guard let mainWindow else { return .secondary }
        return Self.tint(for: mainWindow.remainingPercent)
    }

    var tagBackgroundColor: NSColor {
        guard let mainWindow else { return NSColor(calibratedWhite: 1, alpha: 0.36) }
        return Self.tagBackgroundColor(for: mainWindow.remainingPercent)
    }

    var tagTextColor: NSColor {
        guard let mainWindow else { return .labelColor }
        return Self.tagTextColor(for: mainWindow.remainingPercent)
    }

    var weeklyTint: Color {
        Self.tint(for: weeklyWindow?.remainingPercent ?? 0)
    }

    private static func tint(for percent: Int) -> Color {
        switch percent {
        case 0...20:
            return .red
        case 21...45:
            return .yellow
        default:
            return .green
        }
    }

    private static func tagBackgroundColor(for percent: Int) -> NSColor {
        switch percent {
        case 0...20:
            return NSColor(calibratedRed: 1.0, green: 0.784, blue: 0.780, alpha: 0.92)
        case 21...45:
            return NSColor(calibratedRed: 0.973, green: 0.910, blue: 0.714, alpha: 0.92)
        default:
            return NSColor(calibratedRed: 0.722, green: 0.953, blue: 0.820, alpha: 0.92)
        }
    }

    private static func tagTextColor(for percent: Int) -> NSColor {
        switch percent {
        case 0...20:
            return NSColor(calibratedRed: 0.290, green: 0.071, blue: 0.075, alpha: 1)
        case 21...45:
            return NSColor(calibratedRed: 0.227, green: 0.176, blue: 0.043, alpha: 1)
        default:
            return NSColor(calibratedRed: 0.063, green: 0.247, blue: 0.157, alpha: 1)
        }
    }

    var resetText: String {
        guard let resetDate = mainWindow?.resetDate else { return "暂无重置信息" }
        return relativeResetText(for: resetDate)
    }

    var shortResetText: String {
        guard let resetDate = mainWindow?.resetDate else { return "—" }
        return compactResetText(for: resetDate)
    }

    var resetClockText: String {
        guard let resetDate = mainWindow?.resetDate else { return "未同步" }
        return resetDate.formatted(date: .omitted, time: .shortened)
    }

    var lastUpdatedText: String {
        guard !isUnavailable else { return "未同步" }
        return "更新于 \(lastUpdated.formatted(date: .omitted, time: .shortened))"
    }

    var weeklyResetDateText: String {
        guard let weeklyWindow else { return "—" }
        let dateText = weeklyWindow.resetDate.formatted(
            Date.FormatStyle()
                .month(.wide)
                .day(.defaultDigits)
                .locale(Locale(identifier: "zh_CN"))
        )
        return "\(dateText)恢复"
    }

    private func relativeResetText(for date: Date) -> String {
        let seconds = max(Int(date.timeIntervalSinceNow), 0)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return "\(days)天\(hours)小时后"
        }
        if hours > 0 {
            return "\(hours)小时\(minutes)分后"
        }
        return "\(minutes)分后"
    }

    private func compactResetText(for date: Date) -> String {
        let seconds = max(Int(date.timeIntervalSinceNow), 0)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return "\(days)d\(hours)h"
        }
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }

    static func unavailable() -> QuotaSnapshot {
        return QuotaSnapshot(
            mainWindow: nil,
            weeklyWindow: nil,
            lastUpdated: Date(),
            sourceName: "额度未获取"
        )
    }

}

private enum CacheKey {
    static let mainKind = "quota.main.kind"
    static let mainRemainingPercent = "quota.main.remainingPercent"
    static let mainResetDate = "quota.main.resetDate"
    static let weeklyRemainingPercent = "quota.weekly.remainingPercent"
    static let weeklyResetDate = "quota.weekly.resetDate"
    static let lastUpdated = "quota.lastUpdated"
    static let voiceBroadcastIntervalMinutes = "voiceBroadcast.intervalMinutes"
}
