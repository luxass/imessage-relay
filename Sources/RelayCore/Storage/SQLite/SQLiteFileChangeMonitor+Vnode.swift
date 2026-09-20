import Darwin
import Foundation

extension SQLiteFileChangeMonitor {
    final class VnodeMonitor: @unchecked Sendable {
        private struct FileIdentity: Equatable {
            let device: UInt64
            let inode: UInt64
        }

        private struct Registration {
            let source: DispatchSourceFileSystemObject
            let identity: FileIdentity
        }

        private let paths: [String]
        private let queue: DispatchQueue
        private let onChange: @Sendable () -> Void
        private var registrations: [String: Registration] = [:]
        private var isStopped = false

        init(
            paths: [String],
            queue: DispatchQueue,
            onChange: @escaping @Sendable () -> Void
        ) {
            self.paths = paths
            self.queue = queue
            self.onChange = onChange
        }

        func refresh() {
            guard !isStopped else { return }
            for path in paths {
                guard let currentIdentity = identity(of: path) else {
                    registrations.removeValue(forKey: path)?.source.cancel()
                    continue
                }
                if let registration = registrations[path] {
                    guard registration.identity != currentIdentity else { continue }
                    registration.source.cancel()
                    registrations[path] = nil
                }
                guard let registration = makeRegistration(path: path) else { continue }
                registrations[path] = registration
            }
        }

        func rebuild() {
            guard !isStopped else { return }
            cancelRegistrations()
            refresh()
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            cancelRegistrations()
        }

        private func cancelRegistrations() {
            for registration in registrations.values {
                registration.source.cancel()
            }
            registrations.removeAll()
        }

        private func makeRegistration(path: String) -> Registration? {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return nil }
            var information = stat()
            guard fstat(descriptor, &information) == 0,
                  information.st_mode & S_IFMT == S_IFREG else {
                close(descriptor)
                return nil
            }
            let identity = FileIdentity(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino)
            )
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.onChange()
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            return Registration(source: source, identity: identity)
        }

        private func identity(of path: String) -> FileIdentity? {
            var information = stat()
            guard lstat(path, &information) == 0,
                  information.st_mode & S_IFMT == S_IFREG else { return nil }
            return FileIdentity(
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino)
            )
        }
    }
}
