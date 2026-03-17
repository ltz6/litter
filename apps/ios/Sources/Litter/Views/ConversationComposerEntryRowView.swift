import SwiftUI
import UIKit

struct ConversationComposerEntryRowView: View {
    @Binding var showAttachMenu: Bool
    @Binding var inputText: String
    @Binding var isComposerFocused: Bool
    let voiceManager: VoiceTranscriptionManager
    let isTurnActive: Bool
    let hasAttachment: Bool
    let onPasteImage: (UIImage) -> Void
    let onSendText: () -> Void
    let onStopRecording: () -> Void
    let onStartRecording: () -> Void
    let onInterrupt: () -> Void

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSend: Bool {
        hasText || hasAttachment
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !voiceManager.isRecording && !voiceManager.isTranscribing && !isTurnActive {
                Button {
                    showAttachMenu = true
                } label: {
                    Image(systemName: "plus")
                        .litterFont(.body, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .modifier(GlassCircleModifier())
                }
                .transition(.scale.combined(with: .opacity))
            }

            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ConversationComposerTextView(
                        text: $inputText,
                        isFocused: $isComposerFocused,
                        onPasteImage: onPasteImage
                    )

                    if inputText.isEmpty {
                        Text("Message litter...")
                            .litterFont(.body)
                            .foregroundColor(LitterTheme.textMuted)
                            .padding(.leading, 16)
                            .padding(.top, 10)
                            .allowsHitTesting(false)
                    }
                }

                if canSend {
                    Button(action: onSendText) {
                        Image(systemName: "arrow.up.circle.fill")
                            .litterFont(.title2)
                            .foregroundColor(LitterTheme.accent)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                } else if voiceManager.isRecording {
                    AudioWaveformView(level: voiceManager.audioLevel)
                        .frame(width: 48, height: 20)

                    Button(action: onStopRecording) {
                        Image(systemName: "stop.circle.fill")
                            .litterFont(.title2)
                            .foregroundColor(LitterTheme.accentStrong)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                } else if voiceManager.isTranscribing {
                    ProgressView()
                        .tint(LitterTheme.accent)
                        .padding(.trailing, 8)
                } else {
                    Button(action: onStartRecording) {
                        Image(systemName: "mic.fill")
                            .litterFont(.subheadline)
                            .foregroundColor(LitterTheme.textSecondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                }
            }
            .frame(minHeight: 36)
            .modifier(GlassRoundedRectModifier(cornerRadius: 20))

            if isTurnActive {
                Button(action: onInterrupt) {
                    Text("Cancel")
                        .litterFont(.subheadline, weight: .medium)
                        .foregroundColor(LitterTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .modifier(GlassCapsuleModifier())
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: isTurnActive)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}
