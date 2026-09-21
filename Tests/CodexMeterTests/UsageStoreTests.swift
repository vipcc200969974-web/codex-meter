import Foundation
import Combine
import XCTest
@testable import CodexMeter

@MainActor
final class UsageStoreTests: XCTestCase {
    func testLocalLoaderReturnsActivityAlongsideTokens() {
        let tokens = makeTokens(total: 42)
        let loader = LocalUsageLoader(
            quotaProvider: CompositeQuotaProvider(providers: []),
            tokenProvider: StubDailyTokenUsageProvider(usage: tokens),
            taskActivityProvider: StubTaskActivityProvider(activity: true)
        )

        let result = loader.load(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result.dailyTokens, tokens)
        XCTAssertEqual(result.isTaskActive, true)
    }

    func testLocalLoaderMapsActivityFailureToNilWithoutAffectingTokens() {
        let tokens = makeTokens(total: 42)
        let loader = LocalUsageLoader(
            quotaProvider: CompositeQuotaProvider(providers: []),
            tokenProvider: StubDailyTokenUsageProvider(usage: tokens),
            taskActivityProvider: StubTaskActivityProvider(error: StubProviderError.failed)
        )

        let result = loader.load(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result.dailyTokens, tokens)
        XCTAssertNil(result.isTaskActive)
    }

    func testStartPublishesActivityWhileFullUsageLoadIsBlocked() async {
        let loader = BlockingUsageAndActivityLoader(activity: true)
        let store = UsageStore(loader: loader, watcher: SpyActivityWatcher())
        let active = expectation(description: "activity published before full load")
        let subscription = store.$isTaskActive.dropFirst().sink { value in
            if value { active.fulfill() }
        }
        defer {
            loader.releaseUsage()
            store.stop()
            subscription.cancel()
        }

        store.start()
        await loader.waitUntilUsageStarted()
        await fulfillment(of: [active], timeout: 1)

        XCTAssertTrue(store.isTaskActive)
    }

    func testIndependentActivityLoadCannotBeOverwrittenByFullUsageLoad() async {
        let loader = ActivityWinsUsageLoader()
        let store = UsageStore(loader: loader, watcher: SpyActivityWatcher())
        let active = expectation(description: "activity published before full load")
        let subscription = store.$isTaskActive.dropFirst().sink { value in
            if value { active.fulfill() }
        }
        defer {
            loader.releaseUsage()
            store.stop()
            subscription.cancel()
        }

        store.start()
        await loader.waitUntilUsageStarted()
        await fulfillment(of: [active], timeout: 1)
        _ = await nextSnapshot(from: store) {
            loader.releaseUsage()
        }

        XCTAssertTrue(store.isTaskActive)
    }

    func testWatcherPublishesActivityWhileFullUsageLoadIsBlocked() async {
        let loader = BlockingUsageAndActivityLoader(activity: false)
        let watcher = CallbackActivityWatcher()
        let store = UsageStore(
            loader: loader,
            watcher: nil,
            debounceInterval: 0.01,
            watcherFactory: { onChange in
                watcher.setOnChange(onChange)
                return watcher
            }
        )
        let active = expectation(description: "watcher activity published before full load")
        let subscription = store.$isTaskActive.dropFirst().sink { value in
            if value { active.fulfill() }
        }
        defer {
            loader.releaseUsage()
            store.stop()
            subscription.cancel()
        }

        store.start()
        await loader.waitUntilUsageStarted()
        await loader.waitUntilActivityLoaded(count: 1)
        loader.setActivity(true)
        await watcher.emitFromBackground()
        await fulfillment(of: [active], timeout: 1)

        XCTAssertTrue(store.isTaskActive)
        XCTAssertGreaterThanOrEqual(loader.activityCallCount, 2)
    }

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

    func testRefreshPublishesRefreshingUntilLoadCompletes() async {
        let loader = BlockingUsageLoader()
        let store = UsageStore(loader: loader, watcher: nil)

        store.refresh()
        await loader.waitUntilStarted()
        XCTAssertTrue(store.isRefreshing)

        loader.release()
        await loader.waitUntilCompleted(count: 1)
        XCTAssertFalse(store.isRefreshing)
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

    func testOlderQuotaResultCannotReplaceNewerPublishedSnapshot() async {
        let newerTime = Date(timeIntervalSince1970: 1_200)
        let olderTime = Date(timeIntervalSince1970: 1_100)
        let newerCachedQuota = makeQuota(
            remainingPercent: 54,
            sourceName: "本机缓存",
            lastUpdated: newerTime
        )
        let loader = SequenceUsageLoader(results: [
            UsageLoadResult(
                quota: makeQuota(
                    remainingPercent: 64,
                    sourceName: "Codex 日志",
                    lastUpdated: olderTime
                ),
                dailyTokens: .zero
            )
        ])
        let store = UsageStore(
            cachedQuota: newerCachedQuota,
            loader: loader,
            watcher: nil
        )

        let afterOlderRefresh = await nextSnapshot(from: store) { store.refresh() }

        XCTAssertEqual(afterOlderRefresh.quota.remainingPercent, 54)
        XCTAssertEqual(afterOlderRefresh.quota.lastUpdated, newerTime)
        XCTAssertEqual(afterOlderRefresh.freshness, .stale)
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

    func testSuccessfulActivityLoadPublishesIndependentState() async {
        let loader = SequenceUsageLoader(results: [
            UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: true),
            UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: false)
        ])
        let store = UsageStore(loader: loader, watcher: SpyActivityWatcher())

        await nextTaskActivity(from: store) { store.refresh() }
        XCTAssertTrue(store.isTaskActive)
        await nextTaskActivity(from: store) { store.refresh() }
        XCTAssertFalse(store.isTaskActive)
    }

    func testActivityFailureRetainsForSixtySecondsThenFailsIdle() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = LockedDateSource(start)
        let loader = SequenceUsageLoader(results: [
            UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: true),
            UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: nil),
            UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: nil)
        ])
        let store = UsageStore(loader: loader, watcher: SpyActivityWatcher(), now: clock.now)

        await nextTaskActivity(from: store) { store.refresh() }
        clock.set(start.addingTimeInterval(59.999))
        _ = await nextSnapshot(from: store) { store.refresh() }
        XCTAssertTrue(store.isTaskActive)
        clock.set(start.addingTimeInterval(60))
        await nextTaskActivity(from: store) { store.refresh() }
        XCTAssertFalse(store.isTaskActive)
    }

    func testActivityFailureDoesNotChangeQuotaTokenFreshness() async {
        let loader = SequenceUsageLoader(results: [
            UsageLoadResult(
                quota: makeQuota(remainingPercent: 70, sourceName: "fresh"),
                dailyTokens: makeTokens(total: 42),
                isTaskActive: nil
            )
        ])
        let store = UsageStore(loader: loader, watcher: SpyActivityWatcher())

        let snapshot = await nextSnapshot(from: store) { store.refresh() }

        XCTAssertEqual(snapshot.freshness, .live)
        XCTAssertFalse(store.isTaskActive)
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
        let loader = CountingUsageLoader(result: UsageLoadResult(
            quota: nil,
            dailyTokens: nil,
            isTaskActive: true
        ))
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: nil, scheduler: scheduler)

        store.scheduleRefresh()
        scheduler.advance(by: 0.799)
        XCTAssertEqual(loader.callCount, 0)

        _ = await nextSnapshot(from: store) {
            scheduler.advance(by: 0.001)
        }
        XCTAssertEqual(loader.callCount, 1)
        XCTAssertTrue(store.isTaskActive)
    }

    func testFallbackPollRebindsWatcherAndRefreshesEverySixtySeconds() async throws {
        let loader = SequenceUsageLoader(results: [
            UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: true),
            UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: false),
            UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: true)
        ])
        let watcher = SpyActivityWatcher()
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(loader: loader, watcher: watcher, scheduler: scheduler)

        await nextTaskActivity(from: store) { store.start() }
        XCTAssertEqual(loader.callCount, 1)
        XCTAssertTrue(store.isTaskActive)

        scheduler.advance(by: 59.999)
        XCTAssertEqual(watcher.rebindCount, 0)
        XCTAssertEqual(loader.callCount, 1)

        await nextTaskActivity(from: store) {
            scheduler.advance(by: 0.001)
        }
        XCTAssertEqual(watcher.rebindCount, 1)
        XCTAssertEqual(loader.callCount, 2)
        XCTAssertFalse(store.isTaskActive)

        await nextTaskActivity(from: store) {
            scheduler.advance(by: 60)
        }
        XCTAssertEqual(watcher.rebindCount, 2)
        XCTAssertEqual(loader.callCount, 3)
        XCTAssertTrue(store.isTaskActive)
    }

    func testActivityPollFindsTaskWhenFilesystemEventIsMissed() async {
        let loader = MutableActivityUsageLoader(activity: false)
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(
            loader: loader,
            watcher: SpyActivityWatcher(),
            activityPollInterval: 5,
            scheduler: scheduler
        )
        let active = expectation(description: "activity poll published active state")
        let subscription = store.$isTaskActive.dropFirst().sink { value in
            if value { active.fulfill() }
        }
        defer {
            store.stop()
            subscription.cancel()
        }

        store.start()
        await loader.waitUntilActivityLoaded(count: 1)
        loader.setActivity(true)
        scheduler.advance(by: 5)

        await fulfillment(of: [active], timeout: 1)
        XCTAssertTrue(store.isTaskActive)
    }

    func testMidnightFailurePublishesNewDayZeroAndRetainsQuota() async throws {
        let (shanghai, beforeMidnight, midnight) = try makeShanghaiDayBoundary()
        let clock = LockedDateSource(beforeMidnight)
        let scheduler = ManualUsageScheduler()
        let quota = makeQuota(remainingPercent: 61, sourceName: "yesterday")
        let loader = ControlledUsageLoader(
            results: [
                UsageLoadResult(quota: quota, dailyTokens: makeTokens(total: 42)),
                .empty
            ],
            blockedCalls: [2]
        )
        let store = UsageStore(
            loader: loader,
            watcher: SpyActivityWatcher(),
            scheduler: scheduler,
            calendar: shanghai,
            now: clock.now
        )

        let initial = await nextSnapshot(from: store) { store.start() }
        XCTAssertEqual(initial.dailyTokens.totalTokens, 42)
        XCTAssertEqual(initial.quota.remainingPercent, 61)

        scheduler.advance(by: 29.999)
        XCTAssertEqual(store.snapshot.dailyTokens.totalTokens, 42)

        var firstMidnightPublication: UsageSnapshot?
        let firstPublicationCancellable = store.$snapshot.dropFirst().prefix(1).sink {
            firstMidnightPublication = $0
        }
        clock.set(midnight)
        scheduler.advance(by: 0.001)
        await loader.waitUntilStarted(count: 2)
        let beforeFailureCompletes = store.snapshot
        let failed = await nextSnapshot(from: store) {
            loader.release(call: 2)
        }
        XCTAssertEqual(firstMidnightPublication?.dailyTokens, .zero)
        XCTAssertEqual(beforeFailureCompletes.dailyTokens, .zero)
        XCTAssertEqual(beforeFailureCompletes.quota.remainingPercent, 61)
        XCTAssertEqual(beforeFailureCompletes.freshness, .stale)
        XCTAssertEqual(failed.dailyTokens, .zero)
        XCTAssertEqual(failed.quota.remainingPercent, 61)
        XCTAssertEqual(failed.freshness, .stale)
        withExtendedLifetime(firstPublicationCancellable) {}
    }

    func testWakeAfterDayChangeResetsTokensWithoutMidnightCallback() async throws {
        let (shanghai, beforeMidnight, midnight) = try makeShanghaiDayBoundary()
        let clock = LockedDateSource(beforeMidnight)
        let watcher = SpyActivityWatcher()
        let loader = ControlledUsageLoader(
            results: [
                UsageLoadResult(
                    quota: makeQuota(remainingPercent: 61, sourceName: "yesterday"),
                    dailyTokens: makeTokens(total: 42)
                ),
                .empty
            ],
            blockedCalls: [2]
        )
        let store = UsageStore(
            loader: loader,
            watcher: watcher,
            calendar: shanghai,
            now: clock.now
        )

        _ = await nextSnapshot(from: store) { store.refresh() }
        clock.set(midnight)
        var firstWakePublication: UsageSnapshot?
        let firstPublicationCancellable = store.$snapshot.dropFirst().prefix(1).sink {
            firstWakePublication = $0
        }
        store.refreshAfterWakeOrUnlock()
        await loader.waitUntilStarted(count: 2)
        let beforeFailureCompletes = store.snapshot
        let failed = await nextSnapshot(from: store) {
            loader.release(call: 2)
        }

        XCTAssertEqual(firstWakePublication?.dailyTokens, .zero)
        XCTAssertEqual(beforeFailureCompletes.dailyTokens, .zero)
        XCTAssertEqual(beforeFailureCompletes.quota.remainingPercent, 61)
        XCTAssertEqual(beforeFailureCompletes.freshness, .stale)
        XCTAssertEqual(failed.dailyTokens, .zero)
        XCTAssertEqual(watcher.rebindCount, 1)
        withExtendedLifetime(firstPublicationCancellable) {}
    }

    func testLoadCompletingAfterDayChangeRejectsOldTokensAndRequestsCurrentDayFollowUp() async throws {
        let (shanghai, beforeMidnight, midnight) = try makeShanghaiDayBoundary()
        let clock = LockedDateSource(beforeMidnight)
        let lateTokens = makeTokens(total: 99)
        let currentTokens = makeTokens(total: 7)
        let loader = ControlledUsageLoader(
            results: [
                UsageLoadResult(
                    quota: makeQuota(remainingPercent: 61, sourceName: "initial"),
                    dailyTokens: makeTokens(total: 42)
                ),
                UsageLoadResult(
                    quota: makeQuota(remainingPercent: 70, sourceName: "late quota"),
                    dailyTokens: lateTokens
                ),
                UsageLoadResult(
                    quota: makeQuota(remainingPercent: 80, sourceName: "current"),
                    dailyTokens: currentTokens
                )
            ],
            blockedCalls: [2, 3]
        )
        let store = UsageStore(
            loader: loader,
            watcher: nil,
            calendar: shanghai,
            now: clock.now
        )
        var publishedTokenTotals: [Int64] = []
        let cancellable = store.$snapshot.dropFirst().sink {
            publishedTokenTotals.append($0.dailyTokens.totalTokens)
        }

        _ = await nextSnapshot(from: store) { store.refresh() }
        store.refresh()
        await loader.waitUntilStarted(count: 2)
        clock.set(midnight)

        let reset = await nextSnapshot(from: store) {
            loader.release(call: 2)
        }
        guard reset.dailyTokens == .zero else {
            XCTFail("Previous-day completion republished \(reset.dailyTokens.totalTokens) tokens")
            return
        }
        await loader.waitUntilStarted(count: 3)

        XCTAssertEqual(store.snapshot.dailyTokens, .zero)
        XCTAssertEqual(store.snapshot.quota.remainingPercent, 70)
        XCTAssertEqual(store.snapshot.freshness, .stale)
        XCTAssertEqual(loader.callDates, [beforeMidnight, beforeMidnight, midnight])
        XCTAssertFalse(publishedTokenTotals.contains(lateTokens.totalTokens))

        let current = await nextSnapshot(from: store) {
            loader.release(call: 3)
        }
        XCTAssertEqual(current.dailyTokens, currentTokens)
        XCTAssertEqual(current.quota.remainingPercent, 80)
        XCTAssertEqual(current.freshness, .live)
        withExtendedLifetime(cancellable) {}
    }

    func testMidnightSuccessPublishesNewDayTokensAndSchedulesFollowingMidnight() async throws {
        let (shanghai, beforeMidnight, midnight) = try makeShanghaiDayBoundary()
        let clock = LockedDateSource(beforeMidnight)
        let scheduler = ManualUsageScheduler()
        let newDayTokens = makeTokens(total: 7)
        let loader = ControlledUsageLoader(
            results: [
                UsageLoadResult(
                    quota: makeQuota(remainingPercent: 61, sourceName: "yesterday"),
                    dailyTokens: makeTokens(total: 42)
                ),
                UsageLoadResult(
                    quota: makeQuota(remainingPercent: 60, sourceName: "today"),
                    dailyTokens: newDayTokens
                )
            ],
            blockedCalls: [2]
        )
        let store = UsageStore(
            loader: loader,
            watcher: SpyActivityWatcher(),
            scheduler: scheduler,
            calendar: shanghai,
            now: clock.now
        )

        _ = await nextSnapshot(from: store) { store.start() }
        var firstMidnightPublication: UsageSnapshot?
        let firstPublicationCancellable = store.$snapshot.dropFirst().prefix(1).sink {
            firstMidnightPublication = $0
        }
        clock.set(midnight)
        scheduler.advance(by: 30)
        await loader.waitUntilStarted(count: 2)
        let beforeSuccessCompletes = store.snapshot
        let refreshed = await nextSnapshot(from: store) {
            loader.release(call: 2)
        }
        XCTAssertEqual(firstMidnightPublication?.dailyTokens, .zero)
        XCTAssertEqual(beforeSuccessCompletes.dailyTokens, .zero)
        XCTAssertEqual(refreshed.dailyTokens, newDayTokens)
        XCTAssertEqual(refreshed.quota.remainingPercent, 60)
        XCTAssertEqual(refreshed.freshness, .live)
        let activeMidnightTasks = scheduler.tasks.filter {
            !$0.isCancelled && $0.repeatingInterval == nil
        }
        XCTAssertEqual(activeMidnightTasks.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(activeMidnightTasks.first).nextFireTime,
            86_430,
            accuracy: 0.001
        )
        withExtendedLifetime(firstPublicationCancellable) {}
    }

    func testSpringForwardSchedulesCalendarMidnightAndResetsDayIdentity() async throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let springForwardDay = try XCTUnwrap(losAngeles.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 0,
            minute: 0,
            second: 0
        )))
        let followingMidnight = try XCTUnwrap(losAngeles.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 9,
            hour: 0,
            minute: 0,
            second: 0
        )))
        let clock = LockedDateSource(springForwardDay)
        let scheduler = ManualUsageScheduler()
        let store = UsageStore(
            loader: CountingUsageLoader(result: UsageLoadResult(
                quota: makeQuota(remainingPercent: 61, sourceName: "DST"),
                dailyTokens: makeTokens(total: 42)
            )),
            watcher: SpyActivityWatcher(),
            scheduler: scheduler,
            calendar: losAngeles,
            now: clock.now
        )

        _ = await nextSnapshot(from: store) { store.start() }
        let midnightTask = try XCTUnwrap(scheduler.tasks.first {
            !$0.isCancelled && $0.repeatingInterval == nil
        })
        XCTAssertEqual(midnightTask.nextFireTime, 82_800, accuracy: 0.001)

        clock.set(followingMidnight)
        let reset = await nextSnapshot(from: store) {
            midnightTask.fireEvenIfCancelled()
        }
        XCTAssertEqual(reset.dailyTokens, .zero)
        XCTAssertEqual(reset.dailyTokenDay, losAngeles.startOfDay(for: followingMidnight))
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

private enum StubProviderError: Error {
    case failed
}

private final class StubDailyTokenUsageProvider: DailyTokenUsageProviding, @unchecked Sendable {
    private let usage: DailyTokenUsage

    init(usage: DailyTokenUsage) {
        self.usage = usage
    }

    func currentUsage(now: Date) throws -> DailyTokenUsage {
        usage
    }
}

private final class StubTaskActivityProvider: CodexTaskActivityProviding, @unchecked Sendable {
    private let activity: Bool?
    private let error: (any Error)?

    init(activity: Bool) {
        self.activity = activity
        self.error = nil
    }

    init(error: any Error) {
        self.activity = nil
        self.error = error
    }

    func currentActivity(now: Date) throws -> Bool {
        if let error {
            throw error
        }
        return activity ?? false
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

final class BlockingUsageAndActivityLoader: UsageLoading, TaskActivityLoading, @unchecked Sendable {
    private let condition = NSCondition()
    private var activity: Bool
    private var activityCalls = 0
    private var usageStarted = false
    private var usageReleased = false
    private var usageStartedContinuation: CheckedContinuation<Void, Never>?
    private var activityWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(activity: Bool) {
        self.activity = activity
    }

    func load(now: Date) -> UsageLoadResult {
        condition.lock()
        usageStarted = true
        let continuation = usageStartedContinuation
        usageStartedContinuation = nil
        condition.unlock()
        continuation?.resume()

        condition.lock()
        while !usageReleased {
            condition.wait()
        }
        condition.unlock()
        return .empty
    }

    func loadActivity(now: Date) -> Bool? {
        condition.lock()
        activityCalls += 1
        let result = activity
        let readyWaiters = activityWaiters.filter { $0.count <= activityCalls }
        activityWaiters.removeAll { $0.count <= activityCalls }
        condition.unlock()
        readyWaiters.forEach { $0.continuation.resume() }
        return result
    }

    var activityCallCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return activityCalls
    }

    func setActivity(_ activity: Bool) {
        condition.lock()
        self.activity = activity
        condition.unlock()
    }

    func waitUntilActivityLoaded(count: Int) async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if activityCalls >= count {
                condition.unlock()
                continuation.resume()
            } else {
                activityWaiters.append((count, continuation))
                condition.unlock()
            }
        }
    }

    func waitUntilUsageStarted() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if usageStarted {
                condition.unlock()
                continuation.resume()
            } else {
                usageStartedContinuation = continuation
                condition.unlock()
            }
        }
    }

    func releaseUsage() {
        condition.lock()
        usageReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

final class ActivityWinsUsageLoader: UsageLoading, TaskActivityLoading, @unchecked Sendable {
    private let condition = NSCondition()
    private var usageStarted = false
    private var usageReleased = false
    private var usageStartedContinuation: CheckedContinuation<Void, Never>?

    func load(now: Date) -> UsageLoadResult {
        condition.lock()
        usageStarted = true
        let started = usageStartedContinuation
        usageStartedContinuation = nil
        condition.unlock()
        started?.resume()

        condition.lock()
        while !usageReleased {
            condition.wait()
        }
        condition.unlock()
        return UsageLoadResult(quota: nil, dailyTokens: nil, isTaskActive: false)
    }

    func loadActivity(now: Date) -> Bool? {
        true
    }

    func waitUntilUsageStarted() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if usageStarted {
                condition.unlock()
                continuation.resume()
            } else {
                usageStartedContinuation = continuation
                condition.unlock()
            }
        }
    }

    func releaseUsage() {
        condition.lock()
        usageReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

final class MutableActivityUsageLoader: UsageLoading, TaskActivityLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var activity: Bool
    private var activityCalls = 0
    private var activityWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(activity: Bool) {
        self.activity = activity
    }

    func load(now: Date) -> UsageLoadResult {
        .empty
    }

    func loadActivity(now: Date) -> Bool? {
        lock.lock()
        activityCalls += 1
        let result = activity
        let ready = activityWaiters.filter { $0.count <= activityCalls }
        activityWaiters.removeAll { $0.count <= activityCalls }
        lock.unlock()
        ready.forEach { $0.continuation.resume() }
        return result
    }

    func setActivity(_ activity: Bool) {
        lock.lock()
        self.activity = activity
        lock.unlock()
    }

    func waitUntilActivityLoaded(count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if activityCalls >= count {
                lock.unlock()
                continuation.resume()
            } else {
                activityWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }
}

final class SequenceUsageLoader: UsageLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [UsageLoadResult]
    private var calls = 0

    init(results: [UsageLoadResult]) {
        self.results = results
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func load(now: Date) -> UsageLoadResult {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return results.isEmpty ? .empty : results.removeFirst()
    }
}

final class ControlledUsageLoader: UsageLoading, @unchecked Sendable {
    private let condition = NSCondition()
    private let results: [UsageLoadResult]
    private let blockedCalls: Set<Int>
    private var calls = 0
    private var dates: [Date] = []
    private var releasedCalls = Set<Int>()
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(results: [UsageLoadResult], blockedCalls: Set<Int>) {
        self.results = results
        self.blockedCalls = blockedCalls
    }

    var callDates: [Date] {
        condition.lock()
        defer { condition.unlock() }
        return dates
    }

    func load(now: Date) -> UsageLoadResult {
        condition.lock()
        calls += 1
        let call = calls
        dates.append(now)
        let readyWaiters = startWaiters.filter { $0.count <= calls }
        startWaiters.removeAll { $0.count <= calls }
        condition.unlock()
        readyWaiters.forEach { $0.continuation.resume() }

        condition.lock()
        while blockedCalls.contains(call), !releasedCalls.contains(call) {
            condition.wait()
        }
        condition.unlock()
        return results[call - 1]
    }

    func waitUntilStarted(count: Int) async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if calls >= count {
                condition.unlock()
                continuation.resume()
            } else {
                startWaiters.append((count, continuation))
                condition.unlock()
            }
        }
    }

    func release(call: Int) {
        condition.lock()
        releasedCalls.insert(call)
        condition.broadcast()
        condition.unlock()
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

@MainActor
private func nextTaskActivity(
    from store: UsageStore,
    after action: () -> Void
) async {
    await withCheckedContinuation { continuation in
        var cancellable: AnyCancellable?
        cancellable = store.$isTaskActive.dropFirst().prefix(1).sink { _ in
            continuation.resume()
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

private func makeShanghaiDayBoundary() throws -> (
    calendar: Calendar,
    beforeMidnight: Date,
    midnight: Date
) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
    let beforeMidnight = try XCTUnwrap(calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 1,
        hour: 23,
        minute: 59,
        second: 30
    )))
    let midnight = try XCTUnwrap(calendar.date(byAdding: .second, value: 30, to: beforeMidnight))
    return (calendar, beforeMidnight, midnight)
}

private func makeQuota(
    remainingPercent: Int,
    sourceName: String,
    lastUpdated: Date = Date(timeIntervalSince1970: 1_000)
) -> QuotaSnapshot {
    let now = lastUpdated
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
        lastUpdated: lastUpdated
    )
}
