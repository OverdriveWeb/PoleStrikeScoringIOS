import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

/// Owns the capture session and the whole per-frame path:
/// frame -> glow blobs -> court estimate -> classified detections -> tracker ->
/// state machine.
///
/// Detection runs on the capture queue, never on the main thread — a 720p frame
/// scan plus flood fill is cheap, but doing it on the UI thread would still cost
/// you preview smoothness. Only the small published summary hops to main.
final class CameraController: NSObject, ObservableObject {
    @Published var authorized = false
    @Published var running = false
    @Published var status: StatusBadge = .watching
    @Published var notice: String?
    @Published var tracks: [Track] = []
    @Published var blobCount = 0
    @Published var analysisFPS = 0.0

    /// Court state, surfaced only as a one-line readout. There is nothing to
    /// confirm and nothing to tap — this is the app telling you what it worked
    /// out, not asking you to check it.
    @Published var courtReady = false
    @Published var courtConfidence = 0.0
    @Published var courtSummary = "Looking for the court"
    @Published var colorSummary = "learning colours"
    /// Live detector state, for the status line and the debug HUD.
    @Published var detectorStatus: DetectorStatus = .idle
    @Published var diagnostics = DetectorDiagnostics()
    /// True buffer size, needed to undo the preview's aspect-fill crop.
    @Published var videoResolution = CGSize(width: 1280, height: 720)
    /// What the model reported for the most recent frame, in Vision
    /// coordinates, for the overlay to draw.
    @Published var modelDetections: [YOLODetection] = []

    /// Pinch-to-zoom, exactly like the camera app: 1× is the wide lens and the
    /// ceiling is whatever the device can actually do. This exists so the phone
    /// can sit at a comfortable distance instead of being shoved back until both
    /// poles happen to fit in frame.
    @Published var zoom: CGFloat = 1
    @Published private(set) var minZoom: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 1

    let session = AVCaptureSession()

    /// Touched only from `queue` once capture starts.
    let classifier = GlowClassifier()
    let machine = PlayStateMachine()
    private let tracker = Tracker()
    private let courtDetector = CourtDetector()
    private var detector = GlowDetector()

    /// On-device YOLO. Owns no camera of its own — it is handed the buffers
    /// this class already receives, which is the only way to be certain the app
    /// never ends up with two capture sessions fighting over the hardware.
    let yolo = YOLODetectionService()

    /// Set by the preview so the rotation coordinator can level to it.
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    /// A resolved play. Nothing leaves the device with it — inference is
    /// entirely local, so there are no frames to hand over.
    var onOutcome: ((PlayOutcome) -> Void)?

    private let queue = DispatchQueue(label: "polescore.camera", qos: .userInitiated)
    private var configured = false
    private var lastAnalysis: Double = 0
    private var fpsWindow: [Double] = []
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    private var zoomAtGestureStart: CGFloat = 1

    // Court readings taken from the model rather than from blobs.
    private var modelCourtAccepted = false
    private var lastModelCourtAt: Double = 0
    private var restedTrackIds = Set<Int>()
    private var watchingSince: Double = 0
    private var lastFrameTimestamp: Double = 0
    private var measuredVideoSize = CGSize.zero

    // Last values actually pushed to the UI. The court estimate is recomputed
    // every frame and drifts by fractions of a percent as anchors settle;
    // republishing that at frame rate would redraw the whole game screen 24
    // times a second to change nothing anybody can see.
    private var publishedCourtReady = false
    private var publishedCourtSummary = ""
    private var publishedCourtConfidence = 0.0

    // Written on main, read on the capture queue. Guarded by a lock because a
    // torn read of the court mid-frame would put the ground line in the wrong
    // place for exactly one decision — which is the decision that matters.
    private let lock = NSLock()
    private var _court: Court?
    private var _scoringEnabled = true
    private var _frameInterval: Double = 1.0 / 24.0

    var court: Court? {
        get { lock.lock(); defer { lock.unlock() }; return _court }
        set { lock.lock(); _court = newValue; lock.unlock() }
    }

    var scoringEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _scoringEnabled }
        set { lock.lock(); _scoringEnabled = newValue; lock.unlock() }
    }

    func setAnalysisFPS(_ fps: Double) {
        lock.lock(); _frameInterval = 1.0 / max(4, fps); lock.unlock()
    }

    override init() {
        super.init()
        wireDetector()
    }

    // MARK: - Detector wiring

    /// Connects the model to the frame path. Both callbacks arrive on main, so
    /// the published state is set directly and only the scoring work is handed
    /// back to the capture queue that owns the tracker and state machine.
    private func wireDetector() {
        yolo.onFrameProcessed = { [weak self] detections, time in
            guard let self else { return }
            self.modelDetections = detections
            self.diagnostics = self.yolo.diagnostics()
            self.analysisFPS = self.yolo.measuredFPS
            let seconds = CMTimeGetSeconds(time)
            self.queue.async {
                self.consume(modelDetections: detections, timestamp: seconds)
            }
        }

        yolo.onStatusChanged = { [weak self] status in
            guard let self else { return }
            self.detectorStatus = status
            self.diagnostics = self.yolo.diagnostics()
            // Switching pipelines mid-game leaves the tracker holding tracks
            // that the other detector produced, at a different rate and with
            // different box shapes. Start both clean rather than let one
            // pipeline inherit the other's half-finished play.
            self.queue.async {
                self.tracker.reset()
                self.machine.reset()
                self.modelCourtAccepted = false
            }
            if status == .modelMissing || status == .pausedThermal {
                self.modelDetections = []
            }
        }

        yolo.load()
    }

    // MARK: - Session

    /// iOS terminates the process — no catchable error — if you touch the
    /// camera APIs without a usage description in place. So check first and
    /// report it rather than dying on launch.
    static var hasCameraUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

    @MainActor
    func requestAccess() async {
        guard Self.hasCameraUsageDescription else {
            authorized = false
            notice = "Camera capability is missing. In Swift Playgrounds open App Settings, "
                + "add the Camera capability with a description, then run again."
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }
        if authorized { configure() }
    }

    func configure() {
        guard !configured, Self.hasCameraUsageDescription else { return }
        configured = true

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            publish { self.notice = "No rear camera available." }
            return
        }
        session.addInput(input)
        device = camera

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()

        // Zoom range comes from the hardware, not from a guess. The ceiling is
        // capped below the format maximum because past a point it is pure
        // upscaling and the detector gets nothing out of it.
        let low = camera.minAvailableVideoZoomFactor
        let high = min(camera.activeFormat.videoMaxZoomFactor, 12)
        let current = camera.videoZoomFactor
        publish {
            self.minZoom = low
            self.maxZoom = max(high, low)
            self.zoom = min(max(current, low), max(high, low))
        }

        // Continuous auto exposure helps in the dark. Longer exposures smear a
        // flying disc into a streak, which the threshold still finds — one more
        // reason brightness beats a model on a lit set.
        if (try? camera.lockForConfiguration()) != nil {
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            camera.unlockForConfiguration()
        }

        startRotationTracking()
    }

    func start() {
        guard authorized, Self.hasCameraUsageDescription else { return }
        configure()
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        publish { self.running = true }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        publish { self.running = false }
    }

    func resetTracking() {
        queue.async {
            self.tracker.reset()
            self.machine.reset()
            self.classifier.reset()
        }
    }

    /// Start over on the court — used when the phone is moved or zoomed. The
    /// learned colours survive, because the set on the field did not change.
    func rediscoverCourt() {
        court = nil
        // Everything below is capture-queue state. Reaching in from main would
        // be a race against the frame currently being analysed, so the whole
        // reset is handed to the queue that owns it.
        queue.async {
            self.courtDetector.reset()
            self.tracker.reset()
            self.machine.reset()
            self.modelCourtAccepted = false
            self.lastModelCourtAt = 0
            self.restedTrackIds.removeAll()
            self.watchingSince = 0
            self.publishCourtState(ready: false, confidence: 0,
                                   summary: "Looking for the court")
        }
    }

    // MARK: - Rotation

    /// Orientation used to be a four-way picker in Settings, on the theory that
    /// the sensor's idea of "up" varies by device. It does — which is exactly
    /// why the system will tell you, if you ask. This asks.
    private func startRotationTracking() {
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.applyPreviewRotation(angle) }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                DispatchQueue.main.async { self?.applyCaptureRotation(angle) }
            }
        ]
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// Applied to the analysis buffer as well as the preview, so the debug
    /// overlay and the detector never disagree with what you see.
    private func applyCaptureRotation(_ angle: CGFloat) {
        for output in session.outputs {
            for connection in output.connections where connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        rotationObservations = []
        rotationCoordinator = nil
        startRotationTracking()
    }

    // MARK: - Zoom

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minZoom), max(minZoom, maxZoom))
    }

    /// Pinch begins: remember where we were, so the gesture scales from there
    /// rather than jumping.
    func beginZoomGesture() {
        zoomAtGestureStart = zoom
    }

    func updateZoomGesture(scale: CGFloat) {
        setZoom(zoomAtGestureStart * scale)
    }

    func setZoom(_ factor: CGFloat, animated: Bool = false) {
        guard let device else { return }
        let target = clampZoom(factor)
        guard (try? device.lockForConfiguration()) != nil else { return }
        if animated {
            device.ramp(toVideoZoomFactor: target, withRate: 6)
        } else {
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = target
        }
        device.unlockForConfiguration()

        // Zooming changes every normalized coordinate in the frame, so the court
        // measured before the pinch is no longer the court. Rather than rescale
        // it and be subtly wrong about the ground line — the one measurement
        // worth a point per play — read it again.
        let changed = abs(target - zoom) > 0.01
        zoom = target
        if changed { rediscoverCourt() }
    }

    /// Double-tap: snap between 1× and 2×, the way the camera app does.
    func toggleZoom() {
        setZoom(zoom > 1.5 ? 1 : min(2, maxZoom), animated: true)
    }

    // MARK: - Helpers

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// Publish court state only when it changed enough to be worth a redraw.
    private func publishCourtState(ready: Bool, confidence: Double, summary: String) {
        guard ready != publishedCourtReady
            || summary != publishedCourtSummary
            || abs(confidence - publishedCourtConfidence) > 0.02 else { return }
        publishedCourtReady = ready
        publishedCourtSummary = summary
        publishedCourtConfidence = confidence
        publish {
            self.courtReady = ready
            self.courtConfidence = confidence
            self.courtSummary = summary
        }
    }

    /// Downscaled JPEG of the current frame. Small on purpose: the model needs
    /// to see where things are, not read the label on the bottle.
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    /// The one and only frame callback in the app.
    ///
    /// Two pipelines can drive scoring and exactly one of them is live at a
    /// time:
    ///
    ///   * **YOLO**, once the model has loaded. Buffers are handed to the
    ///     detector, which throttles and drops frames on its own, and the
    ///     scoring pipeline is driven from its callback rather than from here.
    ///   * **Glow blobs**, the original brightness-threshold path, whenever the
    ///     model is missing, still loading, or paused because the device is
    ///     hot. It is unchanged, so pulling the model out of the bundle returns
    ///     the app to exactly its previous behaviour rather than to nothing.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMTimeGetSeconds(time)
        lastFrameTimestamp = timestamp

        // The overlay needs the buffer's true size to undo the preview's
        // aspect-fill crop. Published on change, not per frame.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if Int(measuredVideoSize.width) != width || Int(measuredVideoSize.height) != height {
            measuredVideoSize = CGSize(width: width, height: height)
            let size = measuredVideoSize
            publish { self.videoResolution = size }
        }

        if yolo.isRunnableSnapshot {
            // The detector decides whether this frame is worth running: it
            // enforces the FPS ceiling and drops the frame outright if the
            // previous inference has not finished. Nothing is queued, and the
            // buffer is not retained past the call.
            yolo.process(pixelBuffer: pixelBuffer, timestamp: time)
            return
        }

        processWithGlowDetector(pixelBuffer, timestamp: timestamp)
    }

    // MARK: - Model-driven path

    /// Called on the capture queue with a fresh set of model detections.
    ///
    /// Runs on `queue` rather than main because `tracker`, `machine` and
    /// `courtDetector` all belong to that queue and always have. The detector
    /// reports on main; hopping back is one line and keeps the invariant
    /// intact rather than quietly introducing a second owner for that state.
    func consume(modelDetections raw: [YOLODetection], timestamp: Double) {
        let existing = self.court
        let reading = DetectionBridge.read(raw, court: existing)

        // --- court, straight from the model ---------------------------------
        if !modelCourtAccepted || timestamp - lastModelCourtAt > 4 {
            if let modelCourt = DetectionBridge.court(from: reading, existing: existing) {
                courtDetector.accept(modelCourt: modelCourt, confidence: 0.9)
                modelCourtAccepted = true
                lastModelCourtAt = timestamp
                self.court = modelCourt
                publishCourtState(ready: true, confidence: 0.9,
                                  summary: CourtEstimate.Source.model.label)
            }
        }

        // --- court without a pole class --------------------------------------
        //
        // Every pretrained YOLO is a COCO model, and COCO has `frisbee`,
        // `bottle` and `person` but no `pole` and no `ground`. Building the
        // court only from pole boxes would mean a stock model could never
        // establish one, and the app would sit at "Looking for the poles"
        // forever without ever scoring a throw.
        //
        // So the bottles stand in. `CourtDetector` already knows how to turn
        // "bright things that stay in one place" into a court, and a bottle
        // detection is exactly that with better provenance than a blob. Feeding
        // it synthetic observations reuses the whole anchor, ground-line and
        // drift apparatus rather than growing a second copy of it.
        if !modelCourtAccepted {
            courtDetector.observe(blobs: syntheticBlobs(from: reading), timestamp: timestamp)
            if let estimate = courtDetector.current {
                self.court = estimate.court
                publishCourtState(ready: true, confidence: estimate.confidence,
                                  summary: "Read from the model's bottles")
            }
        }

        if self.court == nil {
            let progress = courtDetector.progress
            publishCourtState(ready: false, confidence: 0,
                              summary: progress > 0.05
                                  ? "Reading the court... \(Int(progress * 100))%"
                                  : "Looking for the poles and bottles")
        }

        // --- scoring ---------------------------------------------------------
        let activeCourt = self.court
        let currentTracks = tracker.update(reading.detections, timestamp: timestamp)

        // Quality is about whether the model is seeing the court at all, which
        // is the model-era equivalent of "is anything lit".
        let quality = reading.detections.isEmpty
            ? 0.35
            : min(1.0, 0.6 + 0.1 * Double(reading.detections.count))

        let result: MachineOutput
        if let activeCourt {
            result = machine.update(tracks: currentTracks, court: activeCourt,
                                    timestamp: timestamp, quality: quality)
        } else {
            machine.reset()
            result = MachineOutput(state: .idle, status: .watching, outcome: nil, notice: nil)
        }

        let scoring = self.scoringEnabled
        let snapshot = currentTracks
        let count = reading.detections.count
        let outcome = result.outcome

        DispatchQueue.main.async {
            self.tracks = snapshot
            self.blobCount = count
            self.status = result.status
            self.notice = result.notice
            if let outcome, scoring { self.onOutcome?(outcome) }
        }
    }

    /// Model detections dressed up as `Blob`s so `CourtDetector` can consume
    /// them.
    ///
    /// Only the box matters downstream: the detector uses position to find
    /// anchors, the box's aspect ratio to tell a pole from a bottle, and its
    /// lower edge as the ground line. Colour and brightness are unused on this
    /// path, so they are filled with values that cannot accidentally mean
    /// something — the glow classifier never sees these.
    private func syntheticBlobs(from reading: DetectionBridge.Reading) -> [Blob] {
        (reading.poles + reading.bottles).map { box in
            Blob(box: box,
                 hue: 0,
                 saturation: 0,
                 brightness: 1,
                 // Clamped under the detector's own "that is a floodlight, not
                 // a set" ceiling, which a full-height pole box would otherwise
                 // trip.
                 area: min(0.05, max(0.0002, box.w * box.h)))
        }
    }

    // MARK: - Glow fallback

    /// The original pipeline, untouched.
    private func processWithGlowDetector(_ pixelBuffer: CVPixelBuffer, timestamp: Double) {
        lock.lock()
        let interval = _frameInterval
        let knownCourt = _court
        let scoring = _scoringEnabled
        lock.unlock()

        guard timestamp - lastAnalysis >= interval else { return }
        let previous = lastAnalysis
        lastAnalysis = timestamp

        let blobs = detector.detect(pixelBuffer)

        courtDetector.observe(blobs: blobs, timestamp: timestamp)
        if knownCourt != nil, courtDetector.hasDrifted() {
            courtDetector.reset()
            machine.reset()
            tracker.reset()
            restedTrackIds.removeAll()
            watchingSince = 0
            self.court = nil
            modelCourtAccepted = false
            publishCourtState(ready: false, confidence: 0,
                              summary: "Scene changed - reading the court again")
            return
        }

        if let estimate = courtDetector.current {
            watchingSince = 0
            self.court = estimate.court
            publishCourtState(ready: true,
                              confidence: estimate.confidence,
                              summary: estimate.source.label)
        } else {
            if watchingSince == 0 { watchingSince = timestamp }
            let progress = courtDetector.progress
            publishCourtState(ready: false, confidence: 0,
                              summary: progress > 0.05
                                  ? "Reading the court... \(Int(progress * 100))%"
                                  : "Looking for the court")
        }

        let activeCourt = self.court
        let detections = classifier.classify(blobs: blobs, court: activeCourt)
        let currentTracks = tracker.update(detections, timestamp: timestamp)

        // Once per track, not once per frame: a disc that lies still for ten
        // seconds is one observation of the ground, not two hundred and forty
        // of them.
        for track in currentTracks where track.label == .disc {
            if !restedTrackIds.contains(track.id),
               track.hits >= 8,
               track.meanSpeed(window: 0.4) <= 0.03,
               let first = track.history.first?.c,
               distance(first, track.box.center) >= 0.18 {
                restedTrackIds.insert(track.id)
                courtDetector.observeRest(track.box.center)
            }
        }
        if restedTrackIds.count > 200 { restedTrackIds.removeAll() }

        // On a glow set a dark frame is the *good* case, so quality is about
        // whether anything is lit at all, not about exposure.
        let quality = blobs.isEmpty ? 0.35 : 0.95

        let result: MachineOutput
        if let activeCourt {
            result = machine.update(tracks: currentTracks, court: activeCourt,
                                    timestamp: timestamp, quality: quality)
        } else {
            machine.reset()
            result = MachineOutput(state: .idle, status: .watching, outcome: nil, notice: nil)
        }

        var fps = 0.0
        if previous > 0 {
            let delta = timestamp - previous
            if delta > 0 {
                fpsWindow.append(1 / delta)
                if fpsWindow.count > 30 { fpsWindow.removeFirst() }
                fps = fpsWindow.reduce(0, +) / Double(fpsWindow.count)
            }
        }

        let snapshot = currentTracks
        let blobTotal = blobs.count
        let outcome = result.outcome
        let colors = classifier.colors.summary

        DispatchQueue.main.async {
            self.tracks = snapshot
            self.blobCount = blobTotal
            self.status = result.status
            self.notice = result.notice
            self.colorSummary = colors
            if fps > 0 { self.analysisFPS = fps }
            if let outcome, scoring { self.onOutcome?(outcome) }
        }
    }
}

/// Live preview. Stores its layer on the controller so rotation can level to it.
struct CameraPreview: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = controller.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        controller.attachPreview(view.videoPreviewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
