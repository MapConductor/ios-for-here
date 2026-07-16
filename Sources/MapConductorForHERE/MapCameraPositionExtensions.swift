import Foundation
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
        if tilt < 0.0 {
            let tiltAbsDeg = min(abs(tilt), 60.0)
            let tiltRadians = tiltAbsDeg * .pi / 180.0
            let originalHereZoom = HereZoomAltitudeConverter.googleZoomToHereZoom(
                zoom,
                latitude: target.latitude
            )
            let altitude = converter.zoomLevelToAltitude(
                zoomLevel: originalHereZoom,
                latitude: target.latitude,
                tilt: 0.0
            )
            let shiftedTarget = Spherical.computeOffset(
                origin: target,
                distance: altitude * tan(tiltRadians),
                heading: bearing
            )
            let adjustedHereZoom = converter.altitudeToZoomLevel(
                altitude: altitude / max(cos(tiltRadians), 0.05),
                latitude: shiftedTarget.latitude,
                tilt: 0.0
            )
            
            NSLog("HERE (in)position=\(position),(in)tilt=\(tilt), (out)target=(\(shiftedTarget.latitude),\(shiftedTarget.longitude)), (out)tiltDeg=\(tiltAbsDeg), (out)hereZoomLevel=\(adjustedHereZoom)")
            return HereDisplayCamera(
                target: shiftedTarget,
                tiltDeg: tiltAbsDeg,
                hereZoomLevel: adjustedHereZoom,
                bearing: bearing
            )
        }
        
        let hereZoomLevel = HereZoomAltitudeConverter.googleZoomToHereZoom(zoom, latitude: target.latitude)
        NSLog("HERE (in)position=\(position),(in)tilt=\(tilt), (out)target=(\(target.latitude),\(target.longitude)), (out)tiltDeg=\(tilt), (out)hereZoomLevel=\(hereZoomLevel)")
        return HereDisplayCamera(
            target: target,
            tiltDeg: min(tilt, 90.0),
            hereZoomLevel: hereZoomLevel,
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
    func toMapCameraPosition(
        logicalTiltHint: Double? = nil,
        visibleRegion: VisibleRegion? = nil
    ) -> MapCameraPosition {
        let position = targetCoordinates.toGeoPoint()
        let nativeTilt = orientationAtTarget.tilt
        let tiltAbsDeg = min(abs(nativeTilt), 90.0)

        if let logicalTiltHint, logicalTiltHint < 0.0, tiltAbsDeg > 0.0 {
            let tiltRadians = tiltAbsDeg * .pi / 180.0
            let adjustedAltitude = converter.zoomLevelToAltitude(
                zoomLevel: zoomLevel,
                latitude: position.latitude,
                tilt: 0.0
            )
            let originalAltitude = adjustedAltitude * cos(tiltRadians)
            let originalCenter = Spherical.computeOffset(
                origin: position,
                distance: originalAltitude * tan(tiltRadians),
                heading: orientationAtTarget.bearing + 180.0
            )
            let originalHereZoom = converter.altitudeToZoomLevel(
                altitude: originalAltitude,
                latitude: originalCenter.latitude,
                tilt: 0.0
            )
            return MapCameraPosition(
                position: originalCenter,
                zoom: HereZoomAltitudeConverter.hereZoomToGoogleZoom(
                    originalHereZoom,
                    latitude: originalCenter.latitude
                ),
                bearing: orientationAtTarget.bearing,
                tilt: -tiltAbsDeg,
                visibleRegion: visibleRegion
            )
        }

        return MapCameraPosition(
            position: position,
            zoom: HereZoomAltitudeConverter.hereZoomToGoogleZoom(zoomLevel, latitude: position.latitude),
            bearing: orientationAtTarget.bearing,
            tilt: nativeTilt,
            visibleRegion: visibleRegion
        )
    }
}
