import AppKit
import SwiftUI

struct TrackInfoView: View {
    let library: LibraryStore
    let track: AudioTrack
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics: LyricsDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                PlayingCover(library: library, track: track, maxPixels: 140)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.title2.bold())
                    Text(track.artist).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Form {
                Section("Metadata") {
                    item("Title", track.title)
                    item("Artist", track.artist)
                    item("Album", track.album)
                    item("Album Artist", track.albumArtist)
                    item("Genre", track.genre)
                    if let year = track.year { item("Year", String(year)) }
                    if track.discNumber > 0 { item("Disc", position(track.discNumber, total: track.discTotal)) }
                    if track.trackNumber > 0 { item("Track", position(track.trackNumber, total: track.trackTotal)) }
                }
                Section("Audio info") {
                    item("File format", track.codecTitle)
                    item("Duration", elapsedLabel(track.duration))
                    if let bitDepth = track.formattedBitDepth { item("Bit Depth", bitDepth) }
                    if let sampleRate = track.formattedSampleRate { item("Sample Rate", sampleRate) }
                    if let bitrate = track.formattedBitrate { item("Bitrate", bitrate) }
                    if let channels = track.channels { item("Channels", String(channels)) }
                    item("Path", track.url.path)
                }
                if let lyrics, !lyrics.lines.isEmpty {
                    Section("Lyrics") {
                        Text(lyrics.lines.map(\.text).joined(separator: "\n"))
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Copy metadata") {
                    copy([track.title, track.artist, track.album, track.genre, track.quality].filter { !$0.isEmpty }.joined(separator: "\n"))
                }
                .buttonStyle(GlassHoverButtonStyle())
                Button("Copy path") { copy(track.url.path) }
                    .buttonStyle(GlassHoverButtonStyle())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(GlassHoverButtonStyle.accent())
            }
        }
        .padding(20)
        .frame(minWidth: 490, idealWidth: 630, minHeight: 410, idealHeight: 590)
        .task(id: track.id) {
            lyrics = nil
            let loaded = try? await library.lyrics(for: track)
            if !Task.isCancelled { lyrics = loaded }
        }
    }

    private func position(_ number: Int, total: Int?) -> String {
        total.map { String(localized: "\(number) of \($0)") } ?? String(number)
    }

    @ViewBuilder
    private func item(_ label: LocalizedStringResource, _ value: String) -> some View {
        if !value.isEmpty {
            LabeledContent(label) { Text(value).textSelection(.enabled) }
                .contextMenu { Button("Copy") { copy(value) } }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
