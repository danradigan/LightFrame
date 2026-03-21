import SwiftUI

// MARK: - MatteStyleIcon
//
// Unified matte style icon used in both the matte picker (DetailPanel)
// and sidebar filters (SidebarView). Replaces the previous separate
// StyleTile and FilterStyleSwatch implementations.
//
// Renders a 16:9 miniature showing the matte proportions with:
//   - Crop vs fit visual distinction (crop = photo fills window,
//     fit = photo centered with matte visible around it)
//   - Per-style bevel or shadowbox rendering
//   - Adaptive colors for light/dark mode
//
// Usage:
//   MatteStyleIcon(style: .flexible, matteColor: .warm, size: 72)
//   MatteStyleIcon(style: .panoramic, size: 48)  // neutral adaptive color
//
struct MatteStyleIcon: View {
    let style: MatteStyle
    var matteColor: MatteColor? = nil
    var size: CGFloat = 72

    private var height: CGFloat { size * 9 / 16 }

    // Matte fill: use provided color or adaptive neutral
    private var matteFill: Color {
        if let color = matteColor {
            return color.previewColor
        }
        return Color(NSColor.unemphasizedSelectedContentBackgroundColor)
    }

    // Inner "photo" fill
    private var photoFill: Color {
        Color(NSColor.controlBackgroundColor).opacity(0.85)
    }

    // All matte styles crop to fill except none (which has no matte at all).
    // Shadowbox crops to fill just like modern — the difference is the shadow effect.
    private var cropsFill: Bool {
        style != .none
    }

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height

            if style == .none {
                drawNoneStyle(context: context, w: w, h: h)
            } else {
                drawMatteStyle(context: context, w: w, h: h)
            }
        }
        .frame(width: size, height: height)
    }

    // MARK: - None Style

    private func drawNoneStyle(context: GraphicsContext, w: CGFloat, h: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let rrect = Path(roundedRect: rect, cornerRadius: 2)

        // Photo fill — slightly dimmed to show "no frame"
        context.fill(rrect, with: .color(photoFill))

        // Dashed border to communicate "no frame" intentionally
        context.stroke(rrect, with: .color(Color.primary.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    }

    // MARK: - Matte Style

    private func drawMatteStyle(context: GraphicsContext, w: CGFloat, h: CGFloat) {
        let outerRect = CGRect(x: 0, y: 0, width: w, height: h)
        let outerPath = Path(roundedRect: outerRect, cornerRadius: 2)

        // Matte background
        context.fill(outerPath, with: .color(matteFill))

        // Compute inner matte window
        let insets = MatteInsets.forStyle(style)
        let innerX = w * insets.leftFraction
        let innerY = h * insets.topFraction
        let innerW = w * (1 - insets.leftFraction - insets.rightFraction)
        let innerH = h * (1 - insets.topFraction - insets.bottomFraction)

        // Photo rect depends on crop vs fit
        let photoRect: CGRect
        if cropsFill {
            // Photo fills the entire matte window
            photoRect = CGRect(x: innerX, y: innerY, width: innerW, height: innerH)
        } else {
            // Photo is aspect-fit as 3:2 landscape inside the matte window
            let photoAspect: CGFloat = 3.0 / 2.0
            let windowAspect = innerW / innerH
            let fitW: CGFloat
            let fitH: CGFloat
            if photoAspect > windowAspect {
                fitW = innerW
                fitH = innerW / photoAspect
            } else {
                fitH = innerH
                fitW = innerH * photoAspect
            }
            photoRect = CGRect(
                x: innerX + (innerW - fitW) / 2,
                y: innerY + (innerH - fitH) / 2,
                width: fitW,
                height: fitH
            )
        }

        // Style-specific overlay
        if style == .shadowbox {
            drawShadowbox(context: context, photoRect: photoRect)
        } else {
            drawBevel(context: context, photoRect: photoRect, w: w)
        }

        // Photo fill (drawn after shadowbox so shadow appears behind photo)
        let photoPath = Path(roundedRect: photoRect, cornerRadius: 1)
        context.fill(photoPath, with: .color(photoFill))

        // Inner hairline for bevel styles — the sharp edge where mat meets photo
        if style != .shadowbox {
            let hairline: CGFloat = 0.5
            let hairlinePath = Path(CGRect(
                x: photoRect.minX, y: photoRect.minY,
                width: photoRect.width, height: photoRect.height
            ))
            context.stroke(hairlinePath, with: .color(Color.black.opacity(0.20)),
                           style: StrokeStyle(lineWidth: hairline))
        }
    }

    // MARK: - Shadowbox Effect
    // Photo floats above matte, casting a well-defined drop shadow DOWN onto the matte.
    // Rendered as a dark rect offset down/right behind the photo with blur.

    private func drawShadowbox(context: GraphicsContext, photoRect: CGRect) {
        let offsetX: CGFloat = max(1, size * 0.015)
        let offsetY: CGFloat = max(2, size * 0.03)
        let blur: CGFloat = max(2, size * 0.025)

        let shadowRect = photoRect.offsetBy(dx: offsetX, dy: offsetY)
        let shadowPath = Path(roundedRect: shadowRect, cornerRadius: 1)

        var shadowCtx = context
        shadowCtx.addFilter(.blur(radius: blur))
        shadowCtx.fill(shadowPath, with: .color(Color.black.opacity(0.50)))
    }

    // MARK: - Bevel Effect
    // Simulates a 45° mat board cut showing the paper core.
    // Top/left faces catch light (bright), bottom/right in shadow (darker).
    // A subtle outer edge line where bevel meets the matte surface adds definition.

    private func drawBevel(context: GraphicsContext, photoRect: CGRect, w: CGFloat) {
        let b = max(1.5, w * 0.02)
        let r = photoRect

        // Paper core colors — warm white for light-catching faces, slightly gray for shadow faces
        let coreLight = Color.white
        let coreShadow = Color(white: 0.85)

        // Outer edge line where bevel meets matte surface
        let edgeThickness: CGFloat = max(0.5, b * 0.25)
        let outerEdge = Color.black.opacity(0.12)
        let outerEdgeShadow = Color.black.opacity(0.18)

        // Outer edge lines (drawn first, behind bevel faces)
        context.fill(Path(CGRect(x: r.minX - b, y: r.minY - b, width: r.width + 2 * b, height: edgeThickness)),
                     with: .color(outerEdge))
        context.fill(Path(CGRect(x: r.minX - b, y: r.minY - b, width: edgeThickness, height: r.height + 2 * b)),
                     with: .color(outerEdge))
        context.fill(Path(CGRect(x: r.minX - b, y: r.maxY + b - edgeThickness, width: r.width + 2 * b, height: edgeThickness)),
                     with: .color(outerEdgeShadow))
        context.fill(Path(CGRect(x: r.maxX + b - edgeThickness, y: r.minY - b, width: edgeThickness, height: r.height + 2 * b)),
                     with: .color(outerEdgeShadow))

        // Top bevel — bright paper core (catches light)
        var topPath = Path()
        topPath.move(to: CGPoint(x: r.minX - b, y: r.minY - b))
        topPath.addLine(to: CGPoint(x: r.maxX + b, y: r.minY - b))
        topPath.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        topPath.addLine(to: CGPoint(x: r.minX, y: r.minY))
        topPath.closeSubpath()
        context.fill(topPath, with: .color(coreLight.opacity(0.95)))

        // Left bevel — bright paper core (catches light)
        var leftPath = Path()
        leftPath.move(to: CGPoint(x: r.minX - b, y: r.minY - b))
        leftPath.addLine(to: CGPoint(x: r.minX, y: r.minY))
        leftPath.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        leftPath.addLine(to: CGPoint(x: r.minX - b, y: r.maxY + b))
        leftPath.closeSubpath()
        context.fill(leftPath, with: .color(coreLight.opacity(0.90)))

        // Bottom bevel — shadowed paper core
        var bottomPath = Path()
        bottomPath.move(to: CGPoint(x: r.minX, y: r.maxY))
        bottomPath.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        bottomPath.addLine(to: CGPoint(x: r.maxX + b, y: r.maxY + b))
        bottomPath.addLine(to: CGPoint(x: r.minX - b, y: r.maxY + b))
        bottomPath.closeSubpath()
        context.fill(bottomPath, with: .color(coreShadow))

        // Right bevel — shadowed paper core
        var rightPath = Path()
        rightPath.move(to: CGPoint(x: r.maxX, y: r.minY))
        rightPath.addLine(to: CGPoint(x: r.maxX + b, y: r.minY - b))
        rightPath.addLine(to: CGPoint(x: r.maxX + b, y: r.maxY + b))
        rightPath.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        rightPath.closeSubpath()
        context.fill(rightPath, with: .color(coreShadow))
    }
}
