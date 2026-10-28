import Foundation
import Darwin

enum NotificationSourceParser {
    // Verified on macOS 27: this application-category message carries the full record UUID,
    // unlike NotificationRecord's abbreviated uuid/ident fields. The text is private OS output,
    // not an Apple API contract: a changed/redacted template yields no attribution.
    private static let uuidPattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
    // Public-API cleanup of our fixture also verified a comma-space-separated UUID list,
    // followed by one bundle applying to the entire list. Validate the complete list first.
    private static let messagePattern = try! NSRegularExpression(pattern:
        #"\A_removeDelivered: Removing \[("# + uuidPattern + "(?:, " + uuidPattern
        + #")*)\] from ([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)\z"#)

    static func parse(message: String) -> NotificationSourceAttribution? {
        let sources = parseAll(message: message)
        return sources.count == 1 ? sources[0] : nil
    }

    static func parseAll(message: String) -> [NotificationSourceAttribution] {
        let text = message as NSString
        guard let match = messagePattern.firstMatch(in: message, range: NSRange(location: 0, length: text.length)) else { return [] }
        let identifiers = text.substring(with: match.range(at: 1)).components(separatedBy: ", ")
        let uuids = identifiers.compactMap(NotificationBannerParser.normalizedUUID)
        guard uuids.count == identifiers.count else { return [] }
        let bundle = text.substring(with: match.range(at: 2))
        guard bundle.utf8.count <= 255 else { return [] }
        return uuids.map { .init(uuid: $0, bundleID: bundle) }
    }

    static func parse(line: Data) -> NotificationSourceAttribution? {
        let sources = parseAll(line: line)
        return sources.count == 1 ? sources[0] : nil
    }

    static func parseAll(line: Data) -> [NotificationSourceAttribution] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["processImagePath"] as? String == "/usr/sbin/usernoted",
              object["subsystem"] as? String == "com.apple.unc",
              object["category"] as? String == "application",
              let message = object["eventMessage"] as? String else { return [] }
        return parseAll(message: message)
    }
}

/// Pipe reads may split a JSON record anywhere or return many records together. Only complete,
/// bounded lines reach the parser; an incomplete last line is deliberately discarded on EOF.
struct NotificationSourceLineDecoder {
    private var pending = Data()
    private var discarding = false
    private static let maximumLine = 64 * 1024

    mutating func append(_ data: Data) -> [NotificationSourceAttribution] {
        let pieces = data.split(separator: 10, omittingEmptySubsequences: false)
        var result: [NotificationSourceAttribution] = []
        for (index, piece) in pieces.enumerated() {
            if !discarding {
                if pending.count + piece.count > Self.maximumLine { pending.removeAll(); discarding = true }
                else { pending.append(contentsOf: piece) }
            }
            guard index < pieces.count - 1 else { continue }
            if !discarding {
                if pending.last == 13 { pending.removeLast() }
                result.append(contentsOf: NotificationSourceParser.parseAll(line: pending))
            }
            pending.removeAll(keepingCapacity: true)
            discarding = false
        }
        return result
    }
}

/// Optional best-effort source completion for AX-only notifications. This reads only a narrowly
/// selected metadata message; it never reads the notification DB, operates UI, or logs raw lines.
/// The removal/replacement message can arrive later than the banner, so it only fills identity.
@MainActor
final class NotificationSourceObserver {
    enum Status: Equatable { case running, stopped, unavailable }
    var onSource: ((NotificationSourceAttribution) -> Void)?
    var onStatus: ((Status) -> Void)?

    private var session: NotificationSourceLogSession?
    private var reading: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var enabled = false
    private var retryCount = 0
    private var generation = 0
    private var lastStatus: Status?
    private let retryDelays: [Double] = [2, 5, 15, 30]

    func start() {
        guard session == nil, retry == nil else { return }
        generation += 1
        enabled = true
        retryCount = 0
        launch()
    }

    func stop() {
        enabled = false
        generation += 1
        reading?.cancel()
        reading = nil
        retry?.cancel()
        retry = nil
        session?.stop()
        session = nil
        status(.stopped)
    }

    deinit { reading?.cancel(); retry?.cancel(); session?.stop() }

    private func launch() {
        guard enabled, session == nil else { return }
        let next = NotificationSourceLogSession()
        let id = next.id
        let started = next.started
        let current = generation
        session = next
        do {
            let events = try next.start()
            reading = Task { [weak self] in
                for await event in events {
                    guard let self, !Task.isCancelled, self.enabled,
                          self.generation == current, self.session?.id == id else { return }
                    switch event {
                    case .sources(let sources):
                        for source in sources {
                            guard self.enabled, self.generation == current else { return }
                            self.onSource?(source)
                        }
                    case .ended:
                        self.reading = nil
                        self.exited(id: id, started: started)
                        return
                    }
                }
            }
            status(.running)
        } catch {
            session = nil
            recover()
        }
    }

    private func exited(id: UUID, started: TimeInterval) {
        guard session?.id == id else { return }
        session = nil
        // A healthy long-lived stream gets a fresh recovery allowance. Fast repeated failures
        // stop after four retries, with an explicit unavailable status until start is requested.
        if ProcessInfo.processInfo.systemUptime - started >= 30 { retryCount = 0 }
        recover()
    }

    private func recover() {
        guard enabled else { return }
        let current = generation
        status(.unavailable)
        // A status callback can synchronously disable or restart the mirror.
        guard enabled, generation == current, session == nil, retry == nil else { return }
        guard retryCount < retryDelays.count else { return }
        let delay = retryDelays[retryCount]
        retryCount += 1
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == current else { return }
            self.retry = nil
            guard self.enabled else { return }
            self.launch()
        }
    }

    private func status(_ next: Status) {
        guard next != lastStatus else { return }
        lastStatus = next
        onStatus?(next)
    }
}

/// One owned child and one background blocking pipe reader. Process reaps its child through its
/// termination handler. Stopping never waits on the main actor; a stuck owned child is killed
/// after a short grace period, which also releases the reader's pipe and its retained session.
final class NotificationSourceLogSession: @unchecked Sendable {
    enum Event: Sendable { case sources([NotificationSourceAttribution]), ended }
    let id = UUID()
    let started = ProcessInfo.processInfo.systemUptime
    private let process = Process()
    private let pipe = Pipe()
    private let queue = DispatchQueue(label: "sill.notification-sources", qos: .utility)
    private let executableURL: URL
    private let arguments: [String]

    // Internal command injection is only for the offline short-line/EOF check; the observer
    // always constructs this with the real fixed command and narrow metadata predicate.
    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/log"), arguments: [String] =
        ["stream", "--style", "ndjson", "--level", "info", "--predicate",
            #"process == "usernoted" AND subsystem == "com.apple.unc" AND category == "application" AND eventMessage BEGINSWITH "_removeDelivered: Removing [""#]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    var isRunning: Bool { process.isRunning }

    func start() throws -> AsyncStream<Event> {
        let (events, continuation) = AsyncStream<Event>.makeStream()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let readerQueue = queue
        // The reader is enqueued before spawning, so even an immediately exiting child has its
        // last complete lines drained before the termination event reaches the same consumer.
        process.terminationHandler = { _ in
            readerQueue.async { continuation.yield(.ended); continuation.finish() }
        }
        queue.async { [self] in
            let handle = pipe.fileHandleForReading
            defer { try? handle.close() }
            var decoder = NotificationSourceLineDecoder()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                // One POSIX read returns any available pipe bytes; it does not wait for a 16 KB
                // buffer to fill or for EOF. A short metadata line must be delivered immediately.
                let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                let sources = decoder.append(Data(buffer.prefix(count)))
                if !sources.isEmpty { continuation.yield(.sources(sources)) }
            }
        }
        do { try process.run() }
        catch {
            try? pipe.fileHandleForWriting.close()
            readerQueue.async { continuation.finish() }
            throw error
        }
        try? pipe.fileHandleForWriting.close()
        return events
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let ownedProcess = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if ownedProcess.isRunning { kill(ownedProcess.processIdentifier, SIGKILL) }
        }
    }
}
