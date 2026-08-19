import Foundation

// MARK: - SplitMix64

/// Deterministic 64-bit generator; same seed → same sequence on every machine and runner.
///
/// 🔒 A copy of `Tests/BackglanceTestSupport/SplitMix64.swift` rather than a dependency on
/// it: this executable ships in the package's own target graph and must not depend on the
/// test support package. The two must stay identical — a fixture's whole claim to being
/// reproducible is that this sequence does not change. If you change one, change both and
/// regenerate every fixture.
struct SplitMix64: RandomNumberGenerator {
    // MARK: Lifecycle

    init(seed: UInt64) {
        state = seed
    }

    // MARK: Internal

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Int in `0 ..< bound`.
    mutating func int(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    /// One element, deterministically.
    mutating func pick<T>(_ values: [T]) -> T {
        values[int(below: values.count)]
    }

    /// Deterministic UUID from the stream.
    mutating func uuid() -> UUID {
        let high = next()
        let low = next()
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: high >> 56), UInt8(truncatingIfNeeded: high >> 48),
            UInt8(truncatingIfNeeded: high >> 40), UInt8(truncatingIfNeeded: high >> 32),
            UInt8(truncatingIfNeeded: high >> 24), UInt8(truncatingIfNeeded: high >> 16),
            UInt8(truncatingIfNeeded: high >> 8), UInt8(truncatingIfNeeded: high),
            UInt8(truncatingIfNeeded: low >> 56), UInt8(truncatingIfNeeded: low >> 48),
            UInt8(truncatingIfNeeded: low >> 40), UInt8(truncatingIfNeeded: low >> 32),
            UInt8(truncatingIfNeeded: low >> 24), UInt8(truncatingIfNeeded: low >> 16),
            UInt8(truncatingIfNeeded: low >> 8), UInt8(truncatingIfNeeded: low)
        ))
    }

    // MARK: Private

    private var state: UInt64
}

// MARK: - GeneratedNotification

/// One synthetic notification: what goes into the store, and what the parser must get
/// back out of it.
///
/// Both come from the same generated values rather than from each other. Deriving
/// `expected.json` by running the parser over the generated store would make the fixture
/// test compare the parser with itself and pass no matter what the parser did.
struct GeneratedNotification {
    var recID: Int64
    var bundleID: String
    var uuid: UUID
    var title: String
    var subtitle: String?
    var body: String
    var sender: String?
    var threadID: String?
    var category: String?
    var deliveredAt: Date
    var presented: Bool
    var userInfo: [String: String]
    var attachments: [GeneratedAttachment]

    /// The binary plist that goes in `record.data`.
    ///
    /// ⚠️ The keys are the observed ones — `req` with `titl`, `subt`, `body`, `thre`,
    /// `cate`, `usda` — which is the whole point: a fixture that used friendlier key names
    /// would test nothing about the store Backglance actually reads.
    func payload() throws -> Data {
        var request: [String: Any] = [
            "titl": title,
            "body": body,
        ]
        request["subt"] = subtitle
        request["thre"] = threadID
        request["cate"] = category
        if !userInfo.isEmpty {
            request["usda"] = userInfo
        }
        if !attachments.isEmpty {
            request["atta"] = attachments.map { attachment in
                ["type": attachment.type, "name": attachment.name, "size": attachment.size] as [String: Any]
            }
        }

        let root: [String: Any] = [
            "app": bundleID,
            "date": deliveredAt,
            "req": request,
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }
}

// MARK: - GeneratedAttachment

/// Attachment *metadata*. There are no bytes anywhere in a fixture: Backglance never
/// copies attachment payloads out of the store, so there is nothing for a fixture to
/// imitate beyond the type, a name and a size.
struct GeneratedAttachment {
    var type: String
    var name: String
    var size: Int
}

// MARK: - SeededContent

/// Generates the rows a fixture holds.
///
/// 🔒 Everything here is invented from the seed: names from a word list, addresses at
/// `example.com`, phone numbers in the `+1 555 01xx` block reserved for fiction, and
/// one-time codes formatted from the generator's own stream. No value is copied from a
/// real notification, and none is a real address, number or code. That is what makes a
/// fixture safe to commit — see docs/testing/TESTING.md#why-fixtures-are-synthetic.
enum SeededContent {
    // MARK: Internal

    /// The apps a fixture's notifications come from — the ones with per-app behaviour
    /// worth exercising (Messages and Mail redact by default, Slack has a resolver) plus
    /// two invented ones.
    static let bundleIDs = [
        "com.apple.MobileSMS",
        "com.apple.mail",
        "com.tinyspeck.slackmacgap",
        "com.example.demo",
        "com.example.chat",
    ]

    /// `count` notifications, oldest first, ending at `endingAt`.
    ///
    /// Delivery dates walk backwards from the end in irregular steps, so a fixture spans
    /// several days the way a real week of notifications does — which is what the digest
    /// and the timeline's day grouping need in order to have anything to group.
    static func notifications(count: Int, seed: UInt64, endingAt: Date) -> [GeneratedNotification] {
        var rng = SplitMix64(seed: seed)
        var deliveredAt = endingAt.addingTimeInterval(-Double(count) * 600)

        return (1 ... max(count, 0)).map { index in
            let bundleID = rng.pick(bundleIDs)
            // Between one minute and three hours apart.
            deliveredAt = deliveredAt.addingTimeInterval(Double(60 + rng.int(below: 10_800)))
            return notification(recID: Int64(index), bundleID: bundleID, deliveredAt: deliveredAt, rng: &rng)
        }
    }

    // MARK: Private

    /// What every generated notification starts from, whatever app it is attributed to.
    private struct Base {
        var recID: Int64
        var bundleID: String
        var uuid: UUID
        var deliveredAt: Date
        var person: String
        var handle: String
        var email: String
        var code: String?
        var attachments: [GeneratedAttachment]
    }

    private static let firstNames = ["Ada", "Grace", "Alan", "Katherine", "Linus", "Barbara", "Edsger", "Radia"]
    private static let lastNames = ["Lovelace", "Hopper", "Turing", "Johnson", "Torvalds", "Liskov", "Dijkstra"]
    private static let subjects = ["the deploy", "the design review", "tomorrow's standup", "the migration", "lunch"]
    private static let verbs = ["is ready", "needs a look", "moved to Thursday", "finished", "is blocked"]
    private static let channels = ["#general", "#backglance", "#incidents", "#design"]

    private static func notification(
        recID: Int64,
        bundleID: String,
        deliveredAt: Date,
        rng: inout SplitMix64
    ) -> GeneratedNotification {
        let person = "\(rng.pick(firstNames)) \(rng.pick(lastNames))"
        // 🔒 The "+1 555 01xx" block is reserved for fiction, and the address is at
        // example.com, which is reserved by RFC 2606. Neither can reach a real person.
        let handle = "+1 555 01\(String(format: "%02d", rng.int(below: 100)))"
        let email = "\(person.split(separator: " ")[0].lowercased())@example.com"

        // Every twelfth notification is OTP-shaped, so the redaction tests have something
        // to bite on. The digits come from the seed — never from a real message.
        let isOneTimeCode = rng.int(below: 12) == 0
        let code = String(format: "%06d", rng.next() % 1_000_000)

        // Every ninth carries an attachment, so the parser's metadata path is exercised by
        // every fixture rather than only by unit tests.
        let attachments: [GeneratedAttachment] = rng.int(below: 9) == 0
            ? [GeneratedAttachment(type: "public.jpeg", name: "photo-\(rng.int(below: 1_000)).jpg", size: 40_960)]
            : []

        let base = Base(
            recID: recID,
            bundleID: bundleID,
            uuid: rng.uuid(),
            deliveredAt: deliveredAt,
            person: person,
            handle: handle,
            email: email,
            code: isOneTimeCode ? code : nil,
            attachments: attachments
        )

        switch bundleID {
        case "com.apple.MobileSMS":
            return message(base, rng: &rng)

        case "com.apple.mail":
            return mail(base, rng: &rng)

        case "com.tinyspeck.slackmacgap":
            return slack(base, rng: &rng)

        default:
            return app(base, rng: &rng)
        }
    }

    private static func message(_ base: Base, rng: inout SplitMix64) -> GeneratedNotification {
        GeneratedNotification(
            recID: base.recID,
            bundleID: base.bundleID,
            uuid: base.uuid,
            title: base.person,
            subtitle: nil,
            body: base.code.map { "Your verification code is \($0)" } ?? "\(rng.pick(subjects)) \(rng.pick(verbs))",
            // Messages declares no sender, so the parser falls back to the title — which
            // is what the expectation has to say too.
            sender: base.person,
            threadID: "chat-\(rng.int(below: 20))",
            category: "MessageReceived",
            deliveredAt: base.deliveredAt,
            presented: rng.int(below: 4) != 0,
            userInfo: ["senderHandle": base.handle],
            attachments: base.attachments
        )
    }

    private static func mail(_ base: Base, rng: inout SplitMix64) -> GeneratedNotification {
        GeneratedNotification(
            recID: base.recID,
            bundleID: base.bundleID,
            uuid: base.uuid,
            title: base.person,
            subtitle: "Re: \(rng.pick(subjects))",
            body: base.code.map { "Your one-time code is \($0)" } ?? "\(rng.pick(subjects)) \(rng.pick(verbs)).",
            // Mail declares a sender in userInfo, and the parser prefers a declared one
            // over the title — so the expectation is the address, not the display name.
            sender: base.email,
            threadID: nil,
            category: "NewMail",
            deliveredAt: base.deliveredAt,
            presented: rng.int(below: 3) != 0,
            userInfo: [
                "messageID": "<\(rng.uuid().uuidString.lowercased())@example.com>",
                "from": base.email,
            ],
            attachments: base.attachments
        )
    }

    private static func slack(_ base: Base, rng: inout SplitMix64) -> GeneratedNotification {
        let channel = rng.pick(channels)
        return GeneratedNotification(
            recID: base.recID,
            bundleID: base.bundleID,
            uuid: base.uuid,
            title: channel,
            subtitle: base.person,
            body: "\(rng.pick(subjects)) \(rng.pick(verbs))",
            sender: base.person,
            threadID: channel,
            category: "Message",
            deliveredAt: base.deliveredAt,
            presented: rng.int(below: 2) != 0,
            userInfo: [
                "deeplink": "slack://channel?team=T0EXAMPLE&id=C0EXAMPLE",
                "sender": base.person,
            ],
            attachments: base.attachments
        )
    }

    private static func app(_ base: Base, rng: inout SplitMix64) -> GeneratedNotification {
        GeneratedNotification(
            recID: base.recID,
            bundleID: base.bundleID,
            uuid: base.uuid,
            title: "\(rng.pick(subjects).capitalized) \(rng.pick(verbs))",
            subtitle: nil,
            body: "Build \(rng.int(below: 1_000)) \(rng.pick(verbs)).",
            sender: nil,
            threadID: "build-\(rng.int(below: 50))",
            category: "BuildStatus",
            deliveredAt: base.deliveredAt,
            presented: rng.int(below: 5) != 0,
            userInfo: ["url": "https://example.com/builds/\(rng.int(below: 1_000))"],
            attachments: base.attachments
        )
    }
}
