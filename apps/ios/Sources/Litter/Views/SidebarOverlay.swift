import SwiftUI

struct SidebarOverlay: View {
    @EnvironmentObject var appState: AppState
    @Binding var dragOffset: CGFloat
    @State private var isSidebarMounted = false
    var topInset: CGFloat = 0

    static let sidebarWidth: CGFloat = 300
    private let animation = Animation.spring(response: 0.3, dampingFraction: 0.86)
    private let closeUnmountDelay: TimeInterval = 0.4

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black
                .opacity(0.42 * revealProgress)
                .ignoresSafeArea()
                .allowsHitTesting(revealProgress > 0.01)
                .onTapGesture {
                    closeSidebar()
                }

            if isSidebarMounted {
                SessionSidebarView()
                    .padding(.top, topInset + 8)
                    .frame(
                        minWidth: Self.sidebarWidth,
                        idealWidth: Self.sidebarWidth,
                        maxWidth: Self.sidebarWidth,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                    .background {
                        if #available(iOS 26.0, *) {
                            Rectangle().fill(.ultraThinMaterial).glassEffect(.regular, in: .rect)
                        } else {
                            Rectangle().fill(.ultraThinMaterial)
                        }
                    }
                    .ignoresSafeArea()
                    .offset(x: panelOffset)
                    .shadow(color: .black.opacity(0.35), radius: 20, x: 6, y: 0)
                    .gesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .local)
                            .onChanged { value in
                                guard appState.sidebarOpen else { return }
                                dragOffset = min(0, value.translation.width)
                            }
                            .onEnded { value in
                                guard appState.sidebarOpen else { return }
                                let shouldClose = value.translation.width < -Self.sidebarWidth * 0.33 ||
                                    value.predictedEndTranslation.width < -Self.sidebarWidth * 0.5
                                withAnimation(animation) {
                                    appState.sidebarOpen = !shouldClose
                                    dragOffset = 0
                                }
                            }
                    )
            }
        }
        .allowsHitTesting(appState.sidebarOpen || revealProgress > 0.01)
        .animation(animation, value: appState.sidebarOpen)
        .animation(animation, value: dragOffset)
        .onAppear {
            isSidebarMounted = appState.sidebarOpen
        }
        .onChange(of: appState.sidebarOpen) { _, isOpen in
            if isOpen {
                isSidebarMounted = true
            } else {
                scheduleUnmountIfNeeded()
            }
        }
    }

    private var panelOffset: CGFloat {
        if appState.sidebarOpen {
            return min(0, max(-Self.sidebarWidth, dragOffset))
        }
        return -Self.sidebarWidth
    }

    private var revealProgress: CGFloat {
        guard appState.sidebarOpen else { return 0 }
        return min(1, max(0, 1 + (dragOffset / Self.sidebarWidth)))
    }

    private func closeSidebar() {
        withAnimation(animation) {
            appState.sidebarOpen = false
            dragOffset = 0
        }
    }

    private func scheduleUnmountIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + closeUnmountDelay) {
            guard !appState.sidebarOpen else { return }
            isSidebarMounted = false
        }
    }
}

#if DEBUG
private struct SidebarOverlayPreviewHost: View {
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        SidebarOverlay(dragOffset: $dragOffset)
    }
}

#Preview("Sidebar Overlay") {
    LitterPreviewScene(
        serverManager: LitterPreviewData.makeSidebarManager(),
        appState: LitterPreviewData.makeAppState(sidebarOpen: true)
    ) {
        SidebarOverlayPreviewHost()
    }
}
#endif
