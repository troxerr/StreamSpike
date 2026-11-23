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
    public static func rows(spikes: [Spike], transcript: [TranscriptSegment], stream: StreamURL,
                            settings: SpikeSettings) -> [SpikeExportRow] {
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
                url: stream.link(at: max(0, spike.time - settings.preRoll)))
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
                String(row.rank), String(Int(row.timeSeconds)), row.timecode, String(row.zScore),
                String(row.messages), String(row.peakMessagesPerSecond),
                row.topEmotes.joined(separator: " "), row.transcript, row.url,
            ]
            lines.append(fields.map(quote).joined(separator: ","))
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
