import CoreGraphics
import Foundation
import ImageIO
import OnnxRuntimeBindings
import Vision

actor PalmVision {
    static let shared = PalmVision()
    private static let size = 512
    private var environment: ORTEnv?
    private var session: ORTSession?

    func read(_ data: Data, side: PalmSide) throws -> HandReading {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1800
              ] as CFDictionary) else { throw ScanError.image }
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let observations = request.results, observations.count == 1, let hand = observations.first else {
            throw ScanError.hand
        }
        let landmarks = try hand.recognizedPoints(.all)
        typealias Joint = VNHumanHandPoseObservation.JointName
        let joints: [Joint] = [
            .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP, .ringPIP, .ringDIP, .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip
        ]
        let width = Double(image.width)
        let height = Double(image.height)
        let pixels = try joints.map { joint -> PalmPoint in
            guard let p = landmarks[joint], p.confidence >= 0.45 else { throw ScanError.hand }
            return PalmPoint(x: Double(p.location.x) * width, y: (1 - Double(p.location.y)) * height)
        }
        let palmTop = [5, 9, 13, 17].map { pixels[$0].y }.reduce(0, +) / 4
        guard pixels[0].y - palmTop > height * 0.08,
              pixels[0].y - pixels[12].y > height * 0.23,
              abs(pixels[0].x - pixels[9].x) < (pixels[0].y - palmTop) * 0.65,
              abs(pixels[5].x - pixels[17].x) > width * 0.11 else { throw ScanError.pose }

        let rect = try cropRect(pixels, width: width, height: height)
        guard let crop = image.cropping(to: rect) else { throw ScanError.image }
        let tensor = try input(crop, mirrored: side == .right)
        try Task.checkCancellation()
        let logits = try run(tensor)
        let measured = try measurements(logits, side)
        guard measured.count >= 2 else { throw ScanError.lines }
        var evidence = measured.flatMap { item in rules(item, side) }
        let base = distance(pixels[3], pixels[2])
        let ratio = distance(pixels[4], pixels[3]) / max(base, 1)
        // Conservative 2D margins around the Android phalanx thresholds.
        if (landmarks[.thumbIP]?.confidence ?? 0) >= 0.8, base >= 14 {
            if ratio >= 1.30 {
                evidence += ["THUMB_P1_001", "THUMB_P2_003"].map { RuleEvidence(id: $0, side: side, confidence: 0.78) }
            } else if ratio <= 0.73 {
                evidence += ["THUMB_P1_011", "THUMB_P2_002"].map { RuleEvidence(id: $0, side: side, confidence: 0.78) }
            }
        }
        return HandReading(side: side, traces: measured.map(\.trace), evidence: evidence)
    }

    private func cropRect(_ points: [PalmPoint], width: Double, height: Double) throws -> CGRect {
        let joints = [5, 9, 13, 17].map { points[$0].y }
        let xs = [0, 1, 2, 5, 9, 13, 17].map { points[$0].x }
        guard let topJoint = joints.min(), let leftJoint = xs.min(), let rightJoint = xs.max() else {
            throw ScanError.pose
        }
        let palmHeight = max(abs(points[0].y - joints.reduce(0, +) / 4), height * 0.08)
        let palmWidth = max(distance(points[5], points[17]), width * 0.08)
        let left = leftJoint - palmWidth * 0.18
        let right = rightJoint + palmWidth * 0.18
        let top = topJoint - palmHeight * 0.20
        let bottom = points[0].y + palmHeight * 0.12
        let size = floor(min(max(right - left, bottom - top) * 1.04, min(width, height) * 0.98))
        guard size >= 64 else { throw ScanError.pose }
        let x = floor(max(0, min(width - size, (left + right - size) / 2)))
        let y = floor(max(0, min(height - size, (top + bottom - size) / 2)))
        return CGRect(x: x, y: y, width: size, height: size)
    }

    private func distance(_ a: PalmPoint, _ b: PalmPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private func input(_ crop: CGImage, mirrored: Bool) throws -> NSMutableData {
        let size = Self.size
        let plane = size * size
        var pixels = [UInt8](repeating: 0, count: plane * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { throw ScanError.image }
        let mean: [Float] = [0.485, 0.456, 0.406]
        let deviation: [Float] = [0.229, 0.224, 0.225]
        var values = [Float](repeating: 0, count: plane * 3)
        var luminance = 0.0
        for y in 0..<size {
            for x in 0..<size {
                let pixel = (y * size + (mirrored ? size - 1 - x : x)) * 4
                let index = y * size + x
                for channel in 0..<3 {
                    values[channel * plane + index] = (Float(pixels[pixel + channel]) / 255 - mean[channel]) / deviation[channel]
                }
                luminance += 0.2126 * Double(pixels[pixel]) + 0.7152 * Double(pixels[pixel + 1]) + 0.0722 * Double(pixels[pixel + 2])
            }
        }
        guard (42...240).contains(luminance / Double(plane)) else { throw ScanError.light }
        return values.withUnsafeBytes { NSMutableData(data: Data($0)) }
    }

    private func run(_ data: NSMutableData) throws -> [Float] {
        let engine: ORTSession
        if let session {
            engine = session
        } else {
            guard let model = Bundle.main.path(forResource: "palm_line_student_fp32", ofType: "onnx") else {
                throw ScanError.resource
            }
            let environment = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            let created = try ORTSession(env: environment, modelPath: model, sessionOptions: options)
            self.environment = environment
            self.session = created
            engine = created
        }
        let tensor = try ORTValue(tensorData: data, elementType: .float, shape: [1, 3, 512, 512])
        let output = try engine.run(withInputs: ["input": tensor], outputNames: ["logits"], runOptions: nil)
        guard let value = output["logits"] else { throw ScanError.resource }
        let raw = try value.tensorData()
        guard raw.length == 4 * Self.size * Self.size * MemoryLayout<Float>.size else { throw ScanError.resource }
        let floats = raw.bytes.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: floats, count: raw.length / MemoryLayout<Float>.size))
    }

    private struct Measurement {
        let trace: PalmTrace
        let span: Double
        let confidence: Double
        let continuity: Double
        let slope: Double
    }

    private struct Sample {
        let sweep: Int
        let across: Int
        let probability: Float
    }

    private func measurements(_ logits: [Float], _ side: PalmSide) throws -> [Measurement] {
        let size = Self.size
        let plane = size * size
        var masks = [[Float]](repeating: [Float](repeating: 0, count: plane), count: 3)
        for i in 0..<plane {
            if i % (size * 32) == 0 { try Task.checkCancellation() }
            let strongest = max(logits[i], logits[plane + i], logits[2 * plane + i], logits[3 * plane + i])
            guard strongest.isFinite, logits[i] < strongest else { continue }
            for line in 1...3 where logits[line * plane + i] == strongest {
                let divisor = (0...3).reduce(Float.zero) { $0 + exp(logits[$1 * plane + i] - strongest) }
                if divisor.isFinite { masks[line - 1][i] = 1 / divisor }
            }
        }
        return zip(PalmLineKind.allCases, masks).compactMap { trace($0.0, mask: $0.1, side: side) }
    }

    private func trace(_ kind: PalmLineKind, mask: [Float], side: PalmSide) -> Measurement? {
        let size = Self.size
        let vertical = kind == .life
        var best: [Sample] = []
        var current: [Sample] = []
        for sweep in stride(from: 12, to: size - 12, by: 4) {
            if let last = current.last, sweep - last.sweep > 20 { current.removeAll(keepingCapacity: true) }
            let candidateRange: Range<Int>
            switch kind {
            case .heart: candidateRange = 28..<315
            case .head: candidateRange = 88..<470
            case .life: candidateRange = 20..<445
            }
            let last = current.last
            let allowed = last.map { max(candidateRange.lowerBound, $0.across - 30)..<min(candidateRange.upperBound, $0.across + 31) } ?? candidateRange
            var peak: Sample?
            for across in allowed {
                let i = vertical ? sweep * size + across : across * size + sweep
                let probability = mask[i]
                if probability >= 0.58 && probability > (peak?.probability ?? 0) {
                    peak = Sample(sweep: sweep, across: across, probability: probability)
                }
            }
            guard let peak else { continue }
            current.append(peak)
            if current.count > best.count { best = current }
        }
        guard let first = best.first, let last = best.last, best.count >= 17 else { return nil }
        let span = Double(last.sweep - first.sweep) / Double(size)
        let continuity = Double(best.count) / Double((last.sweep - first.sweep) / 4 + 1)
        let mean = Double(best.map(\.probability).reduce(0, +)) / Double(best.count)
        guard span >= 0.23, continuity >= 0.70, mean >= 0.70 else { return nil }
        let path = best.enumerated().map { index, sample in
            let from = max(0, index - 2)
            let to = min(best.count - 1, index + 2)
            let across = Double(best[from...to].map(\.across).reduce(0, +)) / Double(to - from + 1)
            let x = (vertical ? across : Double(sample.sweep)) / Double(size)
            let y = (vertical ? Double(sample.sweep) : across) / Double(size)
            return PalmPoint(x: side == .right ? 1 - x : x, y: y)
        }
        let slope = Double(last.across - first.across) / Double(max(1, last.sweep - first.sweep))
        return Measurement(trace: PalmTrace(kind: kind, points: path), span: span, confidence: mean,
                           continuity: continuity, slope: slope)
    }

    private func rules(_ item: Measurement, _ side: PalmSide) -> [RuleEvidence] {
        guard item.confidence >= 0.76, item.continuity >= 0.82 else { return [] }
        var identifiers: [String] = []
        switch item.trace.kind {
        case .heart:
            if item.span >= 0.56 { identifiers.append("HEART_002") }
            if item.span >= 0.42 { identifiers.append("HEART_001") }
        case .head:
            if item.span >= 0.72 { identifiers.append("HEAD_003") }
            else if item.span >= 0.56 { identifiers.append("HEAD_002") }
            else if (0.28...0.36).contains(item.span) { identifiers.append("HEAD_004") }
            if (0.48..<0.72).contains(item.span), abs(item.slope) <= 0.34 { identifiers.append("HEAD_001") }
            if item.span >= 0.38 {
                if abs(item.slope) <= 0.05 { identifiers.append("HEAD_012") }
                else if (0.085..<0.22).contains(item.slope) { identifiers.append("HEAD_013") }
            }
        case .life:
            if item.span >= 0.60 { identifiers.append("LIFE_002") }
            if item.span >= 0.42 { identifiers.append("LIFE_001") }
        }
        return identifiers.map { RuleEvidence(id: $0, side: side, confidence: item.confidence) }
    }
}
