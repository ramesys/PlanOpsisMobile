# PlanOpsis Mobile: architecture

This guide is for developers taking PlanOpsis further. It explains how the code is organised, how
data flows from capture to export, and where to add new capabilities. For what each release added,
see [CHANGELOG.md](../CHANGELOG.md).

## Principles

1. **One semantic model.** `PlanOpsisProject` (in `Semantic/`) holds rooms, walls, openings and
   components, plus the survey record (measurements, room names, documentation settings) and the
   project's underlay. Every view and file is derived from it. Nothing is drawn that the model does
   not hold.
2. **A pure core, a thin app.** Everything that can be pure Swift is in the `PlanOpsisCore` package
   target (see `Package.swift`). It has no UIKit, SwiftUI, RoomPlan, PDFKit or Vision, so it builds
   and tests on Linux. The app (`App/`, `Views/`, `*/UI/`) is SwiftUI on top.
3. **Platform services are injected.** Where the core needs an Apple-only service, the store
   receives a closure from the app at launch. Examples are rendering a PDF page
   (`pdfPageLoader`) and straightening and OCR-ing a plan photo (`photoPlanLoader`). The core logic
   behind them (`PDFVectorExtractor`, `PlanPhotoVectorizer`, `PlanPhotoInterpreter`) stays testable.
4. **Millimetres, y up.** Plan coordinates are millimetres with y up. Imported drawings and images
   are placed through an explicit `CADAffine` / `UnderlayPlacement`, never by implicit unit guesses.
5. **Deterministic and reproducible.** Stable ordering, fixed tolerances (`GeometryTolerances`),
   versioned persistence with migration, and retained raw captures. The same input gives the same
   drawing and the same IFC.

## Layers

```
┌──────────────────────────── App (iOS only) ────────────────────────────┐
│ PlanOpsisMobileApp (SwiftUI scenes, menus)   Views/  */UI/             │
│ PlanOpsisMobileStore: observable state, commands, undo, autosave       │
│ Injected services: RoomPlanCaptureService, PDFUnderlayLoader,          │
│                    PhotoPlanLoader (Vision, VisionKit, Core Image)     │
└───────────────────────────────┬────────────────────────────────────────┘
                                │ calls
┌───────────────────────────── PlanOpsisCore ────────────────────────────┐
│ Inputs:     Adapter/ (RoomPlan), PLY/Core, CAD/ (DXF scene, underlays, │
│             PDF vectors, photo vectoriser + interpreter), IFC reader   │
│ Model:      Semantic/, Survey/Model                                    │
│ Geometry:   Geometry/, Topology/, Reconciliation/, Interaction/        │
│ Derivation: Architecture/ProjectDerivation, Documentation/             │
│ Outputs:    DXF/, IFC/, Documentation/ (sheets, PDF, CSV)              │
│ Storage:    Persistence/, Exchange/                                    │
└────────────────────────────────────────────────────────────────────────┘
```

## The data model

| Type | Holds |
|---|---|
| `PlanOpsisProject` | Rooms, `SurveyRecord`, documentation settings, saved underlay, schema version |
| `PlanOpsisRoom` | Walls, openings, components, capture provenance (floor elevation, RoomPlan IDs) |
| `PlanOpsisWall` | Start, length, angle, height, thickness, confidence, source ID |
| `PlanOpsisOpening` | `.door` (swing, operation), `.window` (operation), `.opening`, each hosted on a wall at an offset |
| `PlanOpsisComponent` | Interior object (furniture, fixture, appliance, stairs, column, beam): position, size, rotation, elevation, scan confidence |
| `SurveyRecord` | Observations (measured values, locks), room names, dimension placements, evidence |

Walls belong to rooms, and a partition between two rooms is held by each of them. The topology and
reconciliation engines keep shared walls consistent when one side is edited.

## Pipelines

### Capture → model

- **RoomPlan.** `RoomPlanCaptureService` (app) records a `StructureCaptureSnapshot`. `RoomPlanAdapter`
  then does the following:
  - registers wall surfaces as interior faces;
  - places openings on their hosts;
  - turns recognised objects into components.

  The raw capture is kept as evidence (`CaptureEvidence`), so it can be replayed when reconstruction
  improves.
- **PLY.** `PLYParser` → `PLYSectionReconstructor` / `PLYWallCandidateEngine` → reviewed in the PLY
  tab → `PLYPlanOpsisAdapter`.
- **Drawings.** A DXF or IFC opens as a `CADViewerDocument` and is shown as a `CADScene`.
  `UnderlayWallTracer` pairs parallel faces into walls and reads door swings and window blocks in
  the gaps. `RoomLoopDetector` splits the result into rooms and names them from the text inside.
  `IFCModelReader` reads an architect's IFC directly.
- **PDF and photos.**
  - `PDFVectorExtractor` reads a PDF page's line work.
  - `PlanPhotoVectorizer` binarises, straightens and strokes a plan photo.
  - `PlanPhotoInterpreter` reads the strokes and the ink as walls, doors, windows, doorways, stairs
    and scale, giving a `PlanPhotoReading`.
  - `PlanPhotoReading.plan(transform:)` builds the rooms.

### Model → outputs

- `ProjectDerivation` computes, once per change, the display geometry, annotations and export
  readiness that every view needs.
- `PlanOrdering` gives the orientation-based numbering. Schedules, tags, DXF and IFC all use it.
- **Drawings.** `DrawingSetComposer` lays out sheets: plan, area plan, RCP, schedules, and
  elevations and sections from `ArchitecturalSectionEngine`. `SheetPDFRenderer` writes the vector
  PDF.
- **Exchange.**
  - `DXFExchangeEngine` writes semantic DXF on the layers of `ArchitecturalDraftingConvention`.
  - `EditableDXFReader` / `EditableDXFWriter` provide round-trip editing.
  - `CADDocumentDXFWriter` writes R12 line work.
  - `IFC4ExchangeEngine` writes IFC4 with quantity sets.
- **Persistence.** `ProjectLibrary` and `ProjectStore` save versioned JSON in Application Support,
  migrated by `ProjectMigrator`. `SurveyAttachmentStore` keeps hash-verified evidence.
  `SurveyDeliveryWriter` / `SurveyDeliveryReader` handle delivery packages.

## The app store

`PlanOpsisMobileStore` (`App/`) is the single `@MainActor ObservableObject` the views observe:

- **Commands.** Edits go through `commitSemanticProject(_:label:…)`, which validates the change
  (survey locks included), records undo history, regenerates the derivation and schedules autosave.
- **Long work.** Imports, PDF rendering and photo reading run in detached tasks. Their results come
  back on the main actor.
- **Testing.** The store is not part of the core. Keep logic out of it, in core engines with their
  own tests, so it stays a thin layer of state and commands.

## Extending PlanOpsis

| To add | Start in | Notes |
|---|---|---|
| A new object kind | `PlanOpsisComponent.Kind` (`Semantic/PlanOpsisProject.swift`) | Add its symbol (`ArchitecturalSymbol`), DXF layer and IFC class; `testEveryRoomPlanCategoryHasAKindAndEveryKindASymbol` checks coverage |
| A new export format | `DXF/` or `IFC/` as a model | Read from `PlanOpsisProject` plus `ProjectDerivation`, and order with `PlanOrdering` |
| A new import | `CAD/` (drawings) or `Adapter/` (captures) | Produce an `UnderlayTraceResult` or rooms, and reuse `RoomLoopDetector` for rooms and names |
| A new sheet or schedule | `Documentation/` | `DrawingSetComposer` places it; `ProjectSchedules` / `ProjectQuantities` hold the rows |
| An Apple-only service | `Views/` loader + a closure on the store | Keep the algorithm in the core and inject only the platform part |
| A persisted field | The model type + `ProjectMigrator` | Decode with `decodeIfPresent` and a default so older projects still open; add a decoding test |

## Testing

- `swift test` runs the core suites on Linux and macOS. CI also builds the iOS app.
- Each feature release has its own suite (`PlanOpsisV12xTests`). Subsystem suites cover exchange
  (golden DXF and IFC), survey, persistence and PLY.
- **Fixtures are synthetic:**
  - rooms are built in code;
  - plan photos are rendered from shapes (`PlanOpsisV129PhotoPlanTests`,
    `PlanOpsisV1210PhotoReadingTests`);
  - captures are mocks (`MockRoomCaptureProvider`, `MockStructureCaptureProvider`).

  The one recorded capture (`RealCaptureFixtures`) is bare geometry with random identifiers. Use
  made-up data for new fixtures.
- Add a test for every behaviour change, and keep tests independent of the machine (no network, no
  clock, no locale).

## Conventions

- Swift 6 tools; the app target builds in Swift 5 language mode.
- **Adding files.** A new core file goes in `Package.swift`'s `sources` and in the Xcode project.
  iOS-only files go in the Xcode project only, wrapped in `#if os(iOS)`.
- **Version comments.** Comments mark the version a behaviour arrived in (`/// v12.10 …`), so a
  reader can find the reason in the changelog.
- **No secrets, no personal data.** See [SECURITY.md](../SECURITY.md).
