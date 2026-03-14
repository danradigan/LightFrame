import SwiftUI
import AppKit

// MARK: - MattePreviewView
// Renders a photo inside a realistic matte border at 16:9 output ratio.
//
// Rules:
// - Output is always 16:9
// - Background is always black
// - If matte is nil or .none: photo scales to fit (aspect fit), black fills rest
// - If matte is set: matte color fills border, bevel on inner edge
struct MattePreviewView: View {
    let photo: Photo
    let size: CGFloat

    private var height: CGFloat { size * 9 / 16 }
    private var matteThickness: CGFloat { size * 0.05 }

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
                // Matte color fills the border, bevel on inner edge
                Rectangle()
                    .fill(matteColor)
                    .frame(width: size, height: height)

                PhotoMatteView(
                    rawData: photo.thumbnailData,
                    url: photo.url,
                    outerSize: CGSize(width: size, height: height),
                    matteThickness: matteThickness
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
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
    }
}

// MARK: - PhotoMatteView
// Handles the matte + bevel rendering.
// Calculates the exact photo rect inside the matte area and draws
// the bevel precisely along the photo boundary.
struct PhotoMatteView: View {
    let rawData: Data?
    let url: URL
    let outerSize: CGSize
    let matteThickness: CGFloat

    @State private var image: NSImage?

    var innerSize: CGSize {
        CGSize(
            width: outerSize.width - matteThickness * 2,
            height: outerSize.height - matteThickness * 2
        )
    }

    // The actual rendered photo rect after aspect-fit scaling within inner area
    var photoRect: CGRect {
        guard let image = image else {
            return CGRect(
                x: matteThickness, y: matteThickness,
                width: innerSize.width, height: innerSize.height
            )
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

        let xOffset = matteThickness + (innerSize.width - photoWidth) / 2
        let yOffset = matteThickness + (innerSize.height - photoHeight) / 2

        return CGRect(x: xOffset, y: yOffset, width: photoWidth, height: photoHeight)
    }

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: innerSize.width, height: innerSize.height)
            }

            BevelOverlay(outerSize: outerSize, photoRect: photoRect)
        }
        .frame(width: outerSize.width, height: outerSize.height)
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

// MARK: - Bevel Overlay
// Renders a realistic angled mat board bevel around the photo.
// Trapezoidal faces with gradients simulate a 45° cut mat board:
//   - Top/left faces are bright (light source above-left)
//   - Bottom/right faces are in shadow
struct BevelOverlay: View {
    let outerSize: CGSize
    let photoRect: CGRect
    let bevelWidth: CGFloat = 3

    var body: some View {
        Canvas { context, _ in
            let r = photoRect
            let b = bevelWidth

            // Top bevel — catches light, bright gradient
            var topPath = Path()
            topPath.move(to: CGPoint(x: r.minX - b, y: r.minY - b))
            topPath.addLine(to: CGPoint(x: r.maxX + b, y: r.minY - b))
            topPath.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            topPath.addLine(to: CGPoint(x: r.minX, y: r.minY))
            topPath.closeSubpath()
            context.fill(topPath, with: .linearGradient(
                Gradient(colors: [Color.black.opacity(0.04), Color.white.opacity(0.85)]),
                startPoint: CGPoint(x: r.minX, y: r.minY - b),
                endPoint: CGPoint(x: r.minX, y: r.minY)
            ))

            // Left bevel — catches light, bright gradient
            var leftPath = Path()
            leftPath.move(to: CGPoint(x: r.minX - b, y: r.minY - b))
            leftPath.addLine(to: CGPoint(x: r.minX, y: r.minY))
            leftPath.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            leftPath.addLine(to: CGPoint(x: r.minX - b, y: r.maxY + b))
            leftPath.closeSubpath()
            context.fill(leftPath, with: .linearGradient(
                Gradient(colors: [Color.black.opacity(0.04), Color.white.opacity(0.75)]),
                startPoint: CGPoint(x: r.minX - b, y: r.minY),
                endPoint: CGPoint(x: r.minX, y: r.minY)
            ))

            // Bottom bevel — in shadow, dark gradient
            var bottomPath = Path()
            bottomPath.move(to: CGPoint(x: r.minX, y: r.maxY))
            bottomPath.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            bottomPath.addLine(to: CGPoint(x: r.maxX + b, y: r.maxY + b))
            bottomPath.addLine(to: CGPoint(x: r.minX - b, y: r.maxY + b))
            bottomPath.closeSubpath()
            context.fill(bottomPath, with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.35), Color.black.opacity(0.10)]),
                startPoint: CGPoint(x: r.minX, y: r.maxY),
                endPoint: CGPoint(x: r.minX, y: r.maxY + b)
            ))

            // Right bevel — in shadow, dark gradient
            var rightPath = Path()
            rightPath.move(to: CGPoint(x: r.maxX, y: r.minY))
            rightPath.addLine(to: CGPoint(x: r.maxX + b, y: r.minY - b))
            rightPath.addLine(to: CGPoint(x: r.maxX + b, y: r.maxY + b))
            rightPath.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            rightPath.closeSubpath()
            context.fill(rightPath, with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.35), Color.black.opacity(0.10)]),
                startPoint: CGPoint(x: r.maxX, y: r.minY),
                endPoint: CGPoint(x: r.maxX + b, y: r.minY)
            ))
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
