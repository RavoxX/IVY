import SwiftUI

/// The Face ID mark: four corner brackets around a simple face.
///
/// Mirrors Apple's animation language: while scanning the face turns gently left and right
/// in 3D; on success the brackets spin and close into a circle while the face gives way to
/// a checkmark that draws itself; on failure the face shakes "no" and its smile flattens.
struct FaceIDGlyph: View {
    enum Phase: Equatable { case idle, scanning, success, failure }

    var state: Phase
    var size: CGFloat = 56
    var color: Color = .white

    @State private var turn = false
    @State private var shake: CGFloat = 0

    private var lineWidth: CGFloat { max(1.5, size * 0.06) }
    private var isSuccess: Bool { state == .success }

    var body: some View {
        ZStack {
            BracketShape(morph: isSuccess ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .rotationEffect(.degrees(isSuccess ? 90 : 0))
                .opacity(state == .scanning ? (turn ? 1 : 0.55) : 1)

            FaceFeaturesShape(smile: state == .failure ? 0 : 1)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .rotation3DEffect(.degrees(state == .scanning ? (turn ? 22 : -22) : 0), axis: (x: 0, y: 1, z: 0),
                                  perspective: 0.6)
                .offset(x: shake)
                .scaleEffect(isSuccess ? 0.4 : 1)
                .opacity(isSuccess ? 0 : 1)

            CheckmarkShape()
                .trim(from: 0, to: isSuccess ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth * 1.15, lineCap: .round, lineJoin: .round))
                .animation(isSuccess ? .easeOut(duration: 0.32).delay(0.28) : .easeIn(duration: 0.1), value: isSuccess)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: state)
        .onAppear { update(for: state) }
        .onChange(of: state) { _, newState in update(for: newState) }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch state {
        case .idle: return "Face ID"
        case .scanning: return "Face ID, scanning"
        case .success: return "Face ID, recognized"
        case .failure: return "Face ID, not recognized"
        }
    }

    private func update(for state: Phase) {
        switch state {
        case .scanning:
            turn = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { turn = true }
        case .failure:
            withAnimation(.easeOut(duration: 0.1)) { turn = false }
            shakeNo()
        case .idle, .success:
            withAnimation(.easeOut(duration: 0.2)) { turn = false }
        }
    }

    /// A damped left-right shake, like the lock screen's failed-passcode wiggle.
    private func shakeNo() {
        let amplitude = size * 0.14
        let offsets: [CGFloat] = [amplitude, -amplitude, amplitude * 0.7, -amplitude * 0.7, amplitude * 0.35, 0]
        for (index, offset) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(index)) {
                withAnimation(.easeInOut(duration: 0.07)) { shake = offset }
            }
        }
    }
}

/// Four corner brackets. `morph` 0 → brackets, 1 → closed circle: corner radii grow to half
/// the size while the straight arms shrink to nothing, so the gaps close into a ring.
struct BracketShape: Shape {
    var morph: CGFloat

    var animatableData: CGFloat {
        get { morph }
        set { morph = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let radius = side * (0.18 + 0.32 * morph)
        let arm = side * 0.12 * (1 - morph)
        var path = Path()
        // (arc center, start angle) per corner, each drawn as arm → quarter arc → arm.
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: box.minX + radius, y: box.minY + radius), 180), // top left
            (CGPoint(x: box.maxX - radius, y: box.minY + radius), 270), // top right
            (CGPoint(x: box.maxX - radius, y: box.maxY - radius), 0),   // bottom right
            (CGPoint(x: box.minX + radius, y: box.maxY - radius), 90),  // bottom left
        ]
        for (center, start) in corners {
            let startRadians = start * .pi / 180
            let endRadians = (start + 90) * .pi / 180
            // Arm leading into the arc, tangent to it.
            let arcStart = CGPoint(x: center.x + radius * cos(startRadians), y: center.y + radius * sin(startRadians))
            let tangentIn = CGPoint(x: -sin(startRadians), y: cos(startRadians))
            path.move(to: CGPoint(x: arcStart.x - tangentIn.x * arm, y: arcStart.y - tangentIn.y * arm))
            path.addLine(to: arcStart)
            path.addArc(center: center, radius: radius, startAngle: .radians(startRadians),
                        endAngle: .radians(endRadians), clockwise: false)
            let arcEnd = CGPoint(x: center.x + radius * cos(endRadians), y: center.y + radius * sin(endRadians))
            let tangentOut = CGPoint(x: -sin(endRadians), y: cos(endRadians))
            path.addLine(to: CGPoint(x: arcEnd.x + tangentOut.x * arm, y: arcEnd.y + tangentOut.y * arm))
        }
        return path
    }
}

/// Eyes, nose and mouth. `smile` 1 → smiling, 0 → flat mouth.
struct FaceFeaturesShape: Shape {
    var smile: CGFloat

    var animatableData: CGFloat {
        get { smile }
        set { smile = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * side, y: origin.y + y * side) }
        var path = Path()
        // Eyes.
        path.move(to: p(0.34, 0.36)); path.addLine(to: p(0.34, 0.43))
        path.move(to: p(0.66, 0.36)); path.addLine(to: p(0.66, 0.43))
        // Nose with a small hook.
        path.move(to: p(0.50, 0.36)); path.addLine(to: p(0.50, 0.56)); path.addLine(to: p(0.455, 0.56))
        // Mouth.
        path.move(to: p(0.355, 0.67))
        path.addQuadCurve(to: p(0.645, 0.67), control: p(0.50, 0.67 + 0.1 * smile))
        return path
    }
}

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * side, y: origin.y + y * side) }
        var path = Path()
        path.move(to: p(0.31, 0.52))
        path.addLine(to: p(0.44, 0.65))
        path.addLine(to: p(0.69, 0.37))
        return path
    }
}

#Preview {
    HStack(spacing: 30) {
        FaceIDGlyph(state: .idle)
        FaceIDGlyph(state: .scanning)
        FaceIDGlyph(state: .success)
        FaceIDGlyph(state: .failure)
    }.padding(40).background(.black)
}
