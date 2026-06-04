# VoxrtWakeWord for iOS

Always-on wake-phrase detection on the **VoxRT** custom on-device inference runtime. ~48K-parameter depthwise-separable convnet, 16 kHz mono in, sigmoid-score out + threshold-crossing events. Detects the phrase **"Hey Assistant"**.

- Current version: `v0.1.0`
- Minimum iOS: 16.0
- Architectures shipped: `arm64` (iPhone / iPad, NEON-accelerated) + simulator slices (`arm64` + `x86_64`)
- License: Apache-2.0 (Swift wrapper) · proprietary (compiled runtime, redistribution allowed via this Swift Package)
- Wake-phrase weights: proprietary in-house (synthetic training data; no upstream license obligations)

---

## What is VoxRT?

VoxRT is a from-scratch inference runtime for on-device speech models. No ONNX Runtime, no PyTorch Mobile, no LiteRT — a custom Rust core sized and tuned for streaming voice workloads on phone-class hardware.

`VoxrtWakeWord` is the wake-word product on that runtime, alongside [`VoxrtSilero`](https://github.com/VoxRT/voxrt-silero-ios) (VAD) and [`VoxrtAsr`](https://github.com/VoxRT/voxrt-asr-ios) (streaming ASR). All three share the same Rust runtime crate and the same NEON kernel set. The runtime is the product; the models are what it runs.

Custom-phrase wake-word models (your own brand name, multi-phrase detection, language extension) are part of the commercial VoxRT SDK tier. Contact help@voxrt.com.

## Model quality

Test split: 5,240 positive utterances + 6,416 hard-negative utterances (isolated "Hey", isolated "Assistant", competitor wake-words like "Hey Siri", phonetic neighbours, arbitrary speech, non-speech audio). All speakers disjoint from train + val.

- **ROC AUC: 0.9966**
- **Average precision (PR AUC): 0.9899**

| Threshold | Precision | Recall | F1     | FPR    | False positives on test |
| --------- | --------- | ------ | ------ | ------ | ----------------------- |
| 0.5       | 0.864     | 0.995  | 0.925  | 12.8 % | 822 / 6,416             |
| 0.85      | 0.957     | 0.987  | 0.972  | 3.7 %  | 234 / 6,416             |
| **0.9 (default)** | **0.993** | **0.982** | **0.987** | **0.5 %** | **34 / 6,416** |
| 0.95      | 0.997     | 0.769  | 0.868  | 0.2 %  | 12 / 6,416              |

The package ships with `threshold = 0.9` as the default operating point. Lower it via `setThreshold` if your application can tolerate more false positives in exchange for higher recall.

## Performance

`arm64` device build, post-warmup, RTF = wall-time-per-frame ÷ frame audio duration (lower is better):

| Device                | RTF        | per-frame latency |
| --------------------- | ---------- | ----------------- |
| iPhone 13 Pro Max (A15 Bionic) | **0.015** | ~150 µs / 10 ms frame |

At RTF ≈ 0.015 the wake-word burns ~1.5 % of one core during continuous listening — well within an always-on power budget.

## Binary footprint

- Swift wrapper source: ~7 KB total (one file)
- `VoxrtWakeWordNative.xcframework.zip` (downloaded by SPM): ~19 MB compressed (device + simulator slices)
- After SPM extraction + linker dead-code elimination on the device-only path: ~2–3 MB delta in your app binary
- Wake-phrase model `voxrt_wake_word.vxrt`: ~100 KB fp16 (downloaded separately)

Net effect on a consuming iOS app's IPA: roughly 2–3 MB once xcframework device slice + .vxrt + Swift wrapper are linked and bundled.

## Install

In Xcode: **File → Add Package Dependencies →** paste:

```
https://github.com/VoxRT/voxrt-wake-word-ios
```

…and pin to **v0.1.0**.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/VoxRT/voxrt-wake-word-ios.git", from: "0.1.0"),
],
```

## Get the wake-phrase model

The model weights are NOT bundled with the package — fetch them once from [`voxrt-wake-word-models`](https://github.com/VoxRT/voxrt-wake-word-models/releases/tag/v0.1.0):

```
https://github.com/VoxRT/voxrt-wake-word-models/releases/download/v0.1.0/voxrt_wake_word.vxrt
```

SHA-256: `9d40bdc132a2ad8e85bd8a28bb49b77c51a7c62f60567222a037e44418510e8f`

Three common bundling patterns for an ~100 KB asset:

- **Bundle in app resources** — drag `voxrt_wake_word.vxrt` into your Xcode target. Works offline from first launch.
- **Download on first run** — `URLSession` fetch into `FileManager.default.urls(for: .applicationSupportDirectory, ...)`. Lets you swap models without an app update.
- **App Thinning / On-Demand Resources** — Apple's per-asset delivery if you want the App Store to host the file.

## Quick start

```swift
import VoxrtWakeWord

// 1. Resolve the bundled model URL.
guard let modelURL = Bundle.main.url(forResource: "voxrt_wake_word",
                                     withExtension: "vxrt") else {
    fatalError("voxrt_wake_word.vxrt not found in bundle")
}

// 2. Build the engine. `init(modelURL:)` reads the .vxrt bytes
//    into the runtime — ~100 KB total, no streaming I/O required.
let engine = try VoxrtWakeWordEngine(modelURL: modelURL)

// 3. Feed Int16 PCM (mono, 16 kHz) blocks of any size — 100 ms
//    blocks are the recommended pace for AVAudioEngine taps.
//    processPcm returns any threshold-crossings emitted during
//    this push; usually empty.
let detections = try engine.processPcm(pcmInt16Array)
for d in detections {
    print("frame=\(d.frameIndex) t=\(d.timestampSec) score=\(d.score)")
}
```

`processPcm` / `reset` / `close` are **synchronous and stateful**. The engine does NOT own a worker thread. Drive it from your own capture thread.

## Live microphone example

The canonical streaming pattern — capture-thread owns the `AVAudioEngine` tap, engine is a stateful function.

```swift
import AVFoundation
import VoxrtWakeWord

let session = AVAudioSession.sharedInstance()
try session.setCategory(.record, mode: .measurement)
try session.setPreferredSampleRate(16_000)
try session.setActive(true)

let audioEngine = AVAudioEngine()
let input = audioEngine.inputNode
let hwFormat = input.outputFormat(forBus: 0)

let voxrtFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: true
)!
let converter = AVAudioConverter(from: hwFormat, to: voxrtFormat)!

guard let modelURL = Bundle.main.url(forResource: "voxrt_wake_word",
                                     withExtension: "vxrt") else { fatalError() }
let wakeWord = try VoxrtWakeWordEngine(modelURL: modelURL)

input.installTap(onBus: 0, bufferSize: 4_096, format: hwFormat) { hwBuf, _ in
    let outCap = AVAudioFrameCount(
        Double(hwBuf.frameLength) * 16_000 / hwBuf.format.sampleRate + 256
    )
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: voxrtFormat, frameCapacity: outCap) else {
        return
    }
    var err: NSError?
    converter.convert(to: outBuf, error: &err) { _, status in
        status.pointee = .haveData
        return hwBuf
    }
    if err != nil { return }
    guard let i16Ptr = outBuf.int16ChannelData?[0] else { return }
    let samples = Array(UnsafeBufferPointer(start: i16Ptr, count: Int(outBuf.frameLength)))
    do {
        for d in try wakeWord.processPcm(samples) {
            DispatchQueue.main.async {
                // update UI on wake detection
                print("wake! score=\(d.score)")
            }
        }
    } catch { /* surface to UI */ }
}

try audioEngine.start()
```

> **Permission:** add `NSMicrophoneUsageDescription` to your `Info.plist` (or `INFOPLIST_KEY_NSMicrophoneUsageDescription` in a generated-plist project) before requesting `AVAudioSession.setActive`.

## Tuning

### Threshold

Default is 0.9 (the chosen operating point on test). Lower for higher recall, raise for stricter precision:

```swift
try engine.setThreshold(0.85)   // a bit more recall, ~5 % false-positive rate
try engine.setThreshold(0.95)   // a bit stricter, but loses ~20 % recall
```

### Cooldown

After a detection, the engine suppresses further events for `cooldownFrames` × 10 ms. Default is 100 frames = 1 second.

```swift
try engine.setCooldownFrames(200)   // 2 seconds
```

## API

```swift
public final class VoxrtWakeWordEngine {
    public init(modelURL: URL) throws
    public init(bytes: Data) throws
    public convenience init(
        bundleResource name: String = "voxrt_wake_word",
        ext: String = "vxrt",
        bundle: Bundle = .main
    ) throws

    public func processPcm(_ pcm: [Int16]) throws -> [WakeWordDetection]
    public func processPcm(_ pcm: [Float]) throws -> [WakeWordDetection]
    public func currentScore() throws -> Float
    public func reset() throws
    public func setThreshold(_ threshold: Float) throws
    public func setCooldownFrames(_ frames: Int) throws
    public func close()
}

public struct WakeWordDetection: Equatable {
    public let frameIndex: UInt64    // 0-based frame index (1 frame = 10 ms)
    public let timestampSec: Float   // seconds since engine start (or last reset)
    public let score: Float          // sigmoid score in [0, 1]
}

public enum VoxrtWakeWord {
    public static var nativeVersion: String
    public static var abiVersion: (major: UInt16, minor: UInt16)
}
```

## License

- **Swift wrapper source** (this Swift Package): Apache-2.0. See [`LICENSE`](LICENSE).
- **Compiled runtime** (`VoxrtWakeWordNative.xcframework`): proprietary, redistributable under the terms in [`LICENSE-BINARY`](LICENSE-BINARY).
- **Wake-phrase model** (`voxrt_wake_word.vxrt`): proprietary, distributed separately under the [`voxrt-wake-word-models`](https://github.com/VoxRT/voxrt-wake-word-models) license terms.

For commercial integration, custom phrase models, or licensing terms beyond redistribution of the unmodified package, contact help@voxrt.com.
