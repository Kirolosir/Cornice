import SwiftUI
import CorniceKit

/// Confirmation for anything destructive or anything that runs a command.
///
/// Rendered inside the panel rather than as an `NSAlert` for one specific
/// reason: an alert would activate the app and take focus away from the
/// editor the user is working in — the exact interruption this app exists to
/// avoid. It also means the command text is shown in the same place the user
/// was already looking.
///
/// The command is displayed verbatim, in full, in a monospaced face. A
/// confirmation that paraphrases what it is about to run is not a confirmation.
struct ConfirmationOverlay: View {
    @Bindable var model: AppModel
    let confirmation: AppModel.PendingConfirmation

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // Scrim. Also swallows clicks on the pane behind, so a mis-click
            // cannot act on the thing being confirmed.
            Rectangle()
                .fill(.black.opacity(scheme == .dark ? 0.55 : 0.25))
                .onTapGesture { model.cancelPending() }

            VStack(alignment: .leading, spacing: 10) {
                Text(confirmation.title)
                    .font(Theme.Typeface.title)
                    .foregroundStyle(Theme.Palette.primaryText(scheme))

                Text(confirmation.message)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = confirmation.detail {
                    ScrollView(.vertical) {
                        Text(detail)
                            .font(Theme.Typeface.mono)
                            .foregroundStyle(Theme.Palette.primaryText(scheme))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 62)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((scheme == .dark ? Color.white : Color.black).opacity(0.06))
                    )
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { model.cancelPending() }
                        .buttonStyle(PanelButtonStyle())
                        .keyboardShortcut(.cancelAction)

                    Button(confirmation.confirmLabel) { model.confirmPending() }
                        .buttonStyle(PanelButtonStyle(
                            tint: confirmation.isDestructive
                                ? Theme.Palette.failure
                                : Theme.Palette.accent
                        ))
                        // Deliberately *not* the default action: a destructive
                        // step should not be one stray Return keypress away.
                }
                .font(Theme.Typeface.body)
            }
            .padding(14)
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.Palette.card(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.Palette.hairline(scheme), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            )
        }
        .transition(.opacity)
        .accessibilityAddTraits(.isModal)
    }
}
