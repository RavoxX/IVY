import AppKit
import QuartzCore
import SwiftUI

/// The notch silhouette rendered with Core Animation.
///
/// Everything inside (blur, black tint, SwiftUI content — including AppKit-backed views
/// like scroll views and text fields) is clipped by a `CAShapeLayer` mask whose path
/// springs between the closed notch and the open panel. Driving the mask and the shadow
/// from the same `CASpringAnimation` keeps content perfectly inside the growing shape,
/// so the panel really grows out of the notch.
final class NotchContainerView: NSView {
    struct Spec: Equatable {
        var size: CGSize
        var topRadius: CGFloat
        var bottomRadius: CGFloat
        var band: CGFloat
        var isOpen: Bool
    }

    private let shadowLayer = CAShapeLayer()
    private let clipView = NSView()
    private let maskLayer = CAShapeLayer()
    private let backgroundView = NSView()
    private let backgroundFade = CAGradientLayer()
    private let effectView = NSVisualEffectView()
    private let tintView = SolidColorView(color: .black)
    private let bandView = SolidColorView(color: .black)
    private var current: Spec?

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        // A filled shadow silhouette would make the translucent body opaque again.
        shadowLayer.fillColor = NSColor.clear.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowRadius = 18
        shadowLayer.shadowOffset = CGSize(width: 0, height: -8)
        shadowLayer.shadowOpacity = 0
        layer?.addSublayer(shadowLayer)

        clipView.wantsLayer = true
        clipView.layer?.mask = maskLayer
        addSubview(clipView)

        backgroundView.wantsLayer = true
        backgroundFade.colors = [1.0, 1.0, 0.82, 0.45].map { NSColor.black.withAlphaComponent($0).cgColor }
        backgroundFade.locations = [0, 0.8, 0.9, 1]
        backgroundFade.startPoint = CGPoint(x: 0.5, y: 1)
        backgroundFade.endPoint = CGPoint(x: 0.5, y: 0)
        backgroundView.layer?.mask = backgroundFade
        clipView.addSubview(backgroundView)

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        backgroundView.addSubview(effectView)

        // Dark translucent body, fully opaque black band at the top (merges with the camera housing).
        // Subviews (not raw sublayers) so AppKit keeps the stacking order.
        backgroundView.addSubview(tintView)
        clipView.addSubview(bandView)

        clipView.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Files dropped on the notch

    /// The SwiftUI content registers no drag types, so drags fall through to this view.
    var dropTarget: NotchDropTarget? {
        didSet { registerForDraggedTypes(NotchDropTarget.types) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { dropTarget?.entered(sender, in: self) ?? [] }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { dropTarget?.updated(sender, in: self) ?? [] }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { dropTarget?.exited() }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropTarget != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { dropTarget?.perform(sender, in: self) ?? false }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipView.frame = bounds
        backgroundView.frame = clipView.bounds
        effectView.frame = backgroundView.bounds
        clipView.subviews.last?.frame = clipView.bounds
        tintView.frame = clipView.bounds
        if let current { layoutBand(current) }
        CATransaction.commit()
    }

    private func layoutBand(_ spec: Spec) {
        // AppKit layers are bottom-left based: the band sits at the top of the canvas.
        bandView.frame = CGRect(x: 0, y: bounds.height - spec.band, width: bounds.width, height: spec.band)
        backgroundFade.frame = CGRect(x: 0, y: bounds.height - spec.size.height, width: bounds.width, height: spec.size.height)
    }

    /// Path of the notch shape centered at the top of the canvas (AppKit coordinates).
    private func path(for spec: Spec) -> CGPath {
        let rect = CGRect(x: (bounds.width - spec.size.width) / 2, y: 0, width: spec.size.width, height: spec.size.height)
        let shape = NotchShape(topCornerRadius: spec.topRadius, bottomCornerRadius: spec.bottomRadius)
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        return shape.path(in: rect).cgPath.copy(using: &transform) ?? CGMutablePath()
    }

    func apply(_ spec: Spec, animated: Bool) {
        if spec == current && animated { return }
        let previous = current
        current = spec
        layoutBand(spec)
        let newPath = path(for: spec)

        guard animated, previous != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            maskLayer.path = newPath
            shadowLayer.path = newPath
            shadowLayer.shadowPath = newPath
            shadowLayer.shadowOpacity = spec.isOpen ? 0.45 : 0
            CATransaction.commit()
            return
        }

        // Response/damping tuned like SwiftUI's spring(response: 0.4, dampingFraction: 0.78)
        // for opening and a firmer, non-bouncy spring for closing.
        let response: CGFloat = spec.isOpen ? 0.42 : 0.32
        let dampingFraction: CGFloat = spec.isOpen ? 0.78 : 0.95
        let stiffness = pow(2 * .pi / response, 2)
        for (layer, key) in [(maskLayer, "path"), (shadowLayer, "shadowPath")] {
            let from = key == "path" ? (layer.presentation()?.path ?? layer.path) : (layer.presentation()?.shadowPath ?? layer.shadowPath)
            let animation = CASpringAnimation(keyPath: key)
            animation.mass = 1
            animation.stiffness = stiffness
            animation.damping = 2 * dampingFraction * sqrt(stiffness)
            animation.fromValue = from
            animation.toValue = newPath
            animation.duration = animation.settlingDuration
            if key == "path" { layer.path = newPath } else { layer.shadowPath = newPath }
            layer.add(animation, forKey: key)
        }
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = shadowLayer.presentation()?.shadowOpacity ?? shadowLayer.shadowOpacity
        shadowLayer.shadowOpacity = spec.isOpen ? 0.45 : 0
        fade.duration = 0.25
        shadowLayer.add(fade, forKey: "shadowOpacity")
    }
}

/// Plain layer-backed color fill.
final class SolidColorView: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
