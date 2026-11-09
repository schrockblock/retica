import Testing
import Foundation
@testable import ReTiCA

/// `LXMessage.ticketField` on hostile input (tickets plan, Review Focus 2): every malformed entry is
/// nil, nothing traps. Each message goes through `packed` -> `unpack`, the path a received one takes.
private let goodTicket = Data((0..<16).map { UInt8($0) })

private func received(fields: [MsgPackValue.IntPair]) throws -> LXMessage {
    let built = LXMessage.create(source: Identity(), destinationHash: Data(repeating: 0xBB, count: 16),
                                 timestamp: 1700000000, title: Data(), content: Data("c".utf8), fields: fields)
    return try #require(LXMessage.unpack(built.packed))
}

private func ticketEntry(_ items: [MsgPackValue]) -> [MsgPackValue.IntPair] {
    [.init(LXMessage.fieldTicket, .array(items))]
}

@Test func aWellFormedTicketFieldParsesWithAnyNumericExpiry() throws {
    for (expires, want) in [(MsgPackValue.double(1700000100.5), 1700000100.5), (.uint(1700000100), 1700000100),
                            (.int(-5), -5), (.float(1024), 1024)] {
        let entry = try #require(try received(fields: ticketEntry([expires, .bin(goodTicket)])).ticketField)
        #expect(entry.expires == want)
        #expect(entry.ticket == goodTicket)
    }
    // Reference only requires len > 1, so trailing elements are tolerated.
    #expect(try received(fields: ticketEntry([.double(1), .bin(goodTicket), .null])).ticketField?.ticket == goodTicket)
}

@Test func aMalformedTicketFieldIsIgnored() throws {
    let hostile: [[MsgPackValue.IntPair]] = [
        [],                                                                              // absent
        ticketEntry([.double(1), .bin(Data(repeating: 1, count: 15))]),                  // short ticket
        ticketEntry([.double(1), .bin(Data(repeating: 1, count: 17))]),                  // long ticket
        ticketEntry([.double(1), .bin(Data())]),                                         // empty ticket
        ticketEntry([.double(1), .string(String(repeating: "a", count: 16))]),           // str, not bytes
        ticketEntry([.double(.nan), .bin(goodTicket)]),
        ticketEntry([.double(.infinity), .bin(goodTicket)]),
        ticketEntry([.double(-.infinity), .bin(goodTicket)]),
        ticketEntry([.float(.nan), .bin(goodTicket)]),
        ticketEntry([.string("1700000100"), .bin(goodTicket)]),                          // non-numeric expiry
        ticketEntry([.bin(Data([1])), .bin(goodTicket)]),
        ticketEntry([.null, .bin(goodTicket)]),
        ticketEntry([.bool(true), .bin(goodTicket)]),
        ticketEntry([.bin(goodTicket), .double(1)]),                                     // swapped
        ticketEntry([.double(1)]),                                                       // too short
        ticketEntry([]),
        [.init(LXMessage.fieldTicket, .bin(goodTicket))],                                // wrong container
        [.init(LXMessage.fieldTicket, .map([.init("expires", .double(1)), .init("ticket", .bin(goodTicket))]))],
        [.init(LXMessage.fieldTicket, .intMap([.init(0, .double(1)), .init(1, .bin(goodTicket))]))],
        [.init(0x0B, .array([.double(1), .bin(goodTicket)]))],                           // another field
    ]
    for fields in hostile {
        #expect(try received(fields: fields).ticketField == nil, "\(fields)")
    }
}

/// Python builds a dict from the msgpack map, so with a repeated key the last value wins.
@Test func withARepeatedTicketKeyTheLastEntryWins() throws {
    let other = Data(repeating: 0xEE, count: 16)
    let fields: [MsgPackValue.IntPair] = [.init(LXMessage.fieldTicket, .array([.double(1), .bin(other)])),
                                          .init(LXMessage.fieldTicket, .array([.double(2), .bin(goodTicket)]))]
    #expect(try received(fields: fields).ticketField?.ticket == goodTicket)
}
