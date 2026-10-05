import AppKit
import ApplicationServices

/// Accessibility uses global coordinates with a top-left origin; AppKit uses bottom-left.
@MainActor
enum WritingAccessibilityBounds {
    /// Resolve a hovered line without reading its text. Editors that don't expose
    /// line geometry use the pointer anchor inside their visible document canvas.
    static func line(element: AXUIElement, pointer: CGPoint) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        var point = CGPoint(x: pointer.x, y: primary.frame.maxY - pointer.y)
        var result: CFTypeRef?
        guard let position = AXValueCreate(.cgPoint, &point),
              AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString, position, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let wrapped = unsafeBitCast(result, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(wrapped) == .cfRange, AXValueGetValue(wrapped, .cfRange, &range), range.location >= 0 else { return nil }
        var line: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXLineForIndexParameterizedAttribute as CFString, NSNumber(value: range.location), &line) == .success,
              let line else { return nil }
        var lineRange: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForLineParameterizedAttribute as CFString, line, &lineRange) == .success,
              let lineRange, CFGetTypeID(lineRange) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(lineRange, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length > 0 else { return nil }
        return selection(element: element, range: range)
    }

    static func selection(element: AXUIElement, range: CFRange) -> CGRect? {
        var queryRange = range
        var result: CFTypeRef?
        var rect = CGRect.zero
        guard let value = AXValueCreate(.cfRange, &queryRange),
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let bounds = unsafeBitCast(result, to: AXValue.self)
        guard AXValueGetType(bounds) == .cgRect, AXValueGetValue(bounds, .cgRect, &rect) else { return nil }
        return appKitRect(rect)
    }

    static func field(element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let position = unsafeBitCast(positionValue, to: AXValue.self), size = unsafeBitCast(sizeValue, to: AXValue.self)
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize,
              AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return appKitRect(CGRect(origin: point, size: dimensions))
    }

    /// A page's text area can extend off-screen after scrolling. Clip to its
    /// scroll viewport and display before placing the keyboard fallback anchor.
    static func visibleField(element: AXUIElement) -> CGRect? {
        guard var bounds = field(element: element) else { return nil }
        var ancestor = element
        for _ in 0..<6 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ancestor, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            ancestor = unsafeBitCast(parent, to: AXUIElement.self)
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(ancestor, kAXRoleAttribute as CFString, &role) == .success,
               role as? String == kAXScrollAreaRole, let viewport = field(element: ancestor) {
                bounds = bounds.intersection(viewport)
                break
            }
        }
        guard !bounds.isNull, !bounds.isEmpty,
              let screen = NSScreen.screens.max(by: {
                  let left = $0.visibleFrame.intersection(bounds), right = $1.visibleFrame.intersection(bounds)
                  return left.width * left.height < right.width * right.height
              }) else { return nil }
        let visible = bounds.intersection(screen.visibleFrame)
        return visible.isNull || visible.isEmpty ? nil : visible
    }

    private static func appKitRect(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isEmpty, let primary = NSScreen.screens.first,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }) else { return nil }
        return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
