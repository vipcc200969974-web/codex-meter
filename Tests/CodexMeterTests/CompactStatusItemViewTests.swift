import AppKit
import XCTest
@testable import CodexMeter

@MainActor
final class CompactStatusItemViewTests: XCTestCase {
    func testLayoutAddsDividerRingAndApprovedSpacing() {
        let layout = CompactStatusItemLayout(textWidth: 100, statusHeight: 24)

        XCTAssertEqual(layout.textFrame.minX, 5)
        XCTAssertEqual(layout.textFrame.maxX + 5, layout.dividerFrame.minX)
        XCTAssertEqual(layout.dividerFrame.height, 9)
        XCTAssertEqual(layout.dividerFrame.midY, 12)
        XCTAssertEqual(layout.ringFrame.width, 12.5)
        XCTAssertEqual(layout.ringFrame.height, 12.5)
        XCTAssertEqual(layout.ringFrame.midY, 12)
        XCTAssertEqual(layout.dividerFrame.maxX + 5, layout.ringFrame.minX)
        XCTAssertEqual(layout.ringFrame.maxX + 6, layout.totalWidth)
    }

    func testIdleLaunchKeepsTopFacingRingWithoutTimer() {
        let factory = SpyStatusAnimationFactory()
        let view = CompactStatusItemView(animationFactory: factory.make)

        view.update(
            title: "64% | 6d0h",
            color: .labelColor,
            backgroundColor: .systemGreen,
            tooltip: "test",
            isTaskActive: false
        )

        XCTAssertEqual(view.ringAngleDegrees, 90)
        XCTAssertEqual(factory.createdCount, 0)
        XCTAssertEqual(factory.cancelledCount, 0)
    }

    func testActiveUpdatesStartOneTwelveFPSAnimationAndIdleStopsIt() {
        let factory = SpyStatusAnimationFactory()
        let view = CompactStatusItemView(animationFactory: factory.make)

        update(view, isTaskActive: true)
        update(view, isTaskActive: true)

        XCTAssertEqual(factory.createdCount, 1)
        XCTAssertEqual(factory.intervals, [1.0 / 12.0])

        update(view, isTaskActive: false)
        update(view, isTaskActive: false)

        XCTAssertEqual(factory.cancelledCount, 1)
    }

    func testTickAdvancesThirtyDegreesAndStoppedViewIgnoresLateTick() {
        let factory = SpyStatusAnimationFactory()
        let view = CompactStatusItemView(animationFactory: factory.make)
        update(view, isTaskActive: true)

        factory.fireLast()

        XCTAssertEqual(view.ringAngleDegrees, 120)

        update(view, isTaskActive: false)
        factory.fireLast()

        XCTAssertEqual(view.ringAngleDegrees, 120)
    }

    func testDeinitCancelsActiveAnimation() {
        let factory = SpyStatusAnimationFactory()
        weak var releasedView: CompactStatusItemView?
        autoreleasepool {
            let view = CompactStatusItemView(animationFactory: factory.make)
            releasedView = view
            update(view, isTaskActive: true)
        }

        XCTAssertNil(releasedView)
        XCTAssertEqual(factory.cancelledCount, 1)
    }

    func testUpdateExpandsWholeClickableTagToRingTrailingEdge() {
        let view = CompactStatusItemView(animationFactory: SpyStatusAnimationFactory().make)
        update(view, isTaskActive: false)
        let titleWidth = ceil(
            NSAttributedString(
                string: "64% | 6d0h",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .kern: -0.2
                ]
            ).size().width
        )
        let expected = CompactStatusItemLayout(
            textWidth: titleWidth,
            statusHeight: NSStatusBar.system.thickness
        )
        var clickCount = 0
        view.onClick = { clickCount += 1 }

        view.mouseDown(with: mouseEvent(type: .leftMouseDown, location: view.bounds.center))
        view.rightMouseDown(with: mouseEvent(type: .rightMouseDown, location: view.bounds.center))

        XCTAssertEqual(view.frame.width, expected.totalWidth)
        XCTAssertEqual(clickCount, 2)
    }

    func testTooltipAndAccessibilityExposeActiveAndIdleState() {
        let view = CompactStatusItemView(animationFactory: SpyStatusAnimationFactory().make)

        update(view, isTaskActive: true)
        XCTAssertEqual(view.toolTip, "test\nChatGPT 正在执行任务")
        XCTAssertEqual(view.accessibilityLabel(), "64% | 6d0h，ChatGPT 正在执行任务")

        update(view, isTaskActive: false)
        XCTAssertEqual(view.toolTip, "test\n当前无运行任务")
        XCTAssertEqual(view.accessibilityLabel(), "64% | 6d0h，当前无运行任务")
    }

    private func update(_ view: CompactStatusItemView, isTaskActive: Bool) {
        view.update(
            title: "64% | 6d0h",
            color: .labelColor,
            backgroundColor: .systemGreen,
            tooltip: "test",
            isTaskActive: isTaskActive
        )
    }

    private func mouseEvent(type: NSEvent.EventType, location: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

private final class SpyStatusAnimationTask: StatusItemAnimationTask {
    private let tick: @MainActor () -> Void
    private let didCancel: () -> Void
    private var isCancelled = false

    init(tick: @escaping @MainActor () -> Void, didCancel: @escaping () -> Void) {
        self.tick = tick
        self.didCancel = didCancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        didCancel()
    }

    @MainActor
    func fireEvenIfCancelled() {
        tick()
    }
}

private final class SpyStatusAnimationFactory {
    private(set) var intervals: [TimeInterval] = []
    private(set) var createdCount = 0
    private(set) var cancelledCount = 0
    private var tasks: [SpyStatusAnimationTask] = []

    func make(
        interval: TimeInterval,
        tick: @escaping @MainActor () -> Void
    ) -> any StatusItemAnimationTask {
        intervals.append(interval)
        createdCount += 1
        let task = SpyStatusAnimationTask(tick: tick) { [weak self] in
            self?.cancelledCount += 1
        }
        tasks.append(task)
        return task
    }

    @MainActor
    func fireLast() {
        tasks.last?.fireEvenIfCancelled()
    }
}
