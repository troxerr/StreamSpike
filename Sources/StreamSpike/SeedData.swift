import Foundation
import SwiftData
import StreamSpikeKit

/// Sample streams for snapshots: APP_SEED=1 with APP_STORE in /tmp fills an empty store with a
/// Twitch and a YouTube stream that have chat, a transcript, and spikes, and a Kick stream that failed.
/// The chat is generated from a fixed seed, so every run draws the same chart.
@MainActor
enum SeedData {
    static func insertIfRequested(into model: AppModel) {
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1" else { return }
        guard Store.isOverridden else {
            print("APP_SEED ignored: APP_STORE must be a file in /tmp")
            return
        }
        guard ((try? model.context.fetchCount(FetchDescriptor<StreamSession>())) ?? 0) == 0 else { return }
        insertSamples(into: model)
    }

    /// Also used by the self-test.
    static func insertSamples(into model: AppModel) {
        let detection = SpikeSettings()
        let samples: [(Platform, String, String, String, Double, [(Double, Int)])] = [
            (.twitch, "https://www.twitch.tv/videos/2937522247", "Oops! All Final Fantasy: NES Trilogy Any% Race",
             "Games Done Quick", 5400, [(420, 70), (900, 45), (1500, 130), (2100, 55), (2760, 95), (3400, 60), (4100, 150), (4800, 50)]),
            (.youtube, "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "Shadow of the Erdtree: First Playthrough, Part 4",
             "Night Owl Plays", 3600, [(600, 60), (1320, 110), (2400, 50), (3000, 85)]),
        ]
        for (index, sample) in samples.enumerated() {
            guard let url = StreamURL.parse(sample.1) else { continue }
            let session = StreamSession(url: url, mode: .vod, limitSeconds: 0)
            session.title = sample.2
            session.channel = sample.3
            session.duration = sample.4
            session.createdAt = Date.now.addingTimeInterval(Double(-index) * 3_600)
            let chat = makeChat(duration: sample.4, bursts: sample.5, seed: UInt64(index + 7))
            let transcript = makeTranscript(duration: sample.4)
            let analysis = SpikeDetector.analyze(messages: chat, settings: detection, duration: sample.4)
            let spikes = TranscriptPairing.attach(transcript, to: analysis.spikes, settings: detection)
            session.chatData = SessionCodec.encode(chat)
            session.transcriptData = SessionCodec.encode(transcript)
            session.spikesData = SessionCodec.encode(spikes)
            session.chatCount = chat.count
            session.segmentCount = transcript.count
            session.spikeCount = spikes.count
            session.transcriptSource = url.platform == .youtube ? "YouTube captions" : "Whisper"
            session.status = .complete
            model.context.insert(session)
        }
        if let url = StreamURL.parse("https://kick.com/video/6f2c1b7e-0000-4000-8000-000000000000") {
            let session = StreamSession(url: url, mode: .vod, limitSeconds: 0)
            session.title = "Kick Late Night Stream"
            session.createdAt = Date.now.addingTimeInterval(-7_200)
            session.status = .failed
            session.statusDetail = "Kick has no chat replay that chat_downloader can read."
            model.context.insert(session)
        }
        try? model.context.save()
        model.selection = model.allSessions().first?.uuid
    }

    // MARK: Generators

    private struct RNG {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private static let plain = ["lol", "nice", "gg", "hello chat", "first time here", "this run is so clean", "what is this route",
                                "how long has this been going", "good luck", "yooo", "that was close", "sheesh"]
    private static let hype = ["KEKW", "LUL", "OMEGALUL", "W", "???", "OMG", "CLIP IT", "PogChamp", "no way", "LETS GOOO", "monkaS", "CLIP"]
    private static let names = ["pixelfox", "n0va", "ghost_run", "tilted_toast", "mossy", "arcadia", "bigbrain", "sunnyd", "k1ra", "zeroday"]

    static func makeChat(duration: Double, bursts: [(Double, Int)], seed: UInt64) -> [ChatMessage] {
        var rng = RNG(state: seed &* 7919)
        var messages: [ChatMessage] = []
        var t = 0.0
        while t < duration {
            let rate = 4 + 2 * sin(t / 300) + rng.next() * 3
            let count = Int(rate)
            for _ in 0..<count {
                messages.append(ChatMessage(time: t + rng.next() * 10, author: names[Int(rng.next() * Double(names.count))],
                                            text: plain[Int(rng.next() * Double(plain.count))]))
            }
            t += 10
        }
        for (time, size) in bursts {
            for _ in 0..<size {
                let word = hype[Int(rng.next() * Double(hype.count))]
                messages.append(ChatMessage(time: time + rng.next() * 12, author: names[Int(rng.next() * Double(names.count))], text: word))
            }
        }
        return messages.sorted { $0.time < $1.time }
    }

    private static let lines = [
        "Alright, we're back and the timer is looking good.",
        "Okay so this next section is where most runs fall apart.",
        "I'm going to skip the cutscene here, you can see the buffer.",
        "Chat, do not spoil the next boss for anyone who's new.",
        "That is the cleanest transition I've pulled off all week.",
        "Oh no, oh no, hold on, I think I mistimed that jump.",
        "Wait, what? Did that just actually work?",
        "Okay, we are recovering, this is still a pace run.",
        "Thanks for the subs, I really appreciate every one of you.",
        "Let me grab a drink and then we get into the final stretch.",
    ]

    static func makeTranscript(duration: Double) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var t = 2.0
        var i = 0
        while t < duration {
            segments.append(TranscriptSegment(start: t, end: t + 5, text: lines[i % lines.count]))
            t += 6
            i += 1
        }
        return segments
    }
}
