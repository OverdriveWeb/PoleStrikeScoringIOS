import CoreML
import CoreMedia
import Foundation
import Vision

/// One detection as the model reported it, before anything in this app has had
/// an opinion about what it means.
///
/// Deliberately stringly-typed and in Vision's own coordinate space: this is the
/// boundary type, and the whole point of a boundary type is that it does not
/// know about `Label`, `Side`, or where the court is. `DetectionBridge` is the
/// only place that translation happens.
struct YOLODetection: Identifiable, Equatable {
    let id: UUID
    let label: String
    let confidence: Float
    /// Normalized Vision coordinates: origin **bottom-left**, 0...1 on both axes.
    let boundingBox: CGRect
    let timestamp: CMTime

    init(id: UUID = UUID(), label: String, confidence: Float,
         boundingBox: CGRect, timestamp: CMTime) {
        self.id = id
        self.label = label
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.timestamp = timestamp
    }
}

/// Everything model-specific lives here.
///
/// There is no single "YOLO Core ML output" — the shape depends entirely on how
/// the model was exported:
///
///   * `ultralytics export(format="coreml", nms=True)` builds a pipeline with a
///     non-maximum-suppression stage on the end, and Vision recognises the
///     result as an object detector. You get `VNRecognizedObjectObservation`
///     and there is nothing to decode.
///   * `nms=False` gives you the raw head as one `MLMultiArray` — typically
///     `[1, 4+numClasses, numAnchors]` for v8/v11 or `[1, numAnchors, 5+numClasses]`
///     for v5 — and you have to decode boxes, pick classes, and run NMS yourself.
///   * Some exports emit the NMS pair as two named arrays, `confidence`
///     `[N, numClasses]` and `coordinates` `[N, 4]`, without the pipeline
///     wrapper Vision looks for.
///
/// All three are handled below so that swapping the exported model does not
/// ripple past this file.
enum YOLOOutputParser {

    /// Where the model puts the origin of its box coordinates. Ultralytics uses
    /// the image convention (top-left); Vision uses bottom-left. Getting this
    /// backwards produces detections that are vertically mirrored, which looks
    /// plausible enough on a symmetric scene to go unnoticed for a while — so
    /// it is named rather than hidden in a subtraction.
    enum BoxOrigin {
        case topLeft
        case bottomLeft
    }

    struct Configuration {
        var confidenceThreshold: Float = 0.45
        var iouThreshold: Float = 0.45
        var maxDetections = 32
        var boxOrigin: BoxOrigin = .topLeft
        /// Only needed for raw-head decoding, where coordinates usually come
        /// back in input-pixel units rather than normalized.
        var inputSize = CGSize(width: 320, height: 320)
        /// Used only when the raw head carries no class names of its own.
        var classLabels: [String] = DetectionBridge.expectedLabels
    }

    // MARK: - Entry point

    static func detections(from observations: [VNObservation],
                           configuration: Configuration,
                           timestamp: CMTime) -> [YOLODetection] {
        // Path 1: the model already did NMS and Vision understood it.
        let recognized = observations.compactMap { $0 as? VNRecognizedObjectObservation }
        if !recognized.isEmpty {
            return recognized.compactMap { observation in
                guard let best = observation.labels.first,
                      best.confidence >= configuration.confidenceThreshold else { return nil }
                return YOLODetection(label: best.identifier.lowercased(),
                                     confidence: best.confidence,
                                     boundingBox: observation.boundingBox,
                                     timestamp: timestamp)
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(configuration.maxDetections)
            .map { $0 }
        }

        // Path 2 and 3: raw tensors.
        let features = observations.compactMap { $0 as? VNCoreMLFeatureValueObservation }
        guard !features.isEmpty else { return [] }

        var arrays: [String: MLMultiArray] = [:]
        for feature in features {
            if let array = feature.featureValue.multiArrayValue {
                arrays[feature.featureName.lowercased()] = array
            }
        }
        guard !arrays.isEmpty else { return [] }

        let raw: [YOLODetection]
        if let confidence = arrays.first(where: { $0.key.contains("confidence") })?.value,
           let coordinates = arrays.first(where: { $0.key.contains("coordinate") })?.value {
            raw = decodePair(confidence: confidence, coordinates: coordinates,
                             configuration: configuration, timestamp: timestamp)
        } else if let head = arrays.values.max(by: { $0.count < $1.count }) {
            raw = decodeHead(head, configuration: configuration, timestamp: timestamp)
        } else {
            raw = []
        }

        return nonMaximumSuppression(raw,
                                     iouThreshold: configuration.iouThreshold,
                                     maxDetections: configuration.maxDetections)
    }

    // MARK: - Raw decoding

    /// `confidence` is `[N, numClasses]`, `coordinates` is `[N, 4]` as centre
    /// x, centre y, width, height — already normalized.
    private static func decodePair(confidence: MLMultiArray,
                                   coordinates: MLMultiArray,
                                   configuration: Configuration,
                                   timestamp: CMTime) -> [YOLODetection] {
        let shape = confidence.shape.map(\.intValue)
        guard shape.count >= 2 else { return [] }
        let rows = shape[shape.count - 2]
        let classes = shape[shape.count - 1]
        guard rows > 0, classes > 0, coordinates.count >= rows * 4 else { return [] }

        let scores = confidence.toFloatArray()
        let boxes = coordinates.toFloatArray()
        var result: [YOLODetection] = []

        for row in 0..<rows {
            var bestClass = 0
            var bestScore: Float = 0
            for klass in 0..<classes {
                let score = scores[row * classes + klass]
                if score > bestScore {
                    bestScore = score
                    bestClass = klass
                }
            }
            guard bestScore >= configuration.confidenceThreshold else { continue }

            let base = row * 4
            let rect = rectFromCenter(cx: CGFloat(boxes[base]),
                                      cy: CGFloat(boxes[base + 1]),
                                      w: CGFloat(boxes[base + 2]),
                                      h: CGFloat(boxes[base + 3]),
                                      origin: configuration.boxOrigin)
            guard let rect else { continue }
            result.append(YOLODetection(label: name(for: bestClass, in: configuration),
                                        confidence: bestScore,
                                        boundingBox: rect,
                                        timestamp: timestamp))
        }
        return result
    }

    /// A single raw head. Two layouts are common and they are distinguished by
    /// which axis is small: the channel axis is `4 + numClasses` (a handful),
    /// the anchor axis is thousands.
    private static func decodeHead(_ array: MLMultiArray,
                                   configuration: Configuration,
                                   timestamp: CMTime) -> [YOLODetection] {
        var shape = array.shape.map(\.intValue)
        while shape.count > 2 && shape.first == 1 { shape.removeFirst() }
        guard shape.count == 2 else { return [] }

        let channelsFirst = shape[0] < shape[1]
        let channels = channelsFirst ? shape[0] : shape[1]
        let anchors = channelsFirst ? shape[1] : shape[0]
        guard channels >= 5, anchors > 0 else { return [] }

        // v5-style heads carry an extra objectness column ahead of the classes;
        // v8/v11 heads do not. If the channel count matches the class list
        // exactly at 4 + classes, assume v8.
        let classes = configuration.classLabels.count
        let hasObjectness = channels == classes + 5
        let classOffset = hasObjectness ? 5 : 4
        let classCount = channels - classOffset
        guard classCount > 0 else { return [] }

        let values = array.toFloatArray()
        func value(_ channel: Int, _ anchor: Int) -> Float {
            channelsFirst ? values[channel * anchors + anchor] : values[anchor * channels + channel]
        }

        var result: [YOLODetection] = []
        for anchor in 0..<anchors {
            let objectness = hasObjectness ? value(4, anchor) : 1
            guard objectness >= configuration.confidenceThreshold * 0.5 else { continue }

            var bestClass = 0
            var bestScore: Float = 0
            for klass in 0..<classCount {
                let score = value(classOffset + klass, anchor) * objectness
                if score > bestScore {
                    bestScore = score
                    bestClass = klass
                }
            }
            guard bestScore >= configuration.confidenceThreshold else { continue }

            // Raw heads usually emit input-pixel units. Anything above ~1.5
            // cannot be normalized, so that is the tell.
            var cx = CGFloat(value(0, anchor))
            var cy = CGFloat(value(1, anchor))
            var w = CGFloat(value(2, anchor))
            var h = CGFloat(value(3, anchor))
            if max(cx, cy, w, h) > 1.5 {
                cx /= configuration.inputSize.width
                cy /= configuration.inputSize.height
                w /= configuration.inputSize.width
                h /= configuration.inputSize.height
            }

            guard let rect = rectFromCenter(cx: cx, cy: cy, w: w, h: h,
                                            origin: configuration.boxOrigin) else { continue }
            result.append(YOLODetection(label: name(for: bestClass, in: configuration),
                                        confidence: bestScore,
                                        boundingBox: rect,
                                        timestamp: timestamp))
        }
        return result
    }

    private static func name(for index: Int, in configuration: Configuration) -> String {
        guard index >= 0, index < configuration.classLabels.count else { return "class_\(index)" }
        return configuration.classLabels[index].lowercased()
    }

    /// Centre-form box to a Vision rect, flipping the origin if the model used
    /// the image convention. Returns nil for degenerate boxes rather than
    /// letting a zero-area detection through to the tracker.
    static func rectFromCenter(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat,
                               origin: BoxOrigin) -> CGRect? {
        guard w > 0.0005, h > 0.0005, w.isFinite, h.isFinite, cx.isFinite, cy.isFinite else { return nil }
        let x = cx - w / 2
        let yTop = cy - h / 2
        let y = origin == .topLeft ? (1 - yTop - h) : yTop
        let rect = CGRect(x: x, y: y, width: w, height: h)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !rect.isNull, rect.width > 0.0005, rect.height > 0.0005 else { return nil }
        return rect
    }

    // MARK: - NMS

    /// Greedy per-class non-maximum suppression. Per class, because a bottle
    /// sitting on a pole overlaps that pole almost completely, and suppressing
    /// across classes would delete one of them every single frame.
    static func nonMaximumSuppression(_ detections: [YOLODetection],
                                      iouThreshold: Float,
                                      maxDetections: Int) -> [YOLODetection] {
        var kept: [YOLODetection] = []
        let grouped = Dictionary(grouping: detections) { $0.label }

        for (_, group) in grouped {
            var candidates = group.sorted { $0.confidence > $1.confidence }
            while !candidates.isEmpty {
                let best = candidates.removeFirst()
                kept.append(best)
                candidates.removeAll { intersectionOverUnion(best.boundingBox, $0.boundingBox) > iouThreshold }
            }
        }

        return kept.sorted { $0.confidence > $1.confidence }
            .prefix(maxDetections)
            .map { $0 }
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Float {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let overlap = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - overlap
        guard union > 0 else { return 0 }
        return Float(overlap / union)
    }
}

extension MLMultiArray {
    /// One contiguous read instead of `count` bridged subscripts. On a
    /// `[1, 84, 8400]` head that is seven hundred thousand elements per frame,
    /// which is the difference between a few milliseconds and a stutter.
    func toFloatArray() -> [Float] {
        switch dataType {
        case .float32:
            let pointer = dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        case .double:
            let pointer = dataPointer.bindMemory(to: Double.self, capacity: count)
            return UnsafeBufferPointer(start: pointer, count: count).map { Float($0) }
        case .float16:
            // No safe direct binding; fall back to the bridged path.
            return (0..<count).map { Float(truncating: self[$0]) }
        default:
            return (0..<count).map { Float(truncating: self[$0]) }
        }
    }
}
