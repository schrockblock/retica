#!/usr/bin/env swift
//
//  check-wire-narrowing.swift
//
//  Fails the build when a *bare* fixed-width integer conversion appears in
//  Sources/ without having been reviewed and recorded in the allowlist.
//
//  WHY THIS EXISTS
//  ---------------
//  `Int(someUInt64)` traps — it does not return nil, it aborts the process.
//  So does `Int(someDouble)` when the double is NaN or out of range. Every
//  integer that came off the wire is attacker-controlled, so every unguarded
//  narrowing conversion of one is a remote process abort.
//
//  Three separate sweeps of this codebase each found Criticals of exactly this
//  shape that the other sweeps missed. Attention does not close this class.
//  A mechanical default-deny gate does.
//
//  THE RULE
//  --------
//  Every `Int(x)` / `UInt8(x)` / ... in Sources/ must be one of:
//    (a) a compile-time-checked literal          — `UInt8(0xC4)`
//    (b) a non-trapping labelled init            — `Int(exactly:)`, `Int(clamping:)`,
//                                                  `Int(truncatingIfNeeded:)`, `Int(bitPattern:)`, ...
//    (c) listed in Scripts/wire-narrowing-allowlist.txt with a reason
//  Anything else is an error. `Int(exactly: x)!` is an error too: the label is
//  safe, the force-unwrap puts the trap straight back.
//
//  This is deliberately a *lexical* check with no dataflow analysis, because
//  "is this value wire-derived?" is precisely the judgement that failed three
//  times. Default-deny means a new conversion cannot enter Sources/ without
//  somebody writing down why it cannot trap.
//
//  USAGE
//  -----
//    Scripts/check-wire-narrowing.swift              # check; exit 1 on violation
//    Scripts/check-wire-narrowing.swift --report     # print every finding, ignore
//                                                    # allowlist, always exit 0
//    Scripts/check-wire-narrowing.swift --root DIR --allowlist FILE
//
//  Run under a specific toolchain with:  swift Scripts/check-wire-narrowing.swift
//

import Foundation

// MARK: - Configuration

/// Conversions we police. Every one of these can trap.
///
/// `UInt64` is included even though it is the widest type: `UInt64(x)` traps
/// for a negative `Int` and for a NaN/out-of-range `Double`, and negative Ints
/// are exactly what a wire-derived subtraction produces.
let policedTypes: Set<String> = [
    "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
]

/// Labelled inits that cannot trap. `exactly:` returns an Optional, `clamping:`
/// and `truncatingIfNeeded:` are total, `bitPattern:`/endian inits reinterpret.
let nonTrappingLabels: Set<String> = [
    "exactly", "clamping", "truncatingIfNeeded", "bitPattern",
    "littleEndian", "bigEndian", "byteSwapped", "ascii", "truncating",
]

// MARK: - Locations

let scriptURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

var rootArg = repoRoot.appendingPathComponent("Sources").path
var allowlistArg = scriptURL.deletingLastPathComponent()
    .appendingPathComponent("wire-narrowing-allowlist.txt").path
var reportMode = false
var failOnOpen = false

var argIndex = 1
let args = CommandLine.arguments
while argIndex < args.count {
    switch args[argIndex] {
    case "--root":
        argIndex += 1
        guard argIndex < args.count else { fail("--root needs a directory") }
        rootArg = args[argIndex]
    case "--allowlist":
        argIndex += 1
        guard argIndex < args.count else { fail("--allowlist needs a file") }
        allowlistArg = args[argIndex]
    case "--report":
        reportMode = true
    case "--fail-on-open":
        failOnOpen = true
    case "-h", "--help":
        print("""
        check-wire-narrowing.swift — default-deny gate on trapping integer conversions.

          --root DIR         directory to scan (default: <repo>/Sources)
          --allowlist FILE   allowlist path (default: <repo>/Scripts/wire-narrowing-allowlist.txt)
          --report           print every finding in allowlist format; ignore the
                             allowlist and always exit 0
          --fail-on-open     also fail on entries whose reason starts with `OPEN` —
                             known-unfixed sites. Use this to assert the hardening
                             plan is complete.
          -h, --help         this text

        Exit 1 if any conversion is unreviewed, or if an allowlist entry is stale.
        """)
        exit(0)
    default:
        fail("unknown argument: \(args[argIndex])")
    }
    argIndex += 1
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("check-wire-narrowing: \(message)\n".utf8))
    exit(2)
}

// MARK: - Lexical masking
//
// Blank out comments and string-literal *content* so we never match inside
// them, preserving every character position and newline so line/column numbers
// stay exact. String interpolation segments are deliberately left unmasked —
// they are real code and can contain a real conversion.

final class Masker {
    private let source: [Character]
    private var out: [Character]
    private let n: Int

    init(_ source: [Character]) {
        self.source = source
        self.out = source
        self.n = source.count
    }

    private func blank(_ range: Range<Int>) {
        for k in range where source[k] != "\n" { out[k] = " " }
    }

    func masked() -> [Character] {
        var i = 0
        while i < n {
            let c = source[i]

            // Line comment
            if c == "/", i + 1 < n, source[i + 1] == "/" {
                var j = i
                while j < n, source[j] != "\n" { j += 1 }
                blank(i..<j)
                i = j
                continue
            }

            // Block comment (Swift allows nesting)
            if c == "/", i + 1 < n, source[i + 1] == "*" {
                var depth = 1
                var j = i + 2
                while j < n, depth > 0 {
                    if source[j] == "/", j + 1 < n, source[j + 1] == "*" { depth += 1; j += 2; continue }
                    if source[j] == "*", j + 1 < n, source[j + 1] == "/" { depth -= 1; j += 2; continue }
                    j += 1
                }
                blank(i..<min(j, n))
                i = min(j, n)
                continue
            }

            // Raw string delimiter: one or more '#' followed by '"'
            if c == "#" {
                var hashes = 0
                var j = i
                while j < n, source[j] == "#" { hashes += 1; j += 1 }
                if j < n, source[j] == "\"" {
                    i = skipString(quoteAt: j, hashes: hashes)
                    continue
                }
                i = j
                continue
            }

            // Plain / multiline string
            if c == "\"" {
                i = skipString(quoteAt: i, hashes: 0)
                continue
            }

            i += 1
        }
        return out
    }

    /// Consumes a string literal beginning at `quoteAt`, blanking its content but
    /// leaving `\(...)` interpolation bodies intact. Returns the index just past it.
    private func skipString(quoteAt: Int, hashes: Int) -> Int {
        let isMultiline = quoteAt + 2 < n && source[quoteAt + 1] == "\"" && source[quoteAt + 2] == "\""
        let quoteLen = isMultiline ? 3 : 1
        var i = quoteAt + quoteLen
        var segmentStart = i

        while i < n {
            if isEscape(i, hashes: hashes) {
                let afterBackslash = i + 1 + hashes
                if afterBackslash < n, source[afterBackslash] == "(" {
                    // Interpolation: blank up to here, then leave the body as code.
                    blank(segmentStart..<i)
                    var depth = 0
                    var j = afterBackslash
                    while j < n {
                        if source[j] == "(" { depth += 1 }
                        if source[j] == ")" { depth -= 1; if depth == 0 { j += 1; break } }
                        j += 1
                    }
                    i = j
                    segmentStart = i
                    continue
                }
                i = min(afterBackslash + 1, n)
                continue
            }
            if let end = terminatorEnd(i, hashes: hashes, quoteLen: quoteLen, isMultiline: isMultiline) {
                blank(segmentStart..<i)
                return end
            }
            i += 1
        }
        blank(segmentStart..<n)
        return n
    }

    /// A backslash escape at `k` is live only when followed by exactly `hashes` '#'.
    private func isEscape(_ k: Int, hashes: Int) -> Bool {
        guard source[k] == "\\" else { return false }
        var h = 0
        var j = k + 1
        while j < n, source[j] == "#", h < hashes { h += 1; j += 1 }
        return h == hashes
    }

    /// A closing quote run at `k` must be followed by exactly `hashes` '#'.
    private func terminatorEnd(_ k: Int, hashes: Int, quoteLen: Int, isMultiline: Bool) -> Int? {
        guard source[k] == "\"" else { return nil }
        if isMultiline {
            guard k + 2 < n, source[k + 1] == "\"", source[k + 2] == "\"" else { return nil }
        }
        var j = k + quoteLen
        var h = 0
        while j < n, source[j] == "#", h < hashes { h += 1; j += 1 }
        return h == hashes ? j : nil
    }
}

func maskCommentsAndStrings(_ source: [Character]) -> [Character] {
    Masker(source).masked()
}

// MARK: - Finding conversions

struct Finding {
    var file: String        // repo-relative
    var line: Int
    var column: Int
    var expression: String  // normalised, e.g. "Int(be(b, i + 1, 2))"
    var reason: String
}

func isIdentifierChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == "_"
}

let literalPattern = try! NSRegularExpression(
    pattern: #"^[+-]?\s*(0[xX][0-9A-Fa-f_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*)$"#
)
let labelPattern = try! NSRegularExpression(
    pattern: #"^([A-Za-z_][A-Za-z0-9_]*)\s*:"#
)

func firstMatch(_ regex: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
    regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
}

func normalise(_ s: String) -> String {
    s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        .joined(separator: " ")
}

func scan(file url: URL, relativePath: String) -> [Finding] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let source = Array(text)
    let masked = maskCommentsAndStrings(source)
    let n = masked.count

    // Precompute line starts for position reporting.
    var lineOfIndex = [Int](repeating: 1, count: n + 1)
    var columnOfIndex = [Int](repeating: 1, count: n + 1)
    var line = 1
    var column = 1
    for k in 0..<n {
        lineOfIndex[k] = line
        columnOfIndex[k] = column
        if source[k] == "\n" { line += 1; column = 1 } else { column += 1 }
    }
    lineOfIndex[n] = line
    columnOfIndex[n] = column

    var findings: [Finding] = []
    var i = 0
    while i < n {
        guard masked[i].isLetter || masked[i] == "_" else { i += 1; continue }
        if i > 0, isIdentifierChar(masked[i - 1]) { // middle of an identifier
            while i < n, isIdentifierChar(masked[i]) { i += 1 }
            continue
        }
        var j = i
        while j < n, isIdentifierChar(masked[j]) { j += 1 }
        let word = String(masked[i..<j])
        guard policedTypes.contains(word), j < n, masked[j] == "(" else { i = j; continue }

        // Balance the parentheses to capture the whole call.
        var depth = 0
        var k = j
        while k < n {
            if masked[k] == "(" { depth += 1 }
            if masked[k] == ")" { depth -= 1; if depth == 0 { break } }
            k += 1
        }
        guard k < n else { i = j; continue } // unbalanced — malformed source

        let argument = normalise(String(source[(j + 1)..<k]))
        let expression = normalise(String(source[i...k]))
        let forceUnwrapped = k + 1 < n && masked[k + 1] == "!" && !(k + 2 < n && masked[k + 2] == "=")

        var reason: String? = nil
        if let m = firstMatch(labelPattern, argument),
           let r = Range(m.range(at: 1), in: argument),
           nonTrappingLabels.contains(String(argument[r])) {
            if forceUnwrapped {
                reason = "force-unwrapped non-trapping init — the `!` restores the trap"
            }
        } else if firstMatch(literalPattern, argument) != nil {
            reason = nil // compile-time-checked literal
        } else {
            reason = "bare narrowing conversion — traps if the value is out of range"
        }

        if let reason {
            findings.append(
                Finding(
                    file: relativePath,
                    line: lineOfIndex[i],
                    column: columnOfIndex[i],
                    expression: expression,
                    reason: reason
                )
            )
        }
        // Resume *inside* the argument, not past it: a conversion nested in another
        // conversion (`Int(min(a, UInt64(b)))`) is its own trap and gets its own finding.
        i = j + 1
    }
    return findings
}

// MARK: - Allowlist

struct AllowlistEntry {
    var file: String
    var expression: String
    var count: Int
    var reason: String
    var sourceLine: Int
}

func loadAllowlist(_ path: String) -> [AllowlistEntry] {
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read allowlist at \(path)")
    }
    var entries: [AllowlistEntry] = []
    for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let stripped = raw.trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty || stripped.hasPrefix("#") { continue }
        // The expression is LAST and unrestricted, because Swift expressions contain `|`
        // (`UInt8(high << 4 | low)`). Only the first three fields are pipe-delimited, so
        // `file`, `count` and `reason` must not contain a pipe.
        let parts = stripped.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4, let count = Int(parts[1]) else {
            fail("\(path):\(index + 1): malformed entry — expected `file | count | reason | expression`")
        }
        entries.append(
            AllowlistEntry(
                file: parts[0],
                expression: normalise(parts[3]),
                count: count,
                reason: parts[2],
                sourceLine: index + 1
            )
        )
    }
    return entries
}

// MARK: - Run

let rootURL = URL(fileURLWithPath: rootArg).resolvingSymlinksInPath()
guard let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
    fail("cannot enumerate \(rootURL.path)")
}
var swiftFiles: [URL] = []
for case let url as URL in walker where url.pathExtension == "swift" {
    swiftFiles.append(url)
}
swiftFiles.sort { $0.path < $1.path }
if swiftFiles.isEmpty { fail("no Swift files under \(rootURL.path)") }

// Report paths relative to the scanned root's PARENT, so `--root <other-checkout>/Sources`
// still yields `Sources/...` keys and can be checked against this repo's allowlist. That is
// what lets the gate be validated against a historical revision.
let relativeBase = rootURL.deletingLastPathComponent().path
let rootPrefix = relativeBase.hasSuffix("/") ? relativeBase : relativeBase + "/"
var findings: [Finding] = []
for url in swiftFiles {
    let resolved = url.resolvingSymlinksInPath().path
    let relative = resolved.hasPrefix(rootPrefix) ? String(resolved.dropFirst(rootPrefix.count)) : resolved
    findings.append(contentsOf: scan(file: url, relativePath: relative))
}
findings.sort { ($0.file, $0.line, $0.column) < ($1.file, $1.line, $1.column) }

// Group by (file, expression) so the allowlist survives line motion.
struct GroupKey: Hashable { var file: String; var expression: String }
var grouped: [GroupKey: [Finding]] = [:]
for f in findings { grouped[GroupKey(file: f.file, expression: f.expression), default: []].append(f) }

if reportMode {
    print("# \(findings.count) finding(s) in \(grouped.count) group(s) under \(rootURL.path)")
    print("# format: file | count | reason | expression")
    for key in grouped.keys.sorted(by: { ($0.file, $0.expression) < ($1.file, $1.expression) }) {
        let group = grouped[key]!
        let lines = group.map(\.line).map(String.init).joined(separator: ",")
        print("\(key.file) | \(group.count) | REVIEW ME (line\(group.count == 1 ? "" : "s") \(lines)) | \(key.expression)")
    }
    exit(0)
}

let allowlist = loadAllowlist(allowlistArg)
var allowed: [GroupKey: AllowlistEntry] = [:]
for entry in allowlist {
    let key = GroupKey(file: entry.file, expression: entry.expression)
    if allowed[key] != nil {
        fail("\(allowlistArg):\(entry.sourceLine): duplicate entry for \(entry.file) | \(entry.expression)")
    }
    allowed[key] = entry
}

var violations = 0
var stale = 0
var openSites: [(key: GroupKey, group: [Finding], entry: AllowlistEntry)] = []

for key in grouped.keys.sorted(by: { ($0.file, $0.expression) < ($1.file, $1.expression) }) {
    let group = grouped[key]!
    guard let entry = allowed[key] else {
        for f in group {
            print("\(f.file):\(f.line):\(f.column): error: \(f.reason): `\(f.expression)`")
            print("  note: prove it cannot trap (use Int(exactly:) and handle nil, or clamp), or")
            print("  note: add to \(URL(fileURLWithPath: allowlistArg).lastPathComponent): "
                + "\(f.file) | \(group.count) | <why this cannot trap> | \(f.expression)")
        }
        violations += group.count
        continue
    }
    if entry.count != group.count {
        print("\(allowlistArg):\(entry.sourceLine): error: stale allowlist entry: "
            + "`\(key.expression)` in \(key.file) — allowlist says \(entry.count), found \(group.count)")
        print("  note: update the count, or remove the entry if the site is gone")
        stale += 1
    }
    if entry.reason.hasPrefix("OPEN") { openSites.append((key, group, entry)) }
}

for entry in allowlist {
    let key = GroupKey(file: entry.file, expression: entry.expression)
    if grouped[key] == nil {
        print("\(allowlistArg):\(entry.sourceLine): error: stale allowlist entry: "
            + "`\(entry.expression)` no longer appears in \(entry.file) — remove it")
        stale += 1
    }
}

// Known-unfixed sites are recorded, not silently blessed. They print on every run so the
// residue cannot fade from view, but they do not fail the gate — a permanently-red gate
// gets switched off, and then it catches nothing. `--fail-on-open` flips that for the run
// that asserts the hardening plan is finished.
let openCount = openSites.reduce(0) { $0 + $1.group.count }
if !openSites.isEmpty {
    print("")
    print("check-wire-narrowing: \(openCount) KNOWN-OPEN site(s) still unfixed:")
    for (key, group, entry) in openSites {
        for f in group {
            print("  \(key.file):\(f.line):\(f.column): `\(key.expression)` — \(entry.reason)")
        }
    }
}

if violations == 0 && stale == 0 && !(failOnOpen && !openSites.isEmpty) {
    print("")
    print("check-wire-narrowing: OK — \(findings.count) reviewed conversion(s) across "
        + "\(swiftFiles.count) file(s); no unreviewed sites"
        + (openCount > 0 ? ", \(openCount) known-open." : "."))
    exit(0)
}

print("")
var summary = "check-wire-narrowing: FAILED — \(violations) unreviewed conversion(s), "
    + "\(stale) stale allowlist entr(y/ies)"
if failOnOpen && !openSites.isEmpty { summary += ", \(openCount) known-open site(s)" }
print(summary + ".")
exit(1)
