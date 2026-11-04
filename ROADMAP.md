# Roadmap

Where PlanOpsis Mobile goes after version 12.10. The roadmap is in three horizons:

- **Now**: started next.
- **Next**: once Now lands.
- **Later**: worth doing and not yet scheduled.

There are no dates. Items move between horizons as priorities change.

The first two priorities are **field accuracy** (surveys you can trust on site) and **BIM and
exchange** (models an architect's office can use without rework). Plans from photos and PDFs,
release and platforms follow.

For what exists today, see [README.md](README.md) and [CHANGELOG.md](CHANGELOG.md). For where code
for each item would go, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Now

### 1. Bluetooth laser distance meters
**Goal:** a measured distance goes into the model without typing.

- Pair Leica DISTO and Bosch GLM meters over Bluetooth LE (Core Bluetooth). The app-side service is
  injected into the store, like the PDF and photo loaders.
- A reading applies to the selected target: wall face, thickness, opening width, or point-to-point.
  It is recorded as a survey observation tagged with the instrument it came from.
- Readings that disagree with the model by more than a tolerance are flagged, not applied silently.
- **Done when:** a surveyor can measure a room's faces and openings with a meter alone, and every
  measurement shows in the survey record with its source.

### 2. Global survey solver (v13)
**Goal:** measurements fix the whole model consistently, not one wall at a time.

- Least-squares adjustment over all observations: wall faces, thicknesses, openings and distances.
  Locked measurements are hard constraints.
- It places the faces RoomPlan saw from one side only (partitions), closes room loops, and keeps
  shared walls consistent between rooms.
- A residuals report shows each measurement's fit and points to outliers.
- **Done when:** a multi-room survey with redundant measurements converges and reproduces every
  locked measurement within 1 mm, with tests on synthetic projects that have known errors.

### 3. Storeys, slabs and ceilings in the model and IFC
**Goal:** the IFC holds the building's vertical structure, not one storey of walls.

- Levels: each room belongs to a storey with its elevation and floor-to-floor height. The capture's
  floor elevation is kept as provenance.
- Floor and ceiling slabs from room boundaries (`IfcSlab`, `.FLOOR` / `.BASESLAB`), and ceiling
  coverings (`IfcCovering`).
- Multiple `IfcBuildingStorey` instances, and stairs related to the storeys they connect.
- **Done when:** a two-storey project exports an IFC that opens in Revit, ArchiCAD and BlenderBIM with
  correct storeys, slabs and stairs, checked by golden-file tests.

### 4. IFC round-trip validation
**Goal:** architects can rely on the IFC without fixing it.

- A test corpus of PlanOpsis exports, opened and re-exported through Revit, ArchiCAD and
  BlenderBIM / IfcOpenShell. The differences are recorded and fixed at the source.
- IFC schema validation in CI (IfcOpenShell's validator in a Linux job).
- Clean round trips of property sets and quantities (`Pset_*`, `Qto_*`).
- **Done when:** the corpus validates in CI and the known differences per program are documented.

---

## Next

### 5. Multi-room capture and partial rescans
- Stitch several RoomPlan sessions into one structure.
- Rescan one room and merge it into an existing project, keeping its measurements and edits.
- Detect and reconcile rooms that overlap or double up.

### 6. True geometry for sloped ceilings, curved walls and columns
- Non-rectangular walls as profiles (under a sloped ceiling), not full rectangles.
- Curved walls as arcs in the model, the DXF and the IFC.
- Free-standing and engaged columns from scans and drawings.

### 7. Building services points
- Sockets, switches, lights, radiators and data points placed on wall faces at a height.
- Schedules of the points, DXF layers (`E-POWR`, `E-LITE`…) and IFC classes (`IfcOutlet`,
  `IfcSwitchingDevice`, `IfcLightFixture`, `IfcSpaceHeater`).

### 8. Review with architects (BCF)
- Raise issues on walls, openings or rooms, with a viewpoint and a photo.
- Export and import BCF, so comments travel with the IFC to and from BIM tools.

### 9. IFC 4.3 and AR export
- An IFC 4.3 export option alongside IFC4.
- USDZ and glTF exports of the 3D model, for AR Quick Look and web viewers.

---

## Later

### Plans from photos and PDFs
- A test set of plans that are made up or used with permission (never client data in the
  repository), with a measured recognition score per release.
- Reading vertical and rotated dimension text, title blocks (scale, project name) and multi-page plan
  sets.
- Symbols for furniture, sanitary fixtures and kitchens; hand-drawn sketches.
- An on-device Core ML model for symbols, trained on that test set.

### Drawings
- Automatic dimension chains on plans; company title-block templates.
- Localisation of the app and the drawing labels (Greek, German, French and more).

### Release and engineering
- Signing in `xcconfig` files, then TestFlight and an App Store release.
- Split `PlanOpsisMobileStore` into feature stores; UI tests in CI.
- DocC documentation for `PlanOpsisCore`; performance work for large projects; an accessibility
  review.

### Collaboration and platforms
- iCloud sync of projects and delivery packages.
- A macOS app and a Linux command-line or server converter. `PlanOpsisCore` already builds on both.
- visionOS: the model overlaid on the real room for checking.
- DWG import and export through an external converter.

---

## How items are delivered

Every roadmap item ships the way the existing releases did:

- **Logic in the core.** It goes in `PlanOpsisCore` with tests; the app only adds UI and platform
  services.
- **Synthetic test data.** Tests use made-up projects and plans, never real client data (see
  [CONTRIBUTING.md](CONTRIBUTING.md)).
- **Compatibility.** Older projects still open: new fields decode with defaults.
- **Documented.** Each release has a CHANGELOG section saying what changed and why.

## Suggesting changes

Open an issue describing the problem it solves and who it is for: surveyors on site, architects
receiving the files, or developers extending the code. Proposals that move an item between horizons
are welcome too.
