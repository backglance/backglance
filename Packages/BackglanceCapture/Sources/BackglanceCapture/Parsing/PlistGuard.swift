import Foundation

// MARK: - PlistGuard

/// Decodes a store payload under hard limits, or refuses to.
///
/// ⚠️ Every `record.data` blob was produced by some *other* app's notification request.
/// A buggy or malicious app can post one with a two-megabyte `userInfo`, a forty-level
/// nested array, or a hundred thousand keys, and Backglance reads it on a background
/// actor that must not stall, allocate without bound, or recurse until the stack gives
/// out. So the payload is treated as hostile input: bounded before decoding, walked and
/// checked after, and rejected as a whole if anything exceeds a limit.
///
/// Rejecting rather than truncating is deliberate. A truncated notification looks like a
/// real one in the timeline while being wrong, and there is no way for the user to tell.
/// A rejected record is counted and skipped, the cursor moves past it, and the next
/// record is unaffected.
///
/// > 🔒 `PropertyListSerialization` with immutable containers, and never
/// > `NSKeyedUnarchiver`. Backglance does not unarchive `NSKeyedArchiver` payloads found
/// > inside `userInfo` at all — instantiating arbitrary classes named by untrusted data
/// > is the classic way this goes wrong. Such a value stays opaque ``Data`` and is
/// > dropped when `userInfo` is flattened to strings.
///
/// See docs/security/SECURITY.md#hostile-store-content-the-plist-guard.
public struct PlistGuard: Sendable {
    // MARK: Lifecycle

    public init(limits: PlistGuardLimits = PlistGuardLimits()) {
        self.limits = limits
    }

    // MARK: Public

    public let limits: PlistGuardLimits

    /// Decodes `data` into a plain dictionary, or throws the limit it broke.
    public func decode(_ data: Data) throws -> [String: Any] {
        guard data.count <= limits.maxBytes else {
            // Checked before decoding: the point is not to build the object graph at all.
            throw PlistGuardError.tooLarge(bytes: data.count)
        }

        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            // The underlying error quotes byte offsets and sometimes the data itself.
            throw PlistGuardError.notAPropertyList
        }

        guard let root = object as? [String: Any] else {
            throw PlistGuardError.notADictionary
        }
        try validate(root, depth: 1)
        return root
    }

    // MARK: Internal

    /// Walks the decoded graph. Internal rather than private so the unsupported-type rule
    /// — which a property list cannot produce, and which exists for the day one can — is
    /// testable.
    func validate(_ value: Any, depth: Int) throws {
        guard depth <= limits.maxDepth else {
            throw PlistGuardError.tooDeep(depth: depth)
        }

        switch value {
        case let dictionary as [String: Any]:
            guard dictionary.count <= limits.maxCollectionCount else {
                throw PlistGuardError.collectionTooLarge(count: dictionary.count)
            }
            for (key, inner) in dictionary {
                guard key.count <= limits.maxStringLength else {
                    throw PlistGuardError.stringTooLong(length: key.count)
                }
                try validate(inner, depth: depth + 1)
            }

        case let array as [Any]:
            guard array.count <= limits.maxCollectionCount else {
                throw PlistGuardError.collectionTooLarge(count: array.count)
            }
            for inner in array {
                try validate(inner, depth: depth + 1)
            }

        case let string as String:
            guard string.count <= limits.maxStringLength else {
                throw PlistGuardError.stringTooLong(length: string.count)
            }

        case is NSNumber,
             is Date,
             is Data:
            // Scalars. Their size is already bounded by `maxBytes`.
            return

        default:
            throw PlistGuardError.unsupportedType(String(describing: type(of: value)))
        }
    }
}

// MARK: - PlistGuardLimits

/// The limits every store payload is read under.
///
/// The numbers are chosen to be far above any real notification and far below anything
/// that could hurt: a notification banner holds a few hundred characters, and 64 KB is
/// already generous for one with a long `userInfo`.
public struct PlistGuardLimits: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        maxBytes: Int = 64 * 1_024,
        maxDepth: Int = 8,
        maxCollectionCount: Int = 512,
        maxStringLength: Int = 16 * 1_024
    ) {
        self.maxBytes = maxBytes
        self.maxDepth = maxDepth
        self.maxCollectionCount = maxCollectionCount
        self.maxStringLength = maxStringLength
    }

    // MARK: Public

    /// 64 KB per record, checked before anything is decoded.
    public var maxBytes: Int

    /// Nesting of dictionaries and arrays. Bounds the recursive walk.
    public var maxDepth: Int

    /// Entries per dictionary or array.
    public var maxCollectionCount: Int

    /// Characters per string, keys included.
    public var maxStringLength: Int
}

// MARK: - PlistGuardError

/// Why a payload was refused.
///
/// > 🔒 Every case carries a *shape* — a count, a length, a depth, a type name — and never
/// > a byte of the payload. That is what makes these safe to log and to count in the
/// > capture metrics.
public enum PlistGuardError: Error, Equatable, Sendable {
    case tooLarge(bytes: Int)
    case notAPropertyList
    case notADictionary
    case tooDeep(depth: Int)
    case collectionTooLarge(count: Int)
    case stringTooLong(length: Int)
    case unsupportedType(String)

    // MARK: Public

    /// Safe for `os_log` with `privacy: .public`, and the reason a rejected record is
    /// counted under.
    public var logDescription: String {
        switch self {
        case let .tooLarge(bytes):
            "payload too large: \(bytes) bytes"

        case .notAPropertyList:
            "not a property list"

        case .notADictionary:
            "root is not a dictionary"

        case let .tooDeep(depth):
            "payload too deep: \(depth)"

        case let .collectionTooLarge(count):
            "collection too large: \(count)"

        case let .stringTooLong(length):
            "string too long: \(length)"

        case let .unsupportedType(name):
            "unsupported type: \(name)"
        }
    }
}
