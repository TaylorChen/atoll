import XCTest
import AppKit
import SwiftUI
@testable import Atoll

/// Regression guard for the expanded-panel bottom corners. The expanded surface
/// carries rectangular content layers (SessionListView's Theme.bg) and
/// `.background(in: shape)` only clips the background, not the content — so
/// without an explicit `.clipShape` the content's right angles overpaint the
/// outline's bottom-left/right arcs. Renders the exact modifier chain with and
/// without the clip and compares corner pixels.
@MainActor
final class NotchShapeRenderTests: XCTestCase {
    /// Mirrors the expanded NotchView modifier chain; `clip` toggles the fix.
    private struct ExpandedProbe: View {
        let clip: Bool
        var body: some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: 20)
                // Rectangular content layer (SessionListView's Theme.bg).
                Theme.bg.frame(height: 200)
            }
            .frame(width: NotchPanel.panelWidth, alignment: .top)
            .padding(.horizontal, NotchGeometry.expandedWingWidth)
            .modifier(ClipIf(on: clip))
            .background(Theme.bg, in: NotchShape(
                topRadius: NotchGeometry.expandedWingWidth,
                bottomRadius: 14))
        }
    }

    private struct ClipIf: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on {
                content.clipShape(NotchShape(
                    topRadius: NotchGeometry.expandedWingWidth,
                    bottomRadius: 14))
            } else {
                content
            }
        }
    }

    private func render(_ clip: Bool) throws -> (cornerL: CGFloat, cornerR: CGFloat) {
        let renderer = ImageRenderer(content: ExpandedProbe(clip: clip))
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            throw NSError(domain: "offscreen-render", code: 1)
        }
        let W = rep.pixelsWide, H = rep.pixelsHigh
        func alpha(_ x: Int, _ y: Int) -> CGFloat {
            guard let c = rep.colorAt(x: x, y: y) else { return 0 }
            return c.alphaComponent
        }
        // Geometry: shape rect 628x220pt, bodyLeft=14, bottom radius 14pt.
        // Decisive pixels are just OUTSIDE the outline arc but INSIDE the
        // rectangular content layer (x >= 14pt): without the clip the content's
        // right angle overpaints them (opaque); with the clip they're removed.
        // Point (16, 218) -> px (32, 436).
        return (alpha(32, H - 4), alpha(W - 33, H - 4))
    }

    func testClipShapeKeepsExpandedBottomCornersRounded() throws {
        let fixed = try render(true)
        let broken = try render(false)
        print("WITH clipShape: cornerL=\(fixed.cornerL) cornerR=\(fixed.cornerR)")
        print("WITHOUT clip:   cornerL=\(broken.cornerL) cornerR=\(broken.cornerR)")

        // Without the clip the rectangular content overpaints the outline's
        // bottom corners — the reported "left/right bottom not rounded" bug.
        XCTAssertGreaterThan(broken.cornerL, 0.8, "pre-fix corner must be opaque (bug reproduced)")
        XCTAssertGreaterThan(broken.cornerR, 0.8, "pre-fix right corner must be opaque (bug reproduced)")

        // With the clip both corner tips are transparent, i.e. rounded.
        XCTAssertLessThan(fixed.cornerL, 0.3, "bottom-left corner tip must be transparent")
        XCTAssertLessThan(fixed.cornerR, 0.3, "bottom-right corner tip must be transparent")
    }
}
