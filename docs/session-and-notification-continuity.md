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

The collector reads macOS's retained Notification Center SQLite store every two seconds, using
read-only access and the live database's normal WAL handling. It does not open or scrape the
Notification Center interface. Sill needs its own **Full Disk Access** authorization; the button
in General opens that System Settings pane. Allow the actual Sill build and restart it. The
Accessibility permission used for remote input does not authorize this database read.

The current adapter targets the private store schema verified on macOS 27, at
`~/Library/Group Containers/group.com.apple.usernoted/db2/db`. It reads stored delivery records
and supported plain-text title, subtitle and body fields, with the source application's bundle
identifier. It does not filter to the visible banner, an opened notification group or selected
source apps; Sill's own notifications are excluded to avoid a loop. Missing app names fall back
to their bundle IDs. Unsupported content is reported as skipped, without putting system blobs
or notification text in diagnostic logs. Read/access/schema failures remain failures and do not
advance the durable source observations. macOS updates may change this private format and
require an adapter update.

This can recover notifications retained by macOS while Sill was stopped, after the initial
baseline below. It cannot recover notifications macOS never stored, records already deleted
before Sill captured them, or records created and removed entirely between polls. It is not an
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

The first **successful** source snapshot establishes a persistent baseline. Existing records
are marked as seen without importing them into Sill's archive or sending historical alerts.
An empty successful snapshot also establishes that baseline. Failed reads or failed local
transactions do not establish or advance it. Normal restarts and settings changes preserve it.

After the baseline, a new retained delivery is saved to Sill's archive before it is eligible for
TLS synchronization or APNs. Source observations, the archived event and its registered-device
outbox entries commit in one SQLite transaction. If it fails, the source can be retried without
silently marking the event as synchronized. Delivery identity uses the system UUID plus its
delivery occurrence, rather than a maximum integer row ID or matching text. Separate deliveries
with identical text remain separate events. A body revision updates the same event ID and gets
a higher sequence; the archive keeps that event's latest revision. Source delivery time is
preserved in `date`; explicit test events use their creation time.

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

## Current native macOS acceptance

The current native macOS 27 run used the normal Sill app with Full Disk Access authorized for
Sill itself and an independent, real paired TLS fixture. The initial baseline had already been
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

## Validation boundaries

The repository includes separate checks for the distinct parts of this feature:

- `Tests/checks/background-session/run.sh`: session intent persistence, source selection and
  balanced input release.
- `Tests/checks/notification-store/run.sh`: the actual reader against synthetic private-schema
  fixtures, including live WAL records, delivered filtering, distinct delivery identities,
  revisions and store resets. This does not open the person's notification database.
- `Tests/checks/notification-history/run.sh`: atomic baseline/archive writes and rollback, restart
  idempotence, equal-text deliveries, body revisions, ordered replay, durable retry state,
  disabled/resume behavior, legacy JSON and offline APNs response classification.

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
