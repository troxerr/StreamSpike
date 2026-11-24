import Foundation
import Testing
@testable import StreamSpikeKit

// MARK: - URLs

@Suite("StreamURL")
struct StreamURLTests {
    @Test func youtubeForms() {
        for text in ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "youtu.be/dQw4w9WgXcQ?t=5",
                     "https://youtube.com/live/dQw4w9WgXcQ", "https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=x"] {
            let url = StreamURL.parse(text)
            #expect(url?.platform == .youtube, "\(text)")
            #expect(url?.id == "dQw4w9WgXcQ", "\(text)")
        }
        #expect(StreamURL.parse("https://www.youtube.com/watch?v=short") == nil)
    }

    @Test func twitchLinks() {
        let vod = StreamURL.parse("https://www.twitch.tv/videos/2937522247")
        #expect(vod?.platform == .twitch && vod?.kind == .vod && vod?.id == "2937522247")
        let channel = StreamURL.parse("twitch.tv/Shroud")
        #expect(channel?.kind == .live && channel?.id == "shroud")
        #expect(StreamURL.parse("https://kick.com/video/abc-123") == nil)
        #expect(StreamURL.parse("https://kick.com/xqc") == nil)
        #expect(StreamURL.parse("https://example.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(StreamURL.parse("") == nil)
    }

    @Test func timestampLinks() {
        let youtube = StreamURL.parse("youtu.be/dQw4w9WgXcQ")!
        #expect(youtube.link(at: 125.9) == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=125s")
        let twitch = StreamURL.parse("twitch.tv/videos/99")!
        #expect(twitch.link(at: 3725) == "https://www.twitch.tv/videos/99?t=1h2m5s")
        #expect(twitch.supports(.vod) && !twitch.supports(.live))
        #expect(youtube.supports(.live))
    }
}

// MARK: - Spike detection

@Suite("SpikeDetector")
struct SpikeDetectorTests {
    /// 3 messages per 10 s with a little wobble, for `minutes`.
    func background(minutes: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for bucket in 0..<(minutes * 6) {
            let n = 3 + (bucket % 3)
            for k in 0..<n {
                messages.append(ChatMessage(time: Double(bucket * 10) + Double(k), author: "a", text: "hello"))
            }
        }
        return messages
    }

    func burst(at time: Double, count: Int, text: String = "KEKW") -> [ChatMessage] {
        (0..<count).map { ChatMessage(time: time + Double($0) * 10 / Double(count), author: "b", text: text) }
    }

    @Test func findsABurstAndPairsItsTime() {
        let messages = background(minutes: 10) + burst(at: 400, count: 60)
        let analysis = SpikeDetector.analyze(messages: messages, settings: SpikeSettings(), duration: 600)
        #expect(analysis.buckets.count == 60)
        #expect(analysis.spikes.count == 1)
        let spike = analysis.spikes[0]
        #expect(spike.time == 400)
        #expect(spike.zScore > 2.5)
        #expect(spike.messageCount >= 60)
        #expect(spike.topEmotes.first?.name == "KEKW")
    }

    @Test func flatChatHasNoSpikes() {
        let analysis = SpikeDetector.analyze(messages: background(minutes: 10), settings: SpikeSettings())
        #expect(analysis.spikes.isEmpty)
    }

    @Test func messageFloorBlocksSmallBursts() {
        // 8 messages is far above a quiet baseline, but under the floor of 10.
        let messages = background(minutes: 10).filter { $0.time < 300 } + burst(at: 400, count: 8)
        var settings = SpikeSettings()
        #expect(SpikeDetector.analyze(messages: messages, settings: settings).spikes.isEmpty)
        settings.minMessages = 5
        #expect(!SpikeDetector.analyze(messages: messages, settings: settings).spikes.isEmpty)
    }

    @Test func hypeKeywordsLiftTheScore() {
        let plain = background(minutes: 10) + burst(at: 400, count: 14, text: "hello")
        let hype = background(minutes: 10) + burst(at: 400, count: 14, text: "KEKW")
        let plainZ = SpikeDetector.analyze(messages: plain, settings: SpikeSettings()).buckets[40].z
        let hypeZ = SpikeDetector.analyze(messages: hype, settings: SpikeSettings()).buckets[40].z
        #expect(hypeZ > plainZ)
    }

    @Test func neighbouringBucketsMergeIntoOneSpike() {
        let messages = background(minutes: 10) + burst(at: 400, count: 60) + burst(at: 410, count: 50)
        let analysis = SpikeDetector.analyze(messages: messages, settings: SpikeSettings())
        #expect(analysis.spikes.count == 1)
        #expect(analysis.spikes[0].runEnd - analysis.spikes[0].runStart >= 20)
    }

    @Test func rankedByZScore() {
        let messages = background(minutes: 20) + burst(at: 400, count: 40) + burst(at: 900, count: 120)
        let spikes = SpikeDetector.analyze(messages: messages, settings: SpikeSettings()).spikes
        #expect(spikes.count == 2)
        #expect(spikes[0].time == 900)
    }

    @Test func emoteDetection() {
        let matcher = KeywordMatcher(SpikeSettings().hypeKeywords)
        #expect(matcher.emotes(in: "KEKW that was PogChamp wow").sorted() == ["KEKW", "PogChamp"])
        #expect(matcher.emotes(in: "w").contains("W"))
        #expect(matcher.emotes(in: "what????").contains("???"))
        #expect(matcher.emotes(in: "hello there friend").isEmpty)
        #expect(matcher.weight(of: "clip it!") == 2.0)
        #expect(matcher.weight(of: "nothing here") == 1.0)
    }
}

// MARK: - Transcripts

@Suite("Transcripts")
struct TranscriptTests {
    @Test func parsesTranscriptAPIJSON() {
        let json = #"[[{"text": "hello\nworld", "start": 1.5, "duration": 2.0}, {"text": "  ", "start": 4, "duration": 1}]]"#
        let segments = TranscriptParsers.youtubeTranscriptAPI(json)
        #expect(segments == [TranscriptSegment(start: 1.5, end: 3.5, text: "hello world")])
    }

    @Test func parsesJSON3() {
        let json = #"{"events":[{"tStartMs":1000,"dDurationMs":2000,"segs":[{"utf8":"Hi "},{"utf8":"there"}]},{"tStartMs":5000,"segs":[{"utf8":"\n"}]}]}"#
        let segments = TranscriptParsers.json3(Data(json.utf8))
        #expect(segments == [TranscriptSegment(start: 1, end: 3, text: "Hi there")])
    }

    @Test func parsesWhisperLinesWithOffset() {
        let output = """
        [00:00:00.000 --> 00:00:04.320]   Welcome back everyone
        [00:00:04.320 --> 00:00:06.000]   [BLANK_AUDIO]
        [00:00:06.000 --> 00:00:09.500]   Let's go!
        """
        let segments = TranscriptParsers.whisper(output, offset: 40)
        #expect(segments.count == 2)
        #expect(segments[0].start == 40 && segments[0].text == "Welcome back everyone")
        #expect(segments[1].start == 46 && segments[1].end == 49.5)
    }

    @Test func parsesDownloadProgress() {
        #expect(TranscriptParsers.downloadPercent("[download]  45.2% of 12.00MiB at 3MiB/s") == 45.2)
        #expect(TranscriptParsers.downloadPercent("[info] something") == nil)
    }

    @Test func windowAndPreview() {
        let segments = (0..<20).map { TranscriptSegment(start: Double($0 * 10), end: Double($0 * 10 + 8), text: "line \($0)") }
        let window = TranscriptPairing.window(segments, from: 70, to: 115)
        #expect(window.first?.text == "line 7")
        #expect(window.last?.text == "line 11")
        var settings = SpikeSettings()
        settings.preRoll = 30
        let spike = Spike(id: 10, time: 100, zScore: 3, messageCount: 30, peakPerSecond: 3, topEmotes: [],
                          runStart: 100, runEnd: 110, transcriptPreview: "")
        let paired = TranscriptPairing.attach(segments, to: [spike], settings: settings)
        #expect(paired[0].transcriptPreview.contains("line 9"))
    }
}

// MARK: - Chat, export, paths

@Suite("Chat and export")
struct ChatAndExportTests {
    @Test func parsesChatDownloaderLines() {
        let line = #"{"message": "KEKW", "time_in_seconds": 12.5, "author": {"name": "viewer", "id": "1"}, "message_type": "text_message"}"#
        #expect(ChatLineParser.parse(Data(line.utf8)) == ChatMessage(time: 12.5, author: "viewer", text: "KEKW"))
        #expect(ChatLineParser.parse(Data(#"{"message": "early", "time_in_seconds": -4}"#.utf8)) == nil)
        #expect(ChatLineParser.parse(Data("not json".utf8)) == nil)
    }

    @Test func chatBlobRoundTrip() {
        let chat = [ChatMessage(time: 1, author: "a", text: "hi, \"there\""), ChatMessage(time: 2.5, author: "b", text: "KEKW")]
        let data = SessionCodec.encode(chat)
        #expect(SessionCodec.decode([ChatMessage].self, from: data) == chat)
    }

    @Test func csvQuotesFields() {
        let row = SpikeExportRow(rank: 1, timeSeconds: 65, timecode: "1:05", zScore: 3.2, messages: 40,
                                 peakMessagesPerSecond: 4, topEmotes: ["KEKW x9"], transcript: "he said \"go\", then left",
                                 url: "https://example.com")
        let csv = SpikeExport.csv([row])
        #expect(csv.contains("\"he said \"\"go\"\", then left\""))
        #expect(csv.split(separator: "\n").count == 2)
    }

    @Test func expandsTilde() {
        #expect(ToolPaths.expand("~/bin/x") == Dependency.homePath + "/bin/x")
        #expect(ToolPaths.expand("/opt/homebrew/bin/yt-dlp") == "/opt/homebrew/bin/yt-dlp")
        #expect(DependencyStatus.check(path: "/definitely/not/here", mustBeExecutable: true) == .missing)
    }

    @Test func installCommandJoinsBrewPackages() {
        let command = Dependency.installCommand(for: [.ytDlp, .ffmpeg, .chatDownloader])
        #expect(command.hasPrefix("brew install yt-dlp ffmpeg"))
        #expect(command.contains("pipx install chat-downloader"))
    }
}

@Suite("Chat sources")
struct ChatSourceTests {
    @Test func parsesYouTubeReplayLines() {
        let line = #"""
        {"replayChatItemAction":{"actions":[
          {"addChatItemAction":{"item":{"liveChatTextMessageRenderer":{"authorName":{"simpleText":"@fan"},"message":{"runs":[{"text":"nice "},{"emoji":{"emojiId":"😂","shortcuts":[":joy:"]}},{"text":" "},{"emoji":{"emojiId":"UC123/abc","shortcuts":[":_hasanW:"]}}]}}}}},
          {"addChatItemAction":{"item":{"liveChatViewerEngagementMessageRenderer":{"id":"x"}}}}
        ],"videoOffsetTimeMsec":"65500"}}
        """#
        let messages = YouTubeReplayParser.parse(Data(line.utf8))
        #expect(messages == [ChatMessage(time: 65.5, author: "@fan", text: "nice 😂 :_hasanW:")])
        #expect(YouTubeReplayParser.parse(Data(#"{"replayChatItemAction":{"actions":[],"videoOffsetTimeMsec":"-4000"}}"#.utf8)).isEmpty)
        #expect(YouTubeReplayParser.parse(Data("garbage".utf8)).isEmpty)
    }

    @Test func parsesTwitchDlJSON() {
        let json = #"{"comments":[{"contentOffsetSeconds":12,"commenter":{"displayName":"viewer"},"message":{"fragments":[{"text":"hi "},{"text":"KEKW","emote":{"id":"1"}}]}},{"contentOffsetSeconds":3,"commenter":null,"message":{"fragments":[{"text":"early"}]}}]}"#
        let messages = TwitchDlChatSource.parse(Data(json.utf8))
        #expect(messages.map(\.text) == ["early", "hi KEKW"])
        #expect(messages.last?.author == "viewer")
        #expect(TwitchDlChatSource.progress("Loading Comments 56:38/01:11:38 (79%)") == 0.79)
        #expect(TwitchDlChatSource.progress("something else") == nil)
    }

    @Test func optionalToolsAreNeverReportedMissing() {
        let paths = ToolPaths(paths: [.twitchDl: "/nonexistent/twitch-dl"])
        #expect(!paths.missing().contains(.twitchDl))
        #expect(Dependency.twitchDl.isOptional)
    }
}

@Suite("Live chat")
struct LiveChatTests {
    @Test func parsesTwitchIRC() {
        let tagged = #"@badge-info=;color=#FF0000;display-name=Cool\sFan;id=1 :coolfan!coolfan@coolfan.tmi.twitch.tv PRIVMSG #streamer :KEKW that was wild"#
        #expect(TwitchIRCParser.parse(tagged) == .message(author: "Cool Fan", text: "KEKW that was wild"))
        let plain = ":nick!nick@nick.tmi.twitch.tv PRIVMSG #chan :hello: world"
        #expect(TwitchIRCParser.parse(plain) == .message(author: "nick", text: "hello: world"))
        let action = ":nick!nick@nick.tmi.twitch.tv PRIVMSG #chan :\u{1}ACTION waves\u{1}"
        #expect(TwitchIRCParser.parse(action) == .message(author: "nick", text: "waves"))
        #expect(TwitchIRCParser.parse("PING :tmi.twitch.tv") == .ping("tmi.twitch.tv"))
        #expect(TwitchIRCParser.parse(":tmi.twitch.tv 001 justinfan1 :Welcome, GLHF!") == .other)
        #expect(TwitchIRCParser.parse(":tmi.twitch.tv CAP * ACK :twitch.tv/tags") == .other)
    }

    @Test func timesLiveChatFromMonitoringStart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let parser = LiveChatLineParser(startedAt: start)
        func line(_ seconds: Double) -> Data {
            Data(#"{"message":"hi","timestamp":\#(Int((1_000_000 + seconds) * 1_000_000)),"author":{"name":"u"}}"#.utf8)
        }
        #expect(parser.parse(line(12.5))?.time == 12.5)
        #expect(parser.parse(line(-0.5))?.time == 0)
        #expect(parser.parse(line(-300)) == nil)
    }

    @Test func livePlansPickTheRightSources() throws {
        let tools = ToolPaths()
        let twitch = try IngestionPlanner.plan(stream: StreamURL.parse("twitch.tv/streamer")!, mode: .live, tools: tools, limitSeconds: nil)
        #expect(twitch.chat is TwitchIRCChatSource)
        #expect(twitch.transcript is LiveWhisperTranscriptSource)
        let youtube = try IngestionPlanner.plan(stream: StreamURL.parse("youtu.be/dQw4w9WgXcQ")!, mode: .live, tools: tools, limitSeconds: nil)
        #expect(youtube.chat is ReconnectingChatSource)
        #expect(throws: ToolError.self) {
            try IngestionPlanner.plan(stream: StreamURL.parse("twitch.tv/videos/5")!, mode: .live, tools: tools, limitSeconds: nil)
        }
    }
}

@Suite("YouTube live replay lines")
struct LiveReplayTests {
    @Test func timesLiveLinesFromTheirOwnClock() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        func line(_ seconds: Double) -> Data {
            Data(#"{"replayChatItemAction":{"actions":[{"addChatItemAction":{"item":{"liveChatTextMessageRenderer":{"timestampUsec":"\#(Int((2_000_000 + seconds) * 1_000_000))","authorName":{"simpleText":"@fan"},"message":{"runs":[{"text":"hi"}]}}}}}]}}"#.utf8)
        }
        #expect(YouTubeReplayParser.parse(line(7), liveStart: start) == [ChatMessage(time: 7, author: "@fan", text: "hi")])
        #expect(YouTubeReplayParser.parse(line(-600), liveStart: start).isEmpty)
        // Without liveStart a line with no video offset is not a recording's line.
        #expect(YouTubeReplayParser.parse(line(7)).isEmpty)
    }
}

/// A chat source that plays back a script: each attempt delivers its messages, then ends or fails.
private final class ScriptedChat: ChatSource, @unchecked Sendable {
    enum Step { case messages([ChatMessage], fail: Bool) }
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var attempts = 0

    init(_ steps: [Step]) { self.steps = steps }

    func stream() -> AsyncThrowingStream<IngestEvent<ChatMessage>, Error> {
        let step: Step? = lock.withLock {
            attempts += 1
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            guard case .messages(let batch, let fail)? = step else { throw ToolError("no more script") }
            if !batch.isEmpty { continuation.yield(.items(batch)) }
            if fail { throw ToolError("dropped") }
        }
    }
}

@Suite("Reconnecting live chat")
struct ReconnectTests {
    func message(_ time: Double, _ text: String) -> ChatMessage { ChatMessage(time: time, author: "a", text: text) }

    func collect(_ source: ReconnectingChatSource) async throws -> [ChatMessage] {
        var all: [ChatMessage] = []
        for try await event in source.stream() {
            if case .items(let batch) = event { all += batch }
        }
        return all
    }

    @Test func reconnectsAfterADropAndDropsRepeatedBacklog() async throws {
        let first = [message(1, "a"), message(2, "b")]
        let second = [message(2, "b"), message(3, "c")]
        let script = ScriptedChat([.messages(first, fail: true), .messages(second, fail: false), .messages([], fail: false)])
        let source = ReconnectingChatSource(maxFailures: 1, delay: { _ in 0 }) { script }
        // The third attempt delivers nothing, which counts as the one allowed failure and then ends the run.
        var got: [ChatMessage] = []
        do {
            for try await event in source.stream() { if case .items(let batch) = event { got += batch } }
        } catch {}
        #expect(got.map(\.text) == ["a", "b", "c"])
        #expect(script.attempts == 3)
    }

    @Test func aSourceThatNeverDeliversFailsAtOnce() async {
        let script = ScriptedChat([.messages([], fail: true)])
        let source = ReconnectingChatSource(maxFailures: 3, delay: { _ in 0 }) { script }
        await #expect(throws: ToolError.self) { _ = try await collect(source) }
        #expect(script.attempts == 1)
    }

    @Test func givesUpAfterTooManyFailuresInARow() async {
        var steps: [ScriptedChat.Step] = [.messages([message(1, "a")], fail: true)]
        steps += Array(repeating: .messages([], fail: true), count: 10)
        let script = ScriptedChat(steps)
        let source = ReconnectingChatSource(maxFailures: 2, delay: { _ in 0 }) { script }
        await #expect(throws: ToolError.self) { _ = try await collect(source) }
        #expect(script.attempts == 3)
    }
}

@Suite("Detector edge cases")
struct DetectorEdgeTests {
    func quiet(_ minutes: Int) -> [ChatMessage] {
        (0..<(minutes * 60)).flatMap { t in (0..<2).map { ChatMessage(time: Double(t) + Double($0) / 2, author: "q", text: "hi") } }
    }

    func burst(at time: Double, count: Int) -> [ChatMessage] {
        (0..<count).map { ChatMessage(time: time + Double($0) * 10 / Double(count), author: "b", text: "KEKW") }
    }

    @Test func badTimestampsAreIgnored() {
        let bad = [ChatMessage(time: .nan, author: "", text: "x"), ChatMessage(time: .infinity, author: "", text: "x"),
                   ChatMessage(time: 1e15, author: "", text: "x"), ChatMessage(time: -5, author: "", text: "x")]
        let analysis = SpikeDetector.analyze(messages: bad, settings: SpikeSettings(), duration: .nan)
        #expect(analysis.buckets.isEmpty)
        #expect(SpikeDetector.analyze(messages: [], settings: SpikeSettings()).spikes.isEmpty)
    }

    @Test func aSecondSpikeAfterABigOneIsStillFound() {
        let messages = quiet(12) + burst(at: 300, count: 400) + burst(at: 400, count: 60)
        let spikes = SpikeDetector.analyze(messages: messages, settings: SpikeSettings()).spikes
        #expect(spikes.contains { $0.time == 300 })
        #expect(spikes.contains { $0.time == 400 })
    }

    @Test func aBurstSplitAcrossTwoBucketsIsFound() {
        // 14 messages per bucket is 28 in all: neither half clears the floor of 10 by much, but together they stand out.
        let split = (0..<14).map { ChatMessage(time: 305 + Double($0) * 0.7, author: "b", text: "KEKW") }
            + (0..<14).map { ChatMessage(time: 310.5 + Double($0) * 0.3, author: "b", text: "KEKW") }
        let analysis = SpikeDetector.analyze(messages: quiet(10) + split, settings: SpikeSettings())
        #expect(!analysis.spikes.isEmpty)
    }

    @Test func aSpikeEarlyInTheStreamIsFound() {
        let analysis = SpikeDetector.analyze(messages: quiet(1) + burst(at: 40, count: 80), settings: SpikeSettings())
        #expect(analysis.spikes.contains { $0.time == 40 })
    }

    @Test func messageFloorScalesWithTheBucket() {
        var settings = SpikeSettings()
        settings.bucketSeconds = 60
        #expect(settings.messageFloor == 60)
        settings.bucketSeconds = 5
        #expect(settings.messageFloor == 5)
    }

    @Test func windowStartsBeforeTheWholeRun() {
        var settings = SpikeSettings()
        settings.preRoll = 30
        let spike = Spike(id: 1, time: 500, zScore: 4, messageCount: 50, peakPerSecond: 5, topEmotes: [],
                          runStart: 470, runEnd: 520, transcriptPreview: "")
        #expect(spike.windowStart(settings) == 440)
        let segments = [TranscriptSegment(start: 445, end: 450, text: "early"), TranscriptSegment(start: 520, end: 530, text: "late")]
        #expect(TranscriptPairing.window(segments, around: spike, settings: settings).map(\.text) == ["early"])
    }
}
