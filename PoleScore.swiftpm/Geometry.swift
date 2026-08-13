import Foundation

/// Everything is normalized 0...1 against the camera buffer, so calibration
/// survives a change of resolution or preview size.
struct Pt: Codable, Equatable {
    var x: Double
    var y: Double
}

struct Box: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var center: Pt { Pt(x: x + w / 2, y: y + h / 2) }

    func expanded(by factor: Double, pad: Double = 0) -> Box {
        let c = center
        let nw = w * factor + pad * 2
        let nh = h * factor + pad * 2
        return Box(x: c.x - nw / 2, y: c.y - nh / 2, w: nw, h: nh)
    }

    func contains(_ p: Pt) -> Bool {
        p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + h
    }

    var aspect: Double { h / max(w, 1e-6) }
}

func distance(_ a: Pt, _ b: Pt) -> Double {
    (pow(a.x - b.x, 2) + pow(a.y - b.y, 2)).squareRoot()
}

func iou(_ a: Box, _ b: Box) -> Double {
    let x1 = max(a.x, b.x)
    let y1 = max(a.y, b.y)
    let x2 = min(a.x + a.w, b.x + b.w)
    let y2 = min(a.y + a.h, b.y + b.h)
    let inter = max(0, x2 - x1) * max(0, y2 - y1)
    let union = a.w * a.h + b.w * b.h - inter
    return union <= 0 ? 0 : inter / union
}

/// y of the line through a and b at a given x.
func lineY(a: Pt, b: Pt, x: Double) -> Double {
    let dx = b.x - a.x
    if abs(dx) < 1e-6 { return (a.y + b.y) / 2 }
    return a.y + (x - a.x) / dx * (b.y - a.y)
}

func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    min(hi, max(lo, v))
}

/// Shortest distance around the colour wheel, in degrees.
func hueDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs((a - b).truncatingRemainder(dividingBy: 360))
    return d > 180 ? 360 - d : d
}
