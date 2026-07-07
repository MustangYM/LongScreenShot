import AppKit
import CoreImage
import ImageIO
import Vision
import UniformTypeIdentifiers
import Accelerate

enum ImageEffects {
    private static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])
    private static let softwareCIContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: true
    ])

    static func mosaicPatch(
        from image: CGImage,
        pixelRectTopLeft rect: CGRect,
        style: MosaicStyle,
        intensity: CGFloat
    ) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let target = rect.integral.intersection(imageBounds)
        guard target.width > 2, target.height > 2,
              let crop = image.cropping(to: target) else { return nil }
        switch style {
        case .pixel:
            return pixelated(crop, blockSize: max(4, Int(intensity)))
        case .blur:
            return gaussianBlurred(crop, radius: max(2, min(40, Int(intensity))))
        }
    }

    static func quickMosaicPreviewPatch(
        from image: CGImage,
        pixelRectTopLeft rect: CGRect,
        style: MosaicStyle,
        intensity: CGFloat,
        maximumDimension: Int = 260
    ) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let target = rect.integral.intersection(imageBounds)
        guard target.width > 2, target.height > 2,
              let crop = image.cropping(to: target) else { return nil }
        return downsampledObscuredPreview(
            crop,
            style: style,
            intensity: intensity,
            maximumDimension: maximumDimension
        )
    }

    private static func pixelated(_ image: CGImage, blockSize: Int) -> CGImage? {
        let block = min(max(2, blockSize), max(2, min(image.width, image.height)))
        let smallWidth = max(1, image.width / block)
        let smallHeight = max(1, image.height / block)
        guard let small = CGContext(
            data: nil,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let output = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        small.interpolationQuality = .low
        small.draw(image, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let reduced = small.makeImage() else { return nil }
        output.interpolationQuality = .none
        output.draw(reduced, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return output.makeImage()
    }

    private static func downsampledObscuredPreview(
        _ image: CGImage,
        style: MosaicStyle,
        intensity: CGFloat,
        maximumDimension: Int
    ) -> CGImage? {
        let longest = max(image.width, image.height)
        let scale = min(1, CGFloat(max(48, maximumDimension)) / CGFloat(max(1, longest)))
        let previewWidth = max(1, Int(CGFloat(image.width) * scale))
        let previewHeight = max(1, Int(CGFloat(image.height) * scale))
        let block = max(2, Int(style == .pixel ? intensity : intensity * 1.35))
        let sampleWidth = max(1, previewWidth / block)
        let sampleHeight = max(1, previewHeight / block)
        guard let sample = CGContext(
            data: nil,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let output = CGContext(
            data: nil,
            width: previewWidth,
            height: previewHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        sample.interpolationQuality = style == .pixel ? .low : .medium
        sample.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        guard let reduced = sample.makeImage() else { return nil }
        output.interpolationQuality = style == .pixel ? .none : .high
        output.draw(reduced, in: CGRect(x: 0, y: 0, width: previewWidth, height: previewHeight))
        return output.makeImage()
    }

    private static func gaussianBlurred(_ image: CGImage, radius: Int) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let input = CIImage(cgImage: image).clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: radius), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        return ciContext.createCGImage(output, from: extent)
            ?? softwareCIContext.createCGImage(output, from: extent)
            ?? acceleratedBoxBlur(image, radius: radius)
    }

    private static func acceleratedBoxBlur(_ image: CGImage, radius: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var source = [UInt8](repeating: 0, count: bytesPerRow * height)
        var output = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let sourceContext = CGContext(
            data: &source,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        sourceContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let kernel = UInt32(max(3, min(81, radius * 2 + 1)) | 1)
        let error: vImage_Error = source.withUnsafeMutableBytes { sourceBytes in
            output.withUnsafeMutableBytes { outputBytes in
                var sourceBuffer = vImage_Buffer(
                    data: sourceBytes.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                var outputBuffer = vImage_Buffer(
                    data: outputBytes.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                return vImageBoxConvolve_ARGB8888(
                    &sourceBuffer,
                    &outputBuffer,
                    nil,
                    0,
                    0,
                    kernel,
                    kernel,
                    nil,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        guard error == kvImageNoError,
              let resultContext = CGContext(
                data: &output,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        return resultContext.makeImage()
    }
}

enum ImageExporter {
    static func copyToPasteboard(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
    }

    static func showSavePanel(
        for image: CGImage,
        preferredScreen: NSScreen? = nil,
        completion: @escaping () -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename()
        if let preferredScreen {
            let visible = preferredScreen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if response == .OK, let url = panel.url { writePNG(image, to: url) }
            completion()
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "LongScreenShot \(formatter.string(from: Date())).png"
    }
}

enum OCRService {
    static func recognize(image: CGImage, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }
}
