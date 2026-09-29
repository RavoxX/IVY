import CoreGraphics
import Foundation

/// Display geometry needed to attach IVY to the notch, computed from `NSScreen` values
/// but kept free of AppKit so it can be tested for arbitrary displays.
public struct NotchGeometry: Equatable, Sendable {
    /// Screen frame in global (AppKit, bottom-left origin) coordinates.
    public var screenFrame: CGRect
    public var hasNotch: Bool
    /// Width of the camera housing (0 on displays without a notch).
    public var notchWidth: CGFloat
    /// Height of the notch / menu bar band at the top of the screen.
    public var topBandHeight: CGFloat
    /// Horizontal center of the notch in global coordinates.
    public var centerX: CGFloat

    public init(screenFrame: CGRect, hasNotch: Bool, notchWidth: CGFloat, topBandHeight: CGFloat, centerX: CGFloat) {
        self.screenFrame = screenFrame
        self.hasNotch = hasNotch
        self.notchWidth = notchWidth
        self.topBandHeight = topBandHeight
        self.centerX = centerX
    }

    /// Builds geometry from `NSScreen` properties.
    /// - Parameters:
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top` (non-zero only on notched displays).
    ///   - auxiliaryTopLeft / auxiliaryTopRight: `NSScreen.auxiliaryTopLeftArea/RightArea`,
    ///     the usable menu bar areas either side of the notch.
    ///   - visibleFrame: `NSScreen.visibleFrame`, used for the menu bar height on other displays.
    public static func make(screenFrame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                            auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?) -> NotchGeometry {
        if safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight {
            // The auxiliary areas are reported in screen coordinates. Normalize to a local
            // x-offset so the math is identical on secondary displays.
            let leftLocalMaxX = localX(left.maxX, screenFrame: screenFrame, rectMinX: left.minX)
            let rightLocalMinX = localX(right.minX, screenFrame: screenFrame, rectMinX: left.minX)
            let width = max(0, rightLocalMinX - leftLocalMaxX)
            if width > 0 {
                return NotchGeometry(screenFrame: screenFrame, hasNotch: true, notchWidth: width,
                                     topBandHeight: safeAreaTop,
                                     centerX: screenFrame.minX + leftLocalMaxX + width / 2)
            }
        }
        // No notch: attach to the top-center edge, below nothing, using the menu bar height.
        let menuBar = max(0, screenFrame.maxY - visibleFrame.maxY)
        return NotchGeometry(screenFrame: screenFrame, hasNotch: false, notchWidth: 0,
                             topBandHeight: menuBar > 0 ? min(menuBar, 40) : 24,
                             centerX: screenFrame.midX)
    }

    /// Converts an x value to screen-local space. `rectMinX` is the left auxiliary area's
    /// minX, which is 0 locally or equal to the screen's minX globally.
    static func localX(_ x: CGFloat, screenFrame: CGRect, rectMinX: CGFloat) -> CGFloat {
        let isGlobal = abs(rectMinX - screenFrame.minX) < 0.5 && screenFrame.minX != 0
        return isGlobal ? x - screenFrame.minX : x
    }

    /// Window frame for a panel of `size`, horizontally centered on the notch and flush
    /// with the top edge of the screen.
    public func panelFrame(size: CGSize) -> CGRect {
        CGRect(x: (centerX - size.width / 2).rounded(),
               y: screenFrame.maxY - size.height,
               width: size.width,
               height: size.height)
    }
}
