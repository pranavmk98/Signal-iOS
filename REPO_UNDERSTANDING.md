# Signal iOS Repository Understanding

This note records my current understanding of the repository and the likely
areas to inspect for GitHub issue
[#6176](https://github.com/signalapp/Signal-iOS/issues/6176), "Extreme lag when
sending messages on long conversations."

## Repository Shape

Signal iOS is a large Swift-first iOS app with a small Objective-C compatibility
surface. In this checkout I found roughly 2,571 Swift files, 41 headers, and 34
Objective-C implementation files. The top-level modules are split by product
surface and ownership:

- `Signal/`: the main app target. It contains launch code, app-specific flows,
  settings, registration, notifications, and the concrete conversation screen.
- `SignalServiceKit/`: the domain, persistence, networking, message, thread,
  recipient, job, crypto, and service layer. This is where most durable state and
  business logic lives.
- `SignalUI/`: reusable UI components shared by the app and extensions.
- `SignalNSE/` and `SignalShareExtension/`: extension targets sharing the
  database and common service/UI code.
- `Pods/`, `ThirdParty/`, and `Podfile`: CocoaPods-managed dependencies. Notable
  dependencies include GRDB with SQLCipher, LibSignalClient, RingRTC, SDWebImage,
  SwiftProtobuf, BonMot, Lottie, and MobileCoin-related libraries.

The build is Xcode/CocoaPods-based. `BUILDING.md` expects `make dependencies`
and opening `Signal.xcworkspace`. The minimum iOS version in `Podfile` is 15.0.

## Architectural Themes

### Database-Centric State

The app centers durable state in an encrypted GRDB/SQLCipher database. The main
database wrapper is `SignalServiceKit/Storage/Database/SDSDatabaseStorage/`.
Reads and writes are exposed through typed transactions. Async writes are
serialized through queues, and awaitable writes use a single-concurrency task
queue.

Models are persisted through SDS-generated records. `TSInteraction` and related
types serialize into `model_TSInteraction`; `TSThread` stores thread metadata
such as `lastInteractionRowId` and visibility. The generated interaction record
has many nullable columns because several subclasses share one table.

The design tradeoff is clear: shared generic model tables reduce migration and
cross-model plumbing complexity, but make query/index tuning critical. The schema
contains explicitly tuned indexes for conversation loading and unread counts,
which suggests long-thread performance has been a known hot path.

### Explicit Change Observation

`DatabaseChangeObserverImpl` is a legacy GRDB transaction observer that
aggregates table, row, thread, interaction, and story changes. It publishes
batched updates on the main thread through a display link. This avoids updating
views on every write, but introduces a tradeoff:

- UI updates are throttled and coalesced, which protects the app under load.
- If the observer sees too many incremental row changes, it emits a reset-style
  event and delegates reload without caches.

The max incremental row-change threshold is currently 200. That fallback is
important when reasoning about intermittent stalls: a send that unexpectedly
causes many writes could convert a cheap incremental update into a larger reset.

### Conversation UI Is Windowed

The concrete conversation UI lives under `Signal/ConversationView/`. The
conversation loader is deliberately windowed:

- `CVLoadCoordinator` owns the current render state, observes database changes
  for the active thread, and schedules loads.
- `CVLoader` performs a single database-backed load and builds render items.
- `MessageLoader` fetches display units around the current window and caps the
  top-level loaded displayable interaction count at 500.
- `CVUpdate` diffs the previous and next render windows.
- `ConversationViewController+CVC.swift` applies the result as a collection-view
  reload, minor update, or batch diff.

This means long conversations should not normally create 50k-100k collection
view cells. Most operations should scale with the loaded window, not the full
conversation. The cost is more machinery: scroll continuity, reload coalescing,
cache reuse, synthetic items such as date headers and unread indicators, and
collapse sets all have to agree.

### Message Sending Pipeline

The send button path starts in
`Signal/ConversationView/ConversationViewController+ConversationInputToolbarDelegate.swift`.
For a text message, it:

1. Validates the UI/input state on the main thread.
2. Handles block and safety-number prompts.
3. Adds the thread to the profile whitelist or sets default timers if needed.
4. Enqueues the outgoing message through `ThreadUtil`.
5. Calls `messageWasSent()`, clears the input toolbar, clears the draft in a
   separate async database write, and posts a chat-list search-clear
   notification.

`UnpreparedOutgoingMessage.prepare(tx:)` then validates link previews/quoted
replies/stickers/contact shares, inserts the outgoing interaction, creates any
attachment rows, and returns a `PreparedOutgoingMessage`. `MessageSenderJobQueue`
marks recipients as sending, creates a durable job record, queues work by thread
and priority, and later updates send state on success or failure.

The tradeoff here is user-perceived snappiness versus consistency. The UI clears
the input immediately, but the visible message appears only after persistence and
the conversation reload path observe/land the new interaction.

## Issue #6176 Summary

The issue reports that in conversations with 50k-100k+ messages, pressing Send
sometimes blocks the app for 10-45+ seconds before the sent message appears.
It happens on roughly 30-50% of sends, and the app is unresponsive during the
delay. The reporter says it has occurred across multiple iOS and Signal versions.

Because the repo currently uses a bounded conversation window, my working model
is that the problem is probably not "render every message in the thread." More
likely candidates are rare paths where a send causes full-thread-ish queries,
large write batches, reload resets, expensive thread metadata updates, or
main-thread landing work.

## Plausible Root-Cause Areas

### 1. Send Triggers Multiple Reloads

The send code passes a `persistenceCompletionHandler` that calls
`loadCoordinator.enqueueReload()`. Separately, `CVLoadCoordinator` is a
`DatabaseChangeDelegate`; when the database observer publishes changes for the
same thread, it enqueues another reload with updated interaction IDs.

This redundancy may be intentional to make the new message visible as soon as
possible, but it can amplify cost if the initial send write, draft-clearing write,
send-state write, job-record write, and later send-success write are published as
separate batches. Under normal conditions each reload should be bounded, but
when combined with heavy main-thread layout or reset fallback this could become
visible.

Files to inspect:

- `Signal/ConversationView/ConversationViewController+ConversationInputToolbarDelegate.swift`
- `Signal/ConversationView/Loading/CVLoadCoordinator.swift`
- `SignalServiceKit/Storage/Database/Snapshots/DatabaseChangeObserver.swift`

### 2. Observer Reset Fallback From Large Write Bursts

`DatabaseChangeObserverImpl.kMaxIncrementalRowChanges` is 200. If a send-related
transaction or nearby background job touches too many rows before publish, the
observer converts the change into `databaseChangesDidReset()`, and
`CVLoadCoordinator` responds with `enqueueReloadWithoutCaches()`.

This would fit the "sometimes" nature: most sends touch only a handful of rows,
but some sends might coincide with attachment jobs, read/delivery state changes,
expired-message cleanup, backup/indexing work, or other background writes. On a
long thread, a reload without caches can be much more expensive than a small
updated-ID reload because render-item component state is rebuilt.

Files to inspect:

- `SignalServiceKit/Storage/Database/Snapshots/ObservedDatabaseChanges.swift`
- `SignalServiceKit/Storage/Database/Snapshots/DatabaseChangeObserver.swift`
- `Signal/ConversationView/Loading/CVLoader.swift`

### 3. Degenerate Conversation Cursor Scans

`MessageLoader.fetchDisplayUnits` asks `InteractionFinder` for a unique-ID
cursor and iterates until it has enough complete display units. It normally stops
quickly, but it can scan farther when many adjacent interactions collapse into a
single display unit, when many rows are filtered out, or when a boundary needs to
be completed.

The SQL uses the tuned `index_interactions_on_threadUniqueId_and_id` path, so
this is probably not a missing basic index. Still, a pathologically long run of
filtered or collapsible interactions near the bottom of a very long thread could
make a reload cost variable, which matches intermittent lag.

Files to inspect:

- `Signal/ConversationView/Loading/MessageLoader.swift`
- `SignalServiceKit/Storage/Database/Records/InteractionFinder.swift`
- `SignalServiceKit/Storage/Database/GRDBSchemaMigrator.swift`

### 4. Most-Recent Inbox Interaction Can Walk Backward

`InteractionFinder.mostRecentInteractionForInbox` fetches the newest candidate,
then walks backward if that candidate should not appear in the inbox or should
not bump chat-list sorting. `TSThread.updateWithInsertedInteraction` updates
thread visibility and `lastInteractionRowId` after inserts.

For normal outgoing text, this should be cheap. But a long suffix of non-inbox
interactions, hidden story replies, past edit revisions, or non-bumping system
events could cause a backward scan. If that happens during the send transaction,
the UI can be blocked waiting for database work and subsequent main-thread
landing.

Files to inspect:

- `SignalServiceKit/Contacts/TSThread.swift`
- `SignalServiceKit/Storage/Database/Records/InteractionFinder.swift`

### 5. Intent Donation and Avatar Work Inside Send Transactions

After queuing a prepared outgoing message, `ThreadUtil.enqueueMessagePromise`
and other send paths may donate an `INSendMessageIntent`. Building the intent can
resolve display names, count group recipients, inspect mentions/quoted replies,
and create avatar images. This is useful OS integration, but it runs in close
proximity to the send write path.

For a huge group/thread or expensive avatar path, this could inflate send
latency. It may not be the primary issue for a one-to-one thread, but it is worth
profiling because the issue describes the app being unresponsive after tapping
Send, not merely delayed network delivery.

Files to inspect:

- `SignalServiceKit/Util/ThreadUtil.swift`
- `SignalServiceKit/Messages/OutgoingMessagePreparer/PreparedOutgoingMessage.swift`

### 6. Main-Thread Collection-View Landing Cost

After a load completes off-main, `CVLoadCoordinator` lands it on the main thread.
Landing calls `collectionView.layoutIfNeeded()`, captures scroll continuity,
updates navigation and banners, maybe performs batch updates, reloads cells, and
may scroll to bottom for a local outgoing message.

This is bounded by the loaded render window, but if the render window is near
500 complex items, or if the update becomes `reloadAll`, a low-end or loaded
device could stall. The issue report mentions app-wide unresponsiveness, which
sounds like either a main-thread stall here or synchronous database work on the
main thread before async enqueue.

Files to inspect:

- `Signal/ConversationView/ConversationViewController+CVC.swift`
- `Signal/ConversationView/ConversationCollectionView.swift`
- `Signal/ConversationView/ConversationViewLayout.swift`

## Suggested Next Investigation

For this issue, I would instrument rather than guess:

- Log duration and row-count summaries for each send-time write transaction:
  message prepare, message job enqueue, draft clear, send-state transitions, and
  send-success/failure.
- Log whether each CVC update after Send is `minor`, `diff`, `reloadAll`, or
  reset/reload-without-caches.
- Log how many cursor rows `MessageLoader.fetchDisplayUnits` consumes versus how
  many display units it returns.
- Log when `DatabaseChangeObserver` emits `changeTooLarge`.
- Use a local test fixture with a 100k-message thread and synthetic suffixes:
  normal text messages, hidden story replies, edit-history rows, non-bumping
  system events, and long collapsible event runs.

## Added Opt-In Performance Harness

I added opt-in XCTest performance coverage in
`Signal/test/ViewControllers/MessageLoaderTest.swift`. These tests are skipped
unless `SIGNAL_ENABLE_CONVERSATION_PERF_TESTS=1` is present, because the default
fixtures are intentionally large.

Covered scenarios:

- `test_performance_sendPersistence_inLongConversation`: seeds a long
  conversation, then measures `ThreadUtil.enqueueMessage` through persistence
  completion.
- `test_performance_scrollThroughUnreadWindow_withUnreadMarker` and
  `test_performance_scrollThroughUnreadWindow_withoutUnreadMarker`: compare
  `MessageLoader` paging through the unread window versus the same window with
  no unread marker.
- `test_performance_markManyUnreadsRead_inLargeConversation`: seeds a large
  conversation with an unread tail, then measures `TSThread.markAllAsRead`.

Useful environment knobs:

- `SIGNAL_PERF_LONG_THREAD_MESSAGES`, default `100000`
- `SIGNAL_PERF_UNREAD_THREAD_MESSAGES`, default `10000`
- `SIGNAL_PERF_UNREAD_MESSAGES`, default `250`
- `SIGNAL_PERF_UNREAD_SCROLL_PAGES`, default `8`
- `SIGNAL_PERF_MEASURE_ITERATIONS`, default `5` for most tests and `3` for the
  long send-persistence test

I also added `.github/workflows/conversation-perf.yml` for the cheapest
macOS-runner approach. It is manually triggered from the GitHub Actions UI and
defaults to the standard `macos-26` runner, which should be free on public forks.
If the Signal build does not fit on the standard runner, rerun it with
`macos-26-intel` or `macos-26-xlarge`; the xlarge runner is more likely to build
comfortably but can cost money.

My highest-confidence hypotheses are the observer reset fallback and repeated
post-send reloads interacting with expensive main-thread layout. The pure
conversation loader is designed to avoid full-thread scaling, so any repro that
shows a 10-45 second stall should be checked for a path that breaks that bounded
window assumption or rebuilds expensive per-item state without caches.
