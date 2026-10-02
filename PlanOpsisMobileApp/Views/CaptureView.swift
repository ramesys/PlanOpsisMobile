#if os(iOS)
import SwiftUI
import RoomPlan
import UIKit

struct CaptureView: View {
    @ObservedObject var service: RoomPlanCaptureService
    @State private var scannerRequested = false
    let loadSingleMock: () -> Void
    let loadMultiRoomMock: () -> Void

    var body: some View {
        #if targetEnvironment(simulator)
        simulatorWorkspace
        #else
        deviceCaptureWorkspace
        #endif
    }

    #if targetEnvironment(simulator)
    private var simulatorWorkspace: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 18) {
                Image(systemName: "square.3.layers.3d.top.filled")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("Simulator workspace")
                        .font(.title3.weight(.semibold))
                    Text("LiDAR capture runs only on a supported physical device. Load deterministic room data here to test Plan, 3D, DXF, editing, and the Liquid UI.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    Button {
                        loadSingleMock()
                    } label: {
                        Label("Open 1-Room Mock", systemImage: "square")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        loadMultiRoomMock()
                    } label: {
                        Label("Open 2-Room Mock", systemImage: "square.split.2x1")
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 430)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PlanOpsisPalette.workspace)
    }
    #else
    private var deviceCaptureWorkspace: some View {
        Group {
            if service.isSupported {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if scannerRequested || service.isStructureCaptureActive {
                            RoomCaptureRepresentable(
                                service: service,
                                onReady: {
                                    guard scannerRequested,
                                          !service.isStructureCaptureActive else { return }
                                    service.startStructure()
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                        } else {
                            scannerStandby
                        }

                        if service.isScanning {
                            scanBadge
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                    }

                    capturePanel
                }
            } else {
                ContentUnavailableView(
                    "LiDAR unavailable",
                    systemImage: "viewfinder",
                    description: Text("RoomPlan requires a LiDAR-capable iPhone or iPad.")
                )
            }
        }
        .transaction { transaction in
            // Keep the capture surface deterministic and avoid animation/compositing churn.
            transaction.animation = nil
        }
        .onDisappear {
            // A RoomCaptureView owns an ARSession and Metal-backed camera surface. Never allow
            // those resources to survive outside the Scan workspace.
            service.cancelStructure()
            scannerRequested = false
        }
    }
    #endif


    private var scannerStandby: some View {
        VStack(spacing: 14) {
            Image(systemName: "viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Scanner ready")
                .font(.headline)
            Text("The LiDAR camera starts only when you press Start Scan. This keeps RoomPlan and its Metal surface unloaded while PlanOpsis is idle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.94))
    }

    private var scanBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text("Scanning")
                .font(.caption.weight(.semibold))
            if service.capturedRoomCount > 0 {
                Text("Room \(service.capturedRoomCount + 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Intentionally opaque while RoomPlan is live: no glass/material above the Metal camera.
        .background(Color(uiColor: .systemBackground).opacity(0.96), in: Capsule())
    }

    private var capturePanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(captureTitle)
                        .font(.headline.weight(.semibold))
                    Text(captureSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if service.isProcessingRoom || service.isBuildingStructure {
                    ProgressView()
                        .controlSize(.regular)
                }
            }

            if let message = service.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            captureControls

        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Color(uiColor: .systemBackground))
    }

    private var captureTitle: String {
        if service.isScanning { return "Capture the room" }
        if service.isProcessingRoom { return "Processing room" }
        if service.isBuildingStructure { return service.capturedRoomCount <= 1 ? "Preparing plan" : "Merging rooms" }
        if service.capturedRoomCount > 0 { return "Room captured" }
        return "LiDAR survey"
    }

    private var captureSubtitle: String {
        if service.isScanning {
            return "Move slowly along the perimeter. Hold corners, doors, and windows in view."
        }
        if service.isProcessingRoom { return "Converting RoomPlan evidence into PlanOpsis semantics." }
        if service.isBuildingStructure { return "Generating a clean architectural model for review and DXF." }
        if service.capturedRoomCount > 0 { return "Continue to another room or finish the structure." }
        return "Scan first, then clean and edit the architectural drawing."
    }

    @ViewBuilder
    private var captureControls: some View {
        if service.isProcessingRoom || service.isBuildingStructure {
            Button("Cancel", role: .cancel) {
                cancelCapture()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if service.isScanning {
            HStack(spacing: 8) {
                Button {
                    service.finishRoom()
                } label: {
                    Label("Finish Room", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Menu {
                    Button("Finish Structure", action: service.finishStructure)
                    Button("Cancel Scan", role: .destructive) { cancelCapture() }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Scan options")
            }
        } else if service.capturedRoomCount > 0 {
            HStack(spacing: 8) {
                Button {
                    service.startNextRoom()
                } label: {
                    Label("Next Room", systemImage: "plus.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    service.finishStructure()
                } label: {
                    Label("Finish", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button {
                // Mount Apple's RoomCaptureView first. `onReady` starts the RoomPlan session after
                // the representable owns a live view, avoiding a race with startStructure().
                scannerRequested = true
            } label: {
                Label("Start Scan", systemImage: "viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!service.isSupported)
        }
    }

    private func cancelCapture() {
        service.cancelStructure()
        scannerRequested = false
    }
}

private struct RoomCaptureRepresentable: UIViewRepresentable {
    let service: RoomPlanCaptureService
    let onReady: () -> Void

    final class Coordinator {
        let service: RoomPlanCaptureService
        init(service: RoomPlanCaptureService) { self.service = service }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(service: service)
    }

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.backgroundColor = .black
        // Limit the camera view's backing resolution on 3x displays. RoomPlan geometry and LiDAR
        // capture quality are independent of this UI compositing scale, while the drawable footprint
        // is materially smaller on memory-constrained devices.
        view.contentScaleFactor = min(view.traitCollection.displayScale, 2.0)
        context.coordinator.service.attachCaptureView(view)
        DispatchQueue.main.async { onReady() }
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // Published scan state updates the external SwiftUI controls only.
    }

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: Coordinator) {
        // The default stop path pauses the underlying ARSession. Explicitly pause it again before
        // detaching so no camera/AR callbacks can keep the Metal surface alive during navigation.
        uiView.captureSession.stop()
        uiView.captureSession.arSession.pause()
        uiView.delegate = nil
        coordinator.service.detachCaptureView(uiView)
    }
}
#endif
