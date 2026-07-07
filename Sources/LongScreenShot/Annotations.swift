import AppKit
import CoreText

enum AnnotationTool: Equatable {
    case rectangle, ellipse, arrow, text, pen, mosaicPixel, mosaicBlur
}

enum MosaicStyle: Hashable { case pixel, blur }

enum Annotation {
    case rectangle(CGRect, NSColor, CGFloat)
    case ellipse(CGRect, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case text(String, CGPoint, NSColor, CGFloat)
    case pen([CGPoint], NSColor, CGFloat)
    case mosaic(CGRect, MosaicStyle, CGFloat)
}

extension CGRect {
    init(between a: CGPoint, and b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

enum AnnotationRenderer {
    static func render(snapshot: ScreenSnapshot, selection: CGRect, annotations: [Annotation]) -> CGImage? {
        guard let base = snapshot.crop(viewRect: selection) else { return nil }
        let sx = CGFloat(base.width) / selection.width
        let sy = CGFloat(base.height) / selection.height

        guard let context = CGContext(
            data: nil,
            width: base.width,
            height: base.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))

        for annotation in annotations {
            guard case let .mosaic(rect, style, intensity) = annotation else { continue }
            let topLeftRect = CGRect(
                x: (rect.minX - selection.minX) * sx,
                y: (selection.maxY - rect.maxY) * sy,
                width: rect.width * sx,
                height: rect.height * sy
            ).integral
            guard let patch = ImageEffects.mosaicPatch(
                from: base,
                pixelRectTopLeft: topLeftRect,
                style: style,
                intensity: intensity
            ) else { continue }
            let destination = CGRect(
                x: topLeftRect.minX,
                y: CGFloat(base.height) - topLeftRect.maxY,
                width: topLeftRect.width,
                height: topLeftRect.height
            )
            context.draw(patch, in: destination)
        }

        context.saveGState()
        context.scaleBy(x: sx, y: sy)
        context.translateBy(x: -selection.minX, y: -selection.minY)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for annotation in annotations {
            draw(annotation, in: context)
        }
        context.restoreGState()
        return context.makeImage()
    }

    static func draw(_ annotation: Annotation, in context: CGContext) {
        switch annotation {
        case let .rectangle(rect, color, width):
            context.setStrokeColor(color.cgColor); context.setLineWidth(width)
            context.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
        case let .ellipse(rect, color, width):
            context.setStrokeColor(color.cgColor); context.setLineWidth(width)
            context.strokeEllipse(in: rect.insetBy(dx: width / 2, dy: width / 2))
        case let .arrow(start, end, color, width):
            context.setStrokeColor(color.cgColor); context.setFillColor(color.cgColor); context.setLineWidth(width)
            context.move(to: start); context.addLine(to: end); context.strokePath()
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(10, width * 4)
            let a = CGPoint(x: end.x - cos(angle - .pi / 6) * length, y: end.y - sin(angle - .pi / 6) * length)
            let b = CGPoint(x: end.x - cos(angle + .pi / 6) * length, y: end.y - sin(angle + .pi / 6) * length)
            context.beginPath(); context.move(to: end); context.addLine(to: a); context.addLine(to: b); context.closePath(); context.fillPath()
        case let .text(text, point, color, size):
            context.saveGState()
            context.textMatrix = .identity
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color]
            let attributed = NSAttributedString(string: text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = point
            CTLineDraw(line, context)
            context.restoreGState()
        case let .pen(points, color, width):
            guard let first = points.first else { return }
            context.setStrokeColor(color.cgColor); context.setLineWidth(width)
            context.beginPath(); context.move(to: first)
            points.dropFirst().forEach { context.addLine(to: $0) }
            context.strokePath()
        case .mosaic:
            break
        }
    }
}
