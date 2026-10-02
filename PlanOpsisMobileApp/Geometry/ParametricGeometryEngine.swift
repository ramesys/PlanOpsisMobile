import Foundation

public struct ParametricGeometryEngine {
    private let epsilon = 1e-9

    public init() {}

    public func generate(from project: PlanOpsisProject) -> ArchitecturalGeometrySnapshot {
        let topology = StructureTopologyEngine().generate(from: project)
        let reconciliation = StructureReconciliationEngine().generate(from: project, topology: topology)
        var planSegments: [WallPlanSegment] = []
        var solids: [WallSolidSegment] = []
        var openingGeometry: [HostedOpeningGeometry] = []
        var roomFloors: [RoomFloorGeometry] = []

        let junctionResolver = WallJunctionResolver()

        for room in project.rooms {
            var roomFootprintPoints: [Point2D] = []
            let resolvedAxes = junctionResolver.resolve(room: room)

            for wall in room.walls {
                let axis = resolvedAxes[wall.id] ?? WallJunctionResolver.ResolvedAxis(
                    wallID: wall.id,
                    start: wall.start,
                    end: wall.end,
                    joinedAtStart: false,
                    joinedAtEnd: false
                )
                // Per-room floor extents are derived from complete semantic wall footprints,
                // never from fragments after hosted openings are removed.
                roomFootprintPoints.append(contentsOf: footprint(wall: wall, axis: axis, startOffset: 0, length: wall.length))

                let hosted = room.openings
                    .filter { $0.parameters.hostWallID == wall.id }
                    .sorted {
                        if $0.parameters.offsetAlongWall == $1.parameters.offsetAlongWall {
                            return $0.id.uuidString < $1.id.uuidString
                        }
                        return $0.parameters.offsetAlongWall < $1.parameters.offsetAlongWall
                    }

                let voids = hosted.compactMap { clippedVoid(opening: $0, wall: wall) }

                let horizontalVoids = mergeIntervals(voids.map { ($0.startOffset, $0.endOffset) })
                appendPlanSegmentsOutside(
                    roomID: room.id,
                    horizontalVoids: horizontalVoids,
                    wall: wall,
                    axis: axis,
                    output: &planSegments
                )

                appendSolidSegments(
                    roomID: room.id,
                    voids: voids,
                    wall: wall,
                    axis: axis,
                    output: &solids
                )

                for void in voids {
                    let centerOffset = (void.startOffset + void.endOffset) * 0.5
                    openingGeometry.append(HostedOpeningGeometry(
                        id: void.opening.id,
                        roomID: room.id,
                        hostWallID: wall.id,
                        kind: void.opening.kind,
                        center: axis.point(atSemanticOffset: centerOffset, semanticLength: wall.length),
                        startOffset: centerOffset,
                        width: void.endOffset - void.startOffset,
                        height: void.top - void.bottom,
                        sillHeight: void.bottom,
                        angleRadians: axis.angleRadians,
                        thickness: wall.thickness,
                        doorSwing: void.opening.doorSwing ?? .unspecified,
                        doorOperation: void.opening.doorOperation,
                        windowOperation: void.opening.windowOperation
                    ))
                }
            }

            let polygon = ArchitecturalRoomEnvelope.polygon(for: room, topology: topology)
            if polygon.count >= 3, let bounds = floorGeometry(points: polygon) {
                roomFloors.append(RoomFloorGeometry(roomID: room.id, bounds: bounds, polygon: polygon))
            } else if let bounds = floorGeometry(points: roomFootprintPoints) {
                roomFloors.append(RoomFloorGeometry(roomID: room.id, bounds: bounds))
            }
        }

        return ArchitecturalGeometrySnapshot(
            planWallSegments: planSegments,
            wallSolids: solids,
            hostedOpenings: openingGeometry,
            roomFloors: roomFloors,
            topology: topology,
            reconciliation: reconciliation
        )
    }

    private struct OpeningVoid {
        var opening: PlanOpsisOpening
        var startOffset: Double
        var endOffset: Double
        var bottom: Double
        var top: Double
    }

    private func clippedVoid(opening: PlanOpsisOpening, wall: PlanOpsisWall) -> OpeningVoid? {
        let p = opening.parameters
        guard wall.length > epsilon, wall.height > epsilon, p.width > epsilon, p.height > epsilon else { return nil }

        let half = p.width * 0.5
        let start = max(0, min(wall.length, p.offsetAlongWall - half))
        let end = max(0, min(wall.length, p.offsetAlongWall + half))
        let bottom = max(0, min(wall.height, p.sillHeight))
        let top = max(0, min(wall.height, p.sillHeight + p.height))

        guard end > start + epsilon, top > bottom + epsilon else { return nil }
        return OpeningVoid(
            opening: opening,
            startOffset: min(start, end),
            endOffset: max(start, end),
            bottom: min(bottom, top),
            top: max(bottom, top)
        )
    }

    private func appendPlanSegmentsOutside(
        roomID: UUID,
        horizontalVoids: [(Double, Double)],
        wall: PlanOpsisWall,
        axis: WallJunctionResolver.ResolvedAxis,
        output: inout [WallPlanSegment]
    ) {
        var cursor = 0.0
        for interval in horizontalVoids {
            if interval.0 > cursor + epsilon {
                output.append(planSegment(
                    roomID: roomID,
                    wall: wall,
                    axis: axis,
                    startOffset: cursor,
                    length: interval.0 - cursor
                ))
            }
            cursor = max(cursor, interval.1)
        }
        if cursor < wall.length - epsilon {
            output.append(planSegment(
                roomID: roomID,
                wall: wall,
                axis: axis,
                startOffset: cursor,
                length: wall.length - cursor
            ))
        }
    }

    private func appendSolidSegments(
        roomID: UUID,
        voids: [OpeningVoid],
        wall: PlanOpsisWall,
        axis: WallJunctionResolver.ResolvedAxis,
        output: inout [WallSolidSegment]
    ) {
        guard wall.length > epsilon, wall.height > epsilon else { return }

        var breaks = [0.0, wall.length]
        for void in voids {
            breaks.append(void.startOffset)
            breaks.append(void.endOffset)
        }
        breaks = uniqueSorted(breaks)

        for index in 0..<(breaks.count - 1) {
            let x0 = breaks[index]
            let x1 = breaks[index + 1]
            guard x1 > x0 + epsilon else { continue }

            let activeVoids = voids.filter {
                $0.startOffset < x1 - epsilon && $0.endOffset > x0 + epsilon
            }

            if activeVoids.isEmpty {
                output.append(solid(
                    roomID: roomID,
                    wall: wall,
                    axis: axis,
                    kind: .fullHeight,
                    startOffset: x0,
                    length: x1 - x0,
                    bottom: 0,
                    height: wall.height
                ))
                continue
            }

            let verticalVoids = mergeIntervals(activeVoids.map { ($0.bottom, $0.top) })
            var cursor = 0.0
            for void in verticalVoids {
                if void.0 > cursor + epsilon {
                    appendVerticalSolid(
                        roomID: roomID,
                        wall: wall,
                        axis: axis,
                        startOffset: x0,
                        length: x1 - x0,
                        bottom: cursor,
                        top: void.0,
                        output: &output
                    )
                }
                cursor = max(cursor, void.1)
            }
            if cursor < wall.height - epsilon {
                appendVerticalSolid(
                    roomID: roomID,
                    wall: wall,
                    axis: axis,
                    startOffset: x0,
                    length: x1 - x0,
                    bottom: cursor,
                    top: wall.height,
                    output: &output
                )
            }
        }
    }

    private func appendVerticalSolid(
        roomID: UUID,
        wall: PlanOpsisWall,
        axis: WallJunctionResolver.ResolvedAxis,
        startOffset: Double,
        length: Double,
        bottom: Double,
        top: Double,
        output: inout [WallSolidSegment]
    ) {
        guard top > bottom + epsilon else { return }

        let kind: WallSolidSegment.SegmentKind
        if bottom <= epsilon && top >= wall.height - epsilon {
            kind = .fullHeight
        } else if bottom <= epsilon {
            kind = .sill
        } else if top >= wall.height - epsilon {
            kind = .header
        } else {
            kind = .verticalBand
        }

        output.append(solid(
            roomID: roomID,
            wall: wall,
            axis: axis,
            kind: kind,
            startOffset: startOffset,
            length: length,
            bottom: bottom,
            height: top - bottom
        ))
    }

    private func planSegment(
        roomID: UUID,
        wall: PlanOpsisWall,
        axis: WallJunctionResolver.ResolvedAxis,
        startOffset: Double,
        length: Double
    ) -> WallPlanSegment {
        WallPlanSegment(
            roomID: roomID,
            hostWallID: wall.id,
            startOffset: startOffset,
            length: length,
            thickness: wall.thickness,
            footprint: footprint(wall: wall, axis: axis, startOffset: startOffset, length: length)
        )
    }

    private func footprint(
        wall: PlanOpsisWall,
        axis: WallJunctionResolver.ResolvedAxis,
        startOffset: Double,
        length: Double
    ) -> [Point2D] {
        let span = WallJunctionResolver().displaySpan(
            wall: wall,
            axis: axis,
            startOffset: startOffset,
            length: length
        )
        let n = axis.normal * (wall.thickness * 0.5)
        return [span.start + n, span.end + n, span.end - n, span.start - n]
    }

    private func solid(
        roomID: UUID,
        wall: PlanOpsisWall,
        axis: WallJunctionResolver.ResolvedAxis,
        kind: WallSolidSegment.SegmentKind,
        startOffset: Double,
        length: Double,
        bottom: Double,
        height: Double
    ) -> WallSolidSegment {
        let center = wall.start + wall.direction * (startOffset + length * 0.5)
        let renderSpan = WallJunctionResolver().displaySpan(
            wall: wall,
            axis: axis,
            startOffset: startOffset,
            length: length
        )
        return WallSolidSegment(
            roomID: roomID,
            hostWallID: wall.id,
            kind: kind,
            startOffset: startOffset,
            length: length,
            bottom: bottom,
            height: height,
            thickness: wall.thickness,
            center: center,
            angleRadians: wall.angleRadians,
            renderLength: renderSpan.length,
            renderCenter: renderSpan.center,
            renderAngleRadians: renderSpan.angleRadians
        )
    }

    private func mergeIntervals(_ intervals: [(Double, Double)]) -> [(Double, Double)] {
        let sorted = intervals
            .filter { $0.1 > $0.0 + epsilon }
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        guard var current = sorted.first else { return [] }
        var result: [(Double, Double)] = []
        for interval in sorted.dropFirst() {
            if interval.0 <= current.1 + epsilon {
                current.1 = max(current.1, interval.1)
            } else {
                result.append(current)
                current = interval
            }
        }
        result.append(current)
        return result
    }

    private func uniqueSorted(_ values: [Double]) -> [Double] {
        let sorted = values.sorted()
        var result: [Double] = []
        for value in sorted {
            if let last = result.last, abs(last - value) <= epsilon { continue }
            result.append(value)
        }
        return result
    }

    private func floorGeometry(points: [Point2D]) -> FloorGeometry? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return FloorGeometry(min: Point2D(x: minX, y: minY), max: Point2D(x: maxX, y: maxY))
    }
}
