// VoxrtWakeWordEngine.swift — Swift facade over the C ABI exposed by
// VoxrtWakeWordNative.xcframework. 1:1 mirror of the Kotlin
// VoxrtWakeWordEngine in sdk-android-poc — same constructors, same
// instance methods, same Detection model, so cross-platform code
// reviews stay tractable.
//
// Lives directly inside the app target source (not an SPM module) so
// the demo matches the sdk-android-poc layout: no Package.swift, no
// external module reference, just `import VoxrtWakeWordNative` and
// call the C functions.
//
// Threading: NOT thread-safe per-instance. Push + reset + close must
// be serialised against each other on a given engine. Matches the
// Kotlin facade's contract.

import Foundation
import VoxrtWakeWordNative

// ─── Detection event ─────────────────────────────────────────────────

/// One detection event emitted by `processPcm`. Mirrors
/// `WakeWordDetection` on the Kotlin side and
/// `voxrt_wake_word_detection_t` in the C ABI.
public struct WakeWordDetection: Equatable {
    /// 0-based frame index since engine start (or last `reset`).
    public let frameIndex: UInt64
    /// Time in seconds at the detection frame's start.
    public let timestampSec: Float
    /// Sigmoid score in [0, 1].
    public let score: Float
}

// ─── Errors ──────────────────────────────────────────────────────────

public enum VoxrtWakeWordError: Error, CustomStringConvertible {
    case invalidArgument
    case invalidHandle
    case modelDeserialize
    case modelShape
    case oom
    case bufferTooSmall
    case internalError
    case resourceNotFound(name: String, ext: String, bundle: String)
    case unknown(Int32)

    fileprivate init(_ status: voxrt_status_t) {
        switch status {
        case voxrt_status_t(VOXRT_ERR_INVALID_ARG):       self = .invalidArgument
        case voxrt_status_t(VOXRT_ERR_INVALID_HANDLE):    self = .invalidHandle
        case voxrt_status_t(VOXRT_ERR_MODEL_DESERIALIZE): self = .modelDeserialize
        case voxrt_status_t(VOXRT_ERR_MODEL_SHAPE):       self = .modelShape
        case voxrt_status_t(VOXRT_ERR_OOM):               self = .oom
        case voxrt_status_t(VOXRT_ERR_BUFFER_TOO_SMALL):  self = .bufferTooSmall
        case voxrt_status_t(VOXRT_ERR_INTERNAL):          self = .internalError
        default:                                          self = .unknown(status)
        }
    }

    public var description: String {
        switch self {
        case .invalidArgument:  return "invalidArgument"
        case .invalidHandle:    return "invalidHandle"
        case .modelDeserialize: return "modelDeserialize (.vxrt bytes failed to parse)"
        case .modelShape:       return "modelShape (model doesn't match wake-word topology)"
        case .oom:              return "oom"
        case .bufferTooSmall:   return "bufferTooSmall (detection buffer too small)"
        case .internalError:    return "internalError"
        case .resourceNotFound(let n, let e, let b):
            return "resourceNotFound: '\(n).\(e)' not in \(b)"
        case .unknown(let c):   return "unknown(\(c))"
        }
    }
}

// ─── Version helpers ─────────────────────────────────────────────────

public enum VoxrtWakeWord {
    /// SDK version string (`CARGO_PKG_VERSION` of voxrt_wake_word).
    public static var nativeVersion: String {
        guard let p = voxrt_wake_word_version() else { return "unknown" }
        return String(cString: p)
    }

    /// `(major, minor)` ABI version reported by the native side.
    public static var abiVersion: (major: UInt16, minor: UInt16) {
        let raw = voxrt_wake_word_abi_version()
        return (UInt16((raw >> 16) & 0xFFFF), UInt16(raw & 0xFFFF))
    }
}

// ─── Engine ──────────────────────────────────────────────────────────

/// Streaming wake-word detection session. Hold one per audio source;
/// destroy with `close()` (or let `deinit` handle it).
public final class VoxrtWakeWordEngine {
    private var handle: OpaquePointer?

    // ── Constructors ────────────────────────────────────────────────

    /// Load from a model file at `url` (e.g. one returned by
    /// `Bundle.main.url(forResource:withExtension:)`).
    public convenience init(modelURL: URL) throws {
        let data = try Data(contentsOf: modelURL)
        try self.init(bytes: data)
    }

    /// Load from raw `.vxrt` bytes.
    public init(bytes: Data) throws {
        var raw: OpaquePointer?
        let status = bytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> voxrt_status_t in
            guard let ptr = buf.bindMemory(to: UInt8.self).baseAddress else {
                return voxrt_status_t(VOXRT_ERR_INVALID_ARG)
            }
            return voxrt_wake_word_create(ptr, bytes.count, &raw)
        }
        if status != voxrt_status_t(VOXRT_OK) {
            throw VoxrtWakeWordError(status)
        }
        guard let raw = raw else { throw VoxrtWakeWordError.internalError }
        self.handle = raw
    }

    /// Convenience: load a `.vxrt` from the app's bundle by base name.
    /// Default extension is `vxrt`. Looks first under
    /// `Resources/models/wakeword/` (mirrors the staging layout used
    /// by `just wake-word-stage-vxrt-ios`), falls back to a top-level
    /// bundle lookup.
    public convenience init(
        bundleResource name: String = "voxrt_wake_word",
        ext: String = "vxrt",
        bundle: Bundle = .main
    ) throws {
        let url = bundle.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "models/wakeword"
        ) ?? bundle.url(forResource: name, withExtension: ext)

        guard let url = url else {
            throw VoxrtWakeWordError.resourceNotFound(
                name: name, ext: ext, bundle: bundle.bundleIdentifier ?? "main"
            )
        }
        try self.init(modelURL: url)
    }

    deinit { close() }

    // ── Lifecycle ───────────────────────────────────────────────────

    /// Destroy the underlying native handle. Idempotent.
    public func close() {
        if let h = handle {
            voxrt_wake_word_destroy(h)
            handle = nil
        }
    }

    // ── Configuration ───────────────────────────────────────────────

    /// Sigmoid-space detection threshold (0..1). Default 0.9 (v6
    /// deploy operating point — precision 0.993 / recall 0.982).
    public func setThreshold(_ threshold: Float) throws {
        guard let h = handle else { throw VoxrtWakeWordError.invalidHandle }
        let s = voxrt_wake_word_set_threshold(h, threshold)
        if s != voxrt_status_t(VOXRT_OK) { throw VoxrtWakeWordError(s) }
    }

    /// Cooldown after a detection, in 10 ms frames. Default 100 = 1 s.
    public func setCooldownFrames(_ frames: Int) throws {
        guard let h = handle else { throw VoxrtWakeWordError.invalidHandle }
        let s = voxrt_wake_word_set_cooldown_frames(h, size_t(frames))
        if s != voxrt_status_t(VOXRT_OK) { throw VoxrtWakeWordError(s) }
    }

    // ── Streaming ───────────────────────────────────────────────────

    /// Latest sigmoid score (0..1). 0.5 before any frame has been
    /// emitted. Doesn't require `processPcm` since the last call —
    /// reflects whatever the pool would emit if asked NOW.
    public func currentScore() throws -> Float {
        guard let h = handle else { throw VoxrtWakeWordError.invalidHandle }
        var s: Float = 0
        let st = voxrt_wake_word_current_score(h, &s)
        if st != voxrt_status_t(VOXRT_OK) { throw VoxrtWakeWordError(st) }
        return s
    }

    /// Wipe accumulated state (FIFOs, sample buffer, pre-emph carry,
    /// rolling pool, cooldown, frame counter). Re-runs the prewarm
    /// pass if the runtime default has it enabled.
    public func reset() throws {
        guard let h = handle else { throw VoxrtWakeWordError.invalidHandle }
        let s = voxrt_wake_word_reset(h)
        if s != voxrt_status_t(VOXRT_OK) { throw VoxrtWakeWordError(s) }
    }

    /// Push i16 PCM (mono, 16 kHz, native-endian). Returns any
    /// detections that crossed threshold during this push.
    public func processPcm(_ pcm: [Int16]) throws -> [WakeWordDetection] {
        guard let h = handle else { throw VoxrtWakeWordError.invalidHandle }
        return try pushAndCollect { detBuf, detCap, written in
            pcm.withUnsafeBufferPointer { buf in
                voxrt_wake_word_push_pcm_i16(
                    h,
                    buf.baseAddress, pcm.count,
                    detBuf, detCap, written
                )
            }
        }
    }

    /// Push f32 PCM (range [-1, 1], mono, 16 kHz).
    public func processPcm(_ pcm: [Float]) throws -> [WakeWordDetection] {
        guard let h = handle else { throw VoxrtWakeWordError.invalidHandle }
        return try pushAndCollect { detBuf, detCap, written in
            pcm.withUnsafeBufferPointer { buf in
                voxrt_wake_word_push_pcm_f32(
                    h,
                    buf.baseAddress, pcm.count,
                    detBuf, detCap, written
                )
            }
        }
    }

    // ── Internal: shared push + retry-on-overflow loop ──────────────

    private typealias PushClosure = (
        UnsafeMutablePointer<voxrt_wake_word_detection_t>?,
        size_t,
        UnsafeMutablePointer<size_t>
    ) -> voxrt_status_t

    /// Calls the closure with a 16-slot detection buffer; if the
    /// runtime reports buffer-too-small, retries with the requested
    /// size. 16 covers the common case (most pushes emit 0 or 1
    /// detection) without permanently allocating a larger buffer.
    private func pushAndCollect(_ push: PushClosure) throws -> [WakeWordDetection] {
        var cap = 16
        while true {
            var buf = [voxrt_wake_word_detection_t](
                repeating: voxrt_wake_word_detection_t(
                    frame_index: 0, timestamp_sec: 0, score: 0
                ),
                count: cap
            )
            var written: size_t = 0
            let status = buf.withUnsafeMutableBufferPointer { p -> voxrt_status_t in
                push(p.baseAddress, size_t(cap), &written)
            }
            if status == voxrt_status_t(VOXRT_OK) {
                if written == 0 { return [] }
                return (0..<Int(written)).map { i in
                    WakeWordDetection(
                        frameIndex: buf[i].frame_index,
                        timestampSec: buf[i].timestamp_sec,
                        score: buf[i].score
                    )
                }
            } else if status == voxrt_status_t(VOXRT_ERR_BUFFER_TOO_SMALL) {
                cap = Int(written)
            } else {
                throw VoxrtWakeWordError(status)
            }
        }
    }
}
