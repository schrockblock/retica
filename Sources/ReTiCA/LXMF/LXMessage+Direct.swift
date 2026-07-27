import Foundation

extension LXMessage {
    public enum DirectRepresentation: Equatable { case packet, resource }

    /// How this message is delivered over a Link (LXMF DIRECT method): the whole `packed` as a single
    /// link packet if it fits the link MDU, else as a Resource. Reference LXMF compares `content_size`
    /// to `LINK_PACKET_MAX_CONTENT = Link.MDU − LXMF_OVERHEAD`, which reduces exactly to
    /// `packed.count <= Link.mdu` (LXMessage.py:417-424). DIRECT sends the WHOLE `packed` (unlike
    /// opportunistic's `opportunisticPayload`), since a link is addressed by its link id.
    public var directRepresentation: DirectRepresentation {
        packed.count <= Link.mdu ? .packet : .resource
    }
}
