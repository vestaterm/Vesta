import XCTest
import VestaMux

/// Mux wire-protocol coverage: encode/decode round-trips for every frame case, plus the
/// stream behaviors that break silently — partial buffers, byte-at-a-time fragmentation,
/// multiple frames per read, and unknown tags.
final class MuxProtocolTests: XCTestCase {

    private let clientCases: [ClientFrame] = [
        .hello(paneID: "abc-123", cols: 80, rows: 24, cwd: "/tmp/x"),
        .hello(paneID: "no-cwd", cols: 80, rows: 24, cwd: nil),
        .hello(paneID: "", cols: 0, rows: 0, cwd: ""),
        .input(Data([0x01, 0x02, 0xff, 0x00])),
        .input(Data()),
        .resize(cols: 120, rows: 40),
        .detach, .kill, .list,
        .subscribe(paneID: "sub-1"),
    ]

    private var serverCases: [ServerFrame] {
        [
            .helloAck(version: muxProtocolVersion),
            .output(Data("hi ☃ — utf8 and \u{0} bytes".utf8)),
            .output(Data()),
            .exited(status: 137),
            .exited(status: -1),  // negative status must survive the UInt32 bit-pattern trip
            .sessions([]),
            .sessions([
                SessionInfo(id: "p1", name: "build", cwd: "/tmp", alive: true, attachedCount: 2),
                SessionInfo(id: "p2", name: nil, cwd: nil, alive: false, attachedCount: 0),
            ]),
        ]
    }

    // MARK: - Round-trips

    func testClientFrameRoundTrip() {
        for f in clientCases {
            var buf = encode(f)
            XCTAssertEqual(decodeClientFrame(from: &buf), f, "round-trip \(f)")
            XCTAssertTrue(buf.isEmpty, "decode consumed the whole frame for \(f)")
        }
    }

    func testServerFrameRoundTrip() {
        for f in serverCases {
            var buf = encode(f)
            XCTAssertEqual(decodeServerFrame(from: &buf), f, "round-trip \(f)")
            XCTAssertTrue(buf.isEmpty, "decode consumed the whole frame for \(f)")
        }
    }

    // MARK: - Partial / fragmented buffers

    func testPartialFrameLeavesBufferUntouched() {
        let full = encode(ClientFrame.input(Data([0xaa, 0xbb, 0xcc])))
        // Every proper prefix — including an incomplete 4-byte length header — must
        // decode to nil without consuming anything.
        for cut in 0..<full.count {
            var buf = Data(full.prefix(cut))
            let before = buf
            XCTAssertNil(decodeClientFrame(from: &buf), "prefix of \(cut) bytes is not a frame")
            XCTAssertEqual(buf, before, "partial decode must not consume bytes (cut=\(cut))")
        }
    }

    func testFragmentedDecodeByteAtATime() {
        let frame = ClientFrame.hello(paneID: "frag", cols: 80, rows: 24, cwd: "/tmp")
        let wire = encode(frame)
        var buf = Data()
        var decoded: [ClientFrame] = []
        for (i, byte) in wire.enumerated() {
            buf.append(byte)
            if let f = decodeClientFrame(from: &buf) {
                decoded.append(f)
                XCTAssertEqual(i, wire.count - 1, "frame must only complete on the last byte")
            }
        }
        XCTAssertEqual(decoded, [frame])
        XCTAssertTrue(buf.isEmpty)
    }

    func testFragmentedStreamAcrossArbitraryChunkBoundaries() {
        // A realistic read loop: several frames concatenated, delivered in odd-sized
        // chunks; the decoder must yield exactly the original sequence.
        let frames: [ServerFrame] = serverCases
        let wire = frames.map { encode($0) }.reduce(Data(), +)
        for chunkSize in [1, 3, 7, 64, wire.count] {
            var buf = Data()
            var decoded: [ServerFrame] = []
            var i = wire.startIndex
            while i < wire.endIndex {
                let j = min(wire.index(i, offsetBy: chunkSize, limitedBy: wire.endIndex) ?? wire.endIndex, wire.endIndex)
                buf.append(wire[i..<j])
                while let f = decodeServerFrame(from: &buf) { decoded.append(f) }
                i = j
            }
            XCTAssertEqual(decoded, frames, "chunkSize \(chunkSize)")
            XCTAssertTrue(buf.isEmpty, "chunkSize \(chunkSize) left bytes behind")
        }
    }

    func testFullFramePlusPartialSecondFrame() {
        let first = ClientFrame.input(Data([0xaa, 0xbb, 0xcc]))
        let wire = encode(first)
        let partial = wire.dropLast()
        var buf = wire + partial
        XCTAssertEqual(decodeClientFrame(from: &buf), first)
        XCTAssertEqual(buf, Data(partial), "the partial second frame stays buffered intact")
        XCTAssertNil(decodeClientFrame(from: &buf))
    }

    // MARK: - Unknown tags

    func testUnknownTagIsConsumedAndYieldsNil() {
        // A well-framed message with an unknown tag decodes to nil but must be consumed,
        // so one bad frame can't wedge the stream.
        var buf = Data()
        buf.append(contentsOf: [0x00, 0x00, 0x00, 0x03])  // len = tag + 2 payload bytes
        buf.append(contentsOf: [0x7f, 0x01, 0x02])        // unknown tag 0x7f
        buf.append(encode(ClientFrame.list))
        XCTAssertNil(decodeClientFrame(from: &buf), "unknown tag yields nil")
        XCTAssertEqual(decodeClientFrame(from: &buf), .list, "stream continues past it")
        XCTAssertTrue(buf.isEmpty)
    }
}
