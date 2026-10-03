import Foundation

/// Places a compact writing affordance beside a selection, within its display.
public enum WritingIndicatorPlacement {
    public static let size = CGSize(width: 24, height: 32)

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
