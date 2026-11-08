import Foundation
import MeshCoreKit

/// What the slot policy decided for one radio's channel list (spec Contract 2): which slots to
/// clear, then what to do about ours.
struct MeshCoreChannelPlan: Equatable {
    /// Indices of slots holding a retired key, in index order.
    var clears: [UInt8]
    var outcome: Outcome

    enum Outcome: Equatable {
        /// A slot already holds our key.
        case use(UInt8)
        /// Write our key to this empty (or about to be cleared) slot.
        case write(UInt8)
        /// Nothing to use and nothing free. Never overwrite a configured slot.
        case noFreeSlot
    }
}

/// The pure half of the channel slot policy. The adapter reads `channels()`, asks for a plan and
/// performs it.
enum MeshCoreChannelPolicy {
    /// What clearing a slot writes as its secret: 16 zero bytes.
    static let clearedSecret = Data(count: 16)

    /// Empty means an all-zero secret AND an empty name.
    static func isEmpty(_ channel: MeshCoreChannel) -> Bool {
        channel.name.isEmpty && channel.secret == clearedSecret
    }

    static func plan(channels: [MeshCoreChannel], secret: Data, retired: [Data]) -> MeshCoreChannelPlan {
        let sorted = channels.sorted { $0.index < $1.index }
        let doomed = retired.filter { $0 != secret }
        let clears = sorted.filter { doomed.contains($0.secret) }.map(\.index)
        if let ours = sorted.first(where: { $0.secret == secret }) {
            return MeshCoreChannelPlan(clears: clears, outcome: .use(ours.index))
        }
        if let free = sorted.first(where: { isEmpty($0) || clears.contains($0.index) }) {
            return MeshCoreChannelPlan(clears: clears, outcome: .write(free.index))
        }
        return MeshCoreChannelPlan(clears: clears, outcome: .noFreeSlot)
    }
}
