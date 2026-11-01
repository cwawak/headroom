import Foundation
import CoreServices

/// One shared FSEvents stream across every provider root, coalesced by the
/// stream's own latency window and an internal debouncing/rate-limiting engine.
/// Cheaper and quieter than a poll loop or a watcher per provider, and protected
/// against denial-of-service event floods.
final class FileWatcher {

    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: CFTimeInterval
    private let onChange: () -> Void
    internal let queue: DispatchQueue

    // Rate limiting & debouncing state (accessed exclusively on `queue`)
    private let debounceInterval: TimeInterval
    private let maxDeferralInterval: TimeInterval
    private var debounceWorkItem: DispatchWorkItem?
    private var firstEventTime: Date?
    private var lastFireTime: Date = .distantPast

    init(
        roots: [URL],
        latency: CFTimeInterval = 1.0,
        debounceInterval: TimeInterval = 0.5,
        maxDeferralInterval: TimeInterval = 3.0,
        queue: DispatchQueue = DispatchQueue(label: "com.headroom.fsevents", qos: .utility),
        onChange: @escaping () -> Void
    ) {
        self.paths = roots.map(\.path)
        self.latency = latency
        self.debounceInterval = debounceInterval
        self.maxDeferralInterval = maxDeferralInterval
        self.queue = queue
        self.onChange = onChange
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleEvent()
        }

        // Note: kFSEventStreamCreateFlagNoDefer is deliberately omitted.
        // Allowing the OS to defer and coalesce filesystem events within the latency
        // window mitigates event flooding at the kernel/daemon boundary.
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            UInt32(kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// Internal event handling called on `queue`. Can also be invoked directly in unit tests.
    func handleEvent(now: Date = Date()) {
        dispatchPrecondition(condition: .onQueue(queue))

        if firstEventTime == nil {
            firstEventTime = now
        }

        debounceWorkItem?.cancel()

        let timeSinceFirst = now.timeIntervalSince(firstEventTime ?? now)
        let timeSinceLastFire = now.timeIntervalSince(lastFireTime)

        // If events have been arriving continuously past the maximum deferral limit,
        // or if enough time has elapsed since the last fire, trigger immediately.
        if timeSinceFirst >= maxDeferralInterval && timeSinceLastFire >= debounceInterval {
            fire(now: now)
            return
        }

        // Otherwise, schedule debounced fire.
        let remainingToMax = max(0.0, maxDeferralInterval - timeSinceFirst)
        let delay = min(debounceInterval, remainingToMax)

        let work = DispatchWorkItem { [weak self] in
            self?.fire(now: Date())
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fire(now: Date) {
        dispatchPrecondition(condition: .onQueue(queue))
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        firstEventTime = nil
        lastFireTime = now
        onChange()
    }

    func stop() {
        queue.sync {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            firstEventTime = nil
        }

        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
