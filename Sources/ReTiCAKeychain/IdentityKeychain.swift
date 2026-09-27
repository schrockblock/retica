import Foundation
import ReTiCA

public struct IdentityKeychain {
    /// A generic-password item address. `accessGroup == nil` puts no `kSecAttrAccessGroup` in
    /// the query: reads and deletes then match the service in EVERY group the app can access.
    public struct Location: Sendable, Hashable {
        public var service: String
        public var accessGroup: String?
        public init(service: String, accessGroup: String?) {
            self.service = service
            self.accessGroup = accessGroup
        }
    }
}
