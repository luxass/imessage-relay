import Hummingbird
import HummingbirdOpenAPI
import OpenAPIKit
import RelayCore

extension MediaRoutes {
    static let uploadMediaTypes: [OpenAPI.ContentType] = [
        .anyImage, .anyVideo, .anyAudio, .anyText, .pdf, OpenAPI.ContentType(rawValue: "application/octet-stream")!,
    ]

    static let uploadEndpoint = JSONEndpoint<UploadMediaResponse>(
        method: .post, path: "/v1/media", operationID: "uploadMedia", summary: "Upload raw media bytes.",
        description: "Stores files outside Messages. The size limit defaults to 25 MiB and can be configured lower. "
            + "Filenames cannot contain path separators, controls, quotes, or semicolons. MIME types cannot contain parameters. "
            + "Images must decode within bounded dimensions, frame count, and total pixels. No multipart wrapper or base64 encoding.",
        tags: ["Media"],
        parameters: [.init(name: "X-Filename", location: .header, description: "Original filename, at most 255 UTF-8 bytes.",
                           required: true, schema: .string(minLength: 1, maxLength: 255))],
        requestBody: .binary(mediaTypes: uploadMediaTypes,
            description: "Nonempty raw file bytes using the file MIME type as Content-Type."),
        responses: V1OpenAPI.responses(success: .created, description: "Stored upload metadata and download URL.",
                                       errors: [.contentTooLarge, .unprocessableContent]),
        responseHeaders: V1OpenAPI.responseHeaders
    )

    static let getEndpoint = RawEndpoint(EndpointDefinition(
        method: .get, path: "/v1/media/:media_id", operationID: "getMedia", summary: "Read media metadata or download its bytes.",
        description: "Without download=true, returns JSON metadata. With download=true, streams the original file using its MIME type. "
            + "OpenAPI cannot fully select the response schema from a query value. The JSON metadata schema applies only to metadata mode. "
            + "A download with a JSON MIME type is still raw file content, not MediaReference. Filesystem paths are never exposed.",
        tags: ["Media"],
        parameters: [V1OpenAPI.identifier("media_id", type: MediaID.self),
                     V1OpenAPI.boolean("download", description: "Stream the original bytes instead of metadata.")],
        responses: [EndpointResponse(.ok, description: "MediaReference JSON, or raw bytes when download=true.", headers: [
            "Content-Disposition": .b(.init(schema: .string, description: "Attachment filename, present only for downloads.")),
        ]) { context in
            [.json: .b(.init(schema: try context.schema(for: MediaReference.self, direction: .response))),
             .any: .b(.init(schema: nil))]
        }] + V1OpenAPI.rawErrors([.badRequest, .notFound, .serviceUnavailable]),
        responseHeaders: V1OpenAPI.responseHeaders
    ))

    static var endpoints: [EndpointDefinition] { [uploadEndpoint.definition, getEndpoint.definition] }
}
