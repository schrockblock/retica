import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Sending a message, as the person using the app experiences it.
//
// Every node here is a real `LXMFNode` on the simulated network of `MessagingWorld`. A test sends
// with `.sendMessage` (what the app calls) and asserts only on what the app is told: what arrived
// in the recipient's inbox, and which outcome the sender got. How the node got there (packets,
// links, resources, internal actions) is deliberately not asserted.

/// Longer than one packet can carry, so it cannot go as a single opportunistic packet.
private let longText = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)

@Suite(.timeLimit(.minutes(5))) @MainActor struct MessagingIntegrationTests {

    // MARK: First try

    @Test func aShortMessageArrivesAndIsConfirmedOnTheFirstTry() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), bob = world.messenger("bob")
        await world.bringOnline(alice, bob)

        let sent = await alice.send("hello bob", to: bob)
        await world.run(until: { !alice.outcomes(of: sent).isEmpty })

        #expect(bob.inbox == [Received(content: "hello bob", from: alice.address, validated: true, method: .opportunistic)])
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        #expect(world.elapsed == .zero, "no retry or timeout was needed")

        // Nothing more comes of it: no duplicate arrives and no second outcome is reported.
        await world.advance(seconds: 90)
        #expect(bob.inbox.count == 1)
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        await world.shutDown()
    }

    @Test func aLongMessageGoesOverADirectLinkAndIsConfirmed() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), bob = world.messenger("bob")
        await world.bringOnline(alice, bob)

        let sent = await alice.send(longText, to: bob)
        await world.run(until: { !alice.outcomes(of: sent).isEmpty })

        #expect(bob.inbox == [Received(content: longText, from: alice.address, validated: true, method: .direct)])
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        #expect(world.elapsed == .zero, "no retry or timeout was needed")
        await world.shutDown()
    }

    @Test func aConversationGoesBothWays() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), bob = world.messenger("bob")
        await world.bringOnline(alice, bob)

        let question = await alice.send("are you there?", to: bob)
        await world.run(until: { !alice.outcomes(of: question).isEmpty })
        let answer = await bob.send("yes, here", to: alice)
        await world.run(until: { !bob.outcomes(of: answer).isEmpty })

        #expect(bob.inbox.map(\.content) == ["are you there?"])
        #expect(alice.inbox == [Received(content: "yes, here", from: bob.address, validated: true, method: .opportunistic)])
        #expect(alice.outcomes(of: question) == [.confirmed(question)])
        #expect(bob.outcomes(of: answer) == [.confirmed(answer)])
        await world.shutDown()
    }

    @Test func aRecipientThatDemandsStampsStillGetsTheMessage() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice")
        let bob = world.messenger("bob") { state in
            state.deliveryStampCost = 4
            state.enforceDeliveryStamps = true
        }
        await world.bringOnline(alice, bob)

        let sent = await alice.send("stamped", to: bob)
        await world.run(until: { !alice.outcomes(of: sent).isEmpty })

        #expect(bob.inbox.map(\.content) == ["stamped"])
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        await world.shutDown()
    }

    // MARK: Retries

    @Test func aMessageWhoseFirstCopyIsLostIsRetriedAndArrivesOnce() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), bob = world.messenger("bob")
        await world.bringOnline(alice, bob)

        world.loseNextFrames(from: alice.port, 1)
        let sent = await alice.send("try again", to: bob)
        await world.settle()
        #expect(bob.inbox.isEmpty, "the only copy sent so far was lost")
        #expect(alice.outcomes(of: sent).isEmpty)

        await world.advance(upTo: 120, until: { !alice.outcomes(of: sent).isEmpty })
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        #expect(world.elapsed > .zero, "it took a retry")

        await world.advance(seconds: 90)
        #expect(bob.inbox.map(\.content) == ["try again"])
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        await world.shutDown()
    }

    @Test func aMessageWhoseConfirmationIsLostIsStillConfirmedAndArrivesOnce() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), bob = world.messenger("bob")
        await world.bringOnline(alice, bob)

        world.loseNextFrames(from: bob.port, 1)   // bob's proof of receipt
        let sent = await alice.send("did you get this?", to: bob)
        await world.settle()
        #expect(bob.inbox.map(\.content) == ["did you get this?"])
        #expect(alice.outcomes(of: sent).isEmpty, "the confirmation was lost")

        await world.advance(upTo: 120, until: { !alice.outcomes(of: sent).isEmpty })
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])

        await world.advance(seconds: 90)
        #expect(bob.inbox.count == 1, "the resend is not shown to bob a second time")
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        await world.shutDown()
    }

    @Test func aMessageToSomeoneNotYetOnlineArrivesOnceTheyAppear() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), bob = world.messenger("bob")
        await world.bringOnline(alice)

        let sent = await alice.send("see you soon", to: bob)
        await world.advance(seconds: 10)
        #expect(alice.outcomes(of: sent).isEmpty, "still waiting for bob")

        await world.bringOnline(bob)
        await world.advance(upTo: 120, until: { !alice.outcomes(of: sent).isEmpty })

        #expect(bob.inbox.map(\.content) == ["see you soon"])
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        await world.shutDown()
    }

    @Test func aMessageToSomeoneOutOfReachIsReportedFailed() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), bob = world.messenger("bob")
        await world.bringOnline(alice, bob)
        world.unplug(bob.port)

        let sent = await alice.send("anyone?", to: bob)
        await world.advance(upTo: 900, until: { !alice.outcomes(of: sent).isEmpty })

        #expect(alice.outcomes(of: sent) == [.failed(sent)])
        #expect(world.elapsed > .seconds(LXMFDelivery.retryWaitSeconds), "it was retried before giving up")
        #expect(bob.inbox.isEmpty)
        await world.shutDown()
    }

    // MARK: Propagation

    @Test func aMessageToSomeoneOutOfReachIsLeftWithThePropagationNodeAndCollectedLater() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice"), bob = world.messenger("bob")
        let node = world.propagationHost("node")
        await world.bringOnline(alice, bob)
        await node.comeOnline()
        await alice.usePropagationNode(node)
        await bob.usePropagationNode(node)
        world.unplug(bob.port)

        let sent = await alice.send("read this later", to: bob, fallbackToPropagation: true)
        await world.advance(upTo: 600, until: { !alice.outcomes(of: sent).isEmpty })
        #expect(alice.outcomes(of: sent) == [.acceptedByPropagationNode(sent)])
        #expect(node.storedCount == 1)
        #expect(bob.inbox.isEmpty)

        // The direct copy runs out of attempts. That is not a failure: the node has the message.
        await world.advance(seconds: 300)
        #expect(alice.outcomes(of: sent) == [.acceptedByPropagationNode(sent)])

        world.plug(bob.port)
        await bob.sync()
        await world.advance(upTo: 120, until: { !bob.inbox.isEmpty })
        #expect(bob.inbox == [Received(content: "read this later", from: alice.address, validated: true, method: .propagated)])
        await world.shutDown()
    }

    // MARK: AutoInterface

    @Test func aShortMessageCrossesTheLocalNetworkOnTheFirstTry() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.lan]), bob = world.messenger("bob", on: [.lan])
        await world.bringOnline(alice, bob)
        let before = world.elapsed

        let sent = await alice.send("hello over the LAN", to: bob)
        await world.run(until: { !alice.outcomes(of: sent).isEmpty })

        #expect(bob.inbox == [Received(content: "hello over the LAN", from: alice.address, validated: true, method: .opportunistic)])
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        #expect(world.elapsed == before, "no retry or timeout was needed")
        await world.shutDown()
    }

    @Test func aLongMessageCrossesTheLocalNetworkOverADirectLink() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.lan]), bob = world.messenger("bob", on: [.lan])
        await world.bringOnline(alice, bob)
        let before = world.elapsed

        let sent = await alice.send(longText, to: bob)
        await world.run(until: { !alice.outcomes(of: sent).isEmpty })

        #expect(bob.inbox == [Received(content: longText, from: alice.address, validated: true, method: .direct)])
        #expect(alice.outcomes(of: sent) == [.confirmed(sent)])
        #expect(world.elapsed == before, "no retry or timeout was needed")
        await world.shutDown()
    }

    /// One node on both networks reaches a peer on each, and neither peer sees the other's message.
    @Test func aNodeOnTwoNetworksReachesAPeerOnEach() async {
        let world = MessagingWorld()
        let alice = world.messenger("alice", on: [.hub, .lan])
        let bob = world.messenger("bob", on: [.lan]), carol = world.messenger("carol", on: [.hub])
        await world.bringOnline(alice, bob, carol)

        let toBob = await alice.send("for bob, on the LAN", to: bob)
        let toCarol = await alice.send("for carol, on the hub", to: carol)
        await world.run(until: { !alice.outcomes(of: toBob).isEmpty && !alice.outcomes(of: toCarol).isEmpty })

        #expect(bob.inbox.map(\.content) == ["for bob, on the LAN"])
        #expect(carol.inbox.map(\.content) == ["for carol, on the hub"])
        #expect(alice.outcomes(of: toBob) == [.confirmed(toBob)])
        #expect(alice.outcomes(of: toCarol) == [.confirmed(toCarol)])
        await world.shutDown()
    }
}
