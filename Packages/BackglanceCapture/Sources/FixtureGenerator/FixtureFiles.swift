import Foundation

// MARK: - FixtureManifest

/// `manifest.json` — what a fixture claims to represent.
///
/// The claims are checked rather than trusted: `FixtureStoreTests` recomputes
/// `schema_sha256` from `store.db` and fails if it differs, so a fixture whose schema was
/// edited by hand cannot quietly keep its old identity.
struct FixtureManifest: Codable {
    enum CodingKeys: String, CodingKey {
        case osVersion = "os_version"
        case build
        case createdAt = "created_at"
        case generatorVersion = "generator_version"
        case schemaSHA256 = "schema_sha256"
        case dbinfoVersion = "dbinfo_version"
        case adapterID = "adapter_id"
        case seed
        case recordCount = "record_count"
        case notes
    }

    var osVersion: String
    var build: String
    var createdAt: String
    var generatorVersion: String
    var schemaSHA256: String
    var dbinfoVersion: String?
    var adapterID: String
    var seed: UInt64
    var recordCount: Int

    /// Free text that always begins with "Synthetic." — the first thing anyone opening
    /// the file should read.
    var notes: String
}

// MARK: - ExpectedNotification

/// One entry of `expected.json`: what the adapter and parser must produce for a record.
struct ExpectedNotification: Codable {
    var bundleID: String
    var uuid: String
    var title: String?
    var subtitle: String?
    var body: String?
    var sender: String?
    var threadID: String?
    var category: String?

    /// Unix seconds, not Cocoa reference seconds. The store keeps the latter; everything
    /// past the adapter speaks the former, and this file is written for the tests.
    var deliveredAt: Double
    var presented: Bool
    var userInfo: [String: String]
    var attachments: [ExpectedAttachment]
}

// MARK: - ExpectedAttachment

struct ExpectedAttachment: Codable {
    var type: String
    var name: String?
    var size: Int?
}

// MARK: - ExpectedCursor

/// The trailing object of `expected.json`: where a full read of the fixture must leave
/// the cursor.
struct ExpectedCursor: Codable {
    var lastRecID: Int64
    var lastDeliveredDate: Double
}

// MARK: - ExpectedFile

/// `expected.json` as a whole: the notifications, then the cursor.
struct ExpectedFile: Codable {
    var notifications: [ExpectedNotification]
    var cursor: ExpectedCursor
}

// MARK: - GeneratedNotification + expectations

extension GeneratedNotification {
    /// What the parser must produce for this record.
    ///
    /// Built from the generated values, not by running the parser: a fixture whose
    /// expectations came from the parser would agree with the parser no matter what the
    /// parser did.
    var expectation: ExpectedNotification {
        ExpectedNotification(
            bundleID: bundleID,
            uuid: uuid.uuidString,
            title: title,
            subtitle: subtitle,
            body: body,
            sender: sender,
            threadID: threadID,
            category: category,
            deliveredAt: deliveredAt.timeIntervalSince1970,
            presented: presented,
            userInfo: userInfo,
            attachments: attachments.map { ExpectedAttachment(type: $0.type, name: $0.name, size: $0.size) }
        )
    }
}
