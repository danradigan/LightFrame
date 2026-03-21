import SwiftUI
import AppKit

// MARK: - MattePreviewView
// Renders a photo inside a realistic matte border at 16:9 output ratio.
//
// Each MatteStyle has unique proportions matching the actual Samsung Frame TV:
//   - panoramic:   wide letterbox crop, large matte top/bottom
//   - shadowbox:   nearly full-bleed with subtle inset shadow
//   - modern-wide: generous border, slightly wider on sides
//   - modern-thin: moderate even border
//   - flexible:    very thin accent border
//   - modern:      traditional generous even border
//
// Rules:
// - Output frame is always 16:9
// - Background is always black
// - If matte is nil or .none: photo scales to fit (aspect fit), black fills rest
// - If matte is set: matte color fills border area, bevel on inner edge
struct MattePreviewView: View {
    let photo: Photo
    let size: CGFloat

    private var height: CGFloat { size * 9 / 16 }

    private var matteStyle: MatteStyle {
        photo.matte?.style ?? .none
    }

    var matteColor: Color {
        guard let color = photo.matte?.color else {
            return Color(red: 0.93, green: 0.88, blue: 0.78)
        }
        return color.previewColor
    }

    // Show matte only if explicitly set to a non-none style
    var showMatte: Bool {
        guard let matte = photo.matte else { return false }
        return matte.style != .none
    }

    var body: some View {
        ZStack {
            // Always black background
            Color.black

            if showMatte {
                // Matte color fills the border area
                Rectangle()
                    .fill(matteColor)
                    .frame(width: size, height: height)

                PhotoMatteView(
                    rawData: photo.thumbnailData,
                    url: photo.url,
                    outerSize: CGSize(width: size, height: height),
                    matteStyle: matteStyle
                )
            } else {
                // No matte — photo aspect-fits within 16:9, black fills rest
                PhotoImageView(
                    url: photo.url,
                    containerSize: CGSize(width: size, height: height),
                    rawData: photo.thumbnailData
                )
            }
        }
        .frame(width: size, height: height)
        .drawingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.30), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Matte Insets
// Defines the proportional insets for each matte style.
// Values are fractions of the 16:9 outer frame dimensions, measured from
// reference photos of each style on an actual Samsung Frame TV.
struct MatteInsets {
    let topFraction: CGFloat
    let bottomFraction: CGFloat
    let leftFraction: CGFloat
    let rightFraction: CGFloat

    // Symmetric convenience
    init(horizontal: CGFloat, vertical: CGFloat) {
        self.topFraction = vertical
        self.bottomFraction = vertical
        self.leftFraction = horizontal
        self.rightFraction = horizontal
    }

    init(top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        self.topFraction = top
        self.bottomFraction = bottom
        self.leftFraction = left
        self.rightFraction = right
    }

    func topPx(_ outerSize: CGSize) -> CGFloat { topFraction * outerSize.height }
    func bottomPx(_ outerSize: CGSize) -> CGFloat { bottomFraction * outerSize.height }
    func leftPx(_ outerSize: CGSize) -> CGFloat { leftFraction * outerSize.width }
    func rightPx(_ outerSize: CGSize) -> CGFloat { rightFraction * outerSize.width }

    func innerSize(_ outerSize: CGSize) -> CGSize {
        CGSize(
            width: outerSize.width - leftPx(outerSize) - rightPx(outerSize),
            height: outerSize.height - topPx(outerSize) - bottomPx(outerSize)
        )
    }

    func innerOrigin(_ outerSize: CGSize) -> CGPoint {
        CGPoint(x: leftPx(outerSize), y: topPx(outerSize))
    }

    static func forStyle(_ style: MatteStyle) -> MatteInsets {
        switch style {
        case .none:
            return MatteInsets(horizontal: 0, vertical: 0)

        case .panoramic:
            // Wide letterbox: ~12.5% inset on sides, ~37% top/bottom
            return MatteInsets(horizontal: 0.125, vertical: 0.37)

        case .shadowbox:
            // Nearly full-bleed: ~4% sides, ~6% top/bottom
            return MatteInsets(horizontal: 0.04, vertical: 0.06)

        case .modernWide:
            // Generous border: ~17% sides, ~20% top/bottom
            return MatteInsets(horizontal: 0.17, vertical: 0.20)

        case .modernThin:
            // Moderate border: ~7% sides, ~10% top/bottom
            return MatteInsets(horizontal: 0.07, vertical: 0.10)

        case .flexible:
            // Thin accent border: ~5% sides, ~7% top/bottom
            return MatteInsets(horizontal: 0.05, vertical: 0.07)

        case .modern:
            // Traditional generous border: ~20% sides, ~18% top/bottom
            return MatteInsets(horizontal: 0.20, vertical: 0.18)
        }
    }
}

// MARK: - PhotoMatteView
// Handles the matte + bevel rendering with style-specific proportions.
//
// The Samsung Frame TV behaves differently depending on style:
//   - Cropping styles (panoramic, modern, modernThin, modernWide):
//     The image is cropped to FILL the matte window. Panoramic cuts a wide
//     horizontal strip from the center; modern crops to fill its smaller window.
//   - Fitting styles (flexible, shadowbox):
//     The full image is scaled to FIT inside the matte window with the matte
//     color visible in any remaining space.
struct PhotoMatteView: View {
    let rawData: Data?
    let url: URL
    let outerSize: CGSize
    let matteStyle: MatteStyle

    @State private var image: NSImage?

    private var insets: MatteInsets {
        MatteInsets.forStyle(matteStyle)
    }

    var innerSize: CGSize {
        insets.innerSize(outerSize)
    }

    var innerOrigin: CGPoint {
        insets.innerOrigin(outerSize)
    }

    // Styles that crop the image to fill the matte window.
    // Flexible and modern thin both crop — flexible has less border, modern thin more.
    // Only shadowbox is a fit style (full photo visible).
    private var cropsFill: Bool {
        switch matteStyle {
        case .panoramic, .modern, .modernWide, .modernThin, .flexible:
            return true
        case .shadowbox, .none:
            return false
        }
    }

    // The photo rect for the bevel overlay — always matches the inner matte window
    // for cropping styles (image fills it entirely), or the fitted image rect for
    // fitting styles.
    var photoRect: CGRect {
        if cropsFill {
            // Image fills the entire inner window — bevel goes around the window edge
            return CGRect(origin: innerOrigin, size: innerSize)
        }

        // Fitting styles: compute the actual image rect after aspect-fit
        guard let image = image else {
            return CGRect(origin: innerOrigin, size: innerSize)
        }

        let imageAspect = image.size.width / image.size.height
        let containerAspect = innerSize.width / innerSize.height

        let photoWidth: CGFloat
        let photoHeight: CGFloat

        if imageAspect > containerAspect {
            photoWidth = innerSize.width
            photoHeight = innerSize.width / imageAspect
        } else {
            photoHeight = innerSize.height
            photoWidth = innerSize.height * imageAspect
        }

        let xOffset = innerOrigin.x + (innerSize.width - photoWidth) / 2
        let yOffset = innerOrigin.y + (innerSize.height - photoHeight) / 2

        return CGRect(x: xOffset, y: yOffset, width: photoWidth, height: photoHeight)
    }

    // Bevel width scales proportionally with the view size.
    // A real mat board bevel is clearly visible — not a hairline.
    private var bevelWidth: CGFloat {
        max(2, outerSize.width * 0.012)
    }

    // Offset to center the inner area within the outer frame
    private var innerOffset: CGSize {
        CGSize(
            width: (innerOrigin.x + innerSize.width / 2) - outerSize.width / 2,
            height: (innerOrigin.y + innerSize.height / 2) - outerSize.height / 2
        )
    }

    var body: some View {
        ZStack {
            if let image = image {
                let shadowStyle = matteStyle == .shadowbox
                if cropsFill {
                    // Crop to fill: image fills the matte window, excess is clipped
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: innerSize.width, height: innerSize.height)
                        .clipped()
                        .shadow(color: shadowStyle ? .black.opacity(0.7) : .clear,
                                radius: shadowStyle ? max(4, outerSize.width * 0.018) : 0,
                                x: 0, y: 0)
                        .frame(width: outerSize.width, height: outerSize.height, alignment: .center)
                        .offset(innerOffset)
                } else {
                    // Scale to fit: full image visible, matte color fills gaps
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: innerSize.width, height: innerSize.height)
                        .shadow(color: shadowStyle ? .black.opacity(0.7) : .clear,
                                radius: shadowStyle ? max(4, outerSize.width * 0.018) : 0,
                                x: 0, y: 0)
                        .frame(width: outerSize.width, height: outerSize.height, alignment: .center)
                        .offset(innerOffset)
                }
            }

            // Bevel overlay for styles with mat board cut (not shadowbox, not none)
            if matteStyle != .shadowbox && matteStyle != .none {
                BevelOverlay(outerSize: outerSize, photoRect: photoRect, bevelWidth: bevelWidth)
            }
        }
        .frame(width: outerSize.width, height: outerSize.height)
        .clipped()
        .onAppear { loadImage() }
        .onChange(of: url) { loadImage() }
    }

    private func loadImage() {
        let targetSize = max(outerSize.width, outerSize.height)
        if let data = rawData {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = PhotoScanner.thumbnailImage(from: data, size: targetSize)
                DispatchQueue.main.async { image = result }
            }
            return
        }
        let photoURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            let accessing = photoURL.startAccessingSecurityScopedResource()
            defer { if accessing { photoURL.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: photoURL) else { return }
            let result = PhotoScanner.thumbnailImage(from: data, size: targetSize)
            DispatchQueue.main.async { image = result }
        }
    }
}

// MARK: - Shadowbox Overlay
// The shadowbox effect: photo floats ABOVE the matte surface, casting a
// drop shadow DOWN onto the matte beneath it. This is NOT an inset/recessed
// effect — the shadow falls outside the photo rect onto the matte.
struct ShadowboxOverlay: View {
    let outerSize: CGSize
    let photoRect: CGRect

    var body: some View {
        Canvas { context, _ in
            let r = photoRect
            let offsetX: CGFloat = max(1.5, outerSize.width * 0.005)
            let offsetY: CGFloat = max(3, outerSize.width * 0.01)
            let blur: CGFloat = max(4, outerSize.width * 0.015)

            // Drop shadow: dark rect offset down/right behind the photo,
            // blurred so it falls onto the matte surface beneath.
            let shadowRect = r.offsetBy(dx: offsetX, dy: offsetY)
            let shadowPath = Path(shadowRect)

            var shadowCtx = context
            shadowCtx.addFilter(.blur(radius: blur))
            shadowCtx.fill(shadowPath, with: .color(Color.black.opacity(0.45)))
        }
        .frame(width: outerSize.width, height: outerSize.height)
        .allowsHitTesting(false)
    }
}

// MARK: - Bevel Overlay
// Renders the exposed paper core of a 45° mat board cut around the photo.
// On a real mat, the bevel is a solid warm cream/white strip visible on
// all four sides — brighter on top/left (catches light), slightly darker
// on bottom/right (in shadow), but always clearly visible as a distinct band.
struct BevelOverlay: View {
    let outerSize: CGSize
    let photoRect: CGRect
    var bevelWidth: CGFloat = 3

    var body: some View {
        Canvas { context, _ in
            let r = photoRect
            let b = max(1.5, bevelWidth)

            // Paper core — near-white so it contrasts against light mattes too
            let coreLight = Color.white
            let coreShadow = Color(white: 0.88)

            // Outer edge line — thin dark line where bevel meets the matte surface.
            // This is what makes the bevel visible even on antique/polar/warm.
            let edgeThickness: CGFloat = max(0.5, b * 0.3)
            let outerEdge = Color.black.opacity(0.15)

            // Draw outer edge lines first (behind the bevel)
            // Top outer edge
            context.fill(Path(CGRect(x: r.minX - b, y: r.minY - b, width: r.width + 2 * b, height: edgeThickness)),
                         with: .color(outerEdge))
            // Left outer edge
            context.fill(Path(CGRect(x: r.minX - b, y: r.minY - b, width: edgeThickness, height: r.height + 2 * b)),
                         with: .color(outerEdge))
            // Bottom outer edge
            context.fill(Path(CGRect(x: r.minX - b, y: r.maxY + b - edgeThickness, width: r.width + 2 * b, height: edgeThickness)),
                         with: .color(Color.black.opacity(0.20)))
            // Right outer edge
            context.fill(Path(CGRect(x: r.maxX + b - edgeThickness, y: r.minY - b, width: edgeThickness, height: r.height + 2 * b)),
                         with: .color(Color.black.opacity(0.20)))

            // Top bevel — bright paper core
            var topPath = Path()
            topPath.move(to: CGPoint(x: r.minX - b, y: r.minY - b))
            topPath.addLine(to: CGPoint(x: r.maxX + b, y: r.minY - b))
            topPath.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            topPath.addLine(to: CGPoint(x: r.minX, y: r.minY))
            topPath.closeSubpath()
            context.fill(topPath, with: .color(coreLight.opacity(0.95)))

            // Left bevel — bright paper core
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
        .frame(width: outerSize.width, height: outerSize.height)
        .allowsHitTesting(false)
    }
}

// MARK: - PhotoImageView
// Displays a photo centered preserving aspect ratio (aspect fit).
// Used when no matte is set — photo sits on black background.
struct PhotoImageView: View {
    let url: URL
    let containerSize: CGSize
    var rawData: Data?

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: containerSize.width, height: containerSize.height)
            } else {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: containerSize.width, height: containerSize.height)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.5)
                            .tint(.white)
                    )
            }
        }
        .onAppear { loadImage() }
        .onChange(of: url) { loadImage() }
    }

    private func loadImage() {
        let targetSize = max(containerSize.width, containerSize.height)
        if let data = rawData {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = PhotoScanner.thumbnailImage(from: data, size: targetSize)
                DispatchQueue.main.async { image = result }
            }
            return
        }
        let photoURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            let accessing = photoURL.startAccessingSecurityScopedResource()
            defer { if accessing { photoURL.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: photoURL) else { return }
            let result = PhotoScanner.thumbnailImage(from: data, size: targetSize)
            DispatchQueue.main.async { image = result }
        }
    }
}
