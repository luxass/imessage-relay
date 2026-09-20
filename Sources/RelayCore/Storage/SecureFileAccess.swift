import Darwin
import Foundation

struct OpenedRegularFile {
    let descriptor: Int32
    let byteCount: Int64
    let identity: OpenFileIdentity
}

func openRegularFile(path: String, within rootDirectory: URL) -> OpenedRegularFile? {
    let rootPath = normalizedTrustedSystemAlias(rootDirectory.standardizedFileURL.path)
    let rootComponents = (rootPath as NSString).pathComponents
    let expandedPath = normalizedTrustedSystemAlias((path as NSString).expandingTildeInPath)
    let fileComponents = (expandedPath as NSString).pathComponents
    guard expandedPath.hasPrefix("/"),
          !fileComponents.contains("."),
          !fileComponents.contains(".."),
          fileComponents.count > rootComponents.count,
          fileComponents.prefix(rootComponents.count).elementsEqual(rootComponents),
          var directoryDescriptor = openDirectoryWithoutSymlinks(rootPath) else {
        return nil
    }
    defer { close(directoryDescriptor) }

    let relativeComponents = fileComponents.dropFirst(rootComponents.count)
    for component in relativeComponents.dropLast() {
        let next = openat(
            directoryDescriptor,
            component,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard next >= 0 else { return nil }
        close(directoryDescriptor)
        directoryDescriptor = next
    }
    guard let filename = relativeComponents.last else { return nil }
    let descriptor = openat(
        directoryDescriptor,
        filename,
        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return nil }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG,
          status.st_nlink == 1,
          status.st_size >= 0 else {
        close(descriptor)
        return nil
    }
    return OpenedRegularFile(
        descriptor: descriptor,
        byteCount: status.st_size,
        identity: OpenFileIdentity(status)
    )
}

func readRegularFile(path: String, within rootDirectory: URL, maximumBytes: Int) -> Data? {
    guard maximumBytes >= 0,
          let opened = openRegularFile(path: path, within: rootDirectory),
          opened.byteCount <= maximumBytes else { return nil }
    defer { close(opened.descriptor) }
    var data = Data(count: Int(opened.byteCount))
    var offset = 0
    while offset < data.count {
        let readCount = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return pread(
                opened.descriptor,
                baseAddress.advanced(by: offset),
                bytes.count - offset,
                Int64(offset)
            )
        }
        guard readCount > 0 else { return nil }
        offset += readCount
    }
    var status = stat()
    guard fstat(opened.descriptor, &status) == 0,
          OpenFileIdentity(status) == opened.identity else { return nil }
    return data
}

func openDirectoryWithoutSymlinks(_ path: String) -> Int32? {
    let path = normalizedTrustedSystemAlias(path)
    let components = (path as NSString).pathComponents
    guard path.hasPrefix("/"),
          !components.contains("."),
          !components.contains("..") else { return nil }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    for component in components where component != "/" && !component.isEmpty {
        let next = openat(
            descriptor,
            component,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard next >= 0 else {
            close(descriptor)
            return nil
        }
        close(descriptor)
        descriptor = next
    }
    return descriptor
}

private func normalizedTrustedSystemAlias(_ path: String) -> String {
    for (alias, canonical) in [("/tmp", "/private/tmp"), ("/var", "/private/var"), ("/etc", "/private/etc")] {
        if path == alias { return canonical }
        if path.hasPrefix(alias + "/") { return canonical + path.dropFirst(alias.count) }
    }
    return path
}
