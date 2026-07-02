//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

private enum ConversationPerformanceTestConfig {
    static let enableEnvironmentKey = "SIGNAL_ENABLE_CONVERSATION_PERF_TESTS"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[enableEnvironmentKey] == "1"
    }

    static func intValue(_ key: String, default defaultValue: Int) -> Int {
        guard
            let rawValue = ProcessInfo.processInfo.environment[key],
            let value = Int(rawValue),
            value > 0
        else {
            return defaultValue
        }
        return value
    }

    static func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            isEnabled,
            "Set \(enableEnvironmentKey)=1 to run long-conversation performance tests.",
        )
    }

    static func measureOptions(
        defaultIterationCount: Int = 5,
        manuallyStart: Bool = false,
    ) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = intValue(
            "SIGNAL_PERF_MEASURE_ITERATIONS",
            default: defaultIterationCount,
        )
        if manuallyStart {
            options.invocationOptions = [.manuallyStart]
        }
        return options
    }
}

class MessageLoaderTest: XCTestCase {
    private var cursorFactory: MockCursorFactory!
    private var interactionFetcher: MockInteractionFetcher!
    private var messageLoader: MessageLoader!
    private var mockDB: InMemoryDB!

    private class MockCursorFactory: MessageLoaderCursorFactory {
        var interactions = [TSInteraction]()

        /// The total number of uniqueIds vended across every cursor this
        /// factory has built, so tests can assert how many rows the loader
        /// actually consumed.
        private(set) var vendedUniqueIdCount = 0

        func buildUniqueIdCursor(filter: InteractionFinder.RowIdFilter, tx: DBReadTransaction) -> MessageLoaderUniqueIdCursor {
            // Like the database-backed cursor, yield uniqueIds newest first
            // for `.newest`, `.atOrBefore`, and `.before`, and oldest first
            // for `.after` and `.range`.
            let uniqueIds: [String]
            switch filter {
            case .newest:
                uniqueIds = interactions.reversed().map { $0.uniqueId }
            case .after(let rowId):
                uniqueIds = interactions.filter { $0.sqliteRowId! > rowId }.map { $0.uniqueId }
            case .atOrBefore(let rowId):
                uniqueIds = interactions.reversed().filter { $0.sqliteRowId! <= rowId }.map { $0.uniqueId }
            case .before(let rowId):
                uniqueIds = interactions.reversed().filter { $0.sqliteRowId! < rowId }.map { $0.uniqueId }
            case .range(let rowIds):
                uniqueIds = interactions.filter { rowIds.contains($0.sqliteRowId!) }.map { $0.uniqueId }
            }
            return InMemoryUniqueIdCursor(
                uniqueIds: uniqueIds,
                onNext: { [weak self] in
                    self?.vendedUniqueIdCount += 1
                },
            )
        }
    }

    private class MockInteractionFetcher: MessageLoaderInteractionFetcher {
        var interactions = [TSInteraction]() {
            didSet {
                interactionsByUniqueId = Dictionary(uniqueKeysWithValues: interactions.lazy.map { ($0.uniqueId, $0) })
            }
        }

        private var interactionsByUniqueId = [String: TSInteraction]()
        func fetchInteractions(for uniqueIds: [String], tx: DBReadTransaction) -> [String: TSInteraction] {
            var result = [String: TSInteraction]()
            for uniqueId in uniqueIds {
                result[uniqueId] = interactionsByUniqueId[uniqueId]
            }
            return result
        }
    }

    override func setUp() {
        super.setUp()

        cursorFactory = MockCursorFactory()
        interactionFetcher = MockInteractionFetcher()
        messageLoader = MessageLoader(
            cursorFactory: cursorFactory,
            interactionFetchers: [interactionFetcher],
        )
        mockDB = InMemoryDB()
    }

    private func createInteractions(_ count: Int64, threadUniqueId: String) -> [TSInteraction] {
        return ((1 as Int64)...count).map { rowId in
            TSInteraction(
                grdbId: rowId,
                uniqueId: UUID().uuidString,
                receivedAtTimestamp: UInt64(rowId),
                sortId: UInt64(rowId),
                timestamp: UInt64(rowId),
                uniqueThreadId: threadUniqueId,
            )
        }
    }

    private func createInfoMessage(
        rowId: Int64,
        threadUniqueId: String,
        messageType: TSInfoMessageType,
    ) -> TSInteraction {
        return TSInfoMessage(
            grdbId: rowId,
            uniqueId: UUID().uuidString,
            receivedAtTimestamp: UInt64(rowId),
            sortId: UInt64(rowId),
            timestamp: UInt64(rowId),
            uniqueThreadId: threadUniqueId,
            body: nil,
            bodyRanges: nil,
            contactShare: nil,
            deprecated_attachmentIds: nil,
            editState: .none,
            expireStartedAt: 0,
            expireTimerVersion: nil,
            expiresAt: 0,
            expiresInSeconds: 0,
            giftBadge: nil,
            isGroupStoryReply: false,
            isPoll: false,
            isSmsMessageRestoredFromBackup: false,
            isViewOnceComplete: false,
            isViewOnceMessage: false,
            linkPreview: nil,
            messageSticker: nil,
            quotedMessage: nil,
            storedShouldStartExpireTimer: false,
            storyAuthorUuidString: nil,
            storyReactionEmoji: nil,
            storyTimestamp: nil,
            wasRemotelyDeleted: false,
            customMessage: nil,
            infoMessageUserInfo: nil,
            messageType: messageType,
            read: true,
            serverGuid: nil,
            unregisteredAddress: nil,
        )
    }

    private func createInteraction(rowId: Int64, threadUniqueId: String) -> TSInteraction {
        return createInfoMessage(rowId: rowId, threadUniqueId: threadUniqueId, messageType: .userJoinedSignal)
    }

    private func createCollapsibleInteraction(rowId: Int64, threadUniqueId: String) -> TSInteraction {
        return createInfoMessage(rowId: rowId, threadUniqueId: threadUniqueId, messageType: .typeDisappearingMessagesUpdate)
    }

    private func createCollapsibleInteractions(_ count: Int64, threadUniqueId: String) -> [TSInteraction] {
        return ((1 as Int64)...count).map { rowId in
            createCollapsibleInteraction(rowId: rowId, threadUniqueId: threadUniqueId)
        }
    }

    private func createMixedInteractions(_ chunkCount: Int64, threadUniqueId: String) -> [TSInteraction] {
        return ((0 as Int64)..<chunkCount).flatMap { chunkIndex -> [TSInteraction] in
            let rowId = chunkIndex * 3 + 1
            return [
                createCollapsibleInteraction(rowId: rowId, threadUniqueId: threadUniqueId),
                createCollapsibleInteraction(rowId: rowId + 1, threadUniqueId: threadUniqueId),
                createInteraction(rowId: rowId + 2, threadUniqueId: threadUniqueId),
            ]
        }
    }

    private func setInteractions(_ interactions: [TSInteraction]) {
        cursorFactory.interactions = interactions
        interactionFetcher.interactions = interactions
    }

    private func preprocessingContext(threadUniqueId: String) -> MessageLoaderPreprocessingContext {
        return MessageLoaderPreprocessingContext(
            threadUniqueId: threadUniqueId,
            oldestUnreadSortId: nil,
        )
    }

    private func preprocessingContext(
        threadUniqueId: String,
        oldestUnreadSortId: UInt64?,
    ) -> MessageLoaderPreprocessingContext {
        return MessageLoaderPreprocessingContext(
            threadUniqueId: threadUniqueId,
            oldestUnreadSortId: oldestUnreadSortId,
        )
    }

    func test_loadInitialMessagePage_empty() throws {
        let threadUniqueId = UUID().uuidString
        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }
        XCTAssertEqual(messageLoader.loadedInteractions, [])
    }

    func test_loadInitialMessagePage_nonempty() throws {
        let threadUniqueId = UUID().uuidString
        let initialMessages = createInteractions(5, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)
        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }
        XCTAssertEqual(messageLoader.loadedInteractions.count, 5)
        XCTAssertEqual(initialMessages.map { $0.uniqueId }, messageLoader.loadedInteractions.map { $0.uniqueId })
    }

    func test_loadInitialMessagePage_countsCollapsedInteractionsAsTopLevel() throws {
        let threadUniqueId = UUID().uuidString
        let initialMessages = createCollapsibleInteractions(2_000, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)

        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        let newestInteraction = try XCTUnwrap(initialMessages.last)
        XCTAssertEqual(messageLoader.loadedInteractions.last?.uniqueId, newestInteraction.uniqueId)
        let newestCollapseSet = try XCTUnwrap(messageLoader.loadedDisplayableInteractions.last as? CollapseSetInteraction)
        XCTAssertEqual(newestCollapseSet.collapsedInteractions.last?.uniqueId, newestInteraction.uniqueId)
        XCTAssertGreaterThan(messageLoader.loadedInteractions.count, 500)
        XCTAssertLessThanOrEqual(messageLoader.loadedDisplayableInteractions.count, 500)
        XCTAssertTrue(messageLoader.loadedDisplayableInteractions.contains { $0 is CollapseSetInteraction })
    }

    func test_loadInitialMessagePage_fetchesEachInteractionOnce() throws {
        let threadUniqueId = UUID().uuidString
        let initialMessages = createCollapsibleInteractions(5_000, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)

        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        // Even though every interaction is collapsible (so each display unit
        // costs maxCollapseSetSize raw interactions), the loader should fetch
        // exactly the interactions it keeps, plus the single interaction past
        // the window boundary that confirms the oldest collapse set is
        // complete.
        XCTAssertEqual(cursorFactory.vendedUniqueIdCount, messageLoader.loadedInteractions.count + 1)
        XCTAssertLessThanOrEqual(messageLoader.loadedDisplayableInteractions.count, 500)
    }

    func test_loadOlderMessagePage_fetchesEachInteractionOnce() throws {
        let threadUniqueId = UUID().uuidString
        let initialMessages = createCollapsibleInteractions(15_000, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)

        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
            for _ in 0..<2 {
                try self.messageLoader.loadOlderMessagePage(
                    reusableInteractions: [:],
                    deletedInteractionIds: [],
                    preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                    tx: tx,
                )
            }
        }

        // Each of the three loads should only have fetched interactions that
        // weren't already loaded, plus one discarded boundary interaction.
        XCTAssertEqual(cursorFactory.vendedUniqueIdCount, messageLoader.loadedInteractions.count + 3)
    }

    func test_loadOlderMessagePage_keepsCollapseSetsStable() throws {
        let threadUniqueId = UUID().uuidString
        // Repeated [collapsible, collapsible, standalone] chunks: every
        // collapse set should always appear with both of its interactions,
        // even at the edge of the load window.
        let initialMessages = createMixedInteractions(200, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)

        func assertDisplayUnitsAreWhole() {
            for interaction in messageLoader.loadedDisplayableInteractions {
                if let collapseSet = interaction as? CollapseSetInteraction {
                    XCTAssertEqual(collapseSet.collapsedInteractions.count, 2)
                } else if let infoMessage = interaction as? TSInfoMessage {
                    // Collapsible interactions never appear outside a set.
                    XCTAssertEqual(infoMessage.messageType, .userJoinedSignal)
                }
            }
        }

        func displayableIdsIgnoringDateHeaders() -> Set<String> {
            Set(
                messageLoader.loadedDisplayableInteractions.lazy
                    .filter { !($0 is DateHeaderInteraction) }
                    .map { $0.uniqueId },
            )
        }

        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
            assertDisplayUnitsAreWhole()

            var loadCount = 0
            while self.messageLoader.canLoadOlder, loadCount < 100 {
                let previousDisplayableIds = displayableIdsIgnoringDateHeaders()
                try self.messageLoader.loadOlderMessagePage(
                    reusableInteractions: [:],
                    deletedInteractionIds: [],
                    preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                    tx: tx,
                )
                loadCount += 1
                assertDisplayUnitsAreWhole()
                // Loading older pages must never change the identity of
                // displayable items that were already loaded.
                XCTAssertTrue(previousDisplayableIds.isSubset(of: displayableIdsIgnoringDateHeaders()))
            }
            XCTAssertFalse(self.messageLoader.canLoadOlder)
        }
    }

    func test_loadInitialMessagePage_aroundFocus_balancesDisplayableUnits() throws {
        let threadUniqueId = UUID().uuidString
        // 100 collapsible interactions (two 50-item collapse sets) followed by
        // a focus message and 300 standalone messages.
        var initialMessages = createCollapsibleInteractions(100, threadUniqueId: threadUniqueId)
        let focusInteraction = createInteraction(rowId: 101, threadUniqueId: threadUniqueId)
        initialMessages.append(focusInteraction)
        initialMessages += ((102 as Int64)...401).map { createInteraction(rowId: $0, threadUniqueId: threadUniqueId) }
        setInteractions(initialMessages)

        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: focusInteraction.uniqueId,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        // The older half of the window is measured in display units, not raw
        // interactions: its two collapse sets cost fewer units than the older
        // half of the load window, so the loader reaches the start of the chat.
        XCTAssertFalse(messageLoader.canLoadOlder)
        XCTAssertEqual(messageLoader.loadedInteractions.first?.uniqueId, initialMessages.first?.uniqueId)

        // The newer side received the remaining units as standalone messages.
        XCTAssertTrue(messageLoader.canLoadNewer)
        let displayableIds = messageLoader.loadedDisplayableInteractions.map { $0.uniqueId }
        let focusIndex = try XCTUnwrap(displayableIds.firstIndex(of: focusInteraction.uniqueId))
        XCTAssertGreaterThanOrEqual(displayableIds.count - focusIndex - 1, 5)
    }

    func test_loadOlderMessagePage_withMixedCollapseSets_trimsNewerSide() throws {
        let threadUniqueId = UUID().uuidString
        let initialMessages = createMixedInteractions(900, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)

        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        let newestInteraction = try XCTUnwrap(initialMessages.last)
        XCTAssertEqual(messageLoader.loadedInteractions.last?.uniqueId, newestInteraction.uniqueId)

        try mockDB.read { tx in
            var loadCount = 0
            while self.messageLoader.canLoadOlder, loadCount < 100 {
                try self.messageLoader.loadOlderMessagePage(
                    reusableInteractions: [:],
                    deletedInteractionIds: [],
                    preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                    tx: tx,
                )
                loadCount += 1
            }
        }

        XCTAssertLessThanOrEqual(messageLoader.loadedDisplayableInteractions.count, 500)
        XCTAssertTrue(messageLoader.loadedDisplayableInteractions.contains { $0 is CollapseSetInteraction })
        XCTAssertFalse(messageLoader.loadedInteractions.contains { $0.uniqueId == newestInteraction.uniqueId })
    }

    func test_loadNewerMessagePage_withMixedCollapseSets_trimsOlderSide() throws {
        let threadUniqueId = UUID().uuidString
        let initialMessages = createMixedInteractions(900, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)

        let focusInteraction = initialMessages[100]
        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: focusInteraction.uniqueId,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        XCTAssertTrue(messageLoader.loadedInteractions.contains { $0.uniqueId == focusInteraction.uniqueId })

        try mockDB.read { tx in
            var loadCount = 0
            while self.messageLoader.canLoadNewer, loadCount < 100 {
                try self.messageLoader.loadNewerMessagePage(
                    reusableInteractions: [:],
                    deletedInteractionIds: [],
                    preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                    tx: tx,
                )
                loadCount += 1
            }
        }

        let newestInteraction = try XCTUnwrap(initialMessages.last)
        XCTAssertLessThanOrEqual(messageLoader.loadedDisplayableInteractions.count, 500)
        XCTAssertTrue(messageLoader.loadedDisplayableInteractions.contains { $0 is CollapseSetInteraction })
        XCTAssertEqual(messageLoader.loadedInteractions.last?.uniqueId, newestInteraction.uniqueId)
        XCTAssertFalse(messageLoader.loadedInteractions.contains { $0.uniqueId == focusInteraction.uniqueId })
    }

    func test_reloadInteractions_deletes() throws {
        let threadUniqueId = UUID().uuidString
        let initialMessages = createInteractions(5, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)

        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        let remainingMessages = [initialMessages[1], initialMessages[3], initialMessages[4]]
        setInteractions(remainingMessages)

        XCTAssertEqual(initialMessages.map { $0.uniqueId }, messageLoader.loadedInteractions.map { $0.uniqueId })

        let deletedInteractionIds: Set<String> = Set([initialMessages[0], initialMessages[2]].map { $0.uniqueId })
        try mockDB.read { tx in
            return try self.messageLoader.loadSameLocation(
                reusableInteractions: [:],
                deletedInteractionIds: deletedInteractionIds,
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }
        XCTAssertEqual(remainingMessages.map { $0.uniqueId }, messageLoader.loadedInteractions.map { $0.uniqueId })
    }

    func test_reloadInteractions_inserts() throws {
        let threadUniqueId = UUID().uuidString
        let allMessages = createInteractions(5, threadUniqueId: threadUniqueId)

        setInteractions(Array(allMessages.prefix(2)))
        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        setInteractions(allMessages)
        try mockDB.read { tx in
            return try self.messageLoader.loadSameLocation(
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        XCTAssertEqual(allMessages.map { $0.uniqueId }, messageLoader.loadedInteractions.map { $0.uniqueId })
    }

    func test_reloadInteractions_insertsAndDeletes() throws {
        let threadUniqueId = UUID().uuidString
        let allMessages = createInteractions(5, threadUniqueId: threadUniqueId)
        let initialMessages = Array(allMessages.prefix(4))

        setInteractions(initialMessages)
        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        let remainingMessages = [allMessages[1], allMessages[2], allMessages[4]]
        setInteractions(remainingMessages)

        let deletedInteractionIds: Set<String> = Set([allMessages[0], allMessages[3]].map { $0.uniqueId })
        try mockDB.read { tx in
            return try self.messageLoader.loadSameLocation(
                reusableInteractions: [:],
                deletedInteractionIds: deletedInteractionIds,
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        XCTAssertEqual(remainingMessages.map { $0.uniqueId }, messageLoader.loadedInteractions.map { $0.uniqueId })
    }

    func test_reloadInteractions_removeAll() throws {
        let threadUniqueId = UUID().uuidString
        let initialMessages = createInteractions(5, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)

        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        XCTAssert(!messageLoader.canLoadNewer)
        XCTAssert(!messageLoader.canLoadOlder)

        setInteractions([])

        let removedIds = Set(initialMessages.map { $0.uniqueId })
        try mockDB.read { tx in
            return try self.messageLoader.loadSameLocation(
                reusableInteractions: [:],
                deletedInteractionIds: removedIds,
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        XCTAssertEqual(messageLoader.loadedInteractions, [])
    }

    func test_reloadInteractions_fix_crash() throws {
        // Create more messages than are part of the first batch.
        let threadUniqueId = UUID().uuidString
        let initialMessages = createInteractions(400, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)

        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        XCTAssertLessThan(messageLoader.loadedInteractions.count, initialMessages.count)
        XCTAssert(!messageLoader.canLoadNewer)
        XCTAssert(messageLoader.canLoadOlder)

        setInteractions([])

        let removedIds = Set(initialMessages.map { $0.uniqueId })
        try mockDB.read { tx in
            return try self.messageLoader.loadSameLocation(
                reusableInteractions: [:],
                deletedInteractionIds: removedIds,
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        XCTAssertEqual(messageLoader.loadedInteractions, [])
    }

    func test_loadAroundEdge() throws {
        // Create more messages than are part of the first batch.
        let threadUniqueId = UUID().uuidString
        let initialMessages = createInteractions(100, threadUniqueId: threadUniqueId)
        setInteractions(initialMessages)

        // For each message, load the end of the chat, and then jump to that
        // message. (This would be similar to opening the chat and tapping a reply
        // to jump earlier in the history.)
        for idx in stride(from: initialMessages.startIndex, to: initialMessages.endIndex, by: 10) {
            let message = initialMessages[idx]
            let messageLoader = MessageLoader(cursorFactory: cursorFactory, interactionFetchers: [interactionFetcher])
            try mockDB.read { tx in
                try messageLoader.loadInitialMessagePage(
                    focusMessageId: nil,
                    reusableInteractions: [:],
                    deletedInteractionIds: [],
                    preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                    tx: tx,
                )
                XCTAssertLessThan(messageLoader.loadedInteractions.count, initialMessages.count)
                try messageLoader.loadMessagePage(
                    aroundInteractionId: message.uniqueId,
                    reusableInteractions: [:],
                    deletedInteractionIds: [],
                    preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                    tx: tx,
                )
            }
            XCTAssertNotNil(messageLoader.loadedInteractions.map { $0.uniqueId }.firstIndex(of: message.uniqueId))
        }
    }

    func testTotalDeletion() throws {
        let threadUniqueId = UUID().uuidString
        let allMessages = createInteractions(15, threadUniqueId: threadUniqueId)

        let batch1 = Array(allMessages[0..<5])
        let batch2 = Array(allMessages[5..<10])
        let batch3 = Array(allMessages[10..<15])

        setInteractions(batch1)
        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: nil,
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }
        XCTAssertEqual(batch1.map { $0.uniqueId }, messageLoader.loadedInteractions.map { $0.uniqueId })

        setInteractions([])
        try mockDB.read { tx in
            return try self.messageLoader.loadSameLocation(
                reusableInteractions: [:],
                deletedInteractionIds: Set(batch1.map { $0.uniqueId }),
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }
        XCTAssertEqual(messageLoader.loadedInteractions, [])

        setInteractions(batch2)
        try mockDB.read { tx in
            return try self.messageLoader.loadSameLocation(
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }
        XCTAssertEqual(batch2.map { $0.uniqueId }, messageLoader.loadedInteractions.map { $0.uniqueId })

        setInteractions(batch3)
        try mockDB.read { tx in
            return try self.messageLoader.loadSameLocation(
                reusableInteractions: [:],
                deletedInteractionIds: Set(batch2.map { $0.uniqueId }),
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        XCTAssertEqual(batch3.map { $0.uniqueId }, messageLoader.loadedInteractions.map { $0.uniqueId })
    }

    func testDeletionAndLoadOlder() throws {
        let threadUniqueId = UUID().uuidString
        var messages = createInteractions(200, threadUniqueId: threadUniqueId)

        setInteractions(messages)
        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: messages[100].uniqueId, // pretend this is the first unread message
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        // Make sure the load window is pretty small.
        let loadCount1 = messageLoader.loadedInteractions.count
        XCTAssertLessThan(loadCount1, 50)

        // Remove the first, middle and last interactions.
        // This will break "sort index" continuity and make things interesting.
        let removedInteractions1 = [
            messages.remove(at: (messages.startIndex + messages.endIndex) / 2),
            messages.remove(at: messages.endIndex - 1),
            messages.remove(at: messages.startIndex),
        ]
        setInteractions(messages)
        try mockDB.read { tx in
            return try self.messageLoader.loadOlderMessagePage(
                reusableInteractions: [:],
                deletedInteractionIds: Set(removedInteractions1.map { $0.uniqueId }),
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        let loadCount2 = messageLoader.loadedInteractions.count
        XCTAssertLessThan(loadCount1, loadCount2)
        XCTAssertLessThan(loadCount2, 100)

        // Remove the first, middle and last interactions.
        // This will break "sort index" continuity and make things interesting.
        let removedInteractions2 = [
            messages.remove(at: (messages.startIndex + messages.endIndex) / 2),
            messages.remove(at: messages.endIndex - 1),
            messages.remove(at: messages.startIndex),
        ]
        setInteractions(messages)

        try mockDB.read { tx in
            return try self.messageLoader.loadOlderMessagePage(
                reusableInteractions: [:],
                deletedInteractionIds: Set(removedInteractions2.map { $0.uniqueId }),
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        let loadCount3 = messageLoader.loadedInteractions.count
        XCTAssertLessThan(loadCount2, loadCount3)
        XCTAssertLessThan(loadCount3, 150)
    }

    func testDeletionAndLoadNewer() throws {
        let threadUniqueId = UUID().uuidString
        var messages = createInteractions(200, threadUniqueId: threadUniqueId)

        setInteractions(messages)
        try mockDB.read { tx in
            try self.messageLoader.loadInitialMessagePage(
                focusMessageId: messages[100].uniqueId, // pretend this is the first unread message
                reusableInteractions: [:],
                deletedInteractionIds: [],
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        // Make sure the load window is pretty small.
        let loadCount1 = messageLoader.loadedInteractions.count
        XCTAssertLessThan(loadCount1, 50)

        // Remove the first, middle and last interactions.
        // This will break "sort index" continuity and make things interesting.
        let removedInteractions1 = [
            messages.remove(at: (messages.startIndex + messages.endIndex) / 2),
            messages.remove(at: messages.endIndex - 1),
            messages.remove(at: messages.startIndex),
        ]
        setInteractions(messages)
        try mockDB.read { tx in
            return try self.messageLoader.loadNewerMessagePage(
                reusableInteractions: [:],
                deletedInteractionIds: Set(removedInteractions1.map { $0.uniqueId }),
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        let loadCount2 = messageLoader.loadedInteractions.count
        XCTAssertLessThan(loadCount1, loadCount2)
        XCTAssertLessThan(loadCount2, 100)

        // Remove the first, middle and last interactions.
        // This will break "sort index" continuity and make things interesting.
        let removedInteractions2 = [
            messages.remove(at: (messages.startIndex + messages.endIndex) / 2),
            messages.remove(at: messages.endIndex - 1),
            messages.remove(at: messages.startIndex),
        ]
        setInteractions(messages)

        try mockDB.read { tx in
            return try self.messageLoader.loadNewerMessagePage(
                reusableInteractions: [:],
                deletedInteractionIds: Set(removedInteractions2.map { $0.uniqueId }),
                preprocessingContext: preprocessingContext(threadUniqueId: threadUniqueId),
                tx: tx,
            )
        }

        let loadCount3 = messageLoader.loadedInteractions.count
        XCTAssertLessThan(loadCount2, loadCount3)
        XCTAssertLessThan(loadCount3, 150)
    }

    func test_performance_scrollThroughUnreadWindow_withUnreadMarker() throws {
        try ConversationPerformanceTestConfig.skipUnlessEnabled()

        runUnreadWindowPerformance(includeUnreadMarker: true)
    }

    func test_performance_scrollThroughUnreadWindow_withoutUnreadMarker() throws {
        try ConversationPerformanceTestConfig.skipUnlessEnabled()

        runUnreadWindowPerformance(includeUnreadMarker: false)
    }

    private func runUnreadWindowPerformance(includeUnreadMarker: Bool) {
        let threadUniqueId = UUID().uuidString
        let messageCount = ConversationPerformanceTestConfig.intValue(
            "SIGNAL_PERF_UNREAD_THREAD_MESSAGES",
            default: 10_000,
        )
        let unreadCount = min(
            ConversationPerformanceTestConfig.intValue("SIGNAL_PERF_UNREAD_MESSAGES", default: 250),
            messageCount,
        )
        let pageLimit = ConversationPerformanceTestConfig.intValue("SIGNAL_PERF_UNREAD_SCROLL_PAGES", default: 8)
        let interactions = createInteractions(Int64(messageCount), threadUniqueId: threadUniqueId)
        setInteractions(interactions)

        let oldestUnreadInteraction = interactions[messageCount - unreadCount]
        let oldestUnreadSortId = includeUnreadMarker ? oldestUnreadInteraction.sortId : nil

        measure(metrics: [XCTClockMetric()]) {
            let loader = MessageLoader(
                cursorFactory: cursorFactory,
                interactionFetchers: [interactionFetcher],
            )

            let loadSucceeded = mockDB.read { tx in
                do {
                    try loader.loadInitialMessagePage(
                        focusMessageId: oldestUnreadInteraction.uniqueId,
                        reusableInteractions: [:],
                        deletedInteractionIds: [],
                        preprocessingContext: preprocessingContext(
                            threadUniqueId: threadUniqueId,
                            oldestUnreadSortId: oldestUnreadSortId,
                        ),
                        tx: tx,
                    )

                    var loadedPageCount = 0
                    while loader.canLoadNewer, loadedPageCount < pageLimit {
                        try loader.loadNewerMessagePage(
                            reusableInteractions: [:],
                            deletedInteractionIds: [],
                            preprocessingContext: preprocessingContext(
                                threadUniqueId: threadUniqueId,
                                oldestUnreadSortId: oldestUnreadSortId,
                            ),
                            tx: tx,
                        )
                        loadedPageCount += 1
                    }
                    return true
                } catch {
                    XCTFail("Failed to load unread performance window: \(error)")
                    return false
                }
            }
            XCTAssertTrue(loadSucceeded)
            XCTAssertLessThanOrEqual(loader.loadedDisplayableInteractions.count, 500)
        }
    }
}

final class ConversationDatabasePerformanceTest: SignalBaseTest {
    private struct SeededThread {
        let thread: TSContactThread
        let unreadInteractionIds: [String]
    }

    private lazy var incomingMessageBody = String(repeating: "incoming perf message ", count: 3)
    private lazy var outgoingMessageBody = String(repeating: "outgoing perf message ", count: 3)

    func test_performance_sendPersistence_inLongConversation() throws {
        try ConversationPerformanceTestConfig.skipUnlessEnabled()

        let messageCount = ConversationPerformanceTestConfig.intValue(
            "SIGNAL_PERF_LONG_THREAD_MESSAGES",
            default: 100_000,
        )
        let fixture = seedThread(messageCount: messageCount, unreadTailCount: 0)

        measure(
            metrics: [XCTClockMetric()],
            options: ConversationPerformanceTestConfig.measureOptions(defaultIterationCount: 3),
        ) {
            let persistenceExpectation = expectation(description: "message persisted")
            ThreadUtil.enqueueMessage(
                body: MessageBody(text: "perf send \(UUID().uuidString)", ranges: .empty),
                thread: fixture.thread,
                persistenceCompletionHandler: {
                    persistenceExpectation.fulfill()
                },
            )
            wait(for: [persistenceExpectation], timeout: 120)
        }
    }

    func test_performance_markManyUnreadsRead_inLargeConversation() throws {
        try ConversationPerformanceTestConfig.skipUnlessEnabled()

        let messageCount = ConversationPerformanceTestConfig.intValue(
            "SIGNAL_PERF_UNREAD_THREAD_MESSAGES",
            default: 10_000,
        )
        let unreadCount = min(
            ConversationPerformanceTestConfig.intValue("SIGNAL_PERF_UNREAD_MESSAGES", default: 250),
            messageCount,
        )
        let fixture = seedThread(messageCount: messageCount, unreadTailCount: unreadCount)

        measure(
            metrics: [XCTClockMetric()],
            options: ConversationPerformanceTestConfig.measureOptions(manuallyStart: true),
        ) {
            resetUnreadMessages(fixture.unreadInteractionIds)
            startMeasuring()
            write { tx in
                fixture.thread.markAllAsRead(updateStorageService: false, transaction: tx)
            }
            stopMeasuring()
        }
    }

    private func seedThread(messageCount: Int, unreadTailCount: Int) -> SeededThread {
        let unreadStartIndex = max(0, messageCount - unreadTailCount)
        return write { tx in
            let thread = ContactThreadFactory().create(transaction: tx)
            let incomingFactory = IncomingMessageFactory()
            incomingFactory.threadCreator = { _ in thread }
            incomingFactory.messageBodyBuilder = { self.incomingMessageBody }

            let outgoingFactory = OutgoingMessageFactory()
            outgoingFactory.threadCreator = { _ in thread }
            outgoingFactory.messageBodyBuilder = { self.outgoingMessageBody }

            var unreadInteractionIds = [String]()
            for messageIndex in 0..<messageCount {
                autoreleasepool {
                    if messageIndex >= unreadStartIndex {
                        let message = incomingFactory.create(transaction: tx)
                        unreadInteractionIds.append(message.uniqueId)
                    } else if messageIndex.isMultiple(of: 2) {
                        let message = incomingFactory.create(transaction: tx)
                        message.markAsRead(
                            atTimestamp: Date.ows_millisecondTimestamp(),
                            thread: thread,
                            circumstance: .onThisDevice,
                            shouldClearNotifications: false,
                            transaction: tx,
                        )
                    } else {
                        _ = outgoingFactory.create(transaction: tx)
                    }
                }
            }

            return SeededThread(thread: thread, unreadInteractionIds: unreadInteractionIds)
        }
    }

    private func resetUnreadMessages(_ interactionIds: [String]) {
        write { tx in
            let interactions = InteractionFinder.interactions(
                withInteractionIds: Set(interactionIds),
                transaction: tx,
            )
            for interaction in interactions {
                guard let incomingMessage = interaction as? TSIncomingMessage else {
                    XCTFail("Expected unread fixture to contain only incoming messages.")
                    continue
                }
                incomingMessage.anyUpdateIncomingMessage(transaction: tx) { message in
                    message.wasRead = false
                }
            }
        }
    }
}
