import Foundation

nonisolated struct FLACMetadata {
    var comments: [String: String] = [:]
    var artwork: Data?
    var bitsPerSample: Int?

    static func load(_ url: URL, includeArtwork: Bool = false) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { return Self() }
        var result = Self()
        var selectedPictureType: UInt32?
        while let header = try handle.read(upToCount: 4), header.count == 4 {
            let kind = header[0] & 0x7f
            let count = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if kind == 0 || kind == 4 || kind == 6 && includeArtwork && selectedPictureType != 3 {
                guard let block = try handle.read(upToCount: count), block.count == count else { break }
                switch kind {
                case 0:
                    if block.count == 34 {
                        result.bitsPerSample = Int((block[12] & 1) << 4 | block[13] >> 4) + 1
                    }
                case 4:
                    result.comments = comments(in: block)
                case 6:
                    if let picture = picture(in: block), selectedPictureType == nil || picture.type == 3 {
                        selectedPictureType = picture.type
                        result.artwork = picture.data
                    }
                default:
                    break
                }
            } else {
                let offset = try handle.offset()
                try handle.seek(toOffset: offset + UInt64(count))
            }
            if header[0] & 0x80 != 0 { break }
        }
        return result
    }

    private static func comments(in block: Data) -> [String: String] {
        var reader = Reader(data: block)
        guard let vendorLength = reader.integer(littleEndian: true),
              reader.skip(Int(vendorLength)),
              let count = reader.integer(littleEndian: true) else { return [:] }
        var result: [String: String] = [:]
        for _ in 0..<count {
            guard let length = reader.integer(littleEndian: true),
                  let data = reader.read(Int(length)),
                  let item = String(data: data, encoding: .utf8) else { break }
            guard let separator = item.firstIndex(of: "=") else { continue }
            let key = item[..<separator].uppercased()
            let value = String(item[item.index(after: separator)...])
            if !value.isEmpty, result[key] == nil { result[key] = value }
        }
        return result
    }

    private static func picture(in block: Data) -> (type: UInt32, data: Data)? {
        var reader = Reader(data: block)
        guard let type = reader.integer(),
              let mimeLength = reader.integer(),
              let mime = reader.read(Int(mimeLength)),
              mime != Data("-->".utf8),
              let descriptionLength = reader.integer(),
              reader.skip(Int(descriptionLength)),
              reader.skip(16),
              let imageLength = reader.integer(),
              imageLength > 0,
              let image = reader.read(Int(imageLength)) else { return nil }
        return (type, Data(image))
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func skip(_ count: Int) -> Bool {
            guard count <= data.count - offset else { return false }
            offset += count
            return true
        }

        mutating func read(_ count: Int) -> Data? {
            let start = offset
            guard skip(count) else { return nil }
            return data[start..<offset]
        }

        mutating func integer(littleEndian: Bool = false) -> UInt32? {
            guard let bytes = read(4) else { return nil }
            let ordered = littleEndian ? Array(bytes.reversed()) : Array(bytes)
            return ordered.reduce(0) { ($0 << 8) | UInt32($1) }
        }
    }
}
