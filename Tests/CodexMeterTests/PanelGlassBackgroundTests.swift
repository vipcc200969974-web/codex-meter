import AppKit
import SwiftUI
import XCTest
@testable import CodexMeter

@MainActor
final class PanelGlassBackgroundTests: XCTestCase {
    func testMainPanelRendersTransparentOutsideGlassSurface() throws {
        let image = try render(role: .mainPanel)

        XCTAssertLessThan(outerBrightnessRange(in: image), 0.001)
    }

    func testActionsPopoverRetainsRenderedOuterShadow() throws {
        let image = try render(role: .actionsPopover)

        XCTAssertGreaterThan(outerBrightnessRange(in: image), 0.001)
    }

    private func render(role: PanelGlassSurfaceRole) throws -> CGImage {
        let renderer = ImageRenderer(
            content: ZStack {
                Color.white

                role.applyingOuterShadow(
                    to: RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 100, height: 100)
                )
            }
            .frame(width: 160, height: 160)
        )
        renderer.proposedSize = ProposedViewSize(width: 160, height: 160)
        renderer.scale = 1

        return try XCTUnwrap(renderer.cgImage)
    }

    private func outerBrightnessRange(in image: CGImage) -> CGFloat {
        let bitmap = NSBitmapImageRep(cgImage: image)

        var minimum: CGFloat = 1
        var maximum: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide
            where x < 20 || x >= bitmap.pixelsWide - 20 || y < 20 || y >= bitmap.pixelsHigh - 20 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    return 1
                }
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                minimum = min(minimum, brightness)
                maximum = max(maximum, brightness)
            }
        }
        return maximum - minimum
    }
}
