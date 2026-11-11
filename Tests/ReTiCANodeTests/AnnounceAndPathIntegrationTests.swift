import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Announces and path learning end to end, including across a restart.
//
// Real nodes on the simulated network of `MessagingWorld`. Nothing here seeds a path, an identity
// or a contact by hand: whatever a node knows it heard in an announce carried by the network, or
// was handed back at launch out of what an earlier process of the same node had heard. Each test
// then proves the knowledge is usable, by sending a message through it.

private let longText = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)

private func named(_ name: String) -> (inout LXMFNode.State) -> Void {
    { $0.displayName = name }
}

// MARK: - Through a relay

@Suite(.timeLimit(.minutes(5))) @MainActor struct AnnounceAndPathIntegrationTests {

    /// Two clients that only share a relay learn of each other from its rebroadcast.
    @Test func anAnnounceCrossesTheRelayAndMakesItsSenderReachable() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.uplink], configure: named("Alice"))
        let bob = world.messenger("bob", on: [.uplink], configure: named("Bob"))
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(alice, bob)

        #expect(bob.nameKnown(for: alice) == "Alice")
        #expect(alice.nameKnown(for: bob) == "Bob")
        #expect(bob.nextHop(to: alice) == relay.transportID, "the route goes through the relay")

        let sent = await bob.send("hello through the relay", to: alice)
        await world.advance(upTo: 30, until: { !alice.inbox.isEmpty })

        #expect(alice.inbox == [Received(content: "hello through the relay", from: bob.address,
                                         validated: true, method: .opportunistic)])
        _ = sent
        await world.shutDown()
    }

    /// KNOWN DEFECT (found by this suite, 2026-11-11): a ReTiCA relay forwards a single DATA packet
    /// but keeps no reverse-table entry for it, so the recipient's proof is dropped at the relay
    /// (`Transport.swift`, `.proof` consults only our own `pendingReceipts`; reference forwards it
    /// through `reverse_table`). The message arrives, the sender is never told, retries five times
    /// and reports it failed. Links are unaffected (they route by the link table). The other tests
    /// here therefore assert on arrival, not on the sender's confirmation of a short message.
    /// When the relay learns to route proofs this test fails as "known issue not recorded":
    /// delete the wrapper, and restore the confirmation assertions in this file.
    @Test func aShortMessageThroughTheRelayIsConfirmedToItsSender() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.uplink]), bob = world.messenger("bob", on: [.uplink])
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(alice, bob)

        let sent = await bob.send("did it arrive?", to: alice)
        await world.advance(upTo: 120, until: { !bob.outcomes(of: sent).isEmpty })

        #expect(alice.inbox.map(\.content) == ["did it arrive?"])
        withKnownIssue("a ReTiCA relay drops the proof of a single packet it forwarded") {
            #expect(bob.outcomes(of: sent) == [.confirmed(sent)])
        }
        await world.shutDown()
    }

    @Test func aLongMessageCrossesTheRelayOverADirectLink() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.uplink]), bob = world.messenger("bob", on: [.uplink])
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(alice, bob)

        let sent = await alice.send(longText, to: bob)
        await world.advance(upTo: 60, until: { !alice.outcomes(of: sent).isEmpty })

        #expect(bob.inbox == [Received(content: longText, from: alice.address, validated: true, method: .direct)])
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        await world.shutDown()
    }

    @Test func aRenamedPeerIsSeenUnderItsNewName() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.uplink], configure: named("Alice"))
        let bob = world.messenger("bob", on: [.uplink])
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(alice, bob)
        #expect(bob.nameKnown(for: alice) == "Alice")

        await alice.rename(to: "Alice Liddell")
        await world.advance(upTo: 60, until: { bob.nameKnown(for: alice) == "Alice Liddell" })

        #expect(bob.nameKnown(for: alice) == "Alice Liddell")
        await world.shutDown()
    }

    /// Bob arrives after Alice announced and while she is out of reach. Only the relay can tell him
    /// about her, out of the announce it heard.
    @Test func aLatecomerLearnsOfAPeerFromWhatTheRelayHeard() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.uplink], configure: named("Alice"))
        let bob = world.messenger("bob", on: [.uplink])
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(alice)
        await world.quiet()   // the relay has finished repeating her announce
        world.unplug(alice.port)

        await bob.comeOnline()
        await world.advance(seconds: 5)
        #expect(!bob.hasPath(to: alice), "bob was not there for the announce")

        await bob.lookUp(alice)
        await world.advance(upTo: 30, until: { bob.hasPath(to: alice) })
        #expect(bob.hasPath(to: alice))
        #expect(bob.nameKnown(for: alice) == "Alice")
        #expect(bob.nextHop(to: alice) == relay.transportID)

        // And the route is good once she is back.
        world.plug(alice.port)
        let sent = await bob.send("found you", to: alice)
        _ = sent
        await world.advance(upTo: 60, until: { !alice.inbox.isEmpty })
        #expect(alice.inbox.map(\.content) == ["found you"])
        await world.shutDown()
    }

    /// The app just sends; finding the route is the node's job.
    @Test func aLatecomerCanSimplySendToAPeerItNeverHeardAnnounce() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.uplink]), bob = world.messenger("bob", on: [.uplink])
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(alice)
        await bob.comeOnline()
        #expect(!bob.hasPath(to: alice))

        let sent = await bob.send("who are you?", to: alice)
        await world.advance(upTo: 120, until: { !alice.inbox.isEmpty })

        #expect(alice.inbox.map(\.content) == ["who are you?"])
        #expect(bob.hadToLookForRecipient(of: sent))
        await world.shutDown()
    }

    @Test func aSendToSomeoneNobodyHasEverHeardOfIsReportedFailed() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.uplink]), ghost = world.messenger("ghost", on: [.uplink])
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(alice)

        let sent = await alice.send("is anyone there?", to: ghost)
        await world.advance(upTo: 900, until: { !alice.outcomes(of: sent).isEmpty })

        #expect(alice.outcomes(of: sent) == [.failed(sent)])
        await world.shutDown()
    }
}

// MARK: - Across a restart

// The limit is generous on purpose: the propagation test takes about 15 s alone and several minutes
// when the whole package's tests run beside it.
@Suite(.timeLimit(.minutes(15))) @MainActor struct RestartIntegrationTests {

    /// Alice heard Bob, quit, and came back with what she had saved. Bob says nothing new. Her send
    /// goes out at once, stamped at the cost Bob announced before she quit.
    @Test func afterARestartASenderReachesItsContactWithoutLookingForIt() async {
        let world = MessagingWorld()
        let first = world.messenger("alice", on: [.uplink])
        let bob = world.messenger("bob", on: [.uplink]) { state in
            state.displayName = "Bob"
            state.deliveryStampCost = 4
            state.enforceDeliveryStamps = true
        }
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(first, bob)
        await world.quiet()

        let alice = await world.relaunch(first, restoring: first.saved())
        #expect(alice.nameKnown(for: bob) == "Bob")
        #expect(alice.nextHop(to: bob) == relay.transportID)

        let sent = await alice.send("back again", to: bob)
        let before = world.elapsed
        await world.run(until: { !bob.inbox.isEmpty })

        #expect(bob.inbox.map(\.content) == ["back again"])
        #expect(world.elapsed == before, "it went at once")
        #expect(!alice.hadToLookForRecipient(of: sent))
        await world.shutDown()
    }

    /// The control for the test above: the same restart with nothing handed back. The send still
    /// gets there, but only after the node has gone looking, and the relay has answered.
    @Test func afterARestartWithNothingSavedASenderHasToLookForItsContactFirst() async {
        let world = MessagingWorld()
        let first = world.messenger("alice", on: [.uplink])
        let bob = world.messenger("bob", on: [.uplink]) { state in
            state.deliveryStampCost = 4
            state.enforceDeliveryStamps = true
        }
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(first, bob)
        await world.quiet()

        let alice = await world.relaunch(first, restoring: nil)
        #expect(!alice.hasHeardOf(bob))
        #expect(!alice.hasPath(to: bob))

        let sent = await alice.send("back again", to: bob)
        await world.advance(upTo: 120, until: { !bob.inbox.isEmpty })

        #expect(alice.hadToLookForRecipient(of: sent))
        #expect(bob.inbox.map(\.content) == ["back again"])
        await world.shutDown()
    }

    /// Bob restarts. Alice does not announce again, yet Bob still knows whose signature to check.
    @Test func afterARestartARecipientStillVerifiesAContactItHeardBefore() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.uplink], configure: named("Alice"))
        let first = world.messenger("bob", on: [.uplink])
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(alice, first)
        await world.quiet()

        let bob = await world.relaunch(first, restoring: first.saved())
        await world.advance(seconds: 5)
        #expect(bob.nameKnown(for: alice) == "Alice")

        let sent = await alice.send("welcome back", to: bob)
        _ = sent
        await world.advance(upTo: 60, until: { !bob.inbox.isEmpty })

        #expect(bob.inbox == [Received(content: "welcome back", from: alice.address, validated: true, method: .opportunistic)])
        await world.shutDown()
    }

    /// The control: with nothing handed back, Bob gets the message but cannot say who signed it.
    @Test func afterARestartWithNothingSavedARecipientCannotVerifyTheSender() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.uplink]), first = world.messenger("bob", on: [.uplink])
        let relay = world.relay()
        await relay.comeOnline()
        await world.bringOnline(alice, first)
        await world.quiet()

        let bob = await world.relaunch(first, restoring: nil)
        await world.advance(seconds: 5)

        let sent = await alice.send("welcome back", to: bob)
        _ = sent
        await world.advance(upTo: 60, until: { !bob.inbox.isEmpty })

        #expect(bob.inbox == [Received(content: "welcome back", from: alice.address, validated: false, method: .opportunistic)])
        await world.shutDown()
    }

    /// A resend of a message Bob already has reaches him after he restarted. He confirms it again
    /// and does not show it again.
    @Test func aMessageReceivedBeforeARestartIsNotShownAgainAfterIt() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), first = world.messenger("bob")
        await world.bringOnline(alice, first)
        await world.quiet()

        world.loseNextFrames(from: first.port, 1)   // bob's proof of receipt
        let sent = await alice.send("only once", to: first)
        await world.settle()
        #expect(first.inbox.map(\.content) == ["only once"])
        #expect(alice.outcomes(of: sent).isEmpty)

        let bob = await world.relaunch(first, restoring: first.saved())
        await world.advance(upTo: 120, until: { !alice.outcomes(of: sent).isEmpty })

        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        #expect(bob.inbox.isEmpty, "the resend was a duplicate of a message shown before the restart")
        await world.shutDown()
    }

    /// Alice still holds the ratchet Bob announced before he restarted (she missed his launch
    /// announce). What she encrypts to it must still open: Bob got his ratchet keys back.
    @Test func aMessageEncryptedToARatchetFromBeforeARestartStillOpens() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), first = world.messenger("bob", ratchets: true)
        await world.bringOnline(alice, first)
        await world.quiet()

        world.unplug(alice.port)
        let bob = await world.relaunch(first, restoring: first.saved())
        world.plug(alice.port)

        let sent = await alice.send("still secret", to: bob)
        await world.advance(upTo: 120, until: { !alice.outcomes(of: sent).isEmpty })

        #expect(bob.inbox.map(\.content) == ["still secret"])
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        await world.shutDown()
    }

    /// On the local network a peer has to be found again after a restart before anything can reach
    /// it. The saved route is used as soon as it is; Bob does not announce again.
    @Test func afterARestartOnTheLocalNetworkAContactIsReachableOnceFoundAgain() async {
        let world = MessagingWorld()
        let first = world.messenger("alice", on: [.lan]), bob = world.messenger("bob", on: [.lan], configure: named("Bob"))
        await world.bringOnline(first, bob)
        await world.quiet()

        let alice = await world.relaunch(first, restoring: first.saved())
        #expect(alice.nameKnown(for: bob) == "Bob")

        let sent = await alice.send("same room, new launch", to: bob)
        await world.advance(upTo: 120, until: { !alice.outcomes(of: sent).isEmpty })

        #expect(bob.inbox == [Received(content: "same room, new launch", from: alice.address,
                                       validated: true, method: .opportunistic)])
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        #expect(!alice.hadToLookForRecipient(of: sent))
        await world.shutDown()
    }

    /// Bob collected a message from the propagation node, restarted, and syncs again. The node still
    /// holds a message for him; Bob does not take the first one a second time.
    ///
    /// Two things each prevent that on their own, and this test fails only when BOTH are broken
    /// (checked by mutation): the node drops an entry once its client reports having it, and the
    /// client's restored `downloadedTransientIds` refuse an entry it is offered again.
    @Test func aMessageCollectedBeforeARestartIsNotCollectedAgain() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), first = world.messenger("bob")
        let node = world.propagationHost("node")
        await world.bringOnline(alice, first)
        await world.quiet()
        await node.comeOnline()
        await alice.usePropagationNode(node)
        await first.usePropagationNode(node)
        world.unplug(first.port)
        let sent = await alice.send("read this later", to: first, fallbackToPropagation: true)
        await world.advance(upTo: 600, until: { !alice.outcomes(of: sent).isEmpty })
        await world.advance(seconds: 300, step: 10)   // the direct copy runs out
        world.plug(first.port)
        await first.sync()
        await world.advance(upTo: 120, until: { !first.inbox.isEmpty })
        #expect(first.inbox.map(\.content) == ["read this later"])

        // While Bob is away a second message is left for him, so the sync after the restart has
        // something to bring: it must bring that one and only that one.
        world.unplug(first.port)
        let second = await alice.send("and this one", to: first, fallbackToPropagation: true)
        await world.advance(upTo: 600, until: { !alice.outcomes(of: second).isEmpty })
        await world.advance(seconds: 300, step: 10)
        #expect(node.storedCount == 2)

        let bob = await world.relaunch(first, restoring: first.saved())
        await bob.usePropagationNode(node)
        await bob.sync()
        await world.advance(upTo: 120, until: { !bob.inbox.isEmpty })
        await world.advance(seconds: 60, step: 10)

        #expect(bob.inbox.map(\.content) == ["and this one"])
        await world.shutDown()
    }
}
