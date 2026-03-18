import SwiftUI

// MARK: - MattePickerView
// Shared matte style + color picker used in both PhotoDetailView and TVOnlyDetailView.
// Style selector is a compact wrapped row of pill buttons.
// Color picker is an Apple-style swatch grid.
struct MattePickerView: View {
    @Binding var selectedStyle: MatteStyle
    @Binding var selectedColor: MatteColor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // MARK: Style Selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Style")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Wrap styles in a flow layout using LazyVGrid
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 90), spacing: 6)
                    ],
                    spacing: 6
                ) {
                    ForEach(MatteStyle.allCases, id: \.self) { style in
                        StylePill(style: style, isSelected: selectedStyle == style) {
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

// MARK: - StylePill
// Compact pill-shaped button for matte style selection.
private struct StylePill: View {
    let style: MatteStyle
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Text(style.displayName)
            .font(.caption)
            .lineLimit(1)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 1.5 : 0.5)
            )
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
