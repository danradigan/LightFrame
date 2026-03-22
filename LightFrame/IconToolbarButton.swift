import SwiftUI

// MARK: - IconToolbarButton
// Shared icon button component used in both the inspector panel action toolbar
// and potentially other toolbar contexts. SF Symbol icon above a small label.
struct IconToolbarButton: View {
    let icon: String
    let label: String
    var tint: Color = .primary
    var isDisabled: Bool = false
    var isLoading: Bool = false
    var badge: Int? = nil
    var tooltip: String = ""
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 20, height: 18)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 16))
                            .frame(width: 20, height: 18)
                    }

                    // Badge count
                    if let count = badge, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(tint == .red ? Color.red : Color.accentColor))
                            .offset(x: 6, y: -4)
                    }
                }

                Text(label)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .foregroundColor(isDisabled ? tint.opacity(0.3) : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(tooltip.isEmpty ? label : tooltip)
    }
}
