import SwiftUI

// MARK: - MattePickerView
// Shared matte style + color picker used in both PhotoDetailView and TVOnlyDetailView.
// Style selector shows visual tiles that preview the matte proportions.
// Color picker is an Apple-style swatch grid.
struct MattePickerView: View {
    @Binding var selectedStyle: MatteStyle
    @Binding var selectedColor: MatteColor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // MARK: Style Selector — visual tiles
            VStack(alignment: .leading, spacing: 8) {
                Text("Style")
                    .font(.caption)
                    .foregroundColor(.secondary)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                    spacing: 10
                ) {
                    ForEach(MatteStyle.allCases, id: \.self) { style in
                        StyleTile(
                            style: style,
                            matteColor: selectedColor,
                            isSelected: selectedStyle == style
                        ) {
                            selectedStyle = style
                        }
                    }
                }
            }

            // MARK: Color Picker
            if selectedStyle != .none {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Color")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7),
                        spacing: 10
                    ) {
                        ForEach(MatteColor.allCases, id: \.self) { color in
                            ColorSwatch(color: color, isSelected: selectedColor == color) {
                                selectedColor = color
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - StyleTile
// Wrapper around MatteStyleIcon that adds selection state and label.
private struct StyleTile: View {
    let style: MatteStyle
    let matteColor: MatteColor
    let isSelected: Bool
    let onTap: () -> Void

    private let tileWidth: CGFloat = 72

    var body: some View {
        VStack(spacing: 4) {
            MatteStyleIcon(style: style, matteColor: matteColor, size: tileWidth)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            Text(style.displayName)
                .font(.system(size: 9))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - ColorSwatch
// Apple-style circular color swatch with selection ring and label.
private struct ColorSwatch: View {
    let color: MatteColor
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Outer selection ring
                Circle()
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    .frame(width: 30, height: 30)

                // Color fill
                Circle()
                    .fill(color.previewColor)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )

                // Checkmark on selected
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(checkmarkColor)
                }
            }
            .frame(width: 30, height: 30)

            Text(color.displayName)
                .font(.system(size: 8))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    // Use white checkmark on dark colors, dark on light colors
    private var checkmarkColor: Color {
        switch color {
        case .black, .navy, .burgundy, .byzantine:
            return .white
        default:
            return Color(NSColor.controlTextColor)
        }
    }
}

// MARK: - MatteErrorBanner
// Dismissible inline banner shown when the TV rejects a matte change.
struct MatteErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
    }
}
