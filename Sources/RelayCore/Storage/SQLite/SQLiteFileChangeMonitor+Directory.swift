import CoreServices
import Darwin
import Foundation

extension SQLiteFileChangeMonitor {
    final class DirectoryMonitor: @unchecked Sendable {
        struct Notice: Sendable {
            let requiresRescan: Bool
            let rootChanged: Bool
        }

        private let directoryPath: String
        private let watchedPaths: Set<String>
        private let queue: DispatchQueue
        private let onNotice: @Sendable (Notice) -> Void
        private var stream: FSEventStreamRef?

        init(
            directoryPath: String,
            watchedPaths: [String],
            queue: DispatchQueue,
            onNotice: @escaping @Sendable (Notice) -> Void
        ) {
            self.directoryPath = URL(fileURLWithPath: directoryPath).standardizedFileURL.path
            self.watchedPaths = Set(watchedPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
            self.queue = queue
            self.onNotice = onNotice
        }

        var isRunning: Bool { stream != nil }

        @discardableResult
        func start() -> Bool {
            guard stream == nil else { return true }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                sqliteFSEventsCallback,
                &context,
                [directoryPath as CFString] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
                flags
            ) else { return false }

            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            return true
        }

        func restart() {
            stop()
            _ = start()
        }

        func stop() {
            guard let stream else { return }
            self.stream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }

        fileprivate func receive(
            paths: [String],
            flags: UnsafeBufferPointer<FSEventStreamEventFlags>,
            eventIDs: UnsafeBufferPointer<FSEventStreamEventId>
        ) {
            guard paths.count == flags.count,
                  flags.count == eventIDs.count else { return }

            var isRelevant = false
            var requiresRescan = false
            var rootChanged = false
            for index in paths.indices {
                let eventFlags = flags[index]
                let normalizedPath = URL(fileURLWithPath: paths[index]).standardizedFileURL.path
                if eventFlags & Self.recoveryFlags != 0 {
                    requiresRescan = true
                    isRelevant = true
                }
                if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                    rootChanged = true
                    isRelevant = true
                }
                if watchedPaths.contains(normalizedPath) {
                    isRelevant = true
                }
            }

            guard isRelevant else { return }
            onNotice(Notice(requiresRescan: requiresRescan, rootChanged: rootChanged))
        }

        private static let recoveryFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
        )
    }
}

private func sqliteFSEventsCallback(
    _: ConstFSEventStreamRef,
    _ callbackInfo: UnsafeMutableRawPointer?,
    _ numberOfEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let callbackInfo,
          let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    let monitor = Unmanaged<SQLiteFileChangeMonitor.DirectoryMonitor>
        .fromOpaque(callbackInfo)
        .takeUnretainedValue()
    monitor.receive(
        paths: paths,
        flags: UnsafeBufferPointer(start: eventFlags, count: numberOfEvents),
        eventIDs: UnsafeBufferPointer(start: eventIDs, count: numberOfEvents)
    )
}
