import heresdk
import MapConductorCore

private let converter = HereZoomAltitudeConverter()

struct HereDisplayCamera {
    let target: GeoPoint
    let tiltDeg: Double
    let hereZoomLevel: Double
    let bearing: Double
}

extension MapCameraPosition {
    func toHereDisplayCamera() -> HereDisplayCamera {
        let target = GeoPoint.from(position: position)
        return HereDisplayCamera(
            target: target,
            tiltDeg: max(0.0, min(tilt, 90.0)),
            hereZoomLevel: HereZoomAltitudeConverter.googleZoomToHereZoom(zoom, latitude: target.latitude),
            bearing: bearing
        )
    }

}

public extension MapCameraPosition {
    func toMapCameraUpdate() -> MapCameraUpdate {
        let display = toHereDisplayCamera()
        return MapCameraUpdateFactory.lookAt(
            point: display.target.toGeoCoordinates().toUpdate(),
            orientation: GeoOrientation(bearing: display.bearing, tilt: display.tiltDeg).toUpdate(),
            measure: MapMeasure(kind: .zoomLevel, value: display.hereZoomLevel)
        )
    }
}

extension MapCamera.State {
    func toMapCameraPosition(visibleRegion: VisibleRegion? = nil) -> MapCameraPosition {
        let position = targetCoordinates.toGeoPoint()
        return MapCameraPosition(
            position: position,
            zoom: HereZoomAltitudeConverter.hereZoomToGoogleZoom(zoomLevel, latitude: position.latitude),
            bearing: orientationAtTarget.bearing,
            tilt: orientationAtTarget.tilt,
            visibleRegion: visibleRegion
        )
    }
}
