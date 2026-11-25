import CoreGraphics
import Foundation

/// Maps normalized image coordinates (top-left origin, 0…1, relative to the processed upright camera buffer) onto a
/// view that shows that buffer with `.resizeAspectFill`, centred — the geometry of `CameraPreviewView`.
///
/// `scale = max(viewW / imgW, viewH / imgH)`; the scaled image is centred and the overflowing sides are cropped,
/// so offsets can be negative. Every camera overlay (boxes, hit areas, distance line, lane corridor, detail card)
/// uses this one helper so they all line up with the picture.
struct AspectFillMapping: Equatable {
    let displayedWidth: CGFloat
    let displayedHeight: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat

    init(imageSize: CGSize, viewSize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            displayedWidth = viewSize.width
            displayedHeight = viewSize.height
            offsetX = 0
            offsetY = 0
            return
        }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        displayedWidth = imageSize.width * scale
        displayedHeight = imageSize.height * scale
        offsetX = (viewSize.width - displayedWidth) / 2
        offsetY = (viewSize.height - displayedHeight) / 2
    }

    /// View rect of a normalized box.
    func rect(for box: BBox) -> CGRect {
        CGRect(x: offsetX + CGFloat(box.x) * displayedWidth,
               y: offsetY + CGFloat(box.y) * displayedHeight,
               width: CGFloat(box.width) * displayedWidth,
               height: CGFloat(box.height) * displayedHeight)
    }

    /// View point of a normalized image point.
    func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: offsetX + CGFloat(x) * displayedWidth, y: offsetY + CGFloat(y) * displayedHeight)
    }

    /// Normalized image point of a view point (inverse of `point(x:y:)`).
    func normalizedPoint(_ point: CGPoint) -> (x: Double, y: Double) {
        guard displayedWidth > 0, displayedHeight > 0 else { return (0, 0) }
        return (Double((point.x - offsetX) / displayedWidth), Double((point.y - offsetY) / displayedHeight))
    }
}
