import Foundation
import CoreVideo

/// One lit region found in the frame.
struct Blob {
    var box: Box
    var hue: Double          // 0...360
    var saturation: Double   // 0...1
    var brightness: Double   // 0...1
    var area: Double         // fraction of the frame
}

/// Brightness-threshold blob detector for a glow-in-the-dark set.
///
/// On a dark field the lit objects are the only bright pixels, which makes this
/// both far more reliable and vastly cheaper than a general object detector —
/// and it solves the case a detector is worst at, a spinning disc in flight,
/// which blurs into a mess for a model but stays an obvious bright streak here.
///
/// **The threshold is chosen per frame, not configured.** There used to be a
/// slider for it, which was the wrong shape for the problem twice over: it
/// asked the user to tune a number they cannot see the effect of, and it was a
/// *constant* for a quantity that drifts all evening as the glow fades. Instead
/// the cut is picked from the frame's own brightness histogram so that roughly
/// the right *share* of the frame comes back lit. A set at full charge and the
/// same set two hours later both land in range with nothing to adjust.
///
/// Works on the luma plane of the 420 buffer downsampled to a small grid; the
/// chroma plane supplies colour so the disc can be told from the bottles.
struct GlowDetector {
    var gridWidth = 160
    var minPixels = 3
    var maxBlobs = 24

    /// Share of the frame that should come back lit. A two-pole court with a
    /// disc in flight occupies well under one percent of a wide night shot.
    var targetLitFraction = 0.006
    /// Never accept anything dimmer than this, however dark the scene. Without
    /// a floor, a lens cap would produce a full frame of "objects".
    var absoluteFloor: UInt8 = 46
    /// The cut must clear the frame's own median by this much, so a scene with
    /// no glow in it at all yields nothing rather than noise.
    var minimumContrast: UInt8 = 24

    /// The cut actually used on the most recent frame, for the status line.
    private(set) var lastCut: UInt8 = 0

    mutating func detect(_ pixelBuffer: CVPixelBuffer) -> [Blob] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return [] }

        let srcW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let srcH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard srcW > 0, srcH > 0 else { return [] }

        let step = max(1, srcW / gridWidth)
        let gw = srcW / step
        let gh = srcH / step
        guard gw > 4, gh > 4 else { return [] }

        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        var grid = [UInt8](repeating: 0, count: gw * gh)
        var cbGrid = [UInt8](repeating: 128, count: gw * gh)
        var crGrid = [UInt8](repeating: 128, count: gw * gh)
        var histogram = [Int](repeating: 0, count: 256)

        for gy in 0..<gh {
            let sy = gy * step
            for gx in 0..<gw {
                let sx = gx * step
                let value = luma[sy * lumaStride + sx]
                grid[gy * gw + gx] = value
                histogram[Int(value)] += 1
                // Chroma is half resolution and interleaved as Cb, Cr.
                let cy = sy / 2
                let cx = (sx / 2) * 2
                let offset = cy * chromaStride + cx
                cbGrid[gy * gw + gx] = chroma[offset]
                crGrid[gy * gw + gx] = chroma[offset + 1]
            }
        }

        let cut = chooseCut(histogram: histogram, total: gw * gh)
        lastCut = cut

        var visited = [Bool](repeating: false, count: gw * gh)
        var blobs: [Blob] = []
        var stack: [Int] = []

        for start in 0..<(gw * gh) {
            if visited[start] || grid[start] < cut { continue }

            var minX = gw, maxX = 0, minY = gh, maxY = 0
            var count = 0
            var sumY = 0.0, sumCb = 0.0, sumCr = 0.0

            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true

            while let index = stack.popLast() {
                let px = index % gw
                let py = index / gw
                count += 1
                minX = min(minX, px); maxX = max(maxX, px)
                minY = min(minY, py); maxY = max(maxY, py)
                sumY += Double(grid[index])
                sumCb += Double(cbGrid[index])
                sumCr += Double(crGrid[index])

                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = px + dx, ny = py + dy
                        guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                        let n = ny * gw + nx
                        if visited[n] || grid[n] < cut { continue }
                        visited[n] = true
                        stack.append(n)
                    }
                }
            }

            guard count >= minPixels else { continue }

            let (hue, sat, val) = Self.hsv(y: sumY / Double(count),
                                           cb: sumCb / Double(count),
                                           cr: sumCr / Double(count))
            blobs.append(Blob(
                box: Box(x: Double(minX) / Double(gw),
                         y: Double(minY) / Double(gh),
                         w: Double(maxX - minX + 1) / Double(gw),
                         h: Double(maxY - minY + 1) / Double(gh)),
                hue: hue,
                saturation: sat,
                brightness: val,
                area: Double(count) / Double(gw * gh)
            ))
            if blobs.count >= maxBlobs { break }
        }

        return blobs.sorted { $0.area > $1.area }
    }

    /// Walk the histogram down from white until enough of the frame is above
    /// the line, then apply the two safety rails.
    private func chooseCut(histogram: [Int], total: Int) -> UInt8 {
        let wanted = max(minPixels, Int(Double(total) * targetLitFraction))

        var running = 0
        var cut = 255
        while cut > 0 {
            running += histogram[cut]
            if running >= wanted { break }
            cut -= 1
        }

        // Median of the frame — most of a night shot is background, so this is
        // "how bright is the dark part", and the glow has to clear it.
        var seen = 0
        var median = 0
        let half = total / 2
        for value in 0..<256 {
            seen += histogram[value]
            if seen >= half { median = value; break }
        }

        let floor = max(Int(absoluteFloor), median + Int(minimumContrast))
        return UInt8(clamp(Double(max(cut, floor)), 0, 255))
    }

    /// YCbCr -> RGB -> HSV. Hue is what lets a green disc be told from a blue
    /// bottle without any model at all.
    static func hsv(y: Double, cb: Double, cr: Double) -> (Double, Double, Double) {
        let r = clamp(y + 1.402 * (cr - 128), 0, 255) / 255
        let g = clamp(y - 0.344136 * (cb - 128) - 0.714136 * (cr - 128), 0, 255) / 255
        let b = clamp(y + 1.772 * (cb - 128), 0, 255) / 255

        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        var hue = 0.0
        if delta > 1e-6 {
            if maxV == r { hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if maxV == g { hue = 60 * ((b - r) / delta + 2) }
            else { hue = 60 * ((r - g) / delta + 4) }
        }
        if hue < 0 { hue += 360 }
        let saturation = maxV <= 1e-6 ? 0 : delta / maxV
        return (hue, saturation, maxV)
    }
}
