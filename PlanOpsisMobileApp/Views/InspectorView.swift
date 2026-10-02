#if os(iOS)
import SwiftUI

struct InspectorView: View {
    @ObservedObject var store: PlanOpsisMobileStore
    @State private var showAdvanced = false

    var body: some View {
        Form {
            if store.selectedIDs.count > 1 {
                Section("Selection") {
                    LabeledContent("Objects", value: "\(store.selectedIDs.count)")
                    LabeledContent("Components", value: "\(store.selectedComponentCount)")
                    Button(role: .destructive) { store.deleteSelectedObject() } label: {
                        Label("Delete selection", systemImage: "trash")
                    }
                }

                if store.selectedComponentCount >= 2 {
                    Section("Align") {
                        HStack {
                            Button("Left") { store.alignSelection(.left) }
                            Spacer()
                            Button("Center X") { store.alignSelection(.centerX) }
                            Spacer()
                            Button("Right") { store.alignSelection(.right) }
                        }
                        .buttonStyle(.borderless)
                        HStack {
                            Button("Bottom") { store.alignSelection(.bottom) }
                            Spacer()
                            Button("Center Y") { store.alignSelection(.centerY) }
                            Spacer()
                            Button("Top") { store.alignSelection(.top) }
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if store.selectedComponentCount >= 3 {
                    Section("Distribute") {
                        Button("Equal horizontal gaps") { store.distributeSelection(.horizontal) }
                        Button("Equal vertical gaps") { store.distributeSelection(.vertical) }
                    }
                }
            } else if let wall = store.selectedWall {
                Section("Wall · mm") {
                    TextField("Length", value: lengthBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Height", value: heightBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Thickness", value: thicknessBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Angle °", value: angleBinding, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.numbersAndPunctuation)
                    LabeledContent("ΔX", value: "\((wall.end.x - wall.start.x).formatted(.number.precision(.fractionLength(0...1)))) mm")
                    LabeledContent("ΔY", value: "\((wall.end.y - wall.start.y).formatted(.number.precision(.fractionLength(0...1)))) mm")
                }

                if store.representationMode == .reconciledPhysical {
                    physicalEditSection
                }
            } else if let opening = store.selectedOpening {
                Section("\(opening.kind.rawValue.capitalized) · mm") {
                    TextField("Offset", value: openingOffsetBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Width", value: openingWidthBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Height", value: openingHeightBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Sill", value: openingSillBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                }

                if opening.kind == .door {
                    Section("Door") {
                        Picker("Type", selection: doorOperationBinding) {
                            ForEach(PlanOpsisDoor.Operation.allCases, id: \.self) { operation in
                                Text(doorOperationLabel(operation)).tag(operation)
                            }
                        }
                        if opening.doorOperation == .pocket {
                            Picker("Pocket direction", selection: Binding<PlanOpsisDoor.Swing>(
                                get: { (opening.doorSwing == .rightIn || opening.doorSwing == .rightOut) ? .rightIn : .leftIn },
                                set: { doorSwingBinding.wrappedValue = $0 }
                            )) {
                                Text("Left").tag(PlanOpsisDoor.Swing.leftIn)
                                Text("Right").tag(PlanOpsisDoor.Swing.rightIn)
                            }
                        }
                        if opening.doorOperation != .sliding && opening.doorOperation != .pocket {
                            Picker("Swing", selection: doorSwingBinding) {
                                ForEach(PlanOpsisDoor.Swing.allCases, id: \.self) { swing in
                                    Text(doorSwingLabel(swing)).tag(swing)
                                }
                            }
                            if store.canMirrorSelectedDoor {
                                Button {
                                    store.mirrorSelectedDoorHanding()
                                } label: {
                                    Label("Mirror handing", systemImage: "arrow.left.and.right")
                                }
                            }
                        }
                    }
                }

                if opening.kind == .window {
                    Section("Window") {
                        Picker("Type", selection: windowOperationBinding) {
                            ForEach(PlanOpsisWindow.Operation.allCases, id: \.self) { operation in
                                Text(windowOperationLabel(operation)).tag(operation)
                            }
                        }
                    }
                }
            } else if let component = store.selectedComponent {
                Section("\(component.kind.displayName) · mm") {
                    TextField("X", value: componentXBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Y", value: componentYBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Width", value: componentWidthBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Depth", value: componentDepthBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    TextField("Height", value: componentHeightBinding, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    if component.kind == .beam || component.baseElevationMM > 0 {
                        TextField("Elevation", value: componentElevationBinding, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                    }
                    TextField("Rotation °", value: componentRotationBinding, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.numbersAndPunctuation)
                }
            } else {
                Section {
                    ContentUnavailableView("Select a wall, opening, or component", systemImage: "cursorarrow.click")
                }
            }

            if !store.selectedIDs.isEmpty, store.representationMode == .semanticObservations {
                Section("Precision") {
                    Picker("Grid spacing", selection: $store.gridSpacingMM) {
                        Text("50 mm").tag(50.0)
                        Text("100 mm").tag(100.0)
                        Text("250 mm").tag(250.0)
                        Text("500 mm").tag(500.0)
                        Text("1000 mm").tag(1000.0)
                    }

                    if store.selectedIDs.count == 1 {
                        Button { store.duplicateSelectedObject() } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                    }

                    if store.selectedComponent != nil {
                        HStack {
                            Button { store.rotateSelectedComponent(byDegrees: -90) } label: {
                                Label("−90°", systemImage: "rotate.left")
                            }
                            Spacer()
                            Button { store.snapSelectedComponentToGrid() } label: {
                                Label("Snap", systemImage: "dot.scope")
                            }
                            Spacer()
                            Button { store.rotateSelectedComponent(byDegrees: 90) } label: {
                                Label("+90°", systemImage: "rotate.right")
                            }
                        }
                        .buttonStyle(.borderless)

                        HStack {
                            Button("←") { store.nudgeSelectedComponent(dx: -store.gridSpacingMM, dy: 0) }
                            Spacer()
                            Button("↓") { store.nudgeSelectedComponent(dx: 0, dy: -store.gridSpacingMM) }
                            Spacer()
                            Button("↑") { store.nudgeSelectedComponent(dx: 0, dy: store.gridSpacingMM) }
                            Spacer()
                            Button("→") { store.nudgeSelectedComponent(dx: store.gridSpacingMM, dy: 0) }
                        }
                        .font(.title3.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                }
            }

            if store.canArchitecturalTransformSelection {
                Section("Transform") {
                    HStack {
                        TextField("ΔX · mm", value: $store.transformDeltaXMM, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.numbersAndPunctuation)
                        TextField("ΔY · mm", value: $store.transformDeltaYMM, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.numbersAndPunctuation)
                    }
                    HStack {
                        Button("Move") { store.moveArchitecturalSelection() }
                        Spacer()
                        Button("Copy") { store.copyArchitecturalSelection() }
                    }
                    .buttonStyle(.borderless)

                    TextField("Rotate · °", value: $store.transformRotationDegrees, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.numbersAndPunctuation)
                    HStack {
                        Button("Rotate") { store.rotateArchitecturalSelection() }
                        Spacer()
                        Button("Mirror H") { store.mirrorArchitecturalSelection(.horizontal) }
                        Spacer()
                        Button("Mirror V") { store.mirrorArchitecturalSelection(.vertical) }
                    }
                    .buttonStyle(.borderless)

                    if store.selectedIDs.count == 1, store.selectedWall != nil {
                        TextField("Offset · mm", value: $store.wallOffsetMM, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.numbersAndPunctuation)
                        HStack {
                            Button("Offset −") { store.offsetSelectedWall(-1) }
                            Spacer()
                            Button("Offset +") { store.offsetSelectedWall(1) }
                            Spacer()
                            Button("Trim/Extend") { store.trimOrExtendSelectedWall() }
                        }
                        .buttonStyle(.borderless)
                    }

                    Text("Wall transforms are topology-safe: a connected wall subset is blocked unless every wall at the moved junction is selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if store.selectedComponentCount >= 1, store.representationMode == .semanticObservations {
                Section("Linear Array") {
                    Stepper("Count ×\(store.arrayCount)", value: $store.arrayCount, in: 2...20)
                    TextField("Step · mm", value: $store.arrayStepMM, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.numbersAndPunctuation)
                    HStack {
                        Button("Array X") { store.arraySelection(.horizontal) }
                            .disabled(!store.canArraySelection)
                        Spacer()
                        Button("Array Y") { store.arraySelection(.vertical) }
                            .disabled(!store.canArraySelection)
                    }
                    .buttonStyle(.borderless)
                    Text("Count includes the original selection. Step is the translation between occurrences.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("History") {
                HStack {
                    Button { store.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!store.canUndo)
                    Spacer()
                    Button { store.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!store.canRedo)
                }
                .buttonStyle(.borderless)
            }

            Section {
                Button { store.closeWallJunctions() } label: {
                    Label("Close wall junctions", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .disabled(store.representationMode != .semanticObservations)
            } footer: {
                Text("Joins wall endpoints closer than \(Int(GeometryTolerances.junctionJoinMM)) mm into exact corners. Doors and windows keep their position.")
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    advancedContent
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PlanOpsisPalette.workspace)
    }

    @ViewBuilder
    private var physicalEditSection: some View {
        if let draft = store.physicalEditDraft, let plan = store.physicalEditPlan {
            Section("Physical edit preview") {
                TextField("Start X", value: physicalStartXBinding, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.numbersAndPunctuation)
                TextField("Start Y", value: physicalStartYBinding, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.numbersAndPunctuation)
                TextField("Length", value: physicalLengthBinding, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                TextField("Height", value: physicalHeightBinding, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                TextField("Thickness", value: physicalThicknessBinding, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                TextField("Angle °", value: physicalAngleBinding, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.numbersAndPunctuation)
                LabeledContent("Walls affected", value: "\(plan.wallMutations.count)")
                LabeledContent("Openings affected", value: "\(plan.openingMutations.count)")

                ForEach(Array(store.physicalEditValidationMessages.enumerated()), id: \.offset) { _, message in
                    Label(message, systemImage: "exclamationmark.octagon")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Cancel", role: .cancel) { store.cancelPhysicalEdit() }
                    Spacer()
                    Button("Apply") { store.applyPhysicalEdit() }
                        .planOpsisGlassProminentButton(active: true)
                        .disabled(!plan.canApply)
                }
                .accessibilityHint("Applies one atomic semantic transaction for partition \(draft.partitionID)")
            }
        } else if store.selectedEditablePhysicalPartition != nil {
            Section("Physical edit") {
                Button("Begin preview") { store.beginPhysicalEdit() }
                if store.lastPhysicalEditReceipt != nil {
                    Button("Undo last edit") { store.undoLastPhysicalEdit() }
                }
            }
        } else if !store.selectedPhysicalPartitions.isEmpty {
            Section("Physical edit") {
                Label("This partition is unresolved and cannot be edited as one physical wall.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var advancedContent: some View {
        if let project = store.project {
            LabeledContent("Rooms", value: "\(project.rooms.count)")
            LabeledContent("Project", value: String(project.id.uuidString.prefix(8)))
            if let room = store.selectedRoom {
                LabeledContent("Room", value: store.roomLabel(room.id))
            }
        }

        if let wall = store.selectedWall {
            LabeledContent("Wall UUID", value: String(wall.id.uuidString.prefix(12)))
            if let source = wall.sourceRoomPlanID {
                LabeledContent("RoomPlan", value: String(source.uuidString.prefix(12)))
            }
            LabeledContent("Confidence", value: wall.confidence.rawValue)
        }

        if let opening = store.selectedOpening {
            LabeledContent("Opening UUID", value: String(opening.id.uuidString.prefix(12)))
            LabeledContent("Host", value: String(opening.parameters.hostWallID.uuidString.prefix(12)))
            LabeledContent("Confidence", value: opening.parameters.confidence.rawValue)
        }

        if let component = store.selectedComponent {
            LabeledContent("Component UUID", value: String(component.id.uuidString.prefix(12)))
            LabeledContent("Type", value: component.kind.displayName)
        }

        LabeledContent("Shared partitions", value: "\(store.geometry.topology.sharedBoundaries.count)")
        LabeledContent("Physical partitions", value: "\(store.physicalPartitionCount)")

        ForEach(Array(store.diagnosticMessages.enumerated()), id: \.offset) { _, message in
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
        }
        ForEach(Array(store.topologyMessages.enumerated()), id: \.offset) { _, message in
            Label(message, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.footnote)
        }
        ForEach(Array(store.reconciliationMessages.enumerated()), id: \.offset) { _, message in
            Label(message, systemImage: "arrow.triangle.merge")
                .font(.footnote)
        }
        ForEach(Array(store.physicalDisplayMessages.enumerated()), id: \.offset) { _, message in
            Label(message, systemImage: "square.3.layers.3d.down.right")
                .font(.footnote)
        }
        ForEach(Array(store.dxfImportDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
            Label(diagnostic.message, systemImage: "doc.badge.gearshape")
                .font(.footnote)
        }
    }

    private var physicalStartXBinding: Binding<Double> {
        Binding(get: { store.physicalEditDraft?.targetGeometry.start.x ?? 0 }, set: { store.setPhysicalEditStartX($0) })
    }

    private var physicalStartYBinding: Binding<Double> {
        Binding(get: { store.physicalEditDraft?.targetGeometry.start.y ?? 0 }, set: { store.setPhysicalEditStartY($0) })
    }

    private var physicalLengthBinding: Binding<Double> {
        Binding(get: { store.physicalEditDraft?.targetGeometry.length ?? 0 }, set: { store.setPhysicalEditLength($0) })
    }

    private var physicalHeightBinding: Binding<Double> {
        Binding(get: { store.physicalEditDraft?.targetGeometry.height ?? 0 }, set: { store.setPhysicalEditHeight($0) })
    }

    private var physicalThicknessBinding: Binding<Double> {
        Binding(get: { store.physicalEditDraft?.targetGeometry.thickness ?? 0 }, set: { store.setPhysicalEditThickness($0) })
    }

    private var physicalAngleBinding: Binding<Double> {
        Binding(
            get: { (store.physicalEditDraft?.targetGeometry.angleRadians ?? 0) * 180 / .pi },
            set: { store.setPhysicalEditAngleDegrees($0) }
        )
    }


    private var openingOffsetBinding: Binding<Double> {
        Binding(get: { store.selectedOpening?.parameters.offsetAlongWall ?? 0 }, set: { store.setSelectedOpeningOffset($0) })
    }

    private var openingWidthBinding: Binding<Double> {
        Binding(get: { store.selectedOpening?.parameters.width ?? 0 }, set: { store.setSelectedOpeningWidth($0) })
    }

    private var openingHeightBinding: Binding<Double> {
        Binding(get: { store.selectedOpening?.parameters.height ?? 0 }, set: { store.setSelectedOpeningHeight($0) })
    }

    private var openingSillBinding: Binding<Double> {
        Binding(get: { store.selectedOpening?.parameters.sillHeight ?? 0 }, set: { store.setSelectedOpeningSill($0) })
    }

    private var doorSwingBinding: Binding<PlanOpsisDoor.Swing> {
        Binding(get: { store.selectedOpening?.doorSwing ?? .unspecified }, set: { store.setSelectedDoorSwing($0) })
    }

    private var doorOperationBinding: Binding<PlanOpsisDoor.Operation> {
        Binding(get: { store.selectedOpening?.doorOperation ?? .singleHinged }, set: { store.setSelectedDoorOperation($0) })
    }

    private var windowOperationBinding: Binding<PlanOpsisWindow.Operation> {
        Binding(get: { store.selectedOpening?.windowOperation ?? .fixed }, set: { store.setSelectedWindowOperation($0) })
    }

    private var componentXBinding: Binding<Double> {
        Binding(get: { store.selectedComponent?.position.x ?? 0 }, set: { store.setSelectedComponentPositionX($0) })
    }
    private var componentYBinding: Binding<Double> {
        Binding(get: { store.selectedComponent?.position.y ?? 0 }, set: { store.setSelectedComponentPositionY($0) })
    }
    private var componentWidthBinding: Binding<Double> {
        Binding(get: { store.selectedComponent?.width ?? 0 }, set: { store.setSelectedComponentWidth($0) })
    }
    private var componentDepthBinding: Binding<Double> {
        Binding(get: { store.selectedComponent?.depth ?? 0 }, set: { store.setSelectedComponentDepth($0) })
    }
    private var componentHeightBinding: Binding<Double> {
        Binding(get: { store.selectedComponent?.height ?? 0 }, set: { store.setSelectedComponentHeight($0) })
    }
    private var componentElevationBinding: Binding<Double> {
        Binding(get: { store.selectedComponent?.baseElevationMM ?? 0 }, set: { store.setSelectedComponentElevation($0) })
    }
    private var componentRotationBinding: Binding<Double> {
        Binding(get: { (store.selectedComponent?.rotationRadians ?? 0) * 180 / .pi }, set: { store.setSelectedComponentRotationDegrees($0) })
    }

    private func doorOperationLabel(_ operation: PlanOpsisDoor.Operation) -> String {
        switch operation {
        case .singleHinged: return "Single hinged"
        case .doubleHinged: return "Double hinged"
        case .sliding: return "Sliding"
        case .pocket: return "Pocket"
        }
    }

    private func windowOperationLabel(_ operation: PlanOpsisWindow.Operation) -> String {
        switch operation {
        case .fixed: return "Fixed"
        case .singleCasement: return "Single casement"
        case .doubleCasement: return "Double casement"
        case .sliding: return "Sliding"
        }
    }

    private func doorSwingLabel(_ swing: PlanOpsisDoor.Swing) -> String {
        switch swing {
        case .unspecified: return "Unspecified"
        case .leftIn: return "Left · In"
        case .leftOut: return "Left · Out"
        case .rightIn: return "Right · In"
        case .rightOut: return "Right · Out"
        }
    }

    private var lengthBinding: Binding<Double> {
        Binding(get: { store.selectedWall?.length ?? 0 }, set: { store.setSelectedWallLength($0) })
    }

    private var heightBinding: Binding<Double> {
        Binding(get: { store.selectedWall?.height ?? 0 }, set: { value in store.editSelectedWall { $0.editHeight(value) } })
    }

    private var thicknessBinding: Binding<Double> {
        Binding(get: { store.selectedWall?.thickness ?? 0 }, set: { value in store.editSelectedWall { $0.editThickness(value) } })
    }

    private var angleBinding: Binding<Double> {
        Binding(
            get: { (store.selectedWall?.angleRadians ?? 0) * 180 / .pi },
            set: { degrees in store.editSelectedWall { $0.editAngleRadians(degrees * .pi / 180) } }
        )
    }
}
#endif
