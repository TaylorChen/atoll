import SwiftUI

/// A menu-bar notch outline. `topRadius` is the width of each top wing: the
/// black top edge spans the whole window, then curves inward to the content
/// body. The continuous negative-space corners avoid outward-pointing
/// triangular wings.
///
/// Callers add `topRadius` horizontal padding outside their content before
/// applying this shape, so the wings never steal usable content width.
struct NotchShape: Shape {
    var topRadius: CGFloat = NotchGeometry.collapsedWingWidth
    var bottomRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let tr = min(topRadius, w / 2, h)
        let br = min(bottomRadius, (w - 2 * tr) / 2, h - tr)
        let bodyLeft = tr
        let bodyRight = w - tr
        let k: CGFloat = 0.552_284_75
        var p = Path()

        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addCurve(
            to: CGPoint(x: bodyRight, y: tr),
            control1: CGPoint(x: w - k * tr, y: 0),
            control2: CGPoint(x: bodyRight, y: tr - k * tr))
        p.addLine(to: CGPoint(x: bodyRight, y: h - br))
        p.addQuadCurve(
            to: CGPoint(x: bodyRight - br, y: h),
            control: CGPoint(x: bodyRight, y: h))
        p.addLine(to: CGPoint(x: bodyLeft + br, y: h))
        p.addQuadCurve(
            to: CGPoint(x: bodyLeft, y: h - br),
            control: CGPoint(x: bodyLeft, y: h))
        p.addLine(to: CGPoint(x: bodyLeft, y: tr))
        p.addCurve(
            to: CGPoint(x: 0, y: 0),
            control1: CGPoint(x: bodyLeft, y: tr - k * tr),
            control2: CGPoint(x: k * tr, y: 0))
        p.closeSubpath()
        return p
    }
}
