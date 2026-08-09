import SwiftUI

struct NewRoomScanCapabilityView: View {
    let capabilityProvider: any DeviceCapabilityProviding
    let onOpenCapture: () -> Void
    let onOpenMockReview: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("NEW ROOM SCAN")
                    .font(AppTypography.measurement)
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.amber)

                Text(capabilityProvider.supportStatus.title)
                    .font(AppTypography.editorial)
                    .foregroundStyle(AppPalette.ink)
                    .accessibilityIdentifier("newScan.title")

                CapabilitySupportCard(status: capabilityProvider.supportStatus)

                Text("No camera or AR session starts here. The fixture review is an explicit local-package exercise, not a capture substitute.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                AdaptiveActionRow(alignment: .leading, spacing: 12) {
                    if capabilityProvider.supportStatus.canStartLiveCapture {
                        Button(action: onOpenCapture) {
                        Label("Open capture canvas", systemImage: "viewfinder.circle")
                            .font(AppTypography.bodyEmphasized)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppPalette.primaryAction)
                        .accessibilityIdentifier("newScan.openCapture")
                    }

                    Button(action: onOpenMockReview) {
                        Label("Review MockRoom-v1", systemImage: "cube.transparent")
                            .font(AppTypography.bodyEmphasized)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.blueprint)
                    .accessibilityIdentifier("newScan.openMockReview")
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppPalette.paper.ignoresSafeArea())
        .navigationTitle("New Room Scan")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CapabilitySupportCard: View {
    let status: DeviceSupportStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(accent)
                Text(status.title)
                    .font(AppTypography.bodyEmphasized)
            }

            Text(status.detail)
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedOnDark)
                .fixedSize(horizontal: false, vertical: true)

            if case .fixtureMode = status {
                Text("Fixture mode is a safe preview path, not a substitute for capture validation.")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amberOnDark)
            } else if !status.sceneMeshAvailable {
                Label(
                    "Raw mesh is unavailable and will be recorded as an omission; RoomPlan capture remains available.",
                    systemImage: "cube.transparent"
                )
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.amberOnDark)
                .accessibilityIdentifier("capture.meshUnavailable")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.captureBlack, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .foregroundStyle(AppPalette.primaryOnDark)
    }

    private var symbol: String {
        switch status {
        case .captureAvailable:
            return "checkmark.seal.fill"
        case .fixtureMode:
            return "cube.transparent"
        }
    }

    private var accent: Color {
        switch status {
        case .captureAvailable:
            return AppPalette.blueprintOnDark
        case .fixtureMode:
            return AppPalette.amberOnDark
        }
    }
}
