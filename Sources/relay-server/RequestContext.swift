import Hummingbird
import HummingbirdRouter

struct RelayRequestContext: RequestContext, RouterRequestContext {
    var coreContext: CoreRequestContextStorage
    var routerContext: RouterBuilderContext

    /// Bound JSON and form decoding before a controller sees the request.
    var maxUploadSize: Int { 1024 * 1024 }

    init(source: Source) {
        coreContext = .init(source: source)
        routerContext = .init()
    }
}
