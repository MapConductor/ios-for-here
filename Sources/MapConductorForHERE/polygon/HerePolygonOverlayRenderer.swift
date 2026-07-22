import heresdk
import MapConductorCore

@MainActor
final class HerePolygonOverlayRenderer: AbstractPolygonOverlayRenderer<MapPolygon> {
    private weak var mapView: MapView?

    init(mapView: MapView?) {
        self.mapView = mapView
        super.init()
    }

    override func createPolygon(state: PolygonState) async -> MapPolygon? {
        guard let mapView else { return nil }

        return createNativePolygon(state: state, mapView: mapView)
    }

    override func updatePolygonProperties(
        polygon: MapPolygon,
        current: PolygonEntity<MapPolygon>,
        prev: PolygonEntity<MapPolygon>
    ) async -> MapPolygon? {
        guard mapView != nil else { return polygon }
        let finger = current.fingerPrint
        let prevFinger = prev.fingerPrint
        let shapeChanged = finger.points != prevFinger.points
            || finger.holes != prevFinger.holes
            || finger.geodesic != prevFinger.geodesic

        if shapeChanged, let geometry = makeGeometry(state: current.state) {
            polygon.geometry = geometry
        }

        if finger.fillColor != prevFinger.fillColor {
            polygon.fillColor = current.state.fillColor
        }
        if finger.strokeColor != prevFinger.strokeColor {
            polygon.outlineColor = current.state.strokeColor
        }
        if finger.strokeWidth != prevFinger.strokeWidth {
            polygon.outlineWidth = current.state.strokeWidth
        }
        if finger.zIndex != prevFinger.zIndex {
            polygon.drawOrder = Int32(truncatingIfNeeded: current.state.zIndex)
        }
        return polygon
    }

    override func removePolygon(entity: PolygonEntity<MapPolygon>) async {
        guard let mapView, let polygon = entity.polygon else { return }
        mapView.mapScene.removeMapPolygon(polygon)
    }

    func unbind() {
        mapView = nil
    }

    // MARK: - Native polygon

    private func createNativePolygon(
        state: PolygonState,
        mapView: MapView
    ) -> MapPolygon? {
        guard let geometry = makeGeometry(state: state) else { return nil }
        let polygon = MapPolygon(
            geometry: geometry,
            color: state.fillColor,
            outlineColor: state.strokeColor,
            outlineWidthInPixels: state.strokeWidth
        )
        polygon.drawOrder = Int32(truncatingIfNeeded: state.zIndex)
        mapView.mapScene.addMapPolygon(polygon)
        return polygon
    }

    // MARK: - Geometry

    private func makeGeometry(state: PolygonState) -> GeoPolygon? {
        let outerRing = makeRing(points: state.points, geodesic: state.geodesic)
        let vertices = ensureCounterClockwise(outerRing).map { $0.toGeoCoordinates() }
        guard vertices.count >= 4 else { return nil }
        let holes = state.holes.map { holePoints -> [GeoCoordinates] in
            let ring = makeRing(points: holePoints, geodesic: state.geodesic)
            return ensureClockwiseRing(ring).map { $0.toGeoCoordinates() }
        }
        return try? GeoPolygon(vertices: vertices, innerBoundaries: holes)
    }

    private func makeRing(points: [GeoPointProtocol], geodesic: Bool) -> [GeoPointProtocol] {
        var ring = (geodesic ? createInterpolatePoints(points) : createLinearInterpolatePoints(points))
            .map { $0.normalize() }
        if let first = ring.first, let last = ring.last,
           !(GeoPoint.from(position: first) == GeoPoint.from(position: last)) {
            ring.append(first)
        }
        return ring
    }
}
