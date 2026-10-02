# Changelog

## 12.1 — Stabilise

Makes real captures exportable, keeps edits from silently moving architecture, and makes the
editable model, drawing and IFC agree on room closure.

### Capture → model
- **RoomPlan sills are measured from the room floor.** ARKit's world origin is the device's start
  height, so sills came out about −1.4 m and real scans could not be exported. Each room's floor is
  now the median wall bottom (kept as `captureFloorElevationMM` provenance).
- **Overhanging RoomPlan openings are clamped to their host wall**; observations mostly off the wall
  are not imported (`openingMostlyOutsideHost`).
- **Near-coincident wall junctions are closed in the model** (`JunctionNormalizer`, ≤160 mm) on
  RoomPlan and PLY import, and with the Inspector command *Close wall junctions*.
- **Raw RoomPlan captures are retained** as hashed `roomPlanCapture` evidence and travel in delivery
  packages; `CaptureEvidence.replay` re-runs reconstruction on them.

### Editing
- Moving a wall's start (grip, measured correction anchored at the end, Rhino return) no longer slides
  its doors and windows; edits that would push an opening off its wall are refused.
- Deleting a measured wall or opening removes its measurements and dimension placements and unlinks
  photos; locked measurements block the delete with an explanation.
- The plan camera no longer refits while you edit; pinch zoom keeps the pinched point fixed.
- One tolerance table (`GeometryTolerances`) replaces the 1/2/140/160 mm literals.

### Drawing and exchange
- IfcSpace bodies use the clear interior (same construction as the DXF A-SPACE), carry the surveyed
  room name as LongName and report `Qto_SpaceBaseQuantities.NetFloorArea`.
- Drawing preview, plan annotations and export readiness are derived once per change
  (`ProjectDerivation`) instead of on every view refresh.
- Fixed non-deterministic ordering of host IDs on reconciled passage jambs in the drawing preview.

### Engineering
- `PlanOpsisCore` builds and tests on Linux (portable SHA-256 fallback; PDF sheets only where CoreText
  exists). GitHub Actions run core tests on Linux and macOS and build the iOS app for the simulator.

### Behaviour changes to note
- An opening on a wall whose start moves keeps its distance from the wall's *end*; previously it kept
  its distance from the moved start.
- `Survey.pdf` is optional when reading a delivery package (it is still written on Apple platforms).

### Still to verify on device
- The RoomPlan floor-datum fix is derived from ARKit's documented world origin and validated with a
  shifted mock; confirm with one real capture.
- UI changes (plan camera, Inspector command, store wiring) are covered by the CI simulator build,
  not by automated UI tests.
