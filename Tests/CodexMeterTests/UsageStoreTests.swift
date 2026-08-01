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
        store.refresh()
        store.refresh()
        loader.release()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(loader.callCount, 2)
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
        store.refresh()
        try await Task.sleep(for: .milliseconds(80))
        store.refresh()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(store.snapshot.quota.remainingPercent, 61)
        XCTAssertEqual(store.snapshot.freshness, .stale)
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

        store.refresh()
        try await Task.sleep(for: .milliseconds(80))
        store.refresh()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(store.snapshot.quota.remainingPercent, 70)
        XCTAssertEqual(store.snapshot.dailyTokens, initialTokens)
        XCTAssertEqual(store.snapshot.freshness, .stale)
    }

    func testWatcherBurstDebouncesToOneLoad() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let store = UsageStore(loader: loader, watcher: nil, debounceInterval: 0.02)

        store.scheduleRefresh()
        store.scheduleRefresh()
        store.scheduleRefresh()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(loader.callCount, 1)
    }

    func testWakeRebindsWatcherAndRefreshesImmediately() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let store = UsageStore(loader: loader, watcher: watcher, debounceInterval: 0.8)

        store.refreshAfterWakeOrUnlock()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(watcher.rebindCount, 1)
        XCTAssertEqual(loader.callCount, 1)
    }

    func testDefaultWatcherDebounceWaitsExactlyEightHundredMilliseconds() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: nil, scheduler: scheduler)

        store.scheduleRefresh()
        scheduler.advance(by: 0.799)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(loader.callCount, 0)

        scheduler.advance(by: 0.001)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(loader.callCount, 1)
    }

    func testFallbackPollRebindsWatcherAndRefreshesEverySixtySeconds() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: watcher, scheduler: scheduler)

        store.start()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(loader.callCount, 1)

        scheduler.advance(by: 59.999)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(watcher.rebindCount, 0)
        XCTAssertEqual(loader.callCount, 1)

        scheduler.advance(by: 0.001)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(watcher.rebindCount, 1)
        XCTAssertEqual(loader.callCount, 2)
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

        store.start()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(store.snapshot.dailyTokens.totalTokens, 42)

        scheduler.advance(by: 29.999)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.snapshot.dailyTokens.totalTokens, 42)

        clock.set(midnight)
        scheduler.advance(by: 0.001)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(store.snapshot.dailyTokens, .zero)
    }

    func testRepeatedStartDoesNotDuplicateWatcherOrImmediateRefresh() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: watcher, scheduler: scheduler)

        store.start()
        try await Task.sleep(for: .milliseconds(80))
        store.start()
        try await Task.sleep(for: .milliseconds(80))

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
        loader.releaseFirst()
        try await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(loader.callCount, 2)
        XCTAssertEqual(store.snapshot.quota.remainingPercent, 70)
        XCTAssertEqual(publishedSources, ["new"])
        withExtendedLifetime(cancellable) {}
    }

    func testStoppedSchedulerCallbacksCannotAffectRestartedStore() async throws {
        let loader = CountingUsageLoader(result: .empty)
        let watcher = SpyActivityWatcher()
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: watcher, scheduler: scheduler)

        store.start()
        store.scheduleRefresh()
        try await Task.sleep(for: .milliseconds(80))
        let oldTasks = scheduler.tasks
        store.stop()
        store.start()
        try await Task.sleep(for: .milliseconds(80))

        for task in oldTasks {
            task.fireEvenIfCancelled()
        }
        try await Task.sleep(for: .milliseconds(80))

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
            store?.start()
            try await Task.sleep(for: .milliseconds(80))
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

        store?.start()
        try await Task.sleep(for: .milliseconds(80))
        store?.stop()
        store?.stop()
        store = nil

        XCTAssertEqual(watcher.stopCount, 1)
    }
}

final class BlockingUsageLoader: UsageLoading, @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var started = false
    private var released = false
    private var startedContinuation: CheckedContinuation<Void, Never>?

    var callCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return calls
    }

    func load(now: Date) -> UsageLoadResult {
        condition.lock()
        calls += 1
        if !started {
            started = true
            let continuation = startedContinuation
            startedContinuation = nil
            condition.unlock()
            continuation?.resume()
            condition.lock()
        }
        while !released {
            condition.wait()
        }
        condition.unlock()
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
        return task
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
