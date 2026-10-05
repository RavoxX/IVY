import Foundation

/// Places a compact writing affordance beside a selection, within its display.
public enum WritingIndicatorPlacement {
    public static let size = CGSize(width: 14, height: 24)

    /// Some document editors expose the canvas bounds but no selection rectangle.
    /// Anchor near the pointer inside that canvas, or its upper-left for keyboard
    /// selection. The caller holds this anchor stable until the selection changes.
    public static func fallbackAnchor(field: CGRect, pointer: CGPoint) -> CGRect? {
        guard !field.isNull, !field.isEmpty,
              [field.minX, field.minY, field.width, field.height, pointer.x, pointer.y].allSatisfy({ $0.isFinite }) else { return nil }
        let point = field.contains(pointer) ? pointer : CGPoint(x: field.minX + min(24, field.width / 2), y: field.maxY - min(24, field.height / 2))
        return CGRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    public static func frame(selection: CGRect, visibleScreen: CGRect) -> CGRect? {
        guard !selection.isNull, !selection.isEmpty, !visibleScreen.isEmpty,
              [selection.minX, selection.minY, selection.width, selection.height,
               visibleScreen.minX, visibleScreen.minY, visibleScreen.width, visibleScreen.height].allSatisfy({ $0.isFinite }),
              visibleScreen.width >= size.width + 8, visibleScreen.height >= size.height + 8 else { return nil }
        let inset = visibleScreen.insetBy(dx: 4, dy: 4)
        let left = selection.minX - size.width - 6
        let x = left >= inset.minX ? left : selection.maxX + 6
        return CGRect(x: min(max(x, inset.minX), inset.maxX - size.width),
                      y: min(max(selection.maxY - size.height, inset.minY), inset.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
