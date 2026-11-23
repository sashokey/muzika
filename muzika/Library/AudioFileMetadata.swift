import AudioToolbox
import AVFoundation
import Foundation

nonisolated enum AudioFileMetadata {
    static let supportedExtensions: Set<String> = [
        "aac", "ac3", "aif", "aifc", "aiff", "caf", "eac3", "flac", "m4a", "m4b",
        "mp2", "mp3", "mp4", "snd", "au", "wav", "wave"
    ]

    enum ReadError: LocalizedError {
        case unreadable(OSStatus)
        case empty
        case offline

        var errorDescription: String? { LibraryScanIssue.localize(message) }

        var message: String {
            switch self {
            case .unreadable(let status): "The audio file could not be opened (\(status))."
            case .empty: "The file does not contain a playable audio stream."
            case .offline: "The item is not available offline."
            }
        }
    }

    static func read(_ url: URL, addedAt: Date, isTemporary: Bool) async throws -> AudioTrack {
        try Task.checkCancellation()
        guard !url.needsDownload else { throw ReadError.offline }
        var handle: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &handle)
        guard status == noErr, let handle else { throw ReadError.unreadable(status) }
        defer { AudioFileClose(handle) }

        guard let stream = property(handle, kAudioFilePropertyDataFormat, default: AudioStreamBasicDescription()),
              stream.mSampleRate.isFinite, stream.mSampleRate > 0,
              stream.mChannelsPerFrame > 0 else { throw ReadError.empty }
        let duration = property(handle, kAudioFilePropertyEstimatedDuration, default: 0.0)
        guard let duration, duration.isFinite, duration > 0 else { throw ReadError.empty }
        let bitrate = property(handle, kAudioFilePropertyBitRate, default: UInt32(0)).flatMap(positive)
        let info = infoDictionary(handle)
        let flac = stream.mFormatID == kAudioFormatFLAC ? try? FLACMetadata.load(url) : nil
        let values = flac?.comments ?? [:]
        let items = flac == nil ? await metadata(at: url) : []

        func value(_ tags: [String], metadata identifiers: [String], info key: String? = nil) async -> String? {
            for tag in tags {
                if let value = clean(values[tag]) { return value }
            }
            if let value = await text(in: items, identifiers) { return value }
            return key.flatMap { clean(info[$0]) }
        }

        let title = await value(["TITLE"], metadata: ["common/title", "id3/TIT2", "itsk/©nam"], info: "title")
        let artist = await value(["ARTIST"], metadata: ["common/artist", "id3/TPE1", "itsk/©ART"], info: "artist") ?? ""
        let album = await value(["ALBUM"], metadata: ["common/albumName", "id3/TALB", "itsk/©alb"], info: "album") ?? ""
        let albumArtist = await value(["ALBUMARTIST", "ALBUM ARTIST"], metadata: ["itsk/aART", "id3/TPE2"]) ?? artist
        let genre = await value(["GENRE"], metadata: ["id3/TCON", "itsk/©gen"], info: "genre") ?? ""
        let date = await value(["DATE", "YEAR", "ORIGINALDATE"], metadata: ["itsk/©day", "id3/TDRC", "id3/TYER", "common/creationDate"], info: "year")
            ?? clean(info["recorded date"])
        let disc = position(clean(values["DISCNUMBER"]) ?? clean(values["DISC"]))
        let track = position(clean(values["TRACKNUMBER"]) ?? clean(values["TRACK"]))
        let nativeDisc = await position(in: items, ["itsk/disk", "id3/TPOS"])
        let nativeTrack = await position(in: items, ["itsk/trkn", "id3/TRCK"])
        let fileTrack = position(clean(info["track number"]))
        return AudioTrack(
            id: url.path,
            url: url,
            title: title ?? url.deletingPathExtension().lastPathComponent,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: genre,
            discNumber: disc.number ?? nativeDisc.number ?? 0,
            trackNumber: track.number ?? nativeTrack.number ?? fileTrack.number ?? 0,
            year: date.flatMap(releaseYear),
            duration: duration,
            codec: codec(stream.mFormatID, extension: url.pathExtension),
            bitDepth: flac?.bitsPerSample ?? bitDepth(of: stream),
            sampleRate: stream.mSampleRate,
            bitrate: bitrate,
            channels: Int(stream.mChannelsPerFrame),
            addedAt: addedAt,
            isTemporary: isTemporary,
            trackTotal: positiveTag(values["TRACKTOTAL"] ?? values["TOTALTRACKS"]) ?? track.total ?? nativeTrack.total ?? fileTrack.total,
            discTotal: positiveTag(values["DISCTOTAL"] ?? values["TOTALDISCS"]) ?? disc.total ?? nativeDisc.total
        )
    }

    @concurrent
    static func embeddedLyrics(at url: URL) async throws -> String? {
        guard !url.needsDownload else { return nil }
        if url.pathExtension.lowercased() == "flac" {
            let tags = try FLACMetadata.load(url).comments
            if let lyrics = clean(tags["LYRICS"] ?? tags["UNSYNCEDLYRICS"] ?? tags["UNSYNCHRONIZEDLYRICS"]) {
                return lyrics
            }
        }
        let items = await metadata(at: url)
        return await text(in: items, ["itsk/©lyr", "id3/USLT", "id3/ULT"])
    }

    @concurrent
    static func artwork(at url: URL) async -> Data? {
        guard !url.needsDownload else { return nil }
        if url.pathExtension.lowercased() == "flac",
           let image = try? FLACMetadata.load(url, includeArtwork: true).artwork {
            return image
        }
        let items = await metadata(at: url)
        for item in items where item.commonKey == .commonKeyArtwork ||
            ["itsk/covr", "id3/APIC", "id3/PIC"].contains(item.identifier?.rawValue ?? "") {
            if let image = try? await item.load(.dataValue), !image.isEmpty { return image }
        }
        let parent = url.deletingLastPathComponent()
        for name in ["cover", "folder", "front", "Cover", "Folder", "Front"] {
            for suffix in ["jpg", "jpeg", "png"] {
                let file = parent.appending(path: name).appendingPathExtension(suffix)
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 0, size <= 32 * 1024 * 1024, !file.needsDownload else { continue }
                if let image = try? Data(contentsOf: file, options: .mappedIfSafe) { return image }
            }
        }
        return nil
    }

    private static func property<T>(_ file: AudioFileID, _ key: AudioFilePropertyID, default value: T) -> T? {
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &result) {
            AudioFileGetProperty(file, key, &size, $0.baseAddress!)
        }
        return status == noErr ? result : nil
    }

    private static func infoDictionary(_ file: AudioFileID) -> [String: Any] {
        let value: Unmanaged<CFDictionary>? = nil
        guard let result = property(file, kAudioFilePropertyInfoDictionary, default: value),
              let result else { return [:] }
        return result.takeRetainedValue() as NSDictionary as? [String: Any] ?? [:]
    }

    private static func metadata(at url: URL) async -> [AVMetadataItem] {
        let asset = AVURLAsset(url: url)
        let all = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        return all + common
    }

    private static func text(in items: [AVMetadataItem], _ identifiers: [String]) async -> String? {
        for identifier in identifiers {
            for item in items where item.identifier?.rawValue == identifier {
                if let value = try? await item.load(.stringValue), let value = clean(value) { return value }
            }
        }
        return nil
    }

    private struct Position {
        var number: Int?
        var total: Int?
    }

    private static func position(in items: [AVMetadataItem], _ identifiers: [String]) async -> Position {
        for identifier in identifiers {
            for item in items where item.identifier?.rawValue == identifier {
                if identifier.hasPrefix("itsk/"),
                   let bytes = try? await item.load(.dataValue), bytes.count >= 6 {
                    func field(at offset: Int) -> Int? {
                        let index = bytes.startIndex + offset
                        let value = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                        return value > 0 ? value : nil
                    }
                    let result = Position(number: field(at: 2), total: field(at: 4))
                    if result.number != nil || result.total != nil { return result }
                }
                if let value = try? await item.load(.stringValue) {
                    let result = position(value)
                    if result.number != nil || result.total != nil { return result }
                }
                if let value = try? await item.load(.numberValue), value.intValue > 0 {
                    return Position(number: value.intValue)
                }
            }
        }
        return Position()
    }

    private static func clean(_ value: Any?) -> String? {
        let text: String?
        switch value {
        case let string as String: text = string
        case let number as NSNumber: text = number.stringValue
        default: text = nil
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func positive(_ value: UInt32) -> Int? { value > 0 ? Int(value) : nil }

    private static func positiveTag(_ value: String?) -> Int? {
        guard let value, let number = Int(value.trimmingCharacters(in: .whitespaces)),
              number > 0 else { return nil }
        return number
    }

    private static func position(_ value: String?) -> Position {
        let parts = value?.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false) ?? []
        return Position(number: positiveTag(parts.first.map(String.init)),
                        total: parts.count > 1 ? positiveTag(String(parts[1])) : nil)
    }

    private static func releaseYear(_ value: String) -> Int? {
        guard let year = Int(value.prefix(4)), (1...9_999).contains(year) else { return nil }
        return year
    }

    private static func codec(_ format: AudioFormatID, extension suffix: String) -> String {
        switch format {
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatMPEGLayer2: "MP2"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "AAC"
        case kAudioFormatAC3: "AC-3"
        case kAudioFormatEnhancedAC3: "E-AC-3"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatLinearPCM: suffix.isEmpty ? "PCM" : suffix.uppercased()
        default: suffix.isEmpty ? "Audio" : suffix.uppercased()
        }
    }

    private static func bitDepth(of stream: AudioStreamBasicDescription) -> Int? {
        if stream.mFormatID == kAudioFormatAppleLossless {
            return switch stream.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: 16
            case kAppleLosslessFormatFlag_20BitSourceData: 20
            case kAppleLosslessFormatFlag_24BitSourceData: 24
            case kAppleLosslessFormatFlag_32BitSourceData: 32
            default: nil
            }
        }
        return positive(stream.mBitsPerChannel)
    }
}
