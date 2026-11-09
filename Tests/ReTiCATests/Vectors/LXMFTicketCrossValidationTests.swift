import Testing
import Foundation
@testable import ReTiCA

/// LXMF 1.3.0 stamp tickets against genuine reference output (`generate_lxmf_ticket_fixtures.py`,
/// run in the `rns-latest` env). The generator checks every case with reference's own
/// `validate_stamp(target_cost, tickets=...)`, including a wrong-ticket control that must fail.
private struct TicketFixtures: Decodable {
    struct Inbound: Decodable {
        let sourcePrivateKey, sourceHash, destinationHash, issuedTicket, wrongTicket: String
        let fieldTicketExpires: Double
        let fieldTicket, messageId, stamp, packed: String
    }
    struct Outbound: Decodable {
        let sourcePrivateKey, destinationHash: String
        let timestamp: Double
        let title, content, ticket, messageId, stamp, packed: String
    }
    let targetCost: Int
    let costTicket: Int
    let inbound: Inbound
    let outbound: Outbound

    static func load() throws -> TicketFixtures {
        let url = try #require(Bundle.module.url(forResource: "lxmf_ticket_fixtures", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TicketFixtures.self, from: Data(contentsOf: url))
    }
}

private func hex(_ s: String) -> Data { Data(hexString: s)! }

/// Reference -> ReTiCA: a peer's reference-built message, ticket-stamped with the ticket we issued it
/// and carrying a `FIELD_TICKET` for us, validates here only against that ticket.
@Test func aReferenceTicketStampValidatesAgainstTheIssuedTicketOnly() throws {
    let f = try TicketFixtures.load()
    let m = try #require(LXMessage.unpack(hex(f.inbound.packed)))
    let source = try #require(Identity(privateKey: hex(f.inbound.sourcePrivateKey)))
    #expect(m.validateSignature(source: source))
    #expect(m.sourceHash == hex(f.inbound.sourceHash))
    #expect(m.hash == hex(f.inbound.messageId))
    #expect(m.stamp == hex(f.inbound.stamp))
    #expect(m.stamp?.count == LXMessage.ticketLength)

    #expect(m.validateStamp(targetCost: f.targetCost, tickets: [hex(f.inbound.issuedTicket)]))
    #expect(m.validateStamp(targetCost: f.targetCost, tickets: [hex(f.inbound.wrongTicket), hex(f.inbound.issuedTicket)]))
    #expect(!m.validateStamp(targetCost: f.targetCost, tickets: [hex(f.inbound.wrongTicket)]))
    #expect(!m.validateStamp(targetCost: f.targetCost, tickets: []))
    #expect(!m.validateStamp(targetCost: f.targetCost))
}

/// The `FIELD_TICKET` reference put in that message reads back as `[expires, ticket]`.
@Test func aReferenceFieldTicketParses() throws {
    let f = try TicketFixtures.load()
    let m = try #require(LXMessage.unpack(hex(f.inbound.packed)))
    let entry = try #require(m.ticketField)
    #expect(entry.expires == f.inbound.fieldTicketExpires)
    #expect(entry.ticket == hex(f.inbound.fieldTicket))
}

/// ReTiCA -> reference: from the same fixed inputs, our message ID, ticket stamp and stamped payload
/// equal the bytes reference produced and accepted (signatures excluded: ours are randomized and
/// not part of the hash).
@Test func ourTicketStampIsTheOneReferenceMakesAndAccepts() throws {
    let f = try TicketFixtures.load()
    let o = f.outbound
    let source = try #require(Identity(privateKey: hex(o.sourcePrivateKey)))
    let m = LXMessage.create(source: source, destinationHash: hex(o.destinationHash), timestamp: o.timestamp,
                             title: hex(o.title), content: hex(o.content))
    #expect(m.hash == hex(o.messageId))
    let stamp = LXMessage.ticketStamp(ticket: hex(o.ticket), messageHash: m.hash)
    #expect(stamp == hex(o.stamp))
    let headerLength = 2 * LXMessage.destinationLength + LXMessage.signatureLength
    #expect(Data(m.withStamp(stamp).packed.dropFirst(headerLength)) == Data(hex(o.packed).dropFirst(headerLength)))
}

@Test func ticketConstantsMatchReference() throws {
    let f = try TicketFixtures.load()
    #expect(LXMessage.fieldTicket == 0x0C)
    #expect(LXMessage.ticketLength == 16)
    #expect(LXMessage.costTicket == f.costTicket)
    #expect(LXMessage.ticketExpiry == 21 * 86400)
    #expect(LXMessage.ticketGrace == 5 * 86400)
    #expect(LXMessage.ticketRenew == 14 * 86400)
    #expect(LXMessage.ticketInterval == 86400)
}
