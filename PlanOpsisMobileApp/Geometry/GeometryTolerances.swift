import Foundation

/// v12.1 single source for plan-geometry tolerances (millimetres).
///
/// Before v12.1 the junction tolerance was 1, 2, 140 or 160 mm depending on which subsystem asked, so a
/// room could be "closed" for drawing and IFC spaces while editing treated its corners as disconnected.
/// Capture adapters now close junctions within `junctionJoinMM` in the semantic model itself
/// (`JunctionNormalizer`), after which every subsystem agrees on `coincidenceMM`.
public enum GeometryTolerances {
    /// Wall endpoints at most this far apart are one junction for editing and topology guards.
    public static let coincidenceMM = 1.0
    /// Capture-evidence join radius: endpoints this close describe the same physical corner. Used by
    /// `JunctionNormalizer` and, for models that were never normalised, by display/topology clustering.
    public static let junctionJoinMM = 160.0
    /// Interactive endpoint snap radius while drawing or dragging.
    public static let endpointSnapMM = 140.0

    /// v12.2 join radius for one wall's endpoints: never more than half the wall's own length, so a short
    /// real jog (pier, reveal, chimney breast) cannot collapse into a single junction.
    public static func joinRadius(_ radius: Double, wallLength: Double) -> Double {
        min(radius, max(0, wallLength * 0.5 - coincidenceMM))
    }
}
