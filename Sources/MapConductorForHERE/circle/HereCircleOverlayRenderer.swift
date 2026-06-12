import heresdk
import MapConductorCore
import UIKit

@MainActor
final class HereCircleOverlayRenderer: AbstractCircleOverlayRenderer<MapPolygon> {
    private weak var mapView: MapView?

    init(mapView: MapView?) {
        self.mapView = mapView
        super.init()
    }

    override func createCircle(state: CircleState) async -> MapPolygon? {
        guard let mapView else { return nil }
        let polygon = MapPolygon(
            geometry: makeGeometry(state: state),
            color: state.fillColor,
            outlineColor: state.strokeColor,
            outlineWidthInPixels: state.strokeWidth
        )
        polygon.drawOrder = Int32(state.zIndex ?? 0)
        mapView.mapScene.addMapPolygon(polygon)
        return polygon
    }

    override func updateCircleProperties(
        circle: MapPolygon,
        current: CircleEntity<MapPolygon>,
        prev: CircleEntity<MapPolygon>
    ) async -> MapPolygon? {
        let finger = current.fingerPrint
        let prevFinger = prev.fingerPrint

        if finger.center != prevFinger.center || finger.radiusMeters != prevFinger.radiusMeters {
            circle.geometry = makeGeometry(state: current.state)
        }
        if finger.fillColor != prevFinger.fillColor {
            circle.fillColor = current.state.fillColor
        }
        if finger.strokeColor != prevFinger.strokeColor {
            circle.outlineColor = current.state.strokeColor
        }
        if finger.strokeWidth != prevFinger.strokeWidth {
            circle.outlineWidth = current.state.strokeWidth
        }
        if finger.zIndex != prevFinger.zIndex {
            circle.drawOrder = Int32(current.state.zIndex ?? 0)
        }

        return circle
    }

    override func removeCircle(entity: CircleEntity<MapPolygon>) async {
        guard let mapView, let circle = entity.circle else { return }
        mapView.mapScene.removeMapPolygon(circle)
    }

    func unbind() {
        mapView = nil
    }

    private func makeGeometry(state: CircleState) -> GeoPolygon {
        GeoPolygon(
            geoCircle: GeoCircle(
                center: state.center.toGeoCoordinates(),
                radiusInMeters: state.radiusMeters
            )
        )
    }
}
