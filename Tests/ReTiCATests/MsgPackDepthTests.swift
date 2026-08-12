import Foundation
import Testing
@testable import ReTiCA

/// Guards against unbounded parse recursion in `MsgPack.parse` ↔ `parseMap` / `parseArray`.
///
/// The mutual recursion between those three functions has no depth limit. A crafted payload of
/// nested container headers (e.g. a run of `0x91` fixarray-of-1 tags) recurses until the
/// thread's native stack is exhausted, crashing the process with SIGBUS/SIGSEGV — a single-frame
/// remote kill because 431 bytes of nesting fits within one `Link.mdu`.
///
/// **Detection scope:** `Scripts/check-wire-narrowing.swift` covers narrowing-conversion
/// defects only; recursion depth is a different shape and is invisible to it. These tests are
/// the **sole** regression guard for this defect. If they are removed, nothing else catches a
/// regression.
///
/// **Reference behaviour:** Python's `umsgpack` (RNS/vendor/umsgpack.py) is equally recursive
/// and imposes no explicit depth limit — it survives because CPython raises a catchable
/// `RecursionError` at the interpreter level. A native Swift port has no such safety net, so
/// we guard explicitly. We are deliberately diverging from the reference; a crafted payload
/// that `umsgpack` catches via `RecursionError` would hard-crash us without the guard.
@Suite("MsgPack recursion depth guard")
struct MsgPackDepthTests {

    // MARK: — Bomb tests (reject deeply nested containers)

    /// 500 × `0x91` (fixarray-of-1 header). Each tag recurses once through `parse` →
    /// `parseArray` → `parse`. Without the depth guard this crashes the process (SIGBUS at ~431
    /// levels on a 512 KiB background-thread stack in a debug build). With the guard it must
    /// return `nil`.
    @Test("a deeply-nested fixarray bomb is rejected as nil")
    func nestingArrayBombIsRejected() {
        let bomb = Data(repeating: 0x91, count: 500)
        #expect(MsgPack.decodeValue(bomb) == nil)
    }

    /// 500 × `0x81` (fixmap-of-1 header). Each tag recurses through `parse` → `parseMap` →
    /// `parse` (twice: once for the key peek, once for the key, once for the value). Without
    /// the depth guard this crashes the process. With the guard it must return `nil`.
    @Test("a deeply-nested fixmap bomb is rejected as nil")
    func nestingMapBombIsRejected() {
        let bomb = Data(repeating: 0x81, count: 500)
        #expect(MsgPack.decodeValue(bomb) == nil)
    }

    // MARK: — Legitimate nesting (must still decode)

    /// Depth 2: array → array → scalar. The shallowest example from the protocol survey.
    @Test("depth-2 nesting (PNAnnounce costs array shape) still decodes")
    func depth2NestingStillDecodes() {
        let value = MsgPackValue.array([
            .array([.uint(1), .uint(2), .uint(3)]),
            .map([])
        ])
        let packed = MsgPack.encode(value)
        let decoded = MsgPack.decodeValue(packed)
        #expect(decoded != nil)
        if let decoded {
            #expect(decoded == value)
        }
    }

    /// Depth 3: array → intMap → scalar value. Mirrors the deepest **protocol-defined**
    /// nesting in Reticulum: an LXMessage payload whose `fields` element is an intMap whose
    /// values are scalars. Any application data in `fields` values could nest further, which
    /// is why the limit is set well above 3.
    @Test("depth-3 nesting (LXMessage fields shape) still decodes")
    func depth3NestingStillDecodes() {
        // array([double, bin, bin, intMap([IntPair(key, scalar)])])
        let value = MsgPackValue.array([
            .double(1234567890.0),
            .bin(Data(repeating: 0xAA, count: 4)),
            .bin(Data()),
            .intMap([.init(1, .uint(42)), .init(2, .string("hello"))])
        ])
        let packed = MsgPack.encode(value)
        let decoded = MsgPack.decodeValue(packed)
        #expect(decoded != nil)
        if let decoded {
            #expect(decoded == value)
        }
    }

    /// Depth at the limit: a chain nested exactly `maxParseDepth` containers deep should still
    /// decode (the guard rejects at depth > limit, not depth == limit). This pins that the
    /// constant is not off-by-one on the accept side.
    @Test("nesting exactly at maxParseDepth still decodes")
    func nestingAtLimitDecodes() {
        // Build a legitimate value nested maxParseDepth levels: array([array([…])])
        // At depth N the innermost value is a uint scalar.
        var value = MsgPackValue.uint(7)
        for _ in 0..<MsgPack.maxParseDepth {
            value = .array([value])
        }
        let packed = MsgPack.encode(value)
        let decoded = MsgPack.decodeValue(packed)
        #expect(decoded != nil)
        if let decoded {
            #expect(decoded == value)
        }
    }

    /// Depth one past the limit must be rejected. `maxParseDepth + 1` containers nested.
    @Test("nesting one past maxParseDepth is rejected")
    func nestingOnePastLimitIsRejected() {
        var value = MsgPackValue.uint(7)
        for _ in 0..<(MsgPack.maxParseDepth + 1) {
            value = .array([value])
        }
        let packed = MsgPack.encode(value)
        // The outermost container hits depth == maxParseDepth + 1 which is one past the limit;
        // parse rejects it and returns nil.
        #expect(MsgPack.decodeValue(packed) == nil)
    }
}
