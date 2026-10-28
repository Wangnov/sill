import Foundation

/// A low-latency source candidate, not proof of full-UUID identity. Both sides can arrive first.
/// A prefix must name exactly one recent AX UUID and one app, with timestamps within two seconds.
/// Conflicts revoke candidates and remain remembered for the cache TTL; expiry itself never
/// revokes a source already stored by the caller. No notification text participates in matching.
struct NotificationArrivalMatcher {
    private struct Banner { let observedAt: TimeInterval; var seenAt: TimeInterval }
    private struct Arrival { let occurredAt: TimeInterval; var seenAt: TimeInterval }
    private struct Entry {
        var banners: [String: Banner] = [:]
        var arrivals: [String: Arrival] = [:]
        var emitted: Set<String> = []
        var ambiguousUntil: TimeInterval = 0
    }
    private var entries: [String: Entry] = [:]
    private let window: TimeInterval = 2
    private let ttl: TimeInterval = 10

    mutating func reset() { entries.removeAll(keepingCapacity: true) }

    mutating func receiveBanner(uuid: String, observedAt: TimeInterval, now: TimeInterval) -> [NotificationSourceAttribution] {
        guard now.isFinite, observedAt.isFinite, abs(now - observedAt) <= ttl,
              let uuid = NotificationBannerParser.normalizedUUID(uuid) else { return [] }
        prune(now: now)
        let prefix = String(uuid.prefix(8))
        var entry = entries[prefix] ?? Entry()
        if var first = entry.banners[uuid] {
            // AX layout/retry callbacks must not slide an old banner toward a later log event.
            first.seenAt = now
            entry.banners[uuid] = first
        } else { entry.banners[uuid] = Banner(observedAt: observedAt, seenAt: now) }
        let result = reconcile(&entry, now: now)
        entries[prefix] = entry
        return result
    }

    mutating func receiveArrival(_ observation: NotificationArrivalObservation, now: TimeInterval) -> [NotificationSourceAttribution] {
        let prefix = observation.uuidPrefix8.lowercased()
        guard now.isFinite, observation.occurredAt.isFinite, abs(now - observation.occurredAt) <= ttl,
              prefix.utf8.count == 8, prefix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !observation.bundleID.isEmpty else { return [] }
        prune(now: now)
        var entry = entries[prefix] ?? Entry()
        if var first = entry.arrivals[observation.bundleID] {
            // Delivering and Presenting describe one occurrence a few milliseconds apart.
            first.seenAt = now
            entry.arrivals[observation.bundleID] = first
        } else { entry.arrivals[observation.bundleID] = Arrival(occurredAt: observation.occurredAt, seenAt: now) }
        let result = reconcile(&entry, now: now)
        entries[prefix] = entry
        return result
    }

    private func reconcile(_ entry: inout Entry, now: TimeInterval) -> [NotificationSourceAttribution] {
        if entry.banners.count > 1 || entry.arrivals.count > 1 { entry.ambiguousUntil = now + ttl }
        if entry.ambiguousUntil > now {
            let withdrawals = entry.emitted.sorted().map { NotificationSourceAttribution(uuid: $0, bundleID: "", evidence: .ambiguous) }
            entry.emitted.removeAll()
            return withdrawals
        }
        guard entry.banners.count == 1, entry.arrivals.count == 1,
              let (uuid, banner) = entry.banners.first, let (bundle, arrival) = entry.arrivals.first,
              abs(banner.observedAt - arrival.occurredAt) <= window,
              entry.emitted.insert(uuid).inserted else { return [] }
        return [.init(uuid: uuid, bundleID: bundle, evidence: .arrival)]
    }

    private mutating func prune(now: TimeInterval) {
        for prefix in Array(entries.keys) {
            guard var entry = entries[prefix] else { continue }
            entry.banners = entry.banners.filter { now - $0.value.seenAt < ttl }
            entry.arrivals = entry.arrivals.filter { now - $0.value.seenAt < ttl }
            entry.emitted = entry.emitted.filter { entry.banners[$0] != nil }
            if entry.banners.isEmpty && entry.arrivals.isEmpty && entry.ambiguousUntil <= now { entries.removeValue(forKey: prefix) }
            else { entries[prefix] = entry }
        }
    }
}
