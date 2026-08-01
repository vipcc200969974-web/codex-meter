import Foundation
import Combine
import XCTest
@testable import CodexMeter

@MainActor
final class UsageStoreTests: XCTestCase {
    func testRefreshRequestedDuringLoadRunsOneFollowUp() async throws {
        let loader = BlockingUsageLoader()
        let store = UsageStore(loader: loader, watcher: nil, debounceInterval: 0.01)
        store.refresh()
        await loader.waitUntilStarted()

        let prematureSecondStart = expectation(description: "second load must wait for first release")
        prematureSecondStart.isInverted = true
        loader.onPrematureSecondStart {
            prematureSecondStart.fulfill()
        }
        store.refresh()
        store.refresh()
        await fulfillment(of: [prematureSecondStart], timeout: 0.05)
        loader.onPrematureSecondStart(nil)

        XCTAssertEqual(loader.callCount, 1)
        XCTAssertEqual(loader.activeCallCount, 1)
        XCTAssertEqual(loader.maxConcurrentLoads, 1)

        loader.release()
        await loader.waitUntilCompleted(count: 2)

        XCTAssertEqual(loader.callCount, 2)
        XCTAssertEqual(loader.activeCallCount, 0)
        XCTAssertEqual(loader.maxConcurrentLoads, 1)
    }

    func testFailedQuotaReadKeepsPreviousValueAndMarksStale() async throws {
        let quota = QuotaSnapshot(
            record: RateLimitRecord(
                timestamp: Date(timeIntervalSince1970: 1_000),
                fileModifiedAt: Date(timeIntervalSince1970: 1_000),
                windowSet: RateLimitWindowSet(windows: [
                    RateLimitWindow(usedPercent: 39, resetsAt: 4_102_444_800, windowMinutes: 10_080)
                ], now: Date(timeIntervalSince1970: 1_000))
            ),
            sourceName: "测试",
            lastUpdated: Date(timeIntervalSince1970: 1_000)
        )
        let loader = SequenceUsageLoader(results: [
            UsageLoadResult(quota: quota, dailyTokens: .zero),
            UsageLoadResult(quota: nil, dailyTokens: nil)
        ])
        let store = UsageStore(loader: loader, watcher: nil, debounceInterval: 0.01)
        _ = await nextSnapshot(from: store) { store.refresh() }
        let failedSnapshot = await nextSnapshot(from: store) { store.refresh() }

        XCTAssertEqual(failedSnapshot.quota.remainingPercent, 61)
        XCTAssertEqual(failedSnapshot.freshness, .stale)
    }

    func testFailedTokenReadKeepsPreviousValueAndAppliesFreshQuota() async throws {
        let initialTokens = DailyTokenUsage(
            totalTokens: 42,
            cachedInputTokens: 10,
            nonCachedInputTokens: 12,
            outputTokens: 20,
            reasoningOutputTokens: 5,
            latestEventAt: Date(timeIntervalSince1970: 1_000)
        )
        let loader = SequenceUsageLoader(results: [
            UsageLoadResult(
                quota: makeQuota(remainingPercent: 20, sourceName: "old"),
                dailyTokens: initialTokens
            ),
            UsageLoadResult(
                quota: makeQuota(remainingPercent: 70, sourceName: "new"),
                dailyTokens: nil
            )
        ])
        let store = UsageStore(loader: loader, watcher: nil, debounceInterval: 0.01)

        _ = await nextSnapshot(from: store) { store.refresh() }
        let failedSnapshot = await nextSnapshot(from: store) { store.refresh() }

        XCTAssertEqual(failedSnapshot.quota.remainingPercent, 70)
        XCTAssertEqual(failedSnapshot.dailyTokens, initialTokens)
        XCTAssertEqual(failedSnapshot.freshness, .stale)
    }

    func testFreshnessReturnsToLiveAfterPartialAndTotalFailuresRecover() async {
        let firstTokens = makeTokens(total: 42)
        let secondTokens = makeTokens(total: 84)
        let recoveredTokens = makeTokens(total: 126)
        let loader = SequenceUsageLoader(results: [
            UsageLoadResult(
                quota: makeQuota(remainingPercent: 20, sourceName: "first"),
                dailyTokens: firstTokens
            ),
            UsageLoadResult(quota: nil, dailyTokens: secondTokens),
            UsageLoadResult(
                quota: makeQuota(remainingPercent: 70, sourceName: "partial"),
                dailyTokens: nil
            ),
            .empty,
            UsageLoadResult(
                quota: makeQuota(remainingPercent: 90, sourceName: "recovered"),
                dailyTokens: recoveredTokens
            )
        ])
        let store = UsageStore(loader: loader, watcher: nil)

        let first = await nextSnapshot(from: store) { store.refresh() }
        XCTAssertEqual(first.freshness, .live)

        let quotaFailure = await nextSnapshot(from: store) { store.refresh() }
        XCTAssertEqual(quotaFailure.quota.remainingPercent, 20)
        XCTAssertEqual(quotaFailure.dailyTokens, secondTokens)
        XCTAssertEqual(quotaFailure.freshness, .stale)

        let tokenFailure = await nextSnapshot(from: store) { store.refresh() }
        XCTAssertEqual(tokenFailure.quota.remainingPercent, 70)
        XCTAssertEqual(tokenFailure.dailyTokens, secondTokens)
        XCTAssertEqual(tokenFailure.freshness, .stale)

        let totalFailure = await nextSnapshot(from: store) { store.refresh() }
        XCTAssertEqual(totalFailure.quota.remainingPercent, 70)
        XCTAssertEqual(totalFailure.dailyTokens, secondTokens)
        XCTAssertEqual(totalFailure.freshness, .stale)

        let recovered = await nextSnapshot(from: store) { store.refresh() }
        XCTAssertEqual(recovered.quota.remainingPercent, 90)
        XCTAssertEqual(recovered.dailyTokens, recoveredTokens)
        XCTAssertEqual(recovered.freshness, .live)
    }

    func testWatcherBurstDebouncesToOneLoad() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(
            loader: loader,
            watcher: nil,
            debounceInterval: 0.02,
            scheduler: scheduler
        )

        store.scheduleRefresh()
        store.scheduleRefresh()
        store.scheduleRefresh()
        _ = await nextSnapshot(from: store) {
            scheduler.advance(by: 0.02)
        }

        XCTAssertEqual(loader.callCount, 1)
    }

    func testWakeRebindsWatcherAndRefreshesImmediately() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let store = UsageStore(loader: loader, watcher: watcher, debounceInterval: 0.8)

        _ = await nextSnapshot(from: store) {
            store.refreshAfterWakeOrUnlock()
        }

        XCTAssertEqual(watcher.rebindCount, 1)
        XCTAssertEqual(loader.callCount, 1)
    }

    func testDefaultWatcherDebounceWaitsExactlyEightHundredMilliseconds() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: nil, scheduler: scheduler)

        store.scheduleRefresh()
        scheduler.advance(by: 0.799)
        XCTAssertEqual(loader.callCount, 0)

        _ = await nextSnapshot(from: store) {
            scheduler.advance(by: 0.001)
        }
        XCTAssertEqual(loader.callCount, 1)
    }

    func testFallbackPollRebindsWatcherAndRefreshesEverySixtySeconds() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: watcher, scheduler: scheduler)

        _ = await nextSnapshot(from: store) { store.start() }
        XCTAssertEqual(loader.callCount, 1)

        scheduler.advance(by: 59.999)
        XCTAssertEqual(watcher.rebindCount, 0)
        XCTAssertEqual(loader.callCount, 1)

        _ = await nextSnapshot(from: store) {
            scheduler.advance(by: 0.001)
        }
        XCTAssertEqual(watcher.rebindCount, 1)
        XCTAssertEqual(loader.callCount, 2)

        _ = await nextSnapshot(from: store) {
            scheduler.advance(by: 60)
        }
        XCTAssertEqual(watcher.rebindCount, 2)
        XCTAssertEqual(loader.callCount, 3)
    }

    func testNextLocalMidnightRefreshResetsTokensWithoutFileActivity() async throws {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let beforeMidnight = try XCTUnwrap(shanghai.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 1,
            hour: 23,
            minute: 59,
            second: 30
        )))
        let midnight = try XCTUnwrap(shanghai.date(byAdding: .second, value: 30, to: beforeMidnight))
        let clock = LockedDateSource(beforeMidnight)
        let scheduler = ManualUsageScheduler()
        let initialTokens = DailyTokenUsage(
            totalTokens: 42,
            cachedInputTokens: 10,
            nonCachedInputTokens: 12,
            outputTokens: 20,
            reasoningOutputTokens: 5,
            latestEventAt: beforeMidnight
        )
        let loader = SequenceUsageLoader(results: [
            UsageLoadResult(quota: nil, dailyTokens: initialTokens),
            UsageLoadResult(quota: nil, dailyTokens: .zero)
        ])
        let store = UsageStore(
            loader: loader,
            watcher: SpyActivityWatcher(),
            scheduler: scheduler,
            calendar: shanghai,
            now: clock.now
        )

        let initial = await nextSnapshot(from: store) { store.start() }
        XCTAssertEqual(initial.dailyTokens.totalTokens, 42)

        scheduler.advance(by: 29.999)
        XCTAssertEqual(store.snapshot.dailyTokens.totalTokens, 42)

        clock.set(midnight)
        let reset = await nextSnapshot(from: store) {
            scheduler.advance(by: 0.001)
        }
        XCTAssertEqual(reset.dailyTokens, .zero)
    }

    func testRepeatedStartDoesNotDuplicateWatcherOrImmediateRefresh() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: watcher, scheduler: scheduler)

        _ = await nextSnapshot(from: store) { store.start() }
        store.start()

        XCTAssertEqual(watcher.startCount, 1)
        XCTAssertEqual(loader.callCount, 1)
    }

    func testCompletionFromBeforeStopCannotPublishAfterRestart() async throws {
        let oldQuota = makeQuota(remainingPercent: 20, sourceName: "old")
        let newQuota = makeQuota(remainingPercent: 70, sourceName: "new")
        let loader = RestartUsageLoader(results: [
            UsageLoadResult(quota: oldQuota, dailyTokens: .zero),
            UsageLoadResult(quota: newQuota, dailyTokens: .zero)
        ])
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(
            loader: loader,
            watcher: SpyActivityWatcher(),
            scheduler: scheduler
        )
        var publishedSources: [String] = []
        let cancellable = store.$snapshot.dropFirst().sink {
            publishedSources.append($0.quota.sourceName)
        }

        store.start()
        await loader.waitUntilFirstStarted()
        store.stop()
        store.start()
        let restartedSnapshot = await nextSnapshot(from: store) {
            loader.releaseFirst()
        }

        XCTAssertEqual(loader.callCount, 2)
        XCTAssertEqual(restartedSnapshot.quota.remainingPercent, 70)
        XCTAssertEqual(publishedSources, ["new"])
        withExtendedLifetime(cancellable) {}
    }

    func testStoppedSchedulerCallbacksCannotAffectRestartedStore() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: watcher, scheduler: scheduler)

        _ = await nextSnapshot(from: store) { store.start() }
        store.scheduleRefresh()
        let oldTasks = scheduler.tasks
        store.stop()
        _ = await nextSnapshot(from: store) { store.start() }

        for task in oldTasks {
            task.fireEvenIfCancelled()
        }

        XCTAssertEqual(loader.callCount, 2)
        XCTAssertEqual(watcher.rebindCount, 0)
    }

    func testDeinitStopsWatcherAndCancelsScheduledTasks() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let scheduler = ManualUsageScheduler()
        weak var weakStore: UsageStore?

        do {
            var store: UsageStore? = UsageStore(
                loader: loader,
                watcher: watcher,
                scheduler: scheduler
            )
            weakStore = store
            _ = await nextSnapshot(from: try XCTUnwrap(store)) {
                store?.start()
            }
            store = nil
        }

        XCTAssertNil(weakStore)
        XCTAssertEqual(watcher.stopCount, 1)
        XCTAssertTrue(scheduler.tasks.allSatisfy(\.isCancelled))
    }

    func testStopIsIdempotentAndDeinitDoesNotStopWatcherAgain() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let scheduler = ManualUsageScheduler()
        var store: UsageStore? = UsageStore(
            loader: loader,
            watcher: watcher,
            scheduler: scheduler
        )

        _ = await nextSnapshot(from: try XCTUnwrap(store)) {
            store?.start()
        }
        store?.stop()
        store?.stop()
        store = nil

        XCTAssertEqual(watcher.stopCount, 1)
    }

    func testCancelledDebounceCallbackCannotRefreshWithinSameLifecycle() async {
        let loader = CountingUsageLoader(result: .empty)
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: nil, scheduler: scheduler)

        store.scheduleRefresh()
        let cancelledTask = scheduler.tasks.last!
        store.scheduleRefresh()
        cancelledTask.fireEvenIfCancelled()

        XCTAssertEqual(loader.callCount, 0)
        _ = await nextSnapshot(from: store) {
            scheduler.advance(by: 0.8)
        }
        XCTAssertEqual(loader.callCount, 1)
    }

    func testBackgroundWatcherSignalUsesProductionAsyncMainHop() async {
        let loader = CountingUsageLoader(result: .empty)
        let scheduler = ManualUsageScheduler()
        let watcher = CallbackActivityWatcher()
        let store = UsageStore(
            loader: loader,
            watcher: nil,
            scheduler: scheduler,
            watcherFactory: { onChange in
                watcher.setOnChange(onChange)
                return watcher
            }
        )

        _ = await nextSnapshot(from: store) { store.start() }
        XCTAssertEqual(loader.callCount, 1)

        await watcher.emitFromBackground()
        await scheduler.waitUntilTaskCount(3)
        XCTAssertTrue(watcher.lastEmissionWasOffMain)
        XCTAssertEqual(loader.callCount, 1)

        _ = await nextSnapshot(from: store) {
            scheduler.advance(by: 0.8)
        }
        XCTAssertEqual(loader.callCount, 2)
    }
}

final class BlockingUsageLoader: UsageLoading, @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var activeCalls = 0
    private var maximumActiveCalls = 0
    private var completedCalls = 0
    private var started = false
    private var released = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var completionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var prematureSecondStart: (@Sendable () -> Void)?

    var callCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return calls
    }

    var activeCallCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return activeCalls
    }

    var maxConcurrentLoads: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveCalls
    }

    func load(now: Date) -> UsageLoadResult {
        condition.lock()
        calls += 1
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        let isFirstCall = calls == 1
        let prematureSecondStart = calls > 1 && !released ? prematureSecondStart : nil
        if prematureSecondStart != nil {
            self.prematureSecondStart = nil
        }
        if !started {
            started = true
            let continuation = startedContinuation
            startedContinuation = nil
            condition.unlock()
            continuation?.resume()
            condition.lock()
        }
        if !isFirstCall {
            condition.unlock()
            prematureSecondStart?()
            condition.lock()
        }
        while !released {
            condition.wait()
        }
        activeCalls -= 1
        completedCalls += 1
        let readyWaiters = completionWaiters.filter { $0.count <= completedCalls }
        completionWaiters.removeAll { $0.count <= completedCalls }
        condition.unlock()
        readyWaiters.forEach { $0.continuation.resume() }
        return .empty
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if started {
                condition.unlock()
                continuation.resume()
            } else {
                startedContinuation = continuation
                condition.unlock()
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func onPrematureSecondStart(_ action: (@Sendable () -> Void)?) {
        condition.lock()
        prematureSecondStart = action
        condition.unlock()
    }

    func waitUntilCompleted(count: Int) async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if completedCalls >= count {
                condition.unlock()
                continuation.resume()
            } else {
                completionWaiters.append((count, continuation))
                condition.unlock()
            }
        }
    }
}

final class SequenceUsageLoader: UsageLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [UsageLoadResult]

    init(results: [UsageLoadResult]) {
        self.results = results
    }

    func load(now: Date) -> UsageLoadResult {
        lock.lock()
        defer { lock.unlock() }
        return results.isEmpty ? .empty : results.removeFirst()
    }
}

final class RestartUsageLoader: UsageLoading, @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var firstStarted = false
    private var firstReleased = false
    private var firstStartedContinuation: CheckedContinuation<Void, Never>?
    private let results: [UsageLoadResult]

    init(results: [UsageLoadResult]) {
        self.results = results
    }

    var callCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return calls
    }

    func load(now: Date) -> UsageLoadResult {
        condition.lock()
        calls += 1
        let call = calls
        if call == 1 {
            firstStarted = true
            let continuation = firstStartedContinuation
            firstStartedContinuation = nil
            condition.unlock()
            continuation?.resume()
            condition.lock()
            while !firstReleased {
                condition.wait()
            }
        }
        condition.unlock()
        return results[call - 1]
    }

    func waitUntilFirstStarted() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if firstStarted {
                condition.unlock()
                continuation.resume()
            } else {
                firstStartedContinuation = continuation
                condition.unlock()
            }
        }
    }

    func releaseFirst() {
        condition.lock()
        firstReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

final class CountingUsageLoader: UsageLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let result: UsageLoadResult

    init(result: UsageLoadResult) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func load(now: Date) -> UsageLoadResult {
        lock.lock()
        calls += 1
        lock.unlock()
        return result
    }
}

final class SpyActivityWatcher: CodexActivityWatching {
    private(set) var startCount = 0
    private(set) var rebindCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func rebind() { rebindCount += 1 }
    func stop() { stopCount += 1 }
}

final class CallbackActivityWatcher: CodexActivityWatching, @unchecked Sendable {
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "com.codexmeter.tests.callback-watcher")
    private var onChange: (() -> Void)?
    private var emittedOffMain = false

    var lastEmissionWasOffMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return emittedOffMain
    }

    func setOnChange(_ onChange: @escaping () -> Void) {
        lock.lock()
        self.onChange = onChange
        lock.unlock()
    }

    func emitFromBackground() async {
        await withCheckedContinuation { continuation in
            callbackQueue.async { [self] in
                lock.lock()
                emittedOffMain = !Thread.isMainThread
                let onChange = onChange
                lock.unlock()
                onChange?()
                continuation.resume()
            }
        }
    }

    func start() {}
    func rebind() {}
    func stop() {}
}

final class LockedDateSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

@MainActor
final class ManualUsageScheduler: UsageScheduling {
    final class ScheduledTask: UsageScheduledTask, @unchecked Sendable {
        private let lock = NSLock()
        let action: @MainActor () -> Void
        let repeatingInterval: TimeInterval?
        var nextFireTime: TimeInterval
        private var cancelled = false

        init(
            nextFireTime: TimeInterval,
            repeatingInterval: TimeInterval?,
            action: @escaping @MainActor () -> Void
        ) {
            self.nextFireTime = nextFireTime
            self.repeatingInterval = repeatingInterval
            self.action = action
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        @MainActor
        func fireEvenIfCancelled() {
            action()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private var elapsed: TimeInterval = 0
    private(set) var tasks: [ScheduledTask] = []
    private var taskCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        action: @escaping @MainActor () -> Void
    ) -> any UsageScheduledTask {
        let task = ScheduledTask(
            nextFireTime: elapsed + delay,
            repeatingInterval: interval,
            action: action
        )
        tasks.append(task)
        let readyWaiters = taskCountWaiters.filter { $0.count <= tasks.count }
        taskCountWaiters.removeAll { $0.count <= tasks.count }
        readyWaiters.forEach { $0.continuation.resume() }
        return task
    }

    func waitUntilTaskCount(_ count: Int) async {
        if tasks.count >= count { return }
        await withCheckedContinuation { continuation in
            taskCountWaiters.append((count, continuation))
        }
    }

    func advance(by interval: TimeInterval) {
        elapsed += interval
        var shouldContinue = true
        while shouldContinue {
            shouldContinue = false
            for task in tasks where !task.isCancelled && task.nextFireTime <= elapsed {
                if let repeatingInterval = task.repeatingInterval {
                    task.nextFireTime += repeatingInterval
                } else {
                    task.cancel()
                }
                task.action()
                shouldContinue = true
            }
        }
    }
}

@MainActor
private func nextSnapshot(
    from store: UsageStore,
    after action: () -> Void
) async -> UsageSnapshot {
    await withCheckedContinuation { continuation in
        var cancellable: AnyCancellable?
        cancellable = store.$snapshot.dropFirst().prefix(1).sink { snapshot in
            continuation.resume(returning: snapshot)
            cancellable?.cancel()
        }
        action()
    }
}

private func makeTokens(total: Int64) -> DailyTokenUsage {
    DailyTokenUsage(
        totalTokens: total,
        cachedInputTokens: total / 4,
        nonCachedInputTokens: total / 4,
        outputTokens: total / 2,
        reasoningOutputTokens: total / 8,
        latestEventAt: Date(timeIntervalSince1970: TimeInterval(total))
    )
}

private func makeQuota(remainingPercent: Int, sourceName: String) -> QuotaSnapshot {
    let now = Date(timeIntervalSince1970: 1_000)
    return QuotaSnapshot(
        record: RateLimitRecord(
            timestamp: now,
            fileModifiedAt: now,
            windowSet: RateLimitWindowSet(windows: [
                RateLimitWindow(
                    usedPercent: Double(100 - remainingPercent),
                    resetsAt: 4_102_444_800,
                    windowMinutes: 10_080
                )
            ], now: now)
        ),
        sourceName: sourceName,
        lastUpdated: now
    )
}
