import heresdk
import MapConductorCore
import UIKit

@MainActor
final class HerePolylineOverlayRenderer: AbstractPolylineOverlayRenderer<MapPolyline> {
    private weak var mapView: MapView?

    init(mapView: MapView?) {
        self.mapView = mapView
        super.init()
    }

    override func createPolyline(state: PolylineState) async -> MapPolyline? {
        guard let mapView, let polyline = makePolyline(state: state) else { return nil }
        mapView.mapScene.addMapPolyline(polyline)
        return polyline
    }

    override func updatePolylineProperties(
        polyline: MapPolyline,
        current: PolylineEntity<MapPolyline>,
        prev: PolylineEntity<MapPolyline>
    ) async -> MapPolyline? {
        guard let mapView else { return polyline }
        let finger = current.fingerPrint
        let prevFinger = prev.fingerPrint
        var needsReAdd = false

        if finger.points != prevFinger.points || finger.geodesic != prevFinger.geodesic {
            guard let geometry = makeGeometry(state: current.state) else { return polyline }
            polyline.geometry = geometry
            needsReAdd = true
        }

        if finger.strokeColor != prevFinger.strokeColor ||
            finger.strokeWidth != prevFinger.strokeWidth {
            if let representation = makeRepresentation(state: current.state) {
                polyline.setRepresentation(representation)
                needsReAdd = true
            }
        }

        if needsReAdd {
            mapView.mapScene.removeMapPolyline(polyline)
            mapView.mapScene.addMapPolyline(polyline)
        }

        return polyline
    }

    override func removePolyline(entity: PolylineEntity<MapPolyline>) async {
        guard let mapView, let polyline = entity.polyline else { return }
        mapView.mapScene.removeMapPolyline(polyline)
    }

    func unbind() {
        mapView = nil
    }

    private func makePolyline(state: PolylineState) -> MapPolyline? {
        guard let geometry = makeGeometry(state: state),
              let representation = makeRepresentation(state: state) else { return nil }
        let polyline = MapPolyline(geometry: geometry, representation: representation)
        polyline.drawOrder = 5
        return polyline
    }

    private func makeGeometry(state: PolylineState) -> GeoPolyline? {
        let geoPoints: [GeoPointProtocol] = state.geodesic
            ? createInterpolatePoints(state.points)
            : createLinearInterpolatePoints(state.points)
        guard geoPoints.count >= 2 else { return nil }
        return try? GeoPolyline(vertices: geoPoints.map { $0.toGeoCoordinates() })
    }

    private func makeRepresentation(state: PolylineState) -> MapPolyline.Representation? {
        let widthInPixels = max(0.0, state.strokeWidth) * Double(UIScreen.main.scale)
        guard let width = try? MapMeasureDependentRenderSize(sizeUnit: .pixels, size: widthInPixels) else {
            return nil
        }
        return try? MapPolyline.SolidRepresentation(
            lineWidth: width,
            color: state.strokeColor,
            capShape: .square
        )
    }
}
