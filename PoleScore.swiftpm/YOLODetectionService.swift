import CoreML
import CoreMedia
import Foundation
import UIKit
import Vision

/// What the detector is currently doing, in a form the UI can show without
/// interpreting anything.
enum DetectorStatus: Equatable {
    case idle
    case loading
    case ready
    case modelMissing
    case failed(String)
    case pausedThermal
    case pausedBackground

    var text: String {
        switch self {
        case .idle: return "Detector idle"
        case .loading: return "Loading detector…"
        case .ready: return "Detector ready"
        case .modelMissing: return "YOLO model missing from app bundle"
        case .failed(let reason): return "Detector failed: \(reason)"
        case .pausedThermal: return "AI paused: device too hot"
        case .pausedBackground: return "Detector paused"
        }
    }

    var isRunnable: Bool { self == .ready }
}

/// On-device YOLO inference over the existing camera feed.
///
/// This service owns no camera. It is handed pixel buffers by whoever already
/// has them — `CameraController` — which is the only way to guarantee the app
/// never ends up with two capture sessions fighting over the hardware.
///
/// Three properties of the design matter more than the model itself:
///
/// **One request, reused.** The `VNCoreMLModel` and `VNCoreMLRequest` are built
/// once at load. Rebuilding them per frame is the single most common way to
/// turn a 12ms inference into a 200ms one, because it re-plans the whole
/// Core ML graph every time.
///
/// **Frames are dropped, never queued.** If inference is still running when the
/// next frame arrives, that frame is discarded on the spot. A queue would grow
/// without bound the moment the device thermally throttles, and the detections
/// would drift further behind the picture the longer the game went on — which
/// is worse than simply seeing fewer of them.
///
/// **It gets out of the way when the device is in trouble.** Thermal state is
/// observed, not sampled hopefully: serious throttles the rate, critical stops
/// inference entirely and says so.
final class YOLODetectionService {

    // MARK: - Tuning

    /// Inference rate ceiling. Ten is comfortable on an A-series device for a
    /// 320px model and leaves the capture queue enough headroom to keep the
    /// preview smooth. The state machine confirms events over several frames,
    /// so it cares about consistency far more than raw rate.
    var inferenceFPS: Double = 10 {
        didSet {
            stateLock.lock()
            minimumInterval = 1.0 / max(1, inferenceFPS)
            stateLock.unlock()
        }
    }

    /// Used when the device gets warm. Still above the rate at which the
    /// tracker loses object identity between frames.
    var lowPowerFPS: Double = 6

    var confidenceThreshold: Float = 0.45 {
        didSet {
            // Written from a Settings slider on main, read on the inference
            // queue. Hand it over rather than reaching across.
            let value = confidenceThreshold
            inferenceQueue.async { [weak self] in
                self?.parserConfiguration.confidenceThreshold = value
            }
        }
    }

    /// Fired on the main thread after every completed inference. This is the
    /// public hook described in the integration notes.
    var onDetectionsUpdated: (([YOLODetection]) -> Void)?
    /// Same event, plus the frame's presentation time. The scoring pipeline
    /// needs the timestamp to measure speeds, and an empty detection list has
    /// no timestamp to recover it from.
    var onFrameProcessed: (([YOLODetection], CMTime) -> Void)?
    /// Fired on the main thread when the status changes.
    var onStatusChanged: ((DetectorStatus) -> Void)?

    // MARK: - Observable state

    private(set) var latestDetections: [YOLODetection] = []
    /// Read only on main. The capture path uses `isRunnableSnapshot` instead.
    private(set) var status: DetectorStatus = .idle
    private(set) var lastInferenceMilliseconds: Double = 0
    private(set) var measuredFPS: Double = 0
    private(set) var modelInputSize = CGSize(width: 320, height: 320)

    var isInferenceRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isProcessingFrame
    }

    // MARK: - Internals

    private let inferenceQueue = DispatchQueue(label: "polescore.yolo", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isProcessingFrame = false
    /// Lock-guarded mirror of `status.isRunnable`.
    ///
    /// `DetectorStatus` has a `String` payload on its `.failed` case, so it is
    /// not safe to read from the capture queue while main is writing it — a
    /// torn read of a String reference is a crash, not a wrong answer. The
    /// frame path only ever needs the yes/no, so that is what it gets.
    private var runnable = false

    /// Guarded by `stateLock`, like everything else the capture queue reads.
    private var activeRequest: VNCoreMLRequest?
    private var parserConfiguration = YOLOOutputParser.Configuration()
    private var minimumInterval: Double = 0.1
    private var lastInferenceAt: Double = 0
    private var inferenceTimestamps: [Double] = []
    private var backgrounded = false
    private var thermalState: ProcessInfo.ThermalState = .nominal
    /// Lock-guarded mirror, for the same reason as `runnable`.
    private var thermalThrottled = false
    private var observers: [NSObjectProtocol] = []

    init() {
        minimumInterval = 1.0 / inferenceFPS
        thermalThrottled = ProcessInfo.processInfo.thermalState == .serious
        parserConfiguration.confidenceThreshold = confidenceThreshold
        observeSystemState()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Loading

    /// Loads the model off the main thread. Safe to call more than once; the
    /// second call is a no-op once a request exists.
    func load() {
        stateLock.lock()
        let alreadyLoaded = activeRequest != nil
        stateLock.unlock()
        guard !alreadyLoaded, status != .loading else { return }
        setStatus(.loading)
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                let model = try Self.loadModel()
                self.modelInputSize = Self.inputSize(of: model) ?? self.modelInputSize
                self.parserConfiguration.inputSize = self.modelInputSize

                let visionModel = try VNCoreMLModel(for: model)
                let request = VNCoreMLRequest(model: visionModel)
                // `.scaleFill` on purpose. The alternative, `.centerCrop`, would
                // throw away the left and right thirds of a 16:9 frame — which
                // on this court is precisely where the two poles are. Squashing
                // the aspect ratio costs a little accuracy on box shape;
                // cropping would cost the objects entirely. Because the whole
                // frame is fed in, the inverse mapping back to the preview is a
                // straight linear unmap over the full buffer, which is what
                // `DetectionCoordinateMapper` assumes.
                request.imageCropAndScaleOption = .scaleFill
                self.stateLock.lock()
                self.activeRequest = request
                self.stateLock.unlock()
                self.setStatus(.ready)
            } catch let error as ModelLoadError {
                self.setStatus(error == .missing ? .modelMissing : .failed(error.description))
            } catch {
                self.setStatus(.failed(error.localizedDescription))
            }
        }
    }

    private enum ModelLoadError: Error, Equatable {
        case missing
        case compileFailed(String)

        var description: String {
            switch self {
            case .missing: return "not in bundle"
            case .compileFailed(let reason): return reason
            }
        }
    }

    /// Loads `GameDetector` by URL rather than through an Xcode-generated Swift
    /// class.
    ///
    /// This package is a Swift Playgrounds app. Playgrounds has no Core ML
    /// build rule, so dropping in `GameDetector.mlmodel` there does *not*
    /// produce a `GameDetector` type — code written against `try
    /// GameDetector(configuration:)` would simply fail to compile on the device
    /// this app is built on. Loading by URL works identically whether the model
    /// arrives pre-compiled or raw, in Playgrounds or in Xcode, and it is also
    /// what lets a missing model be a recoverable status instead of a build
    /// error.
    private static func loadModel() throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine

        func open(_ url: URL) throws -> MLModel {
            do {
                return try MLModel(contentsOf: url, configuration: configuration)
            } catch {
                // Not every device and OS pairing accepts every compute-unit
                // request. Falling back beats refusing to run.
                for fallback in [MLComputeUnits.all, .cpuOnly] {
                    let retry = MLModelConfiguration()
                    retry.computeUnits = fallback
                    if let model = try? MLModel(contentsOf: url, configuration: retry) { return model }
                }
                throw error
            }
        }

        // Already compiled, either by Xcode or by a previous launch.
        if let url = Bundle.main.url(forResource: "GameDetector", withExtension: "mlmodelc") {
            return try open(url)
        }
        if let cached = cachedCompiledModelURL(), FileManager.default.fileExists(atPath: cached.path) {
            if let model = try? open(cached) { return model }
        }

        // Raw model in the bundle: compile once, keep the result.
        for ext in ["mlpackage", "mlmodel"] {
            guard let source = Bundle.main.url(forResource: "GameDetector", withExtension: ext) else { continue }
            do {
                let compiled = try MLModel.compileModel(at: source)
                if let cache = cachedCompiledModelURL() {
                    try? FileManager.default.removeItem(at: cache)
                    try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    if (try? FileManager.default.moveItem(at: compiled, to: cache)) != nil {
                        return try open(cache)
                    }
                }
                return try open(compiled)
            } catch {
                throw ModelLoadError.compileFailed(error.localizedDescription)
            }
        }

        throw ModelLoadError.missing
    }

    private static func cachedCompiledModelURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GameDetector.mlmodelc")
    }

    private static func inputSize(of model: MLModel) -> CGSize? {
        for (_, description) in model.modelDescription.inputDescriptionsByName {
            if let image = description.imageConstraint {
                return CGSize(width: image.pixelsWide, height: image.pixelsHigh)
            }
        }
        return nil
    }

    // MARK: - Inference

    /// Hand a frame in. Returns immediately; the frame is dropped without fuss
    /// if the detector is busy, throttled, paused, or not loaded.
    ///
    /// The pixel buffer is used only for the duration of the call and is never
    /// retained past it, so the capture system can recycle it straight away.
    func process(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let request = claimSlot(at: CMTimeGetSeconds(timestamp)) else { return }

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            // Every exit path below has to clear the flag, so it is done once,
            // here, rather than at each `return`.
            defer {
                self.stateLock.lock()
                self.isProcessingFrame = false
                self.stateLock.unlock()
            }

            autoreleasepool {
                let started = CFAbsoluteTimeGetCurrent()
                // The capture connection has already rotated the buffer to
                // match the preview, so there is no further orientation to
                // apply here. Passing anything but `.up` would rotate it twice.
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                    orientation: .up,
                                                    options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    self.setStatus(.failed(error.localizedDescription))
                    return
                }

                let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
                let detections = YOLOOutputParser.detections(from: request.results ?? [],
                                                             configuration: self.parserConfiguration,
                                                             timestamp: timestamp)

                self.inferenceTimestamps.append(CFAbsoluteTimeGetCurrent())
                self.inferenceTimestamps.removeAll { CFAbsoluteTimeGetCurrent() - $0 > 2 }
                let rate = Double(self.inferenceTimestamps.count) / 2.0

                DispatchQueue.main.async {
                    self.lastInferenceMilliseconds = elapsed
                    self.measuredFPS = rate
                    self.latestDetections = detections
                    self.onDetectionsUpdated?(detections)
                    self.onFrameProcessed?(detections, timestamp)
                }
            }
        }
    }


    // MARK: - Lifecycle

    private func observeSystemState() {
        let center = NotificationCenter.default
        thermalState = ProcessInfo.processInfo.thermalState

        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.updateThermalState()
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.setBackgrounded(true)
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.setBackgrounded(false)
        })
    }

    private func updateThermalState() {
        thermalState = ProcessInfo.processInfo.thermalState
        stateLock.lock()
        thermalThrottled = thermalState == .serious
        stateLock.unlock()
        switch thermalState {
        case .critical:
            setStatus(.pausedThermal)
        default:
            if status == .pausedThermal, !backgrounded { setStatus(.ready) }
        }
    }

    private func setBackgrounded(_ value: Bool) {
        backgrounded = value
        if value {
            if status.isRunnable { setStatus(.pausedBackground) }
        } else if status == .pausedBackground {
            setStatus(ProcessInfo.processInfo.thermalState == .critical ? .pausedThermal : .ready)
        }
    }

    /// Decide whether to run this frame, and reserve the detector if so, in a
    /// single atomic step.
    ///
    /// Splitting the decision from the reservation is what makes this subtle:
    /// check-then-set leaves a window where two frames both pass the check, and
    /// reserving before confirming the request exists leaves `isProcessingFrame`
    /// stuck on forever if it does not. Either bug stops inference permanently
    /// and silently. Doing it all under one lock removes both.
    private func claimSlot(at now: Double) -> VNCoreMLRequest? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let interval = thermalThrottled ? 1.0 / max(1, lowPowerFPS) : minimumInterval
        guard runnable,
              !isProcessingFrame,
              now - lastInferenceAt >= interval,
              let request = activeRequest else { return nil }
        isProcessingFrame = true
        lastInferenceAt = now
        return request
    }

    /// Cheap, thread-safe answer to "should the capture path bother?".
    var isRunnableSnapshot: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return runnable
    }

    private func setStatus(_ new: DetectorStatus) {
        stateLock.lock()
        runnable = new.isRunnable
        stateLock.unlock()

        DispatchQueue.main.async {
            guard self.status != new else { return }
            self.status = new
            self.onStatusChanged?(new)
        }
    }

    /// Diagnostics for the debug overlay.
    func diagnostics() -> DetectorDiagnostics {
        DetectorDiagnostics(status: status,
                            measuredFPS: measuredFPS,
                            targetFPS: thermalState == .serious ? lowPowerFPS : inferenceFPS,
                            detectionCount: latestDetections.count,
                            lastInferenceMilliseconds: lastInferenceMilliseconds,
                            thermalState: thermalState)
    }
}

struct DetectorDiagnostics {
    var status: DetectorStatus = .idle
    var measuredFPS: Double = 0
    var targetFPS: Double = 10
    var detectionCount = 0
    var lastInferenceMilliseconds: Double = 0
    var thermalState: ProcessInfo.ThermalState = .nominal

    var thermalText: String {
        switch thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
