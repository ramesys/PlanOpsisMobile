# Changelog

## 12.3 — Professional editing and DXF viewer

### DXF tab
- **View any DXF, not only PlanOpsis drawings.** *Open DXF…* shows drawings from AutoCAD, Rhino or an
  architect without importing them: blocks (nested, rotated, scaled, arrayed, mirrored), arcs and bulged
  polylines, circles, ellipses, splines, TEXT and MTEXT, dimensions, solid and patterned hatches, solids
  and leaders, with layer colours and line weights. Paper space and unsupported entities are listed
  under *Drawing notes* instead of disappearing silently. The project's own drawing uses the same viewer.
- **Pan, pinch and deep zoom** with a fixed camera (Fit returns to the whole drawing).
- **Layers.** Show, hide, isolate and search layers; layers that are off or frozen in the file start
  hidden. Each drawing remembers its layer state.
- **Inspect.** Tap an object for its type, layer, block, length, angle, radius, area or text; PlanOpsis
  objects show their class and ID.
- **Measure with object snaps.** Distance (with ΔX, ΔY and angle), chained length, and area with
  perimeter. Snaps: endpoint, midpoint, intersection, centre, quadrant, perpendicular, insertion, node
  and (optional) nearest. Touch and hold for a precision cursor above the finger with a live snap marker.

### DXF layers by IFC class
- **Every element is on the layer of its IFC class:** IfcWall, IfcDoor (leaf and swing), IfcWindow,
  IfcOpeningElement, IfcSpace, IfcColumn, IfcBeam, IfcFurnishingElement and IfcSanitaryTerminal, the same
  classes the IFC4 export writes. Dimensions go to IfcAnnotation-Dimensions, room names and areas to
  IfcAnnotation, and wall axes to IfcWall-Axis (off and not plotted).
- **Rhino drawings keep the classification inside blocks.** Door, window and furniture symbol geometry
  used to sit on layer 0 inside its block; it now carries its IFC class layer, so exploding a block in
  Rhino keeps it classified, and dimension blocks stay on the dimension layer.
- The previous CAD discipline layers (A-WALL, A-DOOR, A-DOOR-SWNG, S-COLS, P-FIXT…) remain available
  under *DXF layers* in the project menu and the survey settings. Files exported with either naming
  import back.

### Plan editing
- **Object snaps while editing.** Wall grips and wall drawing snap to wall axes (endpoint, midpoint,
  intersection, perpendicular), component centres and the DXF underlay, with the snap shown on the plan.
  Polar tracking keeps directions on 15° steps unless Ortho is on.
- **Draw walls as a chain.** Each tap adds a wall from the last corner; returning to the first corner
  closes the outline; *Done* finishes. Type a length (`3450`), length and angle (`3450<90`), relative
  (`@1200,-300`) or absolute (`#5000,2000`) point instead of tapping.
- **Push/pull walls.** Drag the arrow grip in the middle of a selected wall to move it parallel to
  itself; connected walls and T-junction walls stretch with it and openings stay put. Moves that would
  collapse a wall or push a door off its wall are refused.
- **Slide doors and windows** along their wall with the grip on a selected opening; the clear distances
  to both wall ends show while dragging and round to 10 mm (or the grid).
- **Edit dimensions by value.** Tap a wall or opening dimension (or the length label of the selected
  wall), type the size, and choose which end stays for walls.
- **Box selection.** Touch and hold the plan, then drag: to the right selects what is fully inside
  (window), to the left what is touched (crossing). The selection menu adds *Select all*, *Connected
  walls* and *Similar objects*.
- **DXF underlay.** The DXF opened in the viewer can be shown faded under the plan (scaled to
  millimetres), centred, moved and rotated, and snapped to.
- **iPad keyboard:** ⌘Z / ⇧⌘Z undo and redo, ⌘⌫ delete, ⌘A select all, Esc cancels, ⌥⌘W draws walls.

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
