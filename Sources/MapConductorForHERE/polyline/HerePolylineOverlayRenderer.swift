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
        let finger = current.fingerPrint
        let prevFinger = prev.fingerPrint

        if finger.points != prevFinger.points {
            guard let geometry = makeGeometry(points: current.state.points) else { return polyline }
            polyline.geometry = geometry
        }

        if finger.strokeColor != prevFinger.strokeColor ||
            finger.strokeWidth != prevFinger.strokeWidth {
            if let representation = makeRepresentation(state: current.state) {
                polyline.setRepresentation(representation)
            }
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
        guard let geometry = makeGeometry(points: state.points),
              let representation = makeRepresentation(state: state) else { return nil }
        let polyline = MapPolyline(geometry: geometry, representation: representation)
        polyline.drawOrder = 5
        return polyline
    }

    private func makeGeometry(points: [GeoPointProtocol]) -> GeoPolyline? {
        guard points.count >= 2 else { return nil }
        return try? GeoPolyline(vertices: points.map { $0.toGeoCoordinates() })
    }

    private func makeRepresentation(state: PolylineState) -> MapPolyline.Representation? {
        guard let width = try? MapMeasureDependentRenderSize(sizeUnit: .densityIndependentPixels, size: max(0.0, state.strokeWidth)) else {
            return nil
        }
        return try? MapPolyline.SolidRepresentation(
            lineWidth: width,
            color: state.strokeColor,
            capShape: .round
        )
    }
}
