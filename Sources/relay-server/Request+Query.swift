import Hummingbird

/// Typed access to percent-encoded URL query parameters. Kept independent of
/// framework query API churn.
extension Request {
    func queryString(_ name: String) -> String? {
        var result: [String: String] = [:]
        guard let rawQuery = uri.query else { return nil }
        for pair in rawQuery.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first.flatMap({ String($0).removingPercentEncoding }),
                  !key.isEmpty else { continue }
            result[key] = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
        }
        return result[name]
    }

    func queryInt(_ name: String) -> Int64? {
        queryString(name).flatMap(Int64.init)
    }

    func queryBool(_ name: String) -> Bool? {
        switch queryString(name)?.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }
}
