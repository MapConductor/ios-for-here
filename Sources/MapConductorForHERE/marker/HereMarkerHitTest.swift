import CoreGraphics
import Foundation
import heresdk
import MapConductorCore

/// Screen-space marker hit test, shared by the native-marker path
/// (`HereMarkerController.hitTest`) and the strategy-marker path
/// (`HereMapView`'s coordinator, used for clustering).
///
/// Mirrors `HereMarkerController.find` on Android: the icon's own box expanded by
/// `Settings.Default.tapTolerance` on every side, with overlapping markers broken
/// by distance to the anchor.
///
/// This replaced an iOS-only "44pt minimum touch target" floor
/// (`max(iconSize × scale, 44)`), which never actually applied to the default 48pt
/// icon and which refused taps below the marker tip entirely. Measured on device,
/// the box went from 48/0/24/23 pt (up/down/left/right) to 62/13/38/37 pt.
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
        let pixelScale = CGFloat(mapView.pixelScale)
        let tolerancePx = Settings.Default.tapTolerance * pixelScale

        var bestState: MarkerState?
        var bestDistance = CGFloat.infinity

        for state in states {
            guard let p = mapView.geoToViewCoordinates(
                geoCoordinates: state.position.toGeoCoordinates()
            ) else { continue }

            let icon: any MarkerIconProtocol = state.icon ?? defaultIcon
            // Rendered size in physical pixels: iconSize (pts) × scale × pixelScale.
            // Icons are square canvases; anchor is normalized (0–1).
            let iconPx = icon.iconSize * icon.scale * pixelScale
            let renderedPx = iconPx + 2 * tolerancePx

            let left = CGFloat(p.x) - icon.anchor.x * iconPx - tolerancePx
            let top = CGFloat(p.y) - icon.anchor.y * iconPx - tolerancePx
            let hitRect = CGRect(x: left, y: top, width: renderedPx, height: renderedPx)

            guard hitRect.contains(screenPoint) else { continue }

            // Among overlapping markers prefer the one whose anchor is closest to the tap.
            let distance = hypot(screenPoint.x - CGFloat(p.x), screenPoint.y - CGFloat(p.y))
            if distance < bestDistance {
                bestDistance = distance
                bestState = state
            }
        }
        return bestState
    }
}
