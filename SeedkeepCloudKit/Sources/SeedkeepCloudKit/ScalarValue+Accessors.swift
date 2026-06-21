import Foundation

// Typed accessors for the reverse mapping (CloudKitRecordValue → Local* model). Each returns nil
// when the scalar is absent or the wrong case, so an applier can write `model.field = v.scalars[k]?.asInt64`
// and leave the field untouched (via ??) when the record omits it.
public extension ScalarValue {
    var asString: String? { if case .string(let v) = self { return v }; return nil }
    var asInt: Int?       { if case .int(let v)    = self { return v }; return nil }
    /// INT64 fields on the SwiftData models read back as Int64 (lossless on 64-bit).
    var asInt64: Int64?   { if case .int(let v)    = self { return Int64(v) }; return nil }
    var asDouble: Double? { if case .double(let v) = self { return v }; return nil }
    var asBool: Bool?     { if case .bool(let v)   = self { return v }; return nil }
}
