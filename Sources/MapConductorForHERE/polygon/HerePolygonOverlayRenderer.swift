import heresdk
import MapConductorCore
import UIKit

@MainActor
final class HerePolygonOverlayRenderer: AbstractPolygonOverlayRenderer<MapPolygon> {
    private weak var mapView: MapView?

    init(mapView: MapView?) {
        self.mapView = mapView
        super.init()
    }

    override func createPolygon(state: PolygonState) async -> MapPolygon? {
        guard let mapView, let geometry = makeGeometry(state: state) else { return nil }
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

    override func updatePolygonProperties(
        polygon: MapPolygon,
        current: PolygonEntity<MapPolygon>,
        prev: PolygonEntity<MapPolygon>
    ) async -> MapPolygon? {
        let finger = current.fingerPrint
        let prevFinger = prev.fingerPrint

        if finger.points != prevFinger.points || finger.holes != prevFinger.holes || finger.geodesic != prevFinger.geodesic {
            if let geometry = makeGeometry(state: current.state) {
                polygon.geometry = geometry
            }
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

    private func makeGeometry(state: PolygonState) -> GeoPolygon? {
        let vertices = makeRing(points: state.points, geodesic: state.geodesic).map { $0.toGeoCoordinates() }
        guard vertices.count >= 4 else { return nil }
        let holes = state.holes.map { makeRing(points: $0, geodesic: state.geodesic).map { $0.toGeoCoordinates() } }
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
