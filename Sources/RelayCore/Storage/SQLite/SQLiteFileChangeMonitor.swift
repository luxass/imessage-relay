import Foundation

final class SQLiteFileChangeMonitor: @unchecked Sendable {
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "imessage-relay.sqlite-file-watch", qos: .utility)
    private let watchedPaths: [String]
    private let directoryPath: String

    private var pendingNotification: DispatchWorkItem?
    private var needsFollowUpNotification = false
    private var isStarted = false
    private var isStopped = false

    private lazy var vnodeMonitor = VnodeMonitor(
        paths: watchedPaths,
        queue: queue
    ) { [weak self] in
        self?.handleVnodeChange()
    }

    private lazy var directoryMonitor = DirectoryMonitor(
        directoryPath: directoryPath,
        watchedPaths: watchedPaths,
        queue: queue
    ) { [weak self] notice in
        self?.handleDirectoryNotice(notice)
    }

    init(
        path: String,
        debounceInterval: TimeInterval = 0.1,
        onChange: @escaping @Sendable () -> Void
    ) {
        let databasePath = URL(fileURLWithPath: path).standardizedFileURL.path
        watchedPaths = [databasePath, databasePath + "-wal", databasePath + "-shm"]
        directoryPath = URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .path
        self.debounceInterval = max(0, debounceInterval)
        self.onChange = onChange
    }

    func start() {
        queue.sync {
            guard !isStarted else { return }
            isStarted = true
            _ = directoryMonitor.start()
            vnodeMonitor.refresh()
        }
    }

    func reconcile() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            if !self.directoryMonitor.isRunning {
                _ = self.directoryMonitor.start()
            }
            self.vnodeMonitor.refresh()
            self.scheduleNotification()
        }
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            pendingNotification?.cancel()
            pendingNotification = nil
            needsFollowUpNotification = false
            vnodeMonitor.stop()
            directoryMonitor.stop()
        }
    }

    private func handleVnodeChange() {
        guard !isStopped else { return }
        vnodeMonitor.refresh()
        scheduleNotification()
    }

    private func handleDirectoryNotice(_ notice: DirectoryMonitor.Notice) {
        guard !isStopped else { return }
        if notice.requiresRescan {
            vnodeMonitor.rebuild()
        } else {
            vnodeMonitor.refresh()
        }
        scheduleNotification()
        guard notice.rootChanged else { return }
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.directoryMonitor.restart()
            self.vnodeMonitor.refresh()
        }
    }

    private func scheduleNotification() {
        guard !isStopped else { return }
        guard pendingNotification == nil else {
            needsFollowUpNotification = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.pendingNotification = nil
            let scheduleFollowUp = self.needsFollowUpNotification
            self.needsFollowUpNotification = false
            self.onChange()
            if scheduleFollowUp {
                self.scheduleNotification()
            }
        }
        pendingNotification = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
