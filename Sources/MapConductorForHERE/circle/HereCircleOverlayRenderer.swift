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

        if finger.center != prevFinger.center
            || finger.radiusMeters != prevFinger.radiusMeters
            || finger.geodesic != prevFinger.geodesic {
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
        let nativeGeodesicPolygon = GeoPolygon(
            geoCircle: GeoCircle(
                center: state.center.toGeoCoordinates(),
                radiusInMeters: state.radiusMeters
            )
        )
        if state.geodesic {
            // Native geodesic circle.
            return nativeGeodesicPolygon
        }
        // 非 geodesic はコア共通の circleToRing（局所平面近似・unwrap 座標）でリングを
        // 生成し、HERE の座標範囲に収まるよう正規化する（android-for-here と同一仕様）。
        let vertices = closeRing(
            circleToRing(
                center: state.center,
                radiusMeters: state.radiusMeters,
                geodesic: false
            ).map { $0.normalize() }
        ).map { $0.toGeoCoordinates() }
        return (try? GeoPolygon(vertices: vertices)) ?? nativeGeodesicPolygon
    }
}
