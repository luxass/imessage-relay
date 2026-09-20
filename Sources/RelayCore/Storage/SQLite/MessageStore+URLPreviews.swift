import Foundation

extension SQLiteMessageStore {
    // Within a same-sender preview run, the oldest URL-bearing record is the
    // logical message. Newer previews attach to it; older URL-less previews
    // remain standalone. A sender change or a non-preview ends the run.
    struct URLPreviewGroup {
        let newest: Record
        var root: Record?

        init(newest: Record) {
            self.newest = newest
            self.root = containsURL(newest.message.text) ? newest : nil
        }

        mutating func appendOlder(_ record: Record) -> Bool {
            guard sameSender(newest, record),
                  isURLPreview(record) || containsURL(record.message.text) else { return false }
            if containsURL(record.message.text) { root = record }
            return true
        }

        var logicalRoot: Record? {
            guard var root else { return nil }
            if root.row.rowID != newest.row.rowID { attachURLPreview(newest, to: &root) }
            return root
        }

        func resolvedRecords(in records: ArraySlice<Record>) -> [Record] {
            guard let root = logicalRoot,
                  let index = records.firstIndex(where: { $0.row.rowID == root.row.rowID }) else {
                return Array(records)
            }
            return [root] + records.suffix(from: index + 1)
        }
    }

    static func coalesceURLPreviews(_ records: [Record]) -> [Record] {
        coalescedPreviewWindow(records, hasMore: false).records
    }

    static func coalescedPreviewWindow(
        _ records: [Record],
        hasMore: Bool
    ) -> (records: [Record], pending: URLPreviewGroup?) {
        var logical: [Record] = []
        var index = 0
        while index < records.count {
            guard isURLPreview(records[index]) else {
                logical.append(records[index])
                index += 1
                continue
            }
            var group = URLPreviewGroup(newest: records[index])
            var end = index + 1
            while end < records.count, group.appendOlder(records[end]) {
                end += 1
                if !isURLPreview(records[end - 1]) { break }
            }
            if end == records.count, hasMore, isURLPreview(records[end - 1]) {
                return (logical, group)
            }
            logical.append(contentsOf: group.resolvedRecords(in: records[index..<end]))
            index = end
        }
        return (logical, nil)
    }

    static func isURLPreview(_ record: Record) -> Bool {
        record.row.balloonBundleID == "com.apple.messages.URLBalloonProvider"
    }

    static func sameSender(_ lhs: Record, _ rhs: Record) -> Bool {
        lhs.row.isFromMe == rhs.row.isFromMe && lhs.row.handle == rhs.row.handle
    }

    static func attachURLPreview(_ preview: Record, to message: inout Record) {
        message.message.urlPreview = URLPreview(
            messageID: preview.message.id,
            providerGUID: preview.row.guid,
            balloonBundleID: "com.apple.messages.URLBalloonProvider",
            createdAt: preview.message.createdAt
        )
    }

    static func containsURL(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.localizedCaseInsensitiveContains("https://")
            || text.localizedCaseInsensitiveContains("http://")
    }
}
