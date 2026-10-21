import Compression
import Foundation

/// Apple Notes 把一条笔记的正文存成 gzip 包裹的 protobuf（`ZICNOTEDATA.ZDATA`）。
///
/// 这里只做两件事，且都可单独测试：
/// 1. 跳过 gzip 头，用 Deflate 解压；
/// 2. 在最小的 protobuf 读取器里取出 `Document.note.text`。
///
/// 不依赖 AppleScript / Automation 权限，也不依赖 Notes 的完整 protobuf schema；
/// schema 变化时返回 nil，由调用方如实标记“无法读取”，而不是伪造一个空正文。
enum AppleNotesPayload {
    /// 单条笔记最多保存的正文长度。Notes 正文可能很长；日记需要的是可引用的证据，
    /// 不是把整本笔记搬进数据库。
    static let defaultCharacterLimit = 20_000
    private static let inflateCapacities = [1 << 20, 8 << 20, 32 << 20]

    static func extractBody(
        from compressed: Data,
        title: String,
        characterLimit: Int = defaultCharacterLimit
    ) -> String? {
        guard let raw = gunzip(compressed) else { return nil }
        guard let document = Proto.firstBytes(field: 2, in: raw),
              let note = Proto.firstBytes(field: 3, in: document),
              let textData = Proto.firstBytes(field: 2, in: note),
              let text = String(data: textData, encoding: .utf8) else {
            return nil
        }
        return body(from: text, title: title, characterLimit: characterLimit)
    }

    /// 把 protobuf 里的全文（通常第一行是标题）变成正文。
    /// 不静默改写内容：只去标题行、统一换行、压掉连续空行和控制字符。
    static func body(from text: String, title: String, characterLimit: Int = defaultCharacterLimit) -> String? {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        normalized = String(normalized.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.value >= 0x20
        })

        var lines = normalized.components(separatedBy: "\n")
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = lines.first,
           !trimmedTitle.isEmpty,
           first.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedTitle {
            lines.removeFirst()
        }

        var body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        while body.contains("\n\n\n") {
            body = body.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        guard !body.isEmpty else { return nil }

        let limit = max(1, characterLimit)
        if body.count > limit {
            return String(body.prefix(limit)) + "\n…（正文已截断）"
        }
        return body
    }

    static func gunzip(_ data: Data) -> Data? {
        guard let deflate = deflatePayload(data) else { return nil }
        for capacity in inflateCapacities {
            if let output = inflate(deflate, capacity: capacity) {
                return output
            }
        }
        return nil
    }

    private static func deflatePayload(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18,
              bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }
        let flags = bytes[3]
        var index = 10

        if flags & 0x04 != 0 { // FEXTRA
            guard index + 2 <= bytes.count else { return nil }
            let length = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2 + length
        }
        if flags & 0x08 != 0 { // FNAME
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { // FHCRC
            index += 2
        }
        guard index >= 10, index < bytes.count - 8 else { return nil }
        return Data(bytes[index..<(bytes.count - 8)])
    }

    private static func inflate(_ deflate: Data, capacity: Int) -> Data? {
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outputBuffer -> Int in
            deflate.withUnsafeBytes { inputBuffer -> Int in
                guard let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    outputBase, capacity,
                    inputBase, deflate.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }
}

// MARK: - Minimal protobuf reader

private enum Proto {
    struct Field {
        let number: Int
        let wireType: Int
        let bytes: Data?
        let value: UInt64?
    }

    static func firstBytes(field: Int, in data: Data) -> Data? {
        fields(in: data)?.first { $0.number == field && $0.wireType == 2 }?.bytes
    }

    static func fields(in data: Data) -> [Field]? {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [Field] = []

        while index < bytes.count {
            guard let key = readVarint(bytes, &index), key > 0 else { return nil }
            let number = Int(key >> 3)
            let wireType = Int(key & 0x07)
            guard number > 0 else { return nil }

            switch wireType {
            case 0:
                guard let value = readVarint(bytes, &index) else { return nil }
                fields.append(Field(number: number, wireType: 0, bytes: nil, value: value))
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                index += 8
                fields.append(Field(number: number, wireType: 1, bytes: nil, value: nil))
            case 2:
                guard let length = readVarint(bytes, &index), length <= UInt64(bytes.count - index) else {
                    return nil
                }
                let end = index + Int(length)
                fields.append(Field(number: number, wireType: 2, bytes: Data(bytes[index..<end]), value: nil))
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                index += 4
                fields.append(Field(number: number, wireType: 5, bytes: nil, value: nil))
            default:
                return nil
            }
        }
        return fields
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            guard shift < 64 else { return nil }
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
