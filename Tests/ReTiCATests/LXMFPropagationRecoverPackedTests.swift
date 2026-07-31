import Testing
import Foundation
@testable import ReTiCA

/// recoverPacked is the inverse of pack's encryption step: for an entry packed to R, it reproduces the
/// original message.packed bytes (so the router's received(.direct) path can consume it), and open() is
/// just unpack(recoverPacked). A wrong recipient identity fails to decrypt → nil.
@Test func recoverPackedReproducesPackedBytesAndOpenRoundTrips() {
    let sender = Identity()
    let recipient = Identity()
    let msg = LXMessage.create(source: sender,
                               destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hello".utf8))
    let (container, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient, timestamp: 1700000000.5)
    let entries = LXMFPropagation.parseContainer(container)!.entries
    #expect(entries.count == 1)
    let entry = entries[0]

    let packed = LXMFPropagation.recoverPacked(lxmfData: entry, recipientIdentity: recipient)
    #expect(packed == msg.packed)                                   // deterministic wire bytes reproduced

    let opened = LXMFPropagation.open(lxmfData: entry, recipientIdentity: recipient)
    #expect(opened?.hash == msg.hash)
    #expect(opened?.validateSignature(source: sender) == true)      // real Ed25519 validation

    #expect(LXMFPropagation.recoverPacked(lxmfData: entry, recipientIdentity: Identity()) == nil)  // wrong key
}
