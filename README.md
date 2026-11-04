# PlanOpsis Mobile

**Measured architectural surveys on an iPhone or iPad: scan a room, or photograph or import a plan,
and get an editable building model, a drawing set, and DXF and IFC files ready for CAD and BIM.**

[![CI](https://github.com/ramesys/PlanOpsisMobile/actions/workflows/ci.yml/badge.svg)](https://github.com/ramesys/PlanOpsisMobile/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

PlanOpsis turns what a surveyor already has on site into a semantic model: a LiDAR scan, a point
cloud, an architect's DXF, IFC or PDF, or a photo of a paper plan. In that model, walls, doors,
windows, rooms, stairs and furniture are real objects with dimensions. Every drawing and export is
derived from the model, so the plan, the schedules, the DXF and the IFC always agree.

- Version: **12.10** (see [CHANGELOG.md](CHANGELOG.md))
- Swift 6 toolchain, SwiftUI, iOS 17+
- About 41,000 lines of Swift; 350 automated tests run on Linux and macOS on every push
- No third-party dependencies, no accounts, no network access

---

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Getting started](#getting-started)
- [Running the tests](#running-the-tests)
- [Repository layout](#repository-layout)
- [Architecture](#architecture)
- [File formats and standards](#file-formats-and-standards)
- [Privacy, data and security](#privacy-data-and-security)
- [Further development](#further-development)
- [Contributing](#contributing)
- [License](#license)

---

## What it does

### Capture

- **LiDAR room scanning** with Apple RoomPlan. It captures single rooms or whole structures, with
  walls registered as interior faces and sills measured from the room floor. Raw captures are
  retained, so the model can be rebuilt from them later.
- **Scanned objects become design objects.** Beds, tables, sofas, storage, sanitary fixtures,
  kitchen appliances, a television and stairs are placed in the room they were scanned in, at the
  scanned size and orientation.
- **PLY point clouds** are imported. Their wall candidates, sections and QA (support, residuals) are
  reviewed before a room is created.
- **Plan from a photo.** Photograph a paper plan, or pick a photo, and PlanOpsis builds the plan
  directly:
  - The sheet is straightened and the photo's light evened out.
  - Walls are recognised whether drawn solid or as two lines.
  - Doors are read from their swing arcs, including the hand they open to.
  - Windows are read from glazing lines; plain gaps become doorways.
  - Stairs are read from evenly spaced treads, and room names from the photo's text.
  - The scale is taken from the plan's dimension figures, else from its doors or walls.

### Model and editing

- A semantic model of walls, openings (doors with swing and operation, windows, doorways),
  interior components and rooms, with wall junctions resolved at corners and T-junctions.
- Direct editing tools:
  - drawing, grips, typed dimensions, and move / rotate / mirror / offset / trim / extend;
  - polar tracking and object snaps;
  - undo and redo.
- Survey measurements (wall faces, wall thicknesses, opening widths, point-to-point and projected
  distances) that correct the model and can be locked.
- **Rooms from walls.** Closed wall loops become rooms, named from the drawing's text.

### Drawings and documentation

- Floor plan, area plan and reflected ceiling plan.
- Interior elevations of every wall, and sections.
- Door, window and opening schedules, room quantities and finishes, with takeoff in CSV.
- **Drawing sets.** Sheets from A4 to A1 with a title block, exported as a vector PDF at true paper
  size.
- Numbering follows the plan's orientation (rooms, doors and windows in reading order) and is the
  same in the app, the schedules, the DXF and the IFC.

### Working from an architect's drawing

- **DXF viewer.** It shows blocks, arcs, splines, text, dimensions and hatches, with layers, snaps
  and measurement.
- **Underlays.** A DXF, IFC, PDF (raster and vector) or photo can sit under the plan. You align it by
  two points, calibrate its scale, then trace walls by tapping or import them all with their doors
  and windows.
- **Deviation report.** The survey is compared with the drawing wall by wall and opening by opening,
  and the report exports to CSV.

### Exchange

- **DXF.** Layers follow PlanOpsis's semantic convention, in your choice of IFC-class names
  (`IfcWall`, `IfcDoor`…) or discipline names (`A-WALL`, `A-DOOR`…). DXF files can be edited and
  re-imported (round trip).
- **IFC4.** Walls, doors, windows, spaces, furnishing elements, sanitary terminals, appliances and
  stairs, with quantity sets (`Qto_*`). An architect's IFC can be read back as walls and rooms.
- **Survey delivery packages**: the model, its measurements and evidence, hash-verified.

## Requirements

| To | You need |
|---|---|
| Build and run the app | macOS with Xcode 26 or later (the app uses iOS 26 APIs behind availability checks; its deployment target is iOS 17) |
| Scan rooms | An iPhone or iPad with LiDAR (iPhone 12 Pro or later "Pro" models, iPad Pro 2020 or later) |
| Everything else | Any iPhone or iPad on iOS 17+, or the iOS Simulator. The app includes deterministic sample projects |
| Build and test the core library | Swift 6.0 or later on macOS 14+ or Linux |

## Getting started

```sh
git clone https://github.com/ramesys/PlanOpsisMobile.git
cd PlanOpsisMobile
open PlanOpsisMobile.xcodeproj
```

1. In Xcode, select the **PlanOpsisMobile** target, then **Signing & Capabilities**. Choose your own
   development team, and change the bundle identifier if needed.
2. Pick a LiDAR device to scan, or any device or simulator to try the rest.
3. Run. With no device to scan with, open a sample project from the **Scan** tab (**Open 1-Room
   Mock** or **Open 2-Room Mock**). You can also import the PLY files in [`Samples/`](Samples) or photograph any
   paper plan.

No configuration, keys or accounts are needed. [`.env.example`](.env.example) explains where
configuration would go if a future integration needs some.

## Running the tests

The app's logic lives in a Swift package target, `PlanOpsisCore`, which builds without UIKit, so it
can be tested on Linux:

```sh
swift build --build-tests
swift test --parallel
```

The app itself is built with Xcode:

```sh
xcodebuild build -project PlanOpsisMobile.xcodeproj -scheme PlanOpsisMobile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

[CI](.github/workflows/ci.yml) runs three checks on every push and pull request:

- core tests on Linux (`swift:6.0-noble`);
- core tests on macOS (which adds CryptoKit and the PDF paths);
- an unsigned iOS Simulator build of the app.

Tests use synthetic data: generated rooms and plan images, mock RoomPlan captures, and the sample PLY
files. See [Privacy, data and security](#privacy-data-and-security).

## Repository layout

```
PlanOpsisMobileApp/         All source. Everything outside App/, Views/ and */UI is the core library.
  Semantic/                 The model: project, rooms, walls, openings, components
  Geometry/                 Junctions, room boundaries, room loops, display geometry
  Topology/, Reconciliation/  Structure topology; edit transactions across shared walls
  Interaction/              Editing constraints and direct-edit engines
  Adapter/, Capture/        RoomPlan capture → model; capture evidence; mock captures
  PLY/                      Point-cloud parsing, wall candidates, sections, QA (Core/ and UI/)
  CAD/                      Drawing model, scene, snapping, underlays, wall tracing,
                            PDF vectors, plan-photo vectoriser and interpreter
  DXF/                      DXF readers and writers, validation
  IFC/                      IFC4 export and import
  Architecture/             Drafting convention (layers, line weights), symbols, readiness
  Documentation/            Sheets, schedules, quantities, elevations and sections, PDF renderer
  Survey/                   Measurements, corrections, dimensions, survey sheets (Core/ Model/ UI/)
  Persistence/              Project library, autosave, attachments, delivery packages, migration
  Exchange/                 Exchange identity, manifests, DXF reconciliation
  App/                      SwiftUI app entry point and the app store (state and commands)
  Views/                    SwiftUI views, plus iOS-only loaders (PDF pages, plan photos)
PlanOpsisMobileTests/       XCTest suites, one per feature release (V12x…) plus subsystem suites
Samples/                    Synthetic PLY point clouds for trying the PLY import
Package.swift               The PlanOpsisCore library and its tests
PlanOpsisMobile.xcodeproj   The iOS app
docs/ARCHITECTURE.md        How the pieces fit together, and where to extend them
```

## Architecture

The model is the single source of truth. Capture, import and editing change the model. Plans,
sheets, schedules, DXF and IFC are all derived from it, through a cache that recomputes once per
change.

```
 RoomPlan scan ─┐
 PLY cloud ─────┤                          ┌─> plan, area plan, RCP ─> sheets ─> PDF
 DXF / IFC ─────┼─> semantic model ────────┼─> schedules, quantities ─> CSV
 PDF / photo ───┤   (PlanOpsisProject)     ├─> DXF (semantic layers)
 drawing, edits ┘          ▲               └─> IFC4
                           └── survey measurements and corrections
```

The UI layer is a single observable store, `PlanOpsisMobileStore`, which calls pure, testable
engines in `PlanOpsisCore`. Platform services (RoomPlan, PDFKit, Vision) are injected into the store
as closures, so the core never links them.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the data model, the pipelines and the extension
points.

## File formats and standards

| Format | Read | Write | Notes |
|---|---|---|---|
| DXF | ✓ | ✓ | Full viewer; semantic export with IFC-class or discipline layers; round-trip editing; R12 line export for underlays |
| IFC4 (STEP) | ✓ | ✓ | Walls, openings, spaces, furnishing, sanitary, appliances, stairs, `Qto_*` quantities |
| PDF | ✓ | ✓ | Reads pages as underlays (raster and vector line work); writes vector drawing sets |
| JPEG / PNG / HEIC | ✓ | | Plan photos and document scans |
| PLY | ✓ | | ASCII and binary point clouds |
| CSV | | ✓ | Schedules, quantities, deviation report |
| Project JSON | ✓ | ✓ | Versioned, with migration; delivery packages with hash-verified attachments |

## Privacy, data and security

- **On the device only.** PlanOpsis makes no network requests: no analytics, no telemetry, no cloud
  services, no accounts. Projects are stored in the app's own container (Application Support).
- **Permissions.** The camera is used for LiDAR scanning and for photographing plans; the photo
  library is read only through the system picker, and only for the photo you choose.
- **No secrets in the repository.** The app needs no API keys, tokens or passwords, and none are in
  the repository or its history. Every version of every file in the history was scanned
  (`detect-secrets` plus pattern searches for keys, private keys and credentials). Secret files are
  excluded by [`.gitignore`](.gitignore), and [`.env.example`](.env.example) holds placeholders
  only. See [SECURITY.md](SECURITY.md).
- **No personal or customer data.** All samples and test fixtures are made up:
  - generated rooms and plan images;
  - invented names and addresses ("J. Doe", "1 Example Street");
  - mock RoomPlan captures, including an invented irregular room
    (`PlanOpsisMobileTests/SampleCaptureFixtures.swift`).

  None of them describes a real place or person.

## Further development

PlanOpsis is a working, tested product. [ROADMAP.md](ROADMAP.md) sets out what comes next, in
three horizons:

- **Now:** Bluetooth laser distance meters, a global survey solver, storeys, slabs and ceilings in
  the model and IFC, and IFC round-trip validation with Revit, ArchiCAD and BlenderBIM.
- **Next:** multi-room capture and partial rescans; sloped ceilings, curved walls and columns;
  building services points; BCF review with architects; IFC 4.3 and AR export.
- **Later:** production-grade plans from photos and PDFs, drawing automation and localisation, an
  App Store release, sync, and macOS, server and visionOS versions.

Each release is documented in [CHANGELOG.md](CHANGELOG.md) with what changed and why.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to build, test and submit changes, and the coding
conventions used.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).

Apache 2.0 lets anyone use, modify and distribute the code, commercially or not, provided they keep
the licence and notices and state their changes. It grants an explicit patent licence from every
contributor, and it does not grant use of the PlanOpsis name or trademarks.
