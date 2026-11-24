import Foundation

/// A word or emote that makes a chat message count for more.
public struct HypeKeyword: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var word: String
    /// 1.0 is a plain message. 1.5 to 2.0 is hype.
    public var weight: Double

    public init(id: UUID = UUID(), word: String, weight: Double) {
        self.id = id
        self.word = word
        self.weight = weight
    }

    public static let defaults: [HypeKeyword] = [
        ("KEKW", 2.0), ("OMEGALUL", 2.0), ("CLIP", 2.0), ("LUL", 1.5), ("LULW", 1.5),
        ("OMG", 1.5), ("POG", 1.5), ("POGGERS", 1.5), ("W", 1.5), ("???", 1.5),
    ].map { HypeKeyword(word: $0.0, weight: $0.1) }
}

public struct SpikeSettings: Codable, Equatable, Sendable {
    /// A bucket is a spike when its Z-score is above this.
    public var zThreshold = 2.5
    /// ...and it holds at least this many messages.
    public var minMessages = 10
    /// Width of one chat bucket in seconds.
    public var bucketSeconds = 10
    /// How far back the rolling mean and deviation look.
    public var baselineSeconds = 300
    /// Transcript before a spike.
    public var preRoll = 30.0
    /// Transcript after a spike.
    public var postRoll = 15.0
    public var hypeKeywords: [HypeKeyword] = HypeKeyword.defaults

    public init() {}

    /// `minMessages` is a count per 10 s of chat. It scales with the bucket width, so a 60 s bucket needs 60.
    public var messageFloor: Int { max(1, Int((Double(minMessages) * Double(max(1, bucketSeconds)) / 10).rounded())) }

    public static let zRange = 1.0...6.0
    public static let minMessagesRange = 1...100
    public static let bucketOptions = [5, 10, 15, 30, 60]
}
