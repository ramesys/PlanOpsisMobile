# Changelog

## 12.2 — Accuracy from real scans

Validated against a real RoomPlan capture (kept as a regression fixture).

### Capture → model
- **Wall faces, not centrelines.** RoomPlan wall surfaces are the scanned room-side faces (their +Z axis
  points into the room). Walls are now placed half a thickness behind the face, with corners re-joined
  on the wall axes; rooms were previously one wall thickness too small per axis. Inside faces now match
  the scan to the millimetre, except next to partitions RoomPlan saw from one side only.
- **Irregular walls are imported.** Curved and non-rectangular walls (e.g. under a sloped ceiling) come
  in as straight walls with a review warning instead of being dropped and blocking export.
- **Short jogs survive.** Corner joining never merges both ends of a wall or reaches beyond half its
  length, so piers and reveals (here 146–424 mm) are kept.
- Walls record which side faces their room when the scan observed it.

### Survey
- **Measure what you can tape.** Field measurements are wall *face* lengths, inside or outside, corner to
  corner (L-corners, T-junctions and straight continuations handled). Corrections adjust the wall until
  the face has the measured length. Axis-length records stay valid.

### Projects
- **Project library with autosave.** Every project is kept in *Projects* (… menu) and saved
  automatically after each change, before a new scan or import replaces it, and when the app goes to
  the background. Projects can be named, opened and deleted. The old single saved project is imported
  once and its file is kept.

### Fixes
- **DXF export is never silently greyed out.** If something blocks export, the button opens the drawing
  review explaining what to fix.

### Behaviour changes to note
- Real scans now produce larger rooms (by one wall thickness per axis) than 12.1 did for the same
  capture. Re-import an earlier scan from its retained capture to get the corrected geometry.
- "Save project" / "Reopen project" are replaced by *Projects…* and *Save now*.

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
