import Hummingbird
import RelayCore

func withStoreErrorMapping<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as MessageStore.StoreError {
        if case .cannotOpen = error {
            throw HTTPError(.serviceUnavailable, message: error.description)
        }
        throw HTTPError(.internalServerError, message: error.description)
    }
}
