import Darwin
import Foundation

final class SQLiteFileChangeMonitor: @unchecked Sendable {
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Registration {
        let source: DispatchSourceFileSystemObject
        let identity: FileIdentity
    }

    private let databasePath: String
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "imessage-relay.sqlite-file-watch", qos: .utility)

    private var registrations: [String: Registration] = [:]
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingNotification: DispatchWorkItem?
    private var isStarted = false
    private var isStopped = false

    init(
        path: String,
        debounceInterval: TimeInterval = 0.1,
        onChange: @escaping @Sendable () -> Void
    ) {
        databasePath = path
        self.debounceInterval = max(0, debounceInterval)
        self.onChange = onChange
    }

    func start() {
        queue.sync {
            guard !isStarted else { return }
            isStarted = true
            refreshFileSources()
            installDirectorySource()
        }
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            pendingNotification?.cancel()
            pendingNotification = nil
            for registration in registrations.values {
                registration.source.cancel()
            }
            registrations.removeAll()
            directorySource?.cancel()
            directorySource = nil
        }
    }

    private var watchedPaths: [String] {
        [databasePath, databasePath + "-wal", databasePath + "-shm"]
    }

    private var directoryPath: String? {
        guard databasePath.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return path
    }

    private func refreshFileSources() {
        guard !isStopped else { return }
        for path in watchedPaths {
            guard let currentIdentity = identity(of: path) else {
                registrations.removeValue(forKey: path)?.source.cancel()
                continue
            }
            if let registration = registrations[path] {
                guard registration.identity != currentIdentity else { continue }
                registration.source.cancel()
                registrations[path] = nil
            }
            guard let source = makeFileSource(path: path) else { continue }
            registrations[path] = Registration(source: source, identity: currentIdentity)
        }
    }

    private func installDirectorySource() {
        guard directorySource == nil, let path = directoryPath else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.refreshFileSources()
            self?.scheduleNotification()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
    }

    private func makeFileSource(path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.refreshFileSources()
            self?.scheduleNotification()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleNotification() {
        guard !isStopped, pendingNotification == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.pendingNotification = nil
            self.onChange()
        }
        pendingNotification = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func identity(of path: String) -> FileIdentity? {
        var information = stat()
        guard stat(path, &information) == 0 else { return nil }
        return FileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }
}
