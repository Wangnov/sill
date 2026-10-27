import AppKit
import SwiftUI
import SillHostCore

/// Embedded in General's existing Form. Provider settings belong to this Mac's owner; no
/// device message can turn on observation or supply a private key. All switches start off.
struct NotificationMirroringSection: View {
    @Bindable var mirror: NotificationMirror
    var allowAccessibility: () -> Void = {}

    var body: some View {
        Section {
            Toggle("Mirror Mac notifications", isOn: $mirror.enabled)
            Text(mirror.collectorStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if mirror.enabled {
                HStack {
                    Button("Accessibility Settings…", action: allowAccessibility)
                    Button("Send Test Notification") { mirror.sendTestNotification() }
                }
            }
            Toggle("Deliver iOS alerts through APNs", isOn: $mirror.pushEnabled)
                .disabled(!mirror.enabled)
            if mirror.pushEnabled {
                TextField("Apple Team ID", text: $mirror.apns.teamID)
                    .autocorrectionDisabled()
                TextField("APNs Key ID", text: $mirror.apns.keyID)
                    .autocorrectionDisabled()
                TextField("iOS app topic (bundle ID)", text: $mirror.apns.topic)
                    .autocorrectionDisabled()
                Picker("APNs environment", selection: $mirror.apns.environment) {
                    Text("Sandbox (development build)").tag("sandbox")
                    Text("Production (distribution build)").tag("production")
                }
                HStack {
                    TextField("External .p8 private-key path", text: $mirror.apns.keyPath)
                        .autocorrectionDisabled()
                    Button("Choose…", action: choosePrivateKey)
                }
                LabeledContent("Registered paired devices") { Text("\(mirror.registeredDeviceCount)") }
            }
            Text(mirror.deliveryStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Notification mirroring (experimental)")
        } footer: {
            Text("Reads newly observed text that Notification Center exposes through Accessibility. Hidden, grouped or brief banners can be missed; this is not a complete Mac notification feed. The test button checks the delivery path without requiring a Mac banner. Connected devices receive an inbox item. Background iOS alerts require a signed iOS build with Push Notifications, notification permission, and matching APNs topic and environment. APNs sends the mirrored title and body through Apple. Keep the .p8 file outside the app and repository; Sill stores only its path.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose your external APNs .p8 key")
        panel.message = String(localized: "The file stays here. Sill stores its path and reads it when signing APNs requests.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mirror.apns.keyPath = url.path
    }
}
