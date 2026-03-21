import SwiftUI

// MARK: - MattePickerView
// Shared matte style + color picker used in both PhotoDetailView and TVOnlyDetailView.
// Style selector shows visual tiles that preview the matte proportions.
// Color picker is a swatch grid with color names labeling each row.
struct MattePickerView: View {
    @Binding var selectedStyle: MatteStyle
    @Binding var selectedColor: MatteColor

    private let styleColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    // Matte styles excluding .none — those go in the 3x2 grid
    private var matteStyles: [MatteStyle] {
        MatteStyle.allCases.filter { $0 != .none }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // MARK: Style Selector — 3x2 grid + full-width None button
            VStack(alignment: .leading, spacing: 8) {
                Text("Style")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                LazyVGrid(columns: styleColumns, spacing: 10) {
                    ForEach(matteStyles, id: \.self) { style in
                        StyleTile(
                            style: style,
                            matteColor: selectedColor,
                            isSelected: selectedStyle == style
                        ) {
                            selectedStyle = style
                        }
                    }
                }

                // None — full-width button below the grid
                Button {
                    selectedStyle = .none
                } label: {
                    Text("None")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selectedStyle == .none ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(selectedStyle == .none ? Color.accentColor : Color.primary.opacity(0.2),
                                        lineWidth: selectedStyle == .none ? 2 : 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // MARK: Color Picker — rounded rect swatches with names below
            if selectedStyle != .none {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Color")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: colorColumns, spacing: 10) {
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
// Uses GeometryReader + aspectRatio like the sidebar for consistent sizing.
private struct StyleTile: View {
    let style: MatteStyle
    let matteColor: MatteColor
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let tileWidth = geo.size.width
                ZStack {
                    MatteStyleIcon(style: style, matteColor: matteColor, size: tileWidth)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor, lineWidth: 2)
                    }
                }
            }
            .aspectRatio(16.0/9.0, contentMode: .fit)

            Text(style.displayName)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - ColorSwatch
// Rounded rectangle color swatch with name label below.
private struct ColorSwatch: View {
    let color: MatteColor
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.previewColor)
                .aspectRatio(16.0/10.0, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
                )
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(checkmarkColor)
                    }
                }

            Text(color.displayName)
                .font(.system(size: 10))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private var checkmarkColor: Color {
        switch color {
        case .black, .navy, .burgundy, .byzantine, .turquoise:
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
