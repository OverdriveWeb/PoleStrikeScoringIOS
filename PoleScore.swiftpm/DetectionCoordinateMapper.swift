import CoreGraphics
import Foundation

/// Turns Vision boxes into rectangles you can actually draw on the preview.
///
/// Three separate transforms have to happen and every one of them is easy to
/// get almost right:
///
///   1. **Origin flip.** Vision measures y from the bottom, every view on iOS
///      measures it from the top.
///   2. **Aspect-fill crop.** The preview layer uses `.resizeAspectFill`, which
///      scales the video up until it covers the view and throws away the
///      overflow. A 16:9 buffer in a portrait-ish view loses a large slice off
///      the top and bottom. Multiplying normalized coordinates by the view size
///      — which is what the old debug overlay did — silently squashes every box
///      by exactly the amount that was cropped, and the error is largest at the
///      edges of the frame, which is where the poles are.
///   3. **Nothing else.** Rotation is already handled upstream: the capture
///      connection rotates the buffer, so what Vision sees and what the preview
///      shows are the same picture in the same orientation.
///
/// All of it is pure geometry with no UIKit or AVFoundation dependency, so it
/// can be checked directly — see `DetectionSelfTests`.
enum DetectionCoordinateMapper {

    /// Matches `AVLayerVideoGravity`. Named separately so this file stays
    /// dependency-free and testable.
    enum Gravity {
        /// `.resizeAspectFill` — fills the view, crops the overflow.
        case aspectFill
        /// `.resizeAspect` — fits inside the view, letterboxes the remainder.
        case aspectFit
        /// `.resize` — stretches to fit, distorting the picture.
        case stretch
    }

    /// The rectangle the video actually occupies, in view coordinates. Under
    /// aspect-fill this is *larger* than the view and starts at a negative
    /// origin, which is the whole point: the parts outside the view are the
    /// parts that were cropped away.
    static func displayedVideoRect(videoSize: CGSize,
                                   viewSize: CGSize,
                                   gravity: Gravity) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }

        switch gravity {
        case .stretch:
            return CGRect(origin: .zero, size: viewSize)
        case .aspectFill, .aspectFit:
            let scaleX = viewSize.width / videoSize.width
            let scaleY = viewSize.height / videoSize.height
            let scale = gravity == .aspectFill ? max(scaleX, scaleY) : min(scaleX, scaleY)
            let width = videoSize.width * scale
            let height = videoSize.height * scale
            return CGRect(x: (viewSize.width - width) / 2,
                          y: (viewSize.height - height) / 2,
                          width: width,
                          height: height)
        }
    }

    /// Vision box (normalized, bottom-left origin) to a view rect (points,
    /// top-left origin), correct under crop.
    static func viewRect(forVisionBox box: CGRect,
                         videoSize: CGSize,
                         viewSize: CGSize,
                         gravity: Gravity) -> CGRect {
        let video = displayedVideoRect(videoSize: videoSize, viewSize: viewSize, gravity: gravity)
        guard video.width > 0, video.height > 0 else { return .zero }

        // The flip has to use the box's own height: the top edge in view space
        // comes from the box's *maximum* y in Vision space.
        let flippedY = 1 - box.origin.y - box.height

        return CGRect(x: video.origin.x + box.origin.x * video.width,
                      y: video.origin.y + flippedY * video.height,
                      width: box.width * video.width,
                      height: box.height * video.height)
    }

    /// The app's own boxes are already top-left normalized, so they skip the
    /// flip but still need the crop correction.
    static func viewRect(forTopLeftNormalized box: CGRect,
                         videoSize: CGSize,
                         viewSize: CGSize,
                         gravity: Gravity) -> CGRect {
        let video = displayedVideoRect(videoSize: videoSize, viewSize: viewSize, gravity: gravity)
        guard video.width > 0, video.height > 0 else { return .zero }
        return CGRect(x: video.origin.x + box.origin.x * video.width,
                      y: video.origin.y + box.origin.y * video.height,
                      width: box.width * video.width,
                      height: box.height * video.height)
    }

    /// A single normalized top-left point to view coordinates — used for the
    /// ground line, which is two points rather than a box.
    static func viewPoint(forTopLeftNormalized point: CGPoint,
                          videoSize: CGSize,
                          viewSize: CGSize,
                          gravity: Gravity) -> CGPoint {
        let video = displayedVideoRect(videoSize: videoSize, viewSize: viewSize, gravity: gravity)
        return CGPoint(x: video.origin.x + point.x * video.width,
                       y: video.origin.y + point.y * video.height)
    }

    /// Vision's bottom-left box to the app's top-left normalized `Box`. No view
    /// involved — this is the conversion the scoring pipeline needs, and it is
    /// resolution-independent on purpose.
    static func topLeftNormalized(fromVisionBox box: CGRect) -> Box {
        Box(x: Double(box.origin.x),
            y: Double(1 - box.origin.y - box.height),
            w: Double(box.width),
            h: Double(box.height))
    }
}
