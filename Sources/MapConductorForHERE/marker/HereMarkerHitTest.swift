import CoreGraphics
import Foundation
import heresdk
@_spi(MapConductorDriver) import MapConductorCore

/// Screen-space marker hit test, shared by the native-marker path
/// (`HereMarkerController.hitTest`) and the strategy-marker path
/// (`HereMapView`'s coordinator, used for clustering).
///
/// 選び方はコアの ``MarkerHitTest/pick`` と同じ（android-sdk の `AbstractMarkerController.find` とも
/// 同じ）。指の下にアイコン（ラベル込み）が描かれているマーカーを、アンカーの近い別のマーカーより
/// 優先し、どれにも当たらなければ `Settings.Default.tapTolerance` 以内でアンカーの近いものを選ぶ。
///
/// HERE のビュー座標は物理ピクセルなので、`pixelScale` で割ってポイントに直してから比べる。
enum HereMarkerHitTest {
    /// - Parameters:
    ///   - screenPoint: tap location in HERE view coordinates (physical pixels).
    ///   - states: the markers to consider; callers filter for eligibility first.
    ///   - defaultIcon: icon used to size markers that carry none.
    static func find(
        at screenPoint: CGPoint,
        in mapView: MapView,
        states: [MarkerState],
        defaultIcon: any MarkerIconProtocol
    ) -> MarkerState? {
        let pixelScale = max(CGFloat(mapView.pixelScale), 1)
        let touch = CGPoint(x: screenPoint.x / pixelScale, y: screenPoint.y / pixelScale)
        return MarkerHitTest.pick(
            touchScreen: touch,
            candidates: states,
            state: { $0 },
            project: { position in
                mapView.geoToViewCoordinates(geoCoordinates: position.toGeoCoordinates()).map {
                    CGPoint(x: CGFloat($0.x) / pixelScale, y: CGFloat($0.y) / pixelScale)
                }
            },
            defaultIcon: defaultIcon
        )
    }
}
