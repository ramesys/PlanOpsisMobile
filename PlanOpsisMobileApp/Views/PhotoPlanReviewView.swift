#if os(iOS)
import SwiftUI

/// v12.10 what the photo was read as, right after the plan is built: keep it, fix the scale (the plan
/// rebuilds to it), or take it out again.
struct PhotoPlanReviewView: View {
    @ObservedObject var store: PlanOpsisMobileStore
    let review: PhotoPlanReview

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
                        tile(review.walls, "Walls", "square.split.bottomrightquarter")
                        tile(review.rooms, "Rooms", "square.split.2x2")
                        tile(review.doors, "Doors", "door.left.hand.open")
                        tile(review.windows, "Windows", "window.casement")
                        if review.doorways > 0 { tile(review.doorways, "Doorways", "rectangle.portrait") }
                        if review.stairs > 0 { tile(review.stairs, "Stairs", "stairs") }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text(review.wallStyle == .filled ? "Walls read from solid strokes." : "Walls read from double lines.")
                }
                if !review.roomNames.isEmpty {
                    Section("Room names read") {
                        Text(review.roomNames.joined(separator: " · "))
                    }
                }
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scale \(review.scale)")
                            Text(String(format: "1 px = %.1f mm", review.millimetresPerPixel))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: review.scaleIsMeasured ? "ruler" : "exclamationmark.triangle")
                            .foregroundStyle(review.scaleIsMeasured ? Color.accentColor : .orange)
                    }
                    Button { store.fixPhotoScale() } label: { Label("Fix the scale", systemImage: "ruler") }
                } footer: {
                    Text(review.scaleIsMeasured
                         ? "Taken from the plan. Check one wall you know; Fix the scale if it is off."
                         : "No dimensions were read, so the scale is a rule of thumb. Measure one known dimension to set it.")
                }
                Section {
                    Button(role: .destructive) { store.discardPhotoPlan() } label: { Label("Remove this plan", systemImage: "arrow.uturn.backward") }
                } footer: {
                    Text("The photo stays under the plan: edit walls, doors and windows directly, or trace more by tapping them.")
                }
            }
            .navigationTitle("Plan from photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Looks right") { store.photoReview = nil }
                }
            }
        }
    }

    private func tile(_ count: Int, _ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(count > 0 ? Color.accentColor : .secondary)
            Text("\(count)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
#endif
