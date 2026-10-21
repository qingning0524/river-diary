import Compression
import Foundation
import XCTest

@testable import RiverDiaryMac

final class AppleNotesPayloadTests: XCTestCase {
    func testExtractsBodyAndStripsTitle() throws {
        let payload = try makeGzipPayload(title: "日记项目", text: "日记项目\n今天把采集方案写完了。\n\n明天继续。")
        let body = AppleNotesPayload.extractBody(from: payload, title: "日记项目")
        XCTAssertEqual(body, "今天把采集方案写完了。\n\n明天继续。")
    }

    func testKeepsBodyWhenFirstLineIsNotTitle() throws {
        let payload = try makeGzipPayload(title: "标题", text: "这不是标题\n正文第一行")
        let body = AppleNotesPayload.extractBody(from: payload, title: "标题")
        XCTAssertEqual(body, "这不是标题\n正文第一行")
    }

    func testReturnsNilForEmptyBody() throws {
        let payload = try makeGzipPayload(title: "只有标题", text: "只有标题\n\n  ")
        XCTAssertNil(AppleNotesPayload.extractBody(from: payload, title: "只有标题"))
    }

    func testTruncatesLongBodyWithMarker() {
        let text = String(repeating: "字", count: 30)
        let body = AppleNotesPayload.body(from: text, title: "标题", characterLimit: 10)
        XCTAssertEqual(body, String(repeating: "字", count: 10) + "\n…（正文已截断）")
    }

    func testCollapsesExcessBlankLines() {
        let body = AppleNotesPayload.body(from: "标题\n\n\n\n正文", title: "标题")
        XCTAssertEqual(body, "正文")
    }

    func testRejectsNonGzipData() {
        XCTAssertNil(AppleNotesPayload.extractBody(from: Data("not gzip".utf8), title: "标题"))
    }

    func testRejectsTruncatedGzipData() throws {
        let payload = try makeGzipPayload(title: "标题", text: "标题\n正文")
        XCTAssertNil(AppleNotesPayload.extractBody(from: payload.prefix(8), title: "标题"))
    }

    // MARK: - Fixture

    private func makeGzipPayload(title: String, text: String) throws -> Data {
        let textField = lengthDelimited(field: 2, Data(text.utf8))
        let document = lengthDelimited(field: 3, textField)
        let top = lengthDelimited(field: 2, document)
        return try gzip(top)
    }

    private func lengthDelimited(field: Int, _ payload: Data) -> Data {
        var data = Data(varint(UInt64((field << 3) | 2)))
        data.append(contentsOf: varint(UInt64(payload.count)))
        data.append(payload)
        return data
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private func gzip(_ data: Data) throws -> Data {
        guard let deflated = deflate(data) else {
            throw XCTSkip("Compression framework could not deflate test fixture")
        }
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x13])
        output.append(deflated)
        output.append(contentsOf: littleEndian(crc32(data)))
        output.append(contentsOf: littleEndian(UInt32(data.count)))
        return output
    }

    private func deflate(_ data: Data) -> Data? {
        var capacity = max(64, data.count * 2)
        for _ in 0..<4 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { outputBuffer -> Int in
                data.withUnsafeBytes { inputBuffer -> Int in
                    guard let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_encode_buffer(
                        outputBase, capacity,
                        inputBase, data.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 { return output.prefix(written) }
            capacity *= 4
        }
        return nil
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    private func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }
}
