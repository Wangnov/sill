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

## Notification path

Both the Mac and iOS switches are off by default. On Mac, General contains **Notification
mirroring (experimental)**. On iOS, **Notifications** opens a shared inbox from the connect
screen or streaming settings. Enable both and establish a paired TLS connection once.

Live events and APNs registration are accepted only for authenticated, currently paired TLS
peers. A JSON device ID is not an identity. The Mac checks the pairing again before delivery.
Turning off the iOS global switch unregisters remote notifications even when the Mac is offline;
online connections also send an unsubscribe message. Forgetting just one offline Mac cannot
recall a token already stored on that Mac: remove that device's pairing on the Mac to stop its
future deliveries. Requests already handed to Apple cannot be recalled.

The experimental source reads text exposed by Notification Center through public Accessibility
APIs. It does not read Notification Center's database or private APIs. It ignores the initial
visible snapshot and deduplicates continuously visible content; identical text may be accepted
again after disappearing. Hidden, grouped, very brief or ambiguously attributed notifications
can be missed. This is not a complete system notification feed. Opening historical notification
groups can expose old content as new observations. Actual banner capture needs validation on
each supported macOS version before this can be presented as a reliable feature.

The test button creates a Sill event directly. It validates delivery, not system capture.
While connected, events populate the inbox without creating a duplicate local alert. The inbox
keeps the latest 100 events on device, deduplicates by Mac and event ID, and uses available source
app icons. Icons needed by that history are cached across launches; unknown icons use a
placeholder. System alerts remain attributed to Sill with Sill's icon. This implementation does
not use Communication Notifications to impersonate another app.

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
Apple over URLSession. Titles and bodies pass through Apple. Long text is shortened by the
final 4096-byte JSON budget without splitting Unicode grapheme clusters. The event ID remains
the same: a later complete live event upgrades an inbox summary without making it unread again.
There is no durable host notification archive or delivery retry service in this iteration.
APNs deliveries cleared from iOS Notification Center before Sill imports them may not enter
the inbox. A service extension, encrypted payload relay and source-app actions are separate work.

## Permission guidance

The Mac Permissions pane uses Sill's own icon, a short purpose statement, live permission
status and the existing buttons to request or open system settings. Once ready it offers
pairing directly. The reference was a read-only inspection of the installed ChatGPT/Codex
application's permission resources; its source, artwork and strings were not copied.

An ad hoc Mac rebuild changes its code identity and can invalidate Accessibility authorization.
Use a stable development signing identity for repeated device testing. Without one, authorize
the exact current build and keep that binary during the test; see [fork development](fork-development.md).

## Validation boundaries

Build and pure-check commands remain in `.github/workflows/ci.yml`; the new
`Tests/checks/background-session` suite checks intent persistence, source selection and balanced
input release. Synthetic socket acceptance can verify per-viewer pause, all-viewer idle,
parameters/keyframe/audio resume, bounded connection retention and reconnect without a device.
These checks do not replace iOS lifecycle testing on a signed fork build, real APNs delivery,
or actual Notification Center capture. Record those three independently.

Platform references: [iOS background limits](https://developer.apple.com/forums/thread/685525),
[APNs server setup](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server),
[APNs payload limits](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
[unregistering remote notifications](https://developer.apple.com/documentation/uikit/uiapplication/unregisterforremotenotifications()).
