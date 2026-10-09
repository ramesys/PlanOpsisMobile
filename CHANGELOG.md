# Changelog

## 12.10 — Smart plan from a photo

- **Straight to a plan, like a scan:** photograph or pick a paper plan and the plan is built at once.
  You get walls, doors, windows, doorways, stairs and the rooms they close, with names read from the
  photo. A review card then shows what was found and how the scale was set.
- **What it recognises:**
  - **Walls**, drawn solid (poché) or as two face lines. Thin lines inside a wall (glazing carried
    through) stay part of the wall.
  - **Doors**, from the quarter-circle swing at a jamb. The hinge side and opening side become the
    door's hand; two half swings make a double door. This also works for doors next to a corner,
    where the wall stops short of the wall across.
  - **Windows**, from glazing lines across a wall gap, or between the two faces of an outline wall.
  - **Doorways**: a clean gap of door size becomes an opening, so the rooms either side still close.
  - **Stairs**: five or more evenly stepped treads become a stair object with its width and run. A
    tile grid is not taken for stairs.
- **No calibration needed in most cases:** the scale is read from the plan's dimension figures
  ("3500", "3.50", "350 cm", 12'-6") and the lines they label. Without readable dimensions it comes
  from the doors (taken as 850 mm), then from the thickest walls (taken as 300 mm). The review card
  says which, and flags a rule-of-thumb scale.
- **Fix the scale** in the review card or the Underlay menu: tap a dimension you know, and the plan
  rebuilds to it if it hasn't been edited since. **Remove this plan** takes it back out in one step.
  **Build plan from photo** reads it again at any time.
- The photo stays faded under the plan for checking and editing. The plan exports to DXF and IFC like
  any other.

## 12.9 — Plan from a photo

- **Photograph a paper plan:** in Drafting aids → Underlay, **Plan from photo** opens the document
  camera (**Scan with camera**) or the photo library (**Choose photo**). The empty project screen
  offers the same. A blank project is started when none is open.
  - A sheet shot at an angle is found and squared up; the document camera does this as it scans.
  - Uneven light and shadows are evened out, and a slightly turned sheet is straightened before the
    lines are read, then drawn back over the photo as taken.
- **Walls and lines on PlanOpsis semantic layers:** thick strokes are walls on IfcWall / A-WALL,
  thin strokes (dimensions, fixtures, hatching edges) lines on IfcAnnotation / A-ANNO, and the text
  read from the photo goes on A-ANNO-ROOM. The names follow the DXF layer naming setting, so the
  result reads like every other PlanOpsis DXF. Lettering and filled areas are not taken for walls.
- **Calibrate, then build:** a photo has no printed scale, so the underlay opens asking for two
  points and a known distance. **Import all walls** then turns the wall strokes into walls, closed
  loops into rooms, and names the rooms from the text read inside them. From there the plan exports
  to DXF and IFC as usual.
- **Export lines as DXF:** the photo's (or a PDF's or a drawing's) line work straight to an R12 DXF in
  millimetres, placed and calibrated as it shows, on the semantic layers in the chosen naming.
- The straightened photo is saved with the project and read again when it reopens.

## 12.8 — Scanned furniture, fixtures and appliances in the design

- **The scan's objects come in:** everything RoomPlan recognises becomes an editable interior object
  in the room it was scanned in. That covers bed, table, chair, sofa, storage, fireplace, toilet,
  sink, bathtub, refrigerator, stove, oven, dishwasher, washer/dryer, television and stairs.
  - Each object keeps the scanned position, width, depth and height, and turns with the scan.
  - Objects that don't stand on the floor keep their height above it (a TV on the wall, a wall
    cabinet).
  - Backs face the wall, as the plan symbols draw them.
  - The import message counts the objects placed. Categories PlanOpsis does not know yet are noted
    in the review and kept in the capture evidence.
- **A larger object library:** the add menu now has storage, fireplace, bathtub, appliances
  (refrigerator, stove, oven, dishwasher, washer/dryer, television) and stairs. Each has its own
  plan symbol.
- **Fixing misreads:** for any object, the inspector can change its type (RoomPlan may call a
  dresser "storage") and turn it front to back. Objects from the scan show their scan confidence.
  **Remove scanned objects** clears them all as one undoable step; objects placed by hand stay.
- **DXF:**
  - Furniture goes on IfcFurnishingElement / A-FURN and fixtures on IfcSanitaryTerminal / P-FIXT.
  - Appliances go on a new IfcElectricAppliance / A-EQPM layer, and stairs on IfcStair /
    A-FLOR-STRS.
  - Every kind round-trips.
- **IFC:**
  - Appliances are IfcElectricAppliance (FRIDGE_FREEZER, ELECTRICCOOKER, DISHWASHER,
    WASHINGMACHINE).
  - The television is IfcAudioVisualAppliance (TV), the bathtub is IfcSanitaryTerminal (BATH) and
    stairs are IfcStair.
  - Storage and fireplaces are IfcFurnishingElement.
- **3D view:** appliances and stairs have their own colours.

## 12.7 — From an architect's drawing to rooms, and the survey checked against it

### Rooms from walls
- **Closed loops of walls become rooms.**
  - Walls are cut where another wall meets or crosses them, and ends within 30 mm join.
  - Each enclosed area is a room with its own walls (a shared partition belongs to both rooms), plus
    its doors, windows and furniture. Doors that swing in for one room swing out for the other.
  - Stems belong to the room they reach into. Walls that enclose nothing stay together.
- **Import all walls** now arrives as separate rooms, named from the text in each room (words win
  over area labels) or from the IFC's space names.
- **Detect rooms from walls** in the room menu splits a room you traced into rooms. The room menu
  now shows for a single room too.

### Doors from drawings
- The swing arc gives the door's hinge side and which way it opens. Two half leaves make a double
  door.
- Door and window blocks (DOOR…, FENSTER…, IfcDoor…) mark gaps even without an arc.

### The underlay stays with the project
- The drawing (DXF, IFC or PDF) is saved with the project. Its placement, scale, PDF page, hidden
  layers and visibility come back when the project opens. Moving the underlay adds no undo steps,
  and undoing a model edit leaves the underlay where it is.

### PDF and IFC drawings
- **Vector PDFs:** the page's line work is read from the PDF itself, so PDFs exported from CAD snap,
  align and trace like DXFs. Scanned pages still work as images.
- **Multi-page PDFs:** choose the page shown; it keeps its place and scale.
- **IFC models:** open an architect's IFC in the DXF tab or as an underlay.
  - It shows as walls, openings and named spaces.
  - Import all walls takes the model directly: wall axes, thickness and height, doors and windows
    with sill, height and operation type, and room names.
  - Units can be metres, millimetres, feet or inches.
  - **Walls that are not straight boxes:** an L- or U-shaped wall element is split into its straight
    runs, joined at the corners. Each door or window goes on the run it cuts.
  - **Door swings both ways:** the IFC convention is followed — a door opens towards its local +y,
    and LEFT or RIGHT is the hinge side seen looking that way.
    - Export now turns each door to face the way it opens. Doors were previously always written
      opening to the wall's left.
    - Import reads the hand and side from a door's placement and operation type.
  - **Sliding and pocket doors:** sliding doors are exported as SLIDING_TO_LEFT/RIGHT and pocket
    doors as USERDEFINED "POCKET". Both read back.

### Survey against the drawing
- **Compare with drawing** (Drafting aids, with the drawing aligned) matches each surveyed wall to
  the drawing's walls. The drawing's walls come from the IFC model, the DXF's wall layers or the
  PDF's lines.
  - For each wall: the offset and which way, the largest deviation at its ends (so a turned wall
    shows), the angle, and the thickness and length difference.
  - Doors and windows are compared by position and width.
  - Anything that is only in the survey, or only in the drawing, is listed.
- **On the plan:** each wall is marked green (≤ 20 mm), orange (≤ 50 mm) or red, and drawing walls
  nobody surveyed are dashed purple.
- **Report:** a sheet with totals and every row (tap a wall to select it), plus a CSV export.
- The comparison follows model edits.

## 12.6 — Plan-ordered numbering and architects' files

### Numbering follows the plan, not capture order
- Rooms are numbered in reading order: north to south, west to east within a row. Walls are numbered
  clockwise around each room, starting at the north-west, with the room outline before any partitions
  inside it. Openings follow their wall and run clockwise along it. Plan +Y is north.
- **IFC:** spaces, walls, doors, windows and openings are written in this order. Spaces are named
  *Room 1…*, walls *Wall 01…*, and doors, windows and openings carry their schedule mark (D01, W01, O01)
  as Name and Tag, so the model tree in any IFC viewer reads in sequence.
- Schedule marks, room numbers, DXF room labels, interior elevation numbers, the room menus and the
  inspector (*Wall 07 · mm*) all use the same numbers. Numbers change only when the geometry does.

### Working with architects' files
- **Align by two points** (Drafting aids ▸ Underlay): tap two points on the underlay, then where they
  belong on the plan. Underlay picks snap to the drawing and plan picks to the model. The underlay
  turns and moves onto them. If the two distances differ by more than 2 %, you choose whether to
  scale the drawing to fit (wrong units) or keep its scale (approximate picks).
- **Calibrate scale:** tap two points on the underlay and enter their real distance.
- **PDF underlay:** the first page of a PDF drawing is placed at its paper size, assumed 1:100, with
  calibration starting straight away. A scale picker (1:20 … 1:500) is also available. The page is
  inverted in dark mode.
- **Trace walls:** tap inside a wall on a DXF underlay, between its two lines. A wall of that thickness
  is added on the axis, joined to the walls it meets.
- **Import all walls** from a DXF's wall layers (IfcWall, A-WALL, WALL, MUR, WAND…; not axis or hatch
  layers):
  - Double lines 50–700 mm apart become walls, joined at corners and T-junctions.
  - Gaps with a door swing or window glazing become doors and windows.
  - With no project open this starts one; otherwise the walls arrive as a new room.
  - Also available from the DXF tab's drawing menu and the empty plan.
- **Blank plan:** start an empty project to draw or trace over a drawing. An empty plan fits the
  underlay.

## 12.5 — Quantities, area plan and reflected ceiling plan

### Quantities and finishes
- **Quantity takeoff** from the model, shown with the schedules (Sheets ▸ Schedules), on the drawing
  set and in the CSV export:
  - **Room quantities:** floor and ceiling area, perimeter, wall faces gross, openings and net, skirting
    length (perimeter less door widths) and volume, with totals across rooms.
  - **Opening quantities:** area, lintel length (150 mm bearing each side) and reveal area per mark.
  - **Wall quantities** by thickness: length, net side area and net volume.
- **Finishes per room** (floor, walls, ceiling, skirting) in the inspector, with common choices one tap
  away. The *Finishes* table lists them by room and *Finish totals* sums the areas and lengths per
  material — ready for ordering paint, flooring or skirting.
- **IFC base quantities:** Qto_SpaceBaseQuantities (net floor, ceiling and wall areas, perimeter,
  height, volume), Qto_WallBaseQuantities, Qto_DoorBaseQuantities and Qto_WindowBaseQuantities, so
  cost and BIM tools read the same numbers.

### New sheets
- **Area plan:** rooms filled in light colours with name and clear area, and a legend with the total
  net floor area.
- **Reflected ceiling plan:** walls with opening heads dashed, boxed ceiling heights (CH +2.80) and the
  ceiling finish per room.
- Both can be switched off, as can the quantity tables, in the drawing set settings.

## 12.4 — Drawing set: sheets, schedules, elevations and sections

### Sheets tab
- **A printable drawing set from the model.** A new *Sheets* tab lays out the floor plan, the
  schedules, an interior elevation of every wall and any sections on A4–A1 sheets, each with a frame
  and a title block (project, site/client, drawing, scale, date, author, revision, sheet n / N).
  Tap a sheet to zoom and page through the set; export it as a vector PDF at true paper size.
- **Plan sheet:** the largest standard scale that fits the paper (or the one you choose), door and
  window tags, section marks, north arrow and scale bar.
- **Interior elevations:** each wall seen from inside its room, adjacent walls cut at the corners,
  doors and windows as openings with their marks, chain and overall dimensions, sill/head/ceiling
  heights and level marks, titled with the direction the wall faces.
- **Sections:** draw a cut on the plan (*Add ▸ Documentation ▸ Section line*, two taps). Walls on the
  cut are filled, walls beyond are drawn behind, with clear widths, overall length and height.
- **Settings:** title block fields, paper, plan and elevation scales, which parts to include, and the
  section list (flip the viewing direction or delete) — saved with the project.

### Schedules and marks
- **Door, window and opening schedules and a room schedule** (clear floor area, perimeter, height,
  door and window counts, glazing area and ratio). Doors are marked D01…, windows W01…, openings O01…;
  a door captured from both rooms is one entry with one mark.
- Marks are tagged on the plan (doors circled, windows boxed; *Door & window tags* in the
  Documentation menu), shown in the inspector, on elevations, in the drawing and in the DXF
  (IfcAnnotation-Tags). The inspector also shows the room's schedule line.
- Schedules as native tables in the Sheets tab and as CSV for Numbers or Excel.
- Room labels on drawings use the room's name when it has one.

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
