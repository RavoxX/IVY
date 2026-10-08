import CoreGraphics
import Foundation
import Testing
@testable import IVYCore

@Suite("Face ID matching")
struct FaceMatchingTests {
    let model = "arcface-test"

    func unit(_ values: [Float]) -> [Float] { FaceVector.normalized(values) }

    @Test func cosineSimilarityBasics() {
        #expect(abs(FaceVector.cosineSimilarity([1, 0], [1, 0]) - 1) < 1e-6)
        #expect(abs(FaceVector.cosineSimilarity([1, 0], [0, 1])) < 1e-6)
        #expect(FaceVector.cosineSimilarity([1, 0], [1, 0, 0]) == 0)
        #expect(FaceVector.cosineSimilarity([], []) == 0)
    }

    @Test func averageIgnoresMagnitude() throws {
        let average = try #require(FaceVector.average([[10, 0], [0, 1]]))
        #expect(abs(average[0] - average[1]) < 1e-6)
        #expect(abs(average.reduce(0) { $0 + $1 * $1 } - 1) < 1e-5)
    }

    @Test func matchesOwnerAndRejectsStranger() {
        let owner = FaceTemplate(name: "Me", samples: [unit([1, 0.1, 0]), unit([1, -0.1, 0]), unit([1, 0, 0.1])],
                                 modelIdentifier: model)
        let threshold = FaceMatchStrictness.standard.threshold
        let match = FaceMatcher.bestMatch(for: unit([1, 0.05, 0.02]), in: [owner], modelIdentifier: model, threshold: threshold)
        #expect(match?.templateID == owner.id)
        #expect(FaceMatcher.bestMatch(for: unit([0, 1, 0.2]), in: [owner], modelIdentifier: model, threshold: threshold) == nil)
    }

    @Test func skipsDisabledAndOtherModels() {
        var disabled = FaceTemplate(name: "Me", samples: [unit([1, 0])], modelIdentifier: model)
        disabled.isEnabled = false
        let otherModel = FaceTemplate(name: "Old", samples: [unit([1, 0])], modelIdentifier: "vision-print")
        #expect(FaceMatcher.bestMatch(for: unit([1, 0]), in: [disabled, otherModel], modelIdentifier: model, threshold: 0.5) == nil)
    }

    @Test func strictnessIsOrdered() {
        #expect(FaceMatchStrictness.relaxed.threshold < FaceMatchStrictness.standard.threshold)
        #expect(FaceMatchStrictness.standard.threshold < FaceMatchStrictness.strict.threshold)
    }

    @Test func templatesRoundTrip() throws {
        let template = FaceTemplate(name: "Me", samples: [[0.5, 0.5]], modelIdentifier: model)
        let decoded = try JSONDecoder().decode([FaceTemplate].self, from: JSONEncoder().encode([template]))
        #expect(decoded == [template])
    }
}

@Suite("Face ID enrollment")
struct FaceEnrollmentTests {
    @Test func needsCenterBeforeTurning() {
        var progress = FaceEnrollmentProgress()
        #expect(progress.observe(yaw: 20, pitch: 0, quality: 0.9) == nil)
        #expect(progress.litTicks.isEmpty)
        for _ in 0..<FaceEnrollmentProgress.centerSamplesNeeded {
            #expect(progress.observe(yaw: 1, pitch: -2, quality: 0.9) == .center)
        }
        #expect(progress.phase == .turning)
    }

    @Test func circleCompletesEnrollment() {
        var progress = FaceEnrollmentProgress()
        for _ in 0..<3 { progress.observe(yaw: 0, pitch: 0, quality: 0.8) }
        var captures = 0
        for step in 0..<72 {
            let angle = Double(step) / 72 * 2 * .pi
            if progress.observe(yaw: cos(angle) * 15, pitch: sin(angle) * 15, quality: 0.8) != nil { captures += 1 }
        }
        #expect(captures == FaceEnrollmentProgress.directionCount)
        #expect(progress.isComplete)
        #expect(progress.fraction == 1)
        #expect(progress.litTicks.count == FaceEnrollmentProgress.tickCount)
    }

    @Test func smallMovementsAndPoorQualityDoNotCapture() {
        var progress = FaceEnrollmentProgress()
        for _ in 0..<3 { progress.observe(yaw: 0, pitch: 0, quality: 0.8) }
        #expect(progress.observe(yaw: 5, pitch: 3, quality: 0.9) == nil)
        #expect(progress.observe(yaw: 20, pitch: 0, quality: 0.1) == nil)
        #expect(!progress.litTicks.isEmpty) // The ring still follows the head.
        #expect(progress.observe(yaw: 20, pitch: 0, quality: 0.9) == .direction(0))
        #expect(progress.observe(yaw: 0, pitch: 20, quality: 0.9) == .direction(2))
        #expect(progress.observe(yaw: -20, pitch: 0, quality: 0.9) == .direction(4))
    }
}

@Suite("Face ID liveness")
struct FaceLivenessTests {
    func samples(_ openness: [Double]) -> [LivenessSample] {
        openness.enumerated().map { LivenessSample(time: Double($0.offset) * 0.05, eyeOpenness: $0.element, yaw: 0, noseOffset: 0) }
    }

    @Test func detectsBlink() {
        var evaluator = LivenessEvaluator()
        var cue: LivenessCue?
        for sample in samples([0.3, 0.31, 0.3, 0.12, 0.29, 0.3, 0.31]) { cue = evaluator.observe(sample) }
        #expect(cue == .blink)
        #expect(evaluator.isConfirmed)
    }

    @Test func staticFaceStaysPending() {
        var evaluator = LivenessEvaluator()
        for sample in samples(Array(repeating: 0.3, count: 40)) { evaluator.observe(sample) }
        #expect(!evaluator.isConfirmed)
    }

    @Test func eyesClosedAtEndIsNotABlink() {
        #expect(!LivenessEvaluator.detectsBlink(samples([0.3, 0.3, 0.3, 0.3, 0.1])))
    }

    @Test func headTurnWithParallaxConfirms() {
        var evaluator = LivenessEvaluator()
        for i in 0..<12 {
            let yaw = (Double(i) - 6) * 2.5 * .pi / 180
            evaluator.observe(LivenessSample(time: Double(i) * 0.1, eyeOpenness: 0.3, yaw: yaw, noseOffset: tan(yaw) * 0.6))
        }
        #expect(evaluator.confirmedCue == .headTurn)
    }

    @Test func flatPhotoTurnDoesNotConfirm() {
        var evaluator = LivenessEvaluator()
        for i in 0..<12 {
            let yaw = (Double(i) - 6) * 2.5 * .pi / 180
            // A tilted photo: estimated yaw changes but nose parallax doesn't.
            evaluator.observe(LivenessSample(time: Double(i) * 0.1, eyeOpenness: 0.3, yaw: yaw,
                                             noseOffset: 0.02 + (i.isMultiple(of: 2) ? 0.003 : -0.003)))
        }
        #expect(!evaluator.isConfirmed)
    }
}

@Suite("Face ID scan judge")
struct FaceScanJudgeTests {
    @Test func unlocksOnlyWhenMatchedAndLive() {
        var judge = FaceScanJudge(startedAt: 0, duration: 6)
        #expect(judge.observe(.face(matched: true, live: false), at: 0.2) == .scanning(nil))
        #expect(judge.observe(.face(matched: true, live: false), at: 1.6) == .scanning(.blink))
        #expect(judge.observe(.face(matched: true, live: true), at: 1.8) == .recognized)
        #expect(judge.observe(.noFace, at: 2) == .recognized) // Finished verdicts stick.
    }

    @Test func wrongFaceFailsAfterGrace() {
        var judge = FaceScanJudge(startedAt: 0, duration: 6)
        #expect(judge.observe(.face(matched: false, live: true), at: 0.5) == .scanning(nil))
        #expect(judge.observe(.face(matched: false, live: true), at: 1.5) == .scanning(nil))
        #expect(judge.observe(.face(matched: false, live: true), at: 2.6) == .notRecognized)
    }

    @Test func matchResetsWrongFaceTimer() {
        var judge = FaceScanJudge(startedAt: 0, duration: 10)
        judge.observe(.face(matched: false, live: false), at: 0.5)
        judge.observe(.face(matched: true, live: false), at: 2.0)
        #expect(judge.observe(.face(matched: false, live: false), at: 2.6) == .scanning(nil))
        #expect(judge.observe(.face(matched: false, live: false), at: 4.7) == .notRecognized)
    }

    @Test func noFaceTimesOutWithHint() {
        var judge = FaceScanJudge(startedAt: 0, duration: 3)
        #expect(judge.tick(at: 1.5) == .scanning(.lookAtScreen))
        #expect(judge.observe(.noFace, at: 2.5) == .scanning(.lookAtScreen))
        #expect(judge.tick(at: 3.1) == .timedOut)
    }
}

@Suite("Face ID alignment")
struct FaceAlignmentTests {
    @Test func recoversKnownSimilarityTransform() throws {
        let expected = CGAffineTransform(translationX: 12, y: -7).rotated(by: 0.3).scaledBy(x: 1.7, y: 1.7)
        let source = FaceAlignment.referencePoints
        let destination = source.map { $0.applying(expected) }
        let solved = try #require(FaceAlignment.similarityTransform(from: source, to: destination))
        for point in source {
            let a = point.applying(solved), b = point.applying(expected)
            #expect(abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6)
        }
    }

    @Test func rejectsDegenerateInput() {
        #expect(FaceAlignment.similarityTransform(from: [.zero], to: [.zero]) == nil)
        #expect(FaceAlignment.similarityTransform(from: [.zero, .zero], to: [.zero, CGPoint(x: 1, y: 1)]) == nil)
    }
}
