import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ProcessingConfig {
    let inputRoot: URL
    let outputRoot: URL
    let blackPoint: Double
}

struct ProcessingSummary {
    let successCount: Int
    let failedCount: Int
}

enum ProcessingError: LocalizedError {
    case imageReadFailed(URL)
    case foregroundMaskUnavailable(URL)
    case renderFailed(URL)
    case writeFailed(URL)

    var errorDescription: String? {
        switch self {
        case let .imageReadFailed(url):
            return "无法读取图像: \(url.path)"
        case let .foregroundMaskUnavailable(url):
            return "无法生成前景掩码: \(url.path)"
        case let .renderFailed(url):
            return "无法渲染输出图像: \(url.path)"
        case let .writeFailed(url):
            return "无法写入 TIFF: \(url.path)"
        }
    }
}

actor ImageBatchProcessor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let fileManager = FileManager.default
    private let minBlackPoint = 0.0
    private let maxBlackPoint = 0.20

    func process(
        config: ProcessingConfig,
        onProgress: @escaping @Sendable (String) async -> Void
    ) async throws -> ProcessingSummary {
        let inputFiles = collectTIFFFiles(in: config.inputRoot)
        guard !inputFiles.isEmpty else {
            await onProgress("未发现 TIFF 文件。")
            return ProcessingSummary(successCount: 0, failedCount: 0)
        }

        try fileManager.createDirectory(at: config.outputRoot, withIntermediateDirectories: true)
        await onProgress("发现 \(inputFiles.count) 个 TIFF 文件，开始处理。")

        var successCount = 0
        var failedCount = 0

        for (index, inputURL) in inputFiles.enumerated() {
            let relativePath = inputURL.path.replacingOccurrences(
                of: config.inputRoot.path + "/",
                with: ""
            )
            let outputURL = config.outputRoot.appendingPathComponent(relativePath, isDirectory: false)

            do {
                try autoreleasepool {
                    try self.processSingleFile(
                        inputURL: inputURL,
                        outputURL: outputURL,
                        blackPoint: config.blackPoint
                    )
                }
                successCount += 1
                await onProgress("[\(index + 1)/\(inputFiles.count)] ✓ \(relativePath)")
            } catch {
                failedCount += 1
                await onProgress("[\(index + 1)/\(inputFiles.count)] ✗ \(relativePath) -> \(error.localizedDescription)")
            }
        }

        return ProcessingSummary(successCount: successCount, failedCount: failedCount)
    }

    private func processSingleFile(inputURL: URL, outputURL: URL, blackPoint: Double) throws {
        guard
            let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            throw ProcessingError.imageReadFailed(inputURL)
        }

        let sourceProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let extent = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)

        let sourceImage = CIImage(cgImage: cgImage).cropped(to: extent)
        let foregroundMask = try foregroundMaskImage(for: cgImage, sourceURL: inputURL)
        let scaleMask = try scaleMaskImage(for: cgImage)
        let combinedMask = mergeMasks(foregroundMask: foregroundMask, scaleMask: scaleMask, extent: extent)

        let adjustedImage = applyBlackRollOff(to: sourceImage, blackPoint: blackPoint)
        let outputImage = applyMask(cutoutImage: adjustedImage, mask: combinedMask, extent: extent)

        guard let rendered = context.createCGImage(outputImage, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw ProcessingError.renderFailed(inputURL)
        }

        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeTIFF(
            image: rendered,
            destinationURL: outputURL,
            sourceProperties: sourceProperties
        )
    }

    private func collectTIFFFiles(in root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard ext == "tif" || ext == "tiff" else { continue }
            files.append(url)
        }
        return files.sorted(by: { $0.path < $1.path })
    }

    private func foregroundMaskImage(for cgImage: CGImage, sourceURL: URL) throws -> CIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNInstanceMaskObservation else {
            throw ProcessingError.foregroundMaskUnavailable(sourceURL)
        }

        let scaledMaskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )

        let mask = CIImage(cvPixelBuffer: scaledMaskBuffer)
        return mask.applyingFilter(
            "CIColorClamp",
            parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ]
        )
    }

    private func scaleMaskImage(for cgImage: CGImage) throws -> CIImage {
        let textBoxes = try detectTextRegions(in: cgImage)
        let roiMask = roiMaskImage(
            imageWidth: cgImage.width,
            imageHeight: cgImage.height,
            textBoxes: textBoxes
        )
        let whiteMask = nearWhiteMask(from: CIImage(cgImage: cgImage))

        let multiplied = whiteMask.applyingFilter(
            "CIMultiplyCompositing",
            parameters: [kCIInputBackgroundImageKey: roiMask]
        )

        return multiplied
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 1.2])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6])
            .cropped(to: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    }

    private func detectTextRegions(in cgImage: CGImage) throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        request.recognitionLanguages = ["en-US", "zh-Hans"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        if observations.isEmpty {
            return []
        }

        let filtered = observations.filter { observation in
            guard let candidate = observation.topCandidates(1).first else { return true }
            return likelyScaleText(candidate.string)
        }

        if filtered.isEmpty {
            return observations.map(\.boundingBox)
        }
        return filtered.map(\.boundingBox)
    }

    private func likelyScaleText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.rangeOfCharacter(from: .decimalDigits) != nil {
            return true
        }
        let units = ["um", "µm", "nm", "mm", "cm", "μm"]
        return units.contains { lowered.contains($0) }
    }

    private func roiMaskImage(imageWidth: Int, imageHeight: Int, textBoxes: [CGRect]) -> CIImage {
        let gray = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = imageWidth
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)

        guard
            let bitmap = CGContext(
                data: nil,
                width: imageWidth,
                height: imageHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: gray,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            return CIImage(color: .black).cropped(to: bounds)
        }

        bitmap.setFillColor(gray: 0.0, alpha: 1.0)
        bitmap.fill(bounds)

        let fallbackBandHeight = max(Int(Double(imageHeight) * 0.22), 1)
        let bottomBand = CGRect(x: 0, y: 0, width: imageWidth, height: fallbackBandHeight)
        bitmap.setFillColor(gray: 1.0, alpha: 1.0)
        bitmap.fill(bottomBand)

        for normalized in textBoxes {
            let rect = denormalizeVisionRect(normalized, width: imageWidth, height: imageHeight)
            if rect.isNull || rect.isEmpty { continue }

            let expandX = max(rect.width * 1.0, 16)
            let expandY = max(rect.height * 2.5, 18)
            let expanded = rect
                .insetBy(dx: -expandX, dy: -expandY)
                .offsetBy(dx: 0, dy: -max(rect.height * 0.8, 10))
                .intersection(bounds)
            if !expanded.isNull, !expanded.isEmpty {
                bitmap.fill(expanded)
            }
        }

        guard let image = bitmap.makeImage() else {
            return CIImage(color: .black).cropped(to: bounds)
        }
        return CIImage(cgImage: image).cropped(to: bounds)
    }

    private func denormalizeVisionRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: rect.origin.x * Double(width),
            y: rect.origin.y * Double(height),
            width: rect.width * Double(width),
            height: rect.height * Double(height)
        ).integral
    }

    private func nearWhiteMask(from image: CIImage) -> CIImage {
        let threshold: CGFloat = 0.93
        let thresholdGain: CGFloat = 48.0
        let thresholdBias = -threshold * thresholdGain

        let grayscale = image.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.0,
                kCIInputBrightnessKey: 0.0
            ]
        )

        let thresholded = grayscale.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: thresholdGain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: thresholdGain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: thresholdGain, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: thresholdBias, y: thresholdBias, z: thresholdBias, w: 0)
            ]
        )

        return thresholded.applyingFilter(
            "CIColorClamp",
            parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ]
        )
    }

    private func mergeMasks(foregroundMask: CIImage, scaleMask: CIImage, extent: CGRect) -> CIImage {
        let merged = foregroundMask.applyingFilter(
            "CIMaximumCompositing",
            parameters: [kCIInputBackgroundImageKey: scaleMask]
        )

        return merged
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8])
            .cropped(to: extent)
    }

    private func applyBlackRollOff(to image: CIImage, blackPoint: Double) -> CIImage {
        let bp = CGFloat(max(minBlackPoint, min(maxBlackPoint, blackPoint)))
        let scale = 1.0 / max(1.0 - bp, 0.0001)
        let bias = -bp * scale

        let matrix = image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
            ]
        )

        return matrix.applyingFilter(
            "CIColorClamp",
            parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ]
        )
    }

    private func applyMask(cutoutImage: CIImage, mask: CIImage, extent: CGRect) -> CIImage {
        let transparentBackground = CIImage(color: .clear).cropped(to: extent)
        return cutoutImage.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputMaskImageKey: mask,
                kCIInputBackgroundImageKey: transparentBackground
            ]
        )
    }

    private func writeTIFF(
        image: CGImage,
        destinationURL: URL,
        sourceProperties: [CFString: Any]
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            throw ProcessingError.writeFailed(destinationURL)
        }

        var destinationProperties: [CFString: Any] = [:]
        if let tiff = sourceProperties[kCGImagePropertyTIFFDictionary] {
            destinationProperties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let dpiWidth = sourceProperties[kCGImagePropertyDPIWidth] {
            destinationProperties[kCGImagePropertyDPIWidth] = dpiWidth
        }
        if let dpiHeight = sourceProperties[kCGImagePropertyDPIHeight] {
            destinationProperties[kCGImagePropertyDPIHeight] = dpiHeight
        }
        destinationProperties[kCGImagePropertyHasAlpha] = true

        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            throw ProcessingError.writeFailed(destinationURL)
        }
    }
}
