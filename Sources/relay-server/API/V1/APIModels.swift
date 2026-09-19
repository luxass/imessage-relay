import Foundation
import Hummingbird
import NIOCore
import RelayCore

func jsonResponse<Value: Encodable>(
    _ value: Value,
    status: HTTPResponse.Status = .ok,
    requestID: RelayCore.RequestID
) throws -> Response {
    let data = try RelayJSON.encoder.encode(value)
    return Response(
        status: status,
        headers: [
            .contentType: "application/json; charset=utf-8",
            .init("x-request-id")!: requestID.rawValue,
        ],
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
    )
}

enum V1Query {
    static func string(_ request: Request, _ name: String) -> String? {
        guard let query = request.uri.query else { return nil }
        for component in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = pair.first,
                  formDecode(rawName) == name else {
                continue
            }
            return pair.count == 2 ? formDecode(pair[1]) : ""
        }
        return nil
    }

    private static func formDecode(_ value: some StringProtocol) -> String {
        let formValue = String(value).replacingOccurrences(of: "+", with: " ")
        return formValue.removingPercentEncoding ?? formValue
    }

    static func limit(_ request: Request, default fallback: Int) throws -> Int {
        guard let raw = string(request, "limit") else { return fallback }
        guard let value = Int(raw), (1...200).contains(value) else {
            throw APIHTTPError(
                status: .badRequest,
                code: .invalidRequest,
                message: "The limit query parameter must be between 1 and 200.",
                fieldDetails: [APIFieldError(field: "limit", message: "Enter an integer from 1 through 200.")]
            )
        }
        return value
    }

    static func bool(_ request: Request, _ name: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = string(request, name)?.lowercased() else { return fallback }
        switch raw {
        case "true", "1": return true
        case "false", "0": return false
        default:
            throw APIHTTPError(
                status: .badRequest,
                code: .invalidRequest,
                message: "The \(name) query parameter must be true or false.",
                fieldDetails: [APIFieldError(field: name, message: "Enter true or false.")]
            )
        }
    }

    static func cursor(_ request: Request) throws -> Cursor? {
        guard let raw = string(request, "cursor") else { return nil }
        do {
            return try Cursor(validating: raw)
        } catch {
            throw APIHTTPError(
                status: .badRequest,
                code: .invalidCursor,
                message: "The cursor is invalid."
            )
        }
    }
}

func pathValue(_ name: String, context: RelayRequestContext) throws -> String {
    guard let encoded = context.parameters.get(name, as: String.self),
          let value = encoded.removingPercentEncoding,
          !value.isEmpty else {
        throw APIHTTPError(
            status: .badRequest,
            code: .invalidRequest,
            message: "The \(name) path parameter is invalid."
        )
    }
    return value
}
