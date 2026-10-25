import Hummingbird
import HummingbirdRouter
import RelayCore

struct RelayRequestContext: RequestContext, RouterRequestContext {
    var coreContext: CoreRequestContextStorage
    var routerContext: RouterBuilderContext
    let requestID: RelayCore.RequestID

    init(source: Source) {
        coreContext = .init(source: source)
        routerContext = .init()
        requestID = RelayCore.RequestID.generate()
    }
}
