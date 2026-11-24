import Foundation

public struct SpikeExportRow: Codable, Sendable, Equatable {
    public var rank: Int
    public var timeSeconds: Double
    public var timecode: String
    public var zScore: Double
    public var messages: Int
    public var peakMessagesPerSecond: Double
    public var topEmotes: [String]
    public var transcript: String
    public var url: String
}

public enum SpikeExport {
    /// `timestamped` is false for a live monitor, whose times count from when monitoring began, not from the video start.
    public static func rows(spikes: [Spike], transcript: [TranscriptSegment], stream: StreamURL,
                            settings: SpikeSettings, timestamped: Bool = true) -> [SpikeExportRow] {
        spikes.enumerated().map { index, spike in
            let said = TranscriptPairing.window(transcript, around: spike, settings: settings)
                .map(\.text).joined(separator: " ")
            return SpikeExportRow(
                rank: index + 1,
                timeSeconds: spike.time,
                timecode: Timecode.string(spike.time),
                zScore: (spike.zScore * 100).rounded() / 100,
                messages: spike.messageCount,
                peakMessagesPerSecond: (spike.peakPerSecond * 100).rounded() / 100,
                topEmotes: spike.topEmotes.map { "\($0.name) x\($0.count)" },
                transcript: said,
                url: timestamped ? stream.link(at: max(0, spike.windowStart(settings))) : stream.link())
        }
    }

    public static func json(title: String, stream: StreamURL, rows: [SpikeExportRow], settings: SpikeSettings) throws -> Data {
        struct Document: Encodable {
            var title: String
            var platform: String
            var url: String
            var generatedAt: Date
            var zThreshold: Double
            var minMessages: Int
            var bucketSeconds: Int
            var spikes: [SpikeExportRow]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(
            title: title, platform: stream.platform.rawValue, url: stream.link(), generatedAt: Date(),
            zThreshold: settings.zThreshold, minMessages: settings.minMessages,
            bucketSeconds: settings.bucketSeconds, spikes: rows))
    }

    public static func csv(_ rows: [SpikeExportRow]) -> String {
        var lines = ["rank,time_seconds,timecode,z_score,messages,peak_msgs_per_sec,top_emotes,transcript,url"]
        for row in rows {
            let fields = [
                String(row.rank), String(format: "%.1f", row.timeSeconds), row.timecode, String(row.zScore),
                String(row.messages), String(row.peakMessagesPerSecond),
                row.topEmotes.joined(separator: " "), row.transcript, row.url,
            ]
            lines.append(fields.map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A Markdown list, one block per spike, for pasting into notes or a video description.
    public static func markdown(title: String, rows: [SpikeExportRow]) -> String {
        var out = "# \(title)\n\n"
        for row in rows {
            out += "## #\(row.rank) · \(row.timecode) · z \(row.zScore)\n\n"
            out += "- Chat: \(row.messages) messages, \(row.peakMessagesPerSecond) per second"
            if !row.topEmotes.isEmpty { out += ", \(row.topEmotes.joined(separator: ", "))" }
            out += "\n- Link: \(row.url)\n"
            if !row.transcript.isEmpty { out += "\n> \(row.transcript)\n" }
            out += "\n"
        }
        return out
    }

    /// One line per spike in time order, as `start end label`, the window to cut a clip from.
    /// Times are `h:mm:ss`. A live monitor's times count from when monitoring began.
    public static func clipList(spikes: [Spike], settings: SpikeSettings) -> String {
        spikes.sorted { $0.time < $1.time }.map { spike in
            let start = spike.windowStart(settings), end = spike.time + settings.postRoll
            let label = spike.topEmotes.first.map { " \($0.name)" } ?? ""
            return "\(Timecode.string(start)) \(Timecode.string(end)) spike z\(String(format: "%.1f", spike.zScore))\(label)"
        }.joined(separator: "\n") + "\n"
    }

    /// Chapter lines for a YouTube description, in time order. YouTube needs the first at 0:00, a minimum of three,
    /// and 10 s between lines, so the first line is added when missing and close neighbours are dropped.
    public static func chapters(spikes: [Spike], settings: SpikeSettings) -> String {
        var lines = ["0:00 Start"]
        var last = 0.0
        for spike in spikes.sorted(by: { $0.time < $1.time }) {
            let at = spike.windowStart(settings) + settings.preRoll
            guard at - last >= 10 else { continue }
            lines.append("\(Timecode.string(at)) Chat spike\(spike.topEmotes.first.map { " \($0.name)" } ?? "")")
            last = at
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quote(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Chat, transcript, and spikes as compressed blobs, for the database.
public enum SessionCodec {
    public static func encode<T: Encodable>(_ value: T) -> Data? {
        guard let json = try? JSONEncoder().encode(value) else { return nil }
        return try? (json as NSData).compressed(using: .lzfse) as Data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data, let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(type, from: json)
    }
}
