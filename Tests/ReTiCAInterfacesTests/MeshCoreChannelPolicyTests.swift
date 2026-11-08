import Testing
import Foundation
import MeshCoreKit
@testable import ReTiCAMeshCoreLive

private let keyK = Data(repeating: 0x4B, count: 16)
private let keyO = Data(repeating: 0x4F, count: 16)
private let keyR = Data(repeating: 0x52, count: 16)
private let zero = Data(count: 16)

private func slot(_ index: UInt8, _ name: String, _ secret: Data) -> MeshCoreChannel {
    MeshCoreChannel(index: index, name: name, secret: secret)
}

private func empty(_ index: UInt8) -> MeshCoreChannel { slot(index, "", zero) }

private let publicSlot = slot(0, "Public", Data(repeating: 0x01, count: 16))

private func plan(_ channels: [MeshCoreChannel], retired: [Data] = []) -> MeshCoreChannelPlan {
    MeshCoreChannelPolicy.plan(channels: channels, secret: keyK, retired: retired)
}

@Suite struct MeshCoreChannelPolicyTests {
    @Test func anExistingSlotWithOurKeyIsUsed() {
        #expect(plan([publicSlot, slot(1, "x", keyK)]) == MeshCoreChannelPlan(clears: [], outcome: .use(1)))
    }

    @Test func theFirstOfTwoMatchingSlotsIsUsed() {
        let channels = [publicSlot, empty(1), slot(2, "a", keyK), empty(3), slot(4, "b", keyK)]
        #expect(plan(channels) == MeshCoreChannelPlan(clears: [], outcome: .use(2)))
    }

    @Test func theFirstEmptySlotIsWritten() {
        #expect(plan([publicSlot, empty(1), empty(2)]) == MeshCoreChannelPlan(clears: [], outcome: .write(1)))
    }

    @Test func noSlotsMeansNoFreeSlot() {
        #expect(plan([]) == MeshCoreChannelPlan(clears: [], outcome: .noFreeSlot))
    }

    @Test func aFullRadioHasNoFreeSlot() {
        let channels = [publicSlot, slot(1, "A", keyO), slot(2, "B", keyO), slot(3, "C", keyO)]
        #expect(plan(channels) == MeshCoreChannelPlan(clears: [], outcome: .noFreeSlot))
    }

    @Test func aNamedSlotWithAZeroSecretIsNotEmpty() {
        let channels = [publicSlot, slot(1, "Friends", zero), slot(2, "", zero)]
        #expect(plan(channels) == MeshCoreChannelPlan(clears: [], outcome: .write(2)))
    }

    @Test func aBlankNamedSlotWithASecretIsNotEmpty() {
        #expect(plan([slot(1, "", keyO)]) == MeshCoreChannelPlan(clears: [], outcome: .noFreeSlot))
    }

    @Test func aSameNamedSlotWithAnotherSecretIsNotOurs() {
        #expect(plan([slot(1, "RNSTunnel", keyO)]) == MeshCoreChannelPlan(clears: [], outcome: .noFreeSlot))
    }

    @Test func everyRetiredSlotIsCleared() {
        let channels = [publicSlot, slot(1, "a", keyR), slot(2, "b", keyO), slot(3, "c", keyR)]
        let result = plan(channels, retired: [keyR])
        #expect(result.clears == [1, 3])
    }

    @Test func aClearedSlotCanTakeTheNewKey() {
        let channels = [publicSlot, slot(1, "a", keyO), slot(2, "b", keyR), slot(3, "c", keyO)]
        #expect(plan(channels, retired: [keyR]) == MeshCoreChannelPlan(clears: [2], outcome: .write(2)))
    }

    @Test func aRetiredKeyEqualToTheCurrentKeyIsNotCleared() {
        let channels = [publicSlot, slot(1, "a", keyK)]
        #expect(plan(channels, retired: [keyK]) == MeshCoreChannelPlan(clears: [], outcome: .use(1)))
    }

    private static let fixtures: [(channels: [MeshCoreChannel], retired: [Data])] = [
        ([], []),
        ([publicSlot, slot(1, "x", keyK)], []),
        ([publicSlot, empty(1), empty(2)], [keyR]),
        ([publicSlot, slot(1, "a", keyR), slot(2, "RNSTunnel", keyO), slot(3, "c", keyR)], [keyR]),
        ([publicSlot, slot(1, "a", keyR), slot(2, "RNSTunnel", keyO)], [keyR, keyK]),
        ([slot(1, "RNSTunnel", keyO), slot(2, "", keyO), slot(3, "Friends", zero)], [keyR]),
        ([publicSlot, slot(1, "a", keyK), slot(2, "b", keyR)], [keyR, keyK]),
        ([slot(0, "RNSTunnel", keyR), empty(1)], [keyR]),
    ]

    @Test(arguments: fixtures.indices)
    func nothingButRetiredSlotsIsEverCleared(_ i: Int) {
        let fixture = Self.fixtures[i]
        let result = plan(fixture.channels, retired: fixture.retired)
        let doomed = fixture.retired.filter { $0 != keyK }
        let allowed = Set(fixture.channels.filter { doomed.contains($0.secret) }.map(\.index))
        #expect(Set(result.clears).isSubset(of: allowed))
        #expect(allowed.isSubset(of: Set(result.clears)))
        if case let .write(index) = result.outcome {
            let target = fixture.channels.first { $0.index == index }
            #expect(target.map { MeshCoreChannelPolicy.isEmpty($0) || result.clears.contains(index) } == true)
        }
    }
}
