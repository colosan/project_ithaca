// Hand-written: UniFFI emits `CoreError` without `public`, so apps can't switch on it. This exposes its shape.
import Foundation

public enum CoreErrorKind: Sendable, Equatable {
    case notFound, readOnly, invalidInput, io, corrupt
}

/// The core error behind `error`, or nil when it isn't one (FFI / panic errors).
public func coreErrorInfo(_ error: Error) -> (kind: CoreErrorKind, message: String)? {
    guard let e = error as? CoreError else { return nil }
    switch e {
    case .NotFound: return (.notFound, "")
    case .ReadOnly: return (.readOnly, "")
    case .InvalidInput(let m): return (.invalidInput, m)
    case .Io(let m): return (.io, m)
    case .Corrupt(let m): return (.corrupt, m)
    }
}
