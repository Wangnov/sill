import SwiftUI
import UIKit
import UserNotifications

/// A small entry point usable on the connect screen and inside the streaming Settings panel.
/// Presentation belongs to this window; the history and permission preference belong to the App.
struct NotificationInboxButton: View {
    @ObservedObject var inbox: NotificationInbox
    @Environment(\.scenePhase) private var scenePhase
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 8) {
                Label("Notifications", systemImage: "bell")
                if inbox.unreadCount > 0 {
                    Text(inbox.unreadCount, format: .number)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.16), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open notifications mirrored from your paired Macs.")
        .sheet(isPresented: $presented) {
            NotificationInboxView(inbox: inbox)
                .presentationDetents([.medium, .large])
        }
        .onAppear { openRequestedInbox() }
        .onChange(of: inbox.presentationRequest) { _, _ in openRequestedInbox() }
        .onChange(of: scenePhase) { _, _ in openRequestedInbox() }
    }

    private func openRequestedInbox() {
        guard scenePhase == .active, inbox.consumePresentationRequest() else { return }
        presented = true
    }
}

struct NotificationInboxView: View {
    @ObservedObject var inbox: NotificationInbox
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Mirror Mac Notifications", isOn: Binding(get: { inbox.enabled }, set: inbox.setEnabled))
                    if inbox.enabled {
                        permissionStatus
                    }
                    if let problem = inbox.persistenceProblem {
                        Text(problem).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Notifications are displayed by Sill. The source app’s icon appears in this inbox; it cannot replace Sill’s icon in system notifications.")
                }
                if inbox.entries.isEmpty {
                    Section {
                        ContentUnavailableView("No Mac Notifications", systemImage: "bell.slash",
                                               description: Text("Enable mirroring here and on your Mac. Pair and connect once to register this device."))
                    }
                } else {
                    Section {
                        ForEach(inbox.entries) { entry in
                            row(entry)
                        }
                    } footer: {
                        Text("Notification history stays on this device. Connect to your paired Mac to recover notifications missed while Sill was away. Clearing this inbox keeps its place in your Mac’s history.")
                    }
                }
            }
            .navigationTitle("Notifications")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !inbox.entries.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear Inbox", role: .destructive) { inbox.clearHistory() }
                    }
                }
            }
            .onAppear { inbox.markAllRead() }
        }
    }

    @ViewBuilder private var permissionStatus: some View {
        switch inbox.authorization {
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow notifications for Sill in iOS Settings to receive alerts while Sill is in the background.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Notification Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .notDetermined:
            Text("Choose whether Sill may show notification alerts when iOS asks.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        default:
            if let problem = inbox.registrationProblem {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
            } else if inbox.pushRegistration != nil {
                Text("This device is ready to register for background alerts on its next paired connection. Your Mac also needs its own APNs provider configuration.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Live notifications work while connected. Background alerts need a push-enabled signed build and your Mac’s APNs provider configuration.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ entry: NotificationInbox.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon = inbox.icon(for: entry) {
                    Image(uiImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.event.appName).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(Date(timeIntervalSince1970: entry.event.date), style: .time)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !entry.event.title.isEmpty { Text(entry.event.title).font(.subheadline.weight(.medium)) }
                if let subtitle = entry.event.subtitle, !subtitle.isEmpty { Text(subtitle).font(.subheadline) }
                if !entry.event.body.isEmpty { Text(entry.event.body).font(.subheadline) }
                Text(entry.macName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
