# Session and notification continuity (fork)

This fork separates watching a Mac from receiving its notifications. Backgrounding the iOS
app pauses media, while a saved per-window intent lets the app reconnect to the same paired
Mac and restore a suitable source when it becomes active again. It does not promise an
indefinitely running iOS socket.

## Session behavior

- A capable host accepts a per-connection media subscription. A paused viewer receives no new
  video, audio, thumbnails or pointer updates. Other viewers continue normally; when all are
  paused, capture and encoding stop. Pausing also releases that viewer's held keys.
- A paused socket has a 90-second grace period. Repeating pause does not extend it. Background
  time does not consume the iOS foreground reconnect budget.
- On returning, iOS checks a retained connection with a ping barrier before consuming media or
  selecting a source. A stale connection is discarded and redialed. The final catalog snapshot
  wins over old lists buffered while the app was suspended.
- Resume intent records the paired Mac, host launch ID and source. A saved window is restored
  only if it still exists in that host launch and the host has no active source. Another viewer's
  current selection wins. Explicit Disconnect or Forget clears the intent.
- Hosts without the capability use the existing disconnect/reconnect path. Older iOS clients
  remain active viewers because media subscriptions default to enabled.

The optional `WindowList.mediaSubscription` and `notificationMirroring` fields advertise
capability version 1. Fork messages use **200** (`mediaSubscription`), **201**
(`notificationSubscription`) and **202** (`mirroredNotification`); these deliberately avoid
upstream's allocated message numbers. Keep this fork allocation coordinated when rebasing.

## Notification source and permission

Both the Mac and iOS switches are off by default. On Mac, General contains **Notification
mirroring (experimental)**. On iOS, **Notifications** opens a shared inbox from the connect
screen or streaming settings. Enable both and establish a paired TLS connection once.

The collector combines two complementary sources. An Accessibility (AX) observer listens for
changes in the Notification Center interface and reads text from identifiable, visible notification
groups. Separately, it reads macOS's retained Notification Center SQLite store every two seconds,
using read-only access and the live database's normal WAL handling. The observer does not dismiss
notifications or change the interface; it uses bounded work on the callback's element or subtree,
not an idle full-tree poll. AX needs Sill's **Accessibility** authorization. The database needs
Sill's own **Full Disk Access** authorization; the button in General opens that System Settings
pane. Allow the actual Sill build and restart it. Accessibility does not authorize the database read.

The current adapter targets the private store schema verified on macOS 27, at
`~/Library/Group Containers/group.com.apple.usernoted/db2/db`. It reads stored delivery records
and supported plain-text title, subtitle and body fields, with the source application's bundle
identifier. It does not filter to the visible banner, an opened notification group or selected
source apps; the database reader excludes Sill's own notifications to avoid a loop. An AX-only
observation has no authoritative bundle ID, so that database exclusion cannot be applied to it.
Missing database app names fall back to their bundle IDs. Unsupported content is reported as
skipped, without putting system blobs
or notification text in diagnostic logs. Read/access/schema failures remain failures and do not
advance the durable source observations. macOS updates may change this private format and
require an adapter update.

AX can observe a visible banner before a retained record becomes readable, but only when the
system exposes a suitable group and content to the observer. Hidden previews, notifications that
never appear as observable banners, unsupported AX events or tree shapes, and short-lived or
overloaded observations may be missed or incomplete. The database can recover notifications
retained while Sill was stopped after the initial baseline below, including some without a visible
banner. It cannot recover notifications macOS never stored, records deleted before capture, or
records created and removed entirely between polls. Neither source nor their combination is an
OS-supported guarantee of every notification ever delivered.

Apple's documented [`UNUserNotificationCenter.current()`](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/current%28%29)
returns the calling app's notification center, and
[`getDeliveredNotifications`](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getdeliverednotifications%28completionhandler%3A%29)
lists that app's delivered notifications still in Notification Center. These APIs do not supply
the global Mac feed needed here. [Accessory Notifications](https://developer.apple.com/documentation/AccessoryNotifications)
documents iPhone-to-accessory forwarding and supports iPhone only, with its own eligibility
restrictions. This fork has not validated a global, real-time macOS notification channel from
an ordinary Full Disk Access helper. That is the current validation boundary, not a claim that
every alternative approach is impossible.

## Durable history and ordered synchronization

The first **successful database** snapshot establishes a persistent baseline. Existing records
are marked as seen without importing them into Sill's archive or sending historical alerts.
An empty successful snapshot also establishes that baseline. Failed reads or failed local
transactions do not establish or advance it. Normal restarts and settings changes preserve it.
An AX banner observed before that snapshot may already be archived; a uniquely matching record in
the first snapshot can enrich that event, while unrelated existing records remain baseline-only.

After the baseline, a new retained delivery is saved to Sill's archive before it is eligible for
TLS synchronization or APNs. A visible AX observation can also create an event immediately,
including before the database baseline. Source observations, the archived event and its
registered-device outbox entries commit in one SQLite transaction. A failed transaction does not
advance the durable source observation. Retained delivery identity uses the system UUID plus its
delivery occurrence, rather than a maximum integer row ID or matching text. Separate deliveries
with identical text remain separate events. A revision updates the same event ID and gets a higher
sequence; the archive keeps that event's latest revision. Database delivery time is preserved in
`date`; an AX-only event initially uses observation time, and explicit test events use creation time.

An AX group is eligible only when its entire identifier is a UUID in canonical or 32-hex form;
the normalized exact UUID is the alias, never text similarity or timing. AX alone supplies no
authoritative posting bundle ID or delivery timestamp. The initial event therefore has an empty
bundle ID and the neutral app name `Mac`; it may contain only the text visible in the AX tree.
When one matching database occurrence is identifiable, it keeps the AX event ID and supplies its
stored app identity, content and delivery time. Once bound, later AX callbacks cannot overwrite the
database event. If the database arrives first, its bound alias suppresses later AX observations.
Identical AX callbacks do not consume a new sequence; changed unbound content revises the same
event. A UUID reused at a different database delivery time remains a separate database occurrence.
If multiple occurrences with the same UUID are candidates in one snapshot, the collector does not
guess which one matches: their database IDs and the unbound AX event remain separate. Thus UUID
reuse, ambiguous matches and source visibility limits can still produce duplicates or missed events;
the alias is a conservative correlation, not a universal exactly-once guarantee. An accepted APNs
request for an event is not rearmed when the database enriches that same event.

AX-only events are archived and synchronized over paired TLS immediately, but do not create
APNs outbox work until their posting app is identified. The retained database is authoritative.
On the tested macOS 27 build, a narrow `usernoted` log stream provides two levels of evidence:

- `Delivering` and `Presenting` records carry an app bundle ID and eight-character UUID prefix.
  A candidate is emitted only when exactly one recent AX UUID and one app share that prefix,
  with occurrence timestamps within two seconds. The matcher retains observations for ten
  seconds, deduplicates both log forms, and clears its cache when the stream restarts. It does
  not compare message text or caller-supplied request IDs.
- Removal or replacement records carry the complete notification UUID:

```text
_removeDelivered: Removing [full-notification-UUID] from posting.bundle.id
```

The full UUID is the AX group identifier. Arrival candidates may immediately enter the APNs
outbox, without waiting for removal or the next database snapshot. This deliberately trades
certainty for latency: a prefix match is provisional, and an alert already handed to Apple
cannot be recalled if later evidence disagrees. Full-UUID evidence confirms or corrects the
same event; database metadata takes precedence over both. Attribution updates preserve the
archive ID, text and observed date, while a database binding can supply its delivery date.

If a prefix names multiple recent UUIDs or apps, the matcher withdraws emitted candidates.
Pending/retry work is suppressed until stronger evidence arrives. The stored withdrawal also
prevents a late candidate from reopening the push, including after a failed write is retried.
Conflicting full-UUID sources remain unassigned until the database resolves them. Accepted
pushes remain accepted through every correction. Metadata alone never creates message text.

Requiring an identified source prevents a Sill alert mirrored back from an iPhone from triggering
another Sill alert. Own Sill bundle IDs and configured/registered
push topics are excluded from background delivery; explicit test-button events are an exception.
Sending rechecks the current archive/outbox revision after waiting on any earlier request, so a
late source correction cannot pass the source gate using a stale batch. An accepted event stays
accepted across source corrections. Source icons use the existing cache or the exact bundle's
Launch Services registration, including development apps outside the applications directories.

These log messages are private OS output, not a supported Apple notification API. Their absence,
redaction or a changed format can leave the event unknown. The optional stream runs only while
mirroring is enabled, stops its own child on shutdown,
and reports failure after bounded retries. It does not read old logs on startup. An occurrence
missed by both identity sources stays in the live inbox without a guaranteed background alert or
source icon. Failed archive/source writes are retried every two seconds; a process exit during
persistent disk failure can still lose unwritten observations.

The Mac stores this decoded history in its own
`~/Library/Application Support/<current-bundle-id>/NotificationMirror/history.sqlite`.
Its directory has mode `0700` and the file `0600`. The archive contains notification text, source
observations and per-device push state; it does not retain the original system payload blobs,
push tokens or provider private keys. Clearing the system's Notification Center cannot delete
an already captured Sill event. History and pending events are not silently limited to the last
30, 100 or 200 records, and no automatic age/count pruning is implemented. Settings changes and
restarts preserve them.

Each archive has a stable `historyID` and positive, monotonically increasing `sequence` values.
A device's kind **201** subscription may carry optional `historyID` and `afterSequence` fields.
A matching history resumes after that sequence; a missing or different history ID replays the
current archive from its beginning. Kind **202** events carry optional `historyID` and `sequence`
fields, so older JSON clients remain compatible. Only the authenticated, currently paired TLS
subscriber receives its replay. Every connection uses one ordered archive drain for both replay
and newly captured events, in batches of at most 50 with a scheduler yield between batches.
A temporary local read failure retains the cursor and retries after five seconds. This batching
is not a network backpressure mechanism. No application-level acknowledgment message is added.

Turning off **Mirror Mac notifications** stops source collection, new TLS history sends and
APNs requests. It retains local history, pending push work and each connected subscriber's last
enqueued sequence. Turning it on wakes those ordered drains, so a later event cannot jump over
the saved backlog. Records retained by macOS during the pause can be collected after resuming.
Requests already handed to Apple or bytes already queued for a connection cannot be recalled.

On iOS, the shared inbox deduplicates by Mac and event ID and retains its history without a
100-entry cap. It saves inbox changes and the per-Mac TLS cursor atomically; only a successfully
saved cursor is sent on reconnect. A failed save leaves the previous saved cursor available for
replay. APNs import never advances that cursor: receiving push sequence 20 does not establish
that sequences 1–19 were synchronized. A later complete TLS event upgrades an APNs summary
without resetting its read state. Explicit **Clear History** retains the synchronization
checkpoint so reconnect does not restore the entries the person deliberately cleared. Forgetting
a Mac removes that Mac's local inbox and checkpoint. Available source app icons are cached across
launches; unknown icons use a placeholder. System alerts remain attributed to Sill with Sill's
icon; this implementation does not use Communication Notifications to impersonate another app.

TLS subscriptions and APNs registration are accepted only for authenticated, currently paired
peers. A JSON device ID is not an identity. TLS history does not require a push token or APNs
credentials. Before each APNs request, the Mac checks current pairing, registration revision,
provider generation, topic and environment. Turning off the iOS global switch
unregisters remote notifications even when the Mac is offline; online connections also send an
unsubscribe. Forgetting one offline Mac cannot recall a token already stored there: remove that
device's pairing on the Mac to stop its future deliveries.

The test button creates an event directly through the same durable archive path. It checks
history/delivery without requiring access to an actual Mac notification, and does not validate
system collection. While connected, events populate the inbox without scheduling a second local
alert on iOS.

## Background alerts and signing

Background alerts require APNs. For a personal fork, the user's Mac is the provider; no relay
service is required. The Mac must stay running and online. This is not a credential architecture
for distributing one shared provider key to other users.

1. In Apple's developer account, create your own explicit iOS App ID with Push Notifications.
   Select your team and a matching provisioning profile in the Sill iOS project. No upstream
   team is configured. Default fork bundle IDs are `local.sill.fork.ios.debug` and
   `local.sill.fork.ios`; change them to identifiers you control.
2. Debug uses the `development` APS entitlement and `sandbox` endpoint. Release uses
   `production` for both. `SillAPNSEnvironment` in Info.plist tells the registration code which
   environment to send. Keep these settings aligned with the installed provisioning profile.
3. In Mac General, enable APNs delivery and enter your Team ID, Key ID, iOS bundle ID (topic),
   explicit environment and the path to your external `.p8` key. The app saves the path and
   non-secret settings; it does not copy the key into the app, repository or logs.
4. Install that signed iOS build, enable mirroring, allow alerts and connect to this Mac. The
   official App Store/TestFlight client cannot register for this fork's APNs topic.
5. Send a test event with iOS foregrounded, backgrounded and locked. A successful APNs response
   means Apple accepted the request; verify visible arrival separately on the device.

The provider signs ES256 JWTs locally, caches them for 50 minutes, and sends alert requests to
Apple over URLSession. Titles and bodies pass through Apple. Only the APNs copy is shortened to
the final 4096-byte JSON budget without splitting Unicode grapheme clusters; the archive and TLS
copy retain the full supported text. APNs storage expiration is set to five minutes after each
request, which does not limit the lifetime of Sill's local history.

The durable outbox tracks each event separately for each registered paired fingerprint, without
storing its push token in the archive. Collection can retain pending work while APNs is disabled
or its provider settings do not match. Network failures, HTTP 429 and HTTP 5xx retry with delays
of 5, 15, 60, 300, 900 and 3600 seconds. A further temporary failure pauses automatic retries and
retains the event. Permanent failures also remain recorded instead of repeatedly sending in a
loop. Renewing a device registration or changing provider settings rearms failed/paused work.
A rejected invalid token withdraws only the current registration revision. An accepted request
is marked **accepted**, not “displayed”; a text revision of that same delivery does not rearm an
accepted alert. TLS history recovery remains independent of APNs acceptance and retries.

An APNs alert removed from iOS Notification Center before Sill imports it can still be recovered
from the Mac's archive on the next paired TLS synchronization, if Sill captured it. A service
extension, encrypted payload relay and source-app actions are separate work. No relay/helper
service or per-event client acknowledgment has been introduced.

## Permission guidance

The Mac Permissions pane uses Sill's own icon, a short purpose statement, live permission
status and the existing buttons to request or open system settings. Once ready it offers
pairing directly. The reference was a read-only inspection of the installed ChatGPT/Codex
application's permission resources; its source, artwork and strings were not copied.

An ad hoc Mac rebuild changes its code identity and may invalidate system authorizations. Use a
stable development signing identity for repeated testing. Without one, authorize the exact
current build for the required permissions, including Full Disk Access for notification capture,
and keep that binary during the test; see [fork development](fork-development.md). Sill opens
the system permission pane but does not grant itself access or change the system database.

## Earlier native macOS database-path checks

The following native macOS 27 run preceded the AX integration. It used the normal Sill app with
Full Disk Access authorized for Sill itself and an independent, real paired TLS fixture. The initial baseline had already been
established: Sill's archive contained **0** events and `source_seen` contained **26** observations.
This exercised the database capture and TLS path; reading text from an Accessibility window
alone was not treated as successful notification capture.

- A lifecycle fixture delivered **8** notifications, of which Sill captured **7**. One identifier
  was first delivered at **+3 seconds** and redelivered at **+9 seconds**. The first delivery's
  body was not captured. The cause remains undetermined.
- A separate burst of **40 independent deliveries** was received in full, with sequences
  **8–47**. Observed arrival delays within that batch ranged from **5.13 to 46.12 seconds**.
- After disconnecting and resuming with `afterSequence=7`, the fixture received those **40**
  archived events again. Their content and event IDs matched the original received events
  exactly.

These results verify durable replay for that captured burst, but do not establish complete or
immediate collection: the lifecycle run missed one delivery, and the burst had substantial
latency. The initial run did not locate the cause. The separate per-poll probe below narrows a
reproduced gap; it does not establish a root cause for every earlier latency measurement.

### Follow-up visibility and continuity probe

The following source-visibility and TLS timings were independently cross-checked. The probe used
normal Full Disk Access authorization and read the live store every **2 seconds**. All **21**
distinct reads completed with status **ok**, taking approximately **4–6 milliseconds** each.

The public notification fixture run `A57540AC-70EF-40F4-8E74-2837FE25921B` started at
**01:38:41.579 UTC**. Its repeated identifier was first delivered at **+3 seconds** and
redelivered at **+9.45 seconds**. The database probe first observed **6 delivered records** at
**01:38:56.901 UTC** (**+15.322 seconds**); the repeated identifier contained only its newer
body. No target records were observed at **+13.322 seconds**. A pending record was first present
with `delivered_date` null, remained null at **+21.323 seconds**, and first had a positive
delivery date at **01:39:04.901 UTC** (**+23.322 seconds**). The native Sill TLS path received
**7** events in this run, with observed delivery-to-receipt delays of **6.26–11.90 seconds**.
The first six reached TLS **0.578 seconds** after their first independent database observation;
the pending record reached TLS **0.943 seconds** after its first positive delivery date was
observed.

At the first sampled visibility of the delivered records, the first body was already absent.
Together with the successful, short reads and subsequent TLS timing, this locates this run's
main delay at the system's persisted notification view becoming readable. It does not identify
the daemon's internal commit/debounce algorithm, the exact physical disk commit time, or prove
why visibility was delayed. Two-second sampling also cannot exclude a short-lived intermediate
row between observations. Future investigations should retain per-poll status/duration and
source/local transaction timing to distinguish system visibility, collector scheduling, read
failures and local persistence delays in each run.

Separate native continuity checks passed after **restarting Sill**: resuming after sequence **7**
replayed the same **40** archived events with exact content and IDs. A connection established while Mac
mirroring was **off** received **zero** notification events during **15.7 seconds**; turning it
**on** recovered **10** events over that same connection. Those comprised **7** fixture events
and **3** other captured events whose bodies are not recorded here. These checks exercise the
disabled pause and ordered backlog drain without claiming complete or immediate source capture.

The actual iPhone fork and visible APNs delivery have not yet completed acceptance. This TLS
fixture does not establish foreground/background/locked behavior on a provisioned iPhone.

### Independent AX and database probe

In a separate local probe of eight controlled deliveries, the AX observations covered **7**,
including the original version of the repeated notification; the retained database observations
covered **7**, including the other simultaneously delivered twin. Correlating their exact UUIDs
gave a combined set of **8/8** for that fixture. This is a comparison of observations from two
independent probes, not an integrated Sill capture-to-iPhone or APNs test. It does not establish
complete capture for other notification layouts or operating conditions, exactly-once delivery,
or visible push presentation on a real device.

### Integrated native AX + database acceptance

The native Mac build from commit `66dcc31` was exercised on macOS 27 with its own Accessibility,
Full Disk Access and screen-capture permissions. The independent AX probe was stopped and its
permission removed. Both collector sources reported connected, and a disposable, genuinely paired
TLS client observed the production server. Notifications came from a separate app using public
UserNotifications APIs; Sill's test button was not used.

- Lifecycle run `9E9ADD71-08B8-45D9-8406-47935DC10EB2` preserved **8/8 delivery occurrences**,
  including the previously missed original of the replaced request. Seven arrived through AX;
  the database supplied the other simultaneous twin and enriched six existing AX IDs. Final TLS
  replay contained eight IDs. The original remained AX-only with unknown source and no APNs work.
- A 0.2-second observer of Sill's own archive first saw the seven AX events **0.258–1.119 seconds**
  after their public delivery timestamps. The DB-only twin took **20.606 seconds**. These are
  sampled observation delays, not exact SQLite commit times, and not all eight arrived instantly.
- Burst run `E15F76CB-8ADA-4D9A-9D3A-693A5CF4D1BB` delivered **40/40** through paired TLS.
  Its 80 frames comprised 40 initial AX events and 40 same-ID enrichments. Final text, sources and
  delivery dates matched the public sender snapshots. First TLS arrivals had a median delay of
  **136 milliseconds** on this local connection; source enrichment took **6.305–47.281 seconds**.
- After a normal restart of the same binary, resuming after sequence 85 returned **40/40** final
  burst events with every event field unchanged. Sequences 126–165 replaced the earlier versions
  86–125; this proves final-state recovery, not replay of every intermediate revision.

The temporary pairing, credentials and synthetic archive entries were removed afterward. Other
archive entries were verified unchanged. The sender's notification permission was restored off;
Sill's permissions and notification collection remained enabled. Notification display while
screen sharing remained allowed, because hidden banners cannot supply AX content. Both builds,
all 60 local check suites and the commit's CI passed. This run did not establish source-icon
delivery, an actual iPhone fork inbox, or visible background/locked APNs presentation.

### Arrival fast-path bridge acceptance

A separate 2026-10-28 lifecycle run exercised the production arrival parser, matcher and history
store while the previously authorized Mac app supplied AX events through its own archive. The
seven observed AX UUIDs all received arrival attribution first, in **3.1–95.8 milliseconds** from
their original AX observation time (median **63.9 ms**, including a 100 ms bridge poll). The
replaced original was attributed in **63.9 ms**, preserving its ID, text and observed date. One
other historical delivery was database-only and is outside this seven-event AX sample.

All seven events entered an isolated fake-recipient outbox; no APNs provider was connected. There
were no input/source write failures, and the owned log process stopped at exit. The new native
Mac build and signature verification passed; native integrated acceptance is still pending its
system authorization. This bridge timing is not a phone delivery measurement or a replacement
for the preceding full-UUID recovery measurements.

## Validation boundaries

### Exact source recovery acceptance

On 2026-10-28, macOS 27.0 (26A425) emitted an exact `_removeDelivered` line for a replaced
synthetic original that had never reached the retained store. A second run linked the production
source observer and history store into an isolated live harness. The still-authorized previous
Sill build supplied its real AX observations through a read-only view of Sill's own archive;
the harness never read the system notification database or called Accessibility itself.

That run imported seven AX events and recovered the replaced original's posting bundle from the
live log stream about 6.28 seconds after the AX observation. Its ID, body hash and observed date
were unchanged, and exactly one fake-recipient outbox entry was created. The log child was still
running when the callback arrived and was stopped when the harness ended. No APNs provider was
created. A separate fixture cleanup established the batch form: eleven full UUIDs, separated by
comma-space inside the brackets, share the bundle following `from`. The parser accepts that
entire validated list or none of it.

The new native Mac app builds and all 61 local check suites pass, including 41 source/pipe checks.
A subsequent batch live run received 26 source callbacks but imported no AX events after the Mac
locked; that run does not establish full capture coverage.

After unlocking and registering the frozen native build's own Accessibility and Full Disk Access,
commit `32d3385` completed an integrated run on the same Mac. All three collection channels reported
connected. The sender submitted nine requests representing eight historical deliveries and seven
final request IDs. Sill archived **8/8** distinct events: seven ultimately bound to database rows,
and the replaced original recovered from the exact log metadata, with **zero unknown sources**.
The original retained its ID, title, subtitle, body and observed date across source enrichment
(sequence 233 to 238); the read-only archive sampler observed the correction about **6.23 seconds**
after first observing the unknown event. It remained unbound to a database occurrence.

A disposable paired TLS client then received **8/8** final events, including that corrected original,
and eight valid **64 × 64 PNG** source-icon frames. The sender has no custom icon, so this verifies
registered-app icon lookup and transport, not visual fidelity for a distinctive app icon or iOS UI.
Replay is monotonic final-state recovery; its sequence gaps do not imply missing final events or
prove replay of every intermediate revision. No APNs provider or real iPhone participated.

The temporary pair, credentials, eight synthetic archive events and fixture source mappings were
removed. The other nineteen archive events retained identical IDs, sequences and payload hashes.
The original phone pair remained, and the test sender's notification permission and pairing-window
screen-sharing option were restored off. The frozen build stayed in use. The commit's
[CI run](https://github.com/Wangnov/sill/actions/runs/40640399733) passed all build/check steps,
including native Mac and arm64 iOS simulator builds; the separate mutation job was skipped.

The repository includes separate checks for the distinct parts of this feature:

- `Tests/checks/background-session/run.sh`: session intent persistence, source selection and
  balanced input release.
- `Tests/checks/notification-store/run.sh`: the actual reader against synthetic private-schema
  fixtures, including live WAL records, delivered filtering, distinct delivery identities,
  revisions and store resets. This does not open the person's notification database.
- `Tests/checks/notification-banner/run.sh`: offline parsing of AX UUID and text fixtures; it
  does not observe a live Accessibility tree or establish live capture coverage.
- `Tests/checks/notification-source/run.sh`: verified synthetic arrival/removal metadata,
  timestamp parsing, matching in either order, conflict withdrawal, cache expiry/reset, split
  pipe lines, immediate short-line delivery, and ordered delivery before EOF.
- `Tests/checks/notification-history/run.sh`: atomic baseline/archive writes and rollback, restart
  idempotence, exact UUID alias binding and ambiguity, equal-text deliveries, body revisions,
  evidence priority and migration, pending withdrawal retries, ordered replay, durable retry
  state, disabled/resume behavior, legacy JSON and offline APNs
  response classification. Synthetic alias checks do not establish live integrated capture.

Synthetic socket checks can verify per-viewer pause, all-viewer idle, media resume, bounded socket
retention and reconnect without a device. Successful builds, fixture checks and a read-only
inspection of this Mac's retained store establish different facts. The app's own Full Disk Access
permission was exercised in the native run above; the capture-to-phone path must still be
validated using the actual signed builds.

As of this implementation, no valid user-signed fork has completed real-device lifecycle,
notification capture-to-inbox, or foreground/background/locked APNs presentation acceptance.
Valid fork signing/provisioning and APNs credentials remain required for that work. Apple
acceptance is not proof of device display, and the system-store retention/schema limits above
remain even after those tests pass. Record device lifecycle, real capture and visible APNs
arrival independently; do not promote a test-button event or a simulator build into that result.

Platform references: [iOS background limits](https://developer.apple.com/forums/thread/685525),
[APNs server setup](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server),
[APNs payload limits](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
[unregistering remote notifications](https://developer.apple.com/documentation/uikit/uiapplication/unregisterforremotenotifications()).
