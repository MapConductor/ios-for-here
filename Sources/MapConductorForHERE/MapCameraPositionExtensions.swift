import Foundation
import heresdk
@_spi(MapConductorDriver) import MapConductorCore

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
                heading: CameraBearing.toNativeHeading(bearing)
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
                bearing: CameraBearing.toNativeHeading(bearing)
            )
        }
        
        let hereZoomLevel = HereZoomAltitudeConverter.googleZoomToHereZoom(zoom, latitude: target.latitude)
        NSLog("HERE (in)position=\(position),(in)tilt=\(tilt), (out)target=(\(target.latitude),\(target.longitude)), (out)tiltDeg=\(tilt), (out)hereZoomLevel=\(hereZoomLevel)")
        return HereDisplayCamera(
            target: target,
            tiltDeg: min(tilt, 90.0),
            hereZoomLevel: hereZoomLevel,
            bearing: CameraBearing.toNativeHeading(bearing)
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

/// HERE（iOS）のカメラの縦の視野角（度）。
///
/// SDK は値を公開していない。iPad Pro 11 で、傾けた地図の中心と北の地点の画面位置から
/// 焦点距離を求めて実測した値（tilt 30°〜60° で一定）。
let hereVerticalFieldOfView: Double = 31.8

extension MapCamera.State {
    /// 地図の中心をそのまま `position` にする。パディングで中心をずらしているときの
    /// ターゲットへの戻しは呼び出し側（``CameraPaddingEmulation/restored(_:paddings:fov:viewportSize:unproject:)``）が行う。
    /// - Parameter paddings: 結果に載せるパディング。
    func toMapCameraPosition(
        logicalTiltHint: Double? = nil,
        paddings: MapPaddingsProtocol? = nil,
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
                bearing: CameraBearing.bearingFromNativeHeading(orientationAtTarget.bearing),
                tilt: -tiltAbsDeg,
                paddings: paddings ?? MapPaddings.Zeros,
                visibleRegion: visibleRegion,
                fov: hereVerticalFieldOfView
            )
        }

        return MapCameraPosition(
            position: position,
            zoom: HereZoomAltitudeConverter.hereZoomToGoogleZoom(zoomLevel, latitude: position.latitude),
            bearing: CameraBearing.bearingFromNativeHeading(orientationAtTarget.bearing),
            tilt: nativeTilt,
            paddings: paddings ?? MapPaddings.Zeros,
            visibleRegion: visibleRegion,
            fov: hereVerticalFieldOfView
        )
    }
}
