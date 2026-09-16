import SwiftUI
import CorniceKit

/// The whole interface.
///
/// A single view that renders either form, rather than two windows swapped in
/// and out, so SwiftUI can interpolate the outline between them: the corner
/// radii, the width, and the content all animate as one object growing out of
/// the notch instead of a panel appearing beneath it.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            switch model.surfaceState {
            case .collapsed:
                CollapsedSurface(model: model)
                    .transition(.opacity)
            case .expanded:
                ExpandedSurface(model: model)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                            removal: .opacity
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(
            model.surfaceState == .expanded ? Theme.Motion.expand : Theme.Motion.collapse,
            value: model.surfaceState
        )
        // The collapsed surface must stay black to blend with the notch
        // regardless of the system appearance; the expanded panel follows it.
        .environment(\.colorScheme, model.surfaceState == .collapsed ? .dark : systemScheme)
    }

    @Environment(\.colorScheme) private var systemScheme
}

/// The resting state: the notch, plus an indicator on either side when there is
/// something worth saying.
struct CollapsedSurface: View {
    @Bindable var model: AppModel

    private var content: CollapsedContent { model.collapsedContent }

    var body: some View {
        let profile = model.notchProfile

        ZStack {
            NotchShape(
                bottomRadius: (profile?.cornerRadius ?? 10) + (content.isEmpty ? 0 : 4),
                flareRadius: content.isEmpty ? 0 : 8
            )
            .fill(Theme.Palette.notch)

            if !content.isEmpty {
                HStack(spacing: 0) {
                    chipView(content.leading, alignment: .leading)
                        .frame(width: Theme.Metrics.wingWidth)

                    // The notch itself. Nothing can be drawn here — it is a
                    // hole in the display — so it is reserved as empty space.
                    Color.clear
                        .frame(width: profile?.rect.width ?? 200)

                    chipView(content.trailing, alignment: .trailing)
                        .frame(width: Theme.Metrics.wingWidth)
                }
                .padding(.bottom, Theme.Metrics.wingDrop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the Cornice panel")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func chipView(_ chip: CollapsedContent.Chip?, alignment: Alignment) -> some View {
        if let chip {
            ChipView(chip: chip)
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(.horizontal, 10)
                .transition(.opacity.combined(with: .move(edge: alignment == .leading ? .trailing : .leading)))
        } else {
            Color.clear
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = ["Cornice"]
        if let text = content.leading?.text { parts.append(text) }
        if let text = content.trailing?.text { parts.append(text) }
        return parts.joined(separator: ", ")
    }
}

/// One collapsed indicator.
struct ChipView: View {
    let chip: CollapsedContent.Chip
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: chip.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(chip.tint)
                .opacity(chip.isUrgent && isPulsing ? 0.45 : 1)

            if let text = chip.text {
                Text(text)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Color(white: 0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .onAppear {
            guard chip.isUrgent else { return }
            // A slow, shallow pulse. Fast blinking in peripheral vision is
            // genuinely unpleasant to work next to, so this is closer to a
            // breath than a flash.
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
