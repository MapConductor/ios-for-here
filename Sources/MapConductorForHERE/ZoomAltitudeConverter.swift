import Foundation
import MapConductorCore

public final class HereZoomAltitudeConverter: ZoomAltitudeConverterProtocol {
    public static let hereZoomToGoogleZoomAtEquator = 0.0

    public let zoom0Altitude: Double
    private let zoomFactor = 2.0
    private let minZoomLevel = 0.0
    private let maxZoomLevel = 22.0
    private let minAltitude = 100.0
    private let maxAltitude = 50_000_000.0
    private let minCosLat = 0.01
    private let minCosTilt = 0.05

    public init(zoom0Altitude: Double = 171_319_879.0) {
        self.zoom0Altitude = zoom0Altitude
    }

    public static func hereZoomToGoogleZoom(_ hereZoom: Double, latitude: Double) -> Double {
        let googleZoom = hereZoom + hereZoomToGoogleZoomAtEquator + latitudeZoomCorrection(latitude)
        return clamp(googleZoom, min: 0.0, max: 22.0)
    }

    public static func googleZoomToHereZoom(_ googleZoom: Double, latitude: Double) -> Double {
        let hereZoom = googleZoom - hereZoomToGoogleZoomAtEquator - latitudeZoomCorrection(latitude)
        return clamp(hereZoom, min: 0.0, max: 22.0)
    }

    public func zoomLevelToAltitude(zoomLevel: Double, latitude: Double, tilt: Double) -> Double {
        let clampedZoom = Self.clamp(zoomLevel, min: minZoomLevel, max: maxZoomLevel)
        let distance = (zoom0Altitude * cosLatitudeFactor(latitude)) / pow(zoomFactor, clampedZoom)
        let altitude = distance * cosTiltFactor(tilt)
        return Self.clamp(altitude, min: minAltitude, max: maxAltitude)
    }

    public func altitudeToZoomLevel(altitude: Double, latitude: Double, tilt: Double) -> Double {
        let clampedAltitude = Self.clamp(altitude, min: minAltitude, max: maxAltitude)
        let distance = clampedAltitude / cosTiltFactor(tilt)
        let zoom = log2((zoom0Altitude * cosLatitudeFactor(latitude)) / distance)
        return Self.clamp(zoom, min: minZoomLevel, max: maxZoomLevel)
    }

    private static func latitudeZoomCorrection(_ latitude: Double) -> Double {
        log2(cosLatitudeFactor(latitude))
    }

    private static func cosLatitudeFactor(_ latitude: Double) -> Double {
        max(0.01, cos(latitude * .pi / 180.0))
    }

    private func cosLatitudeFactor(_ latitude: Double) -> Double {
        Self.cosLatitudeFactor(latitude)
    }

    private func cosTiltFactor(_ tilt: Double) -> Double {
        max(minCosTilt, cos(tilt * .pi / 180.0))
    }

    private static func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        max(minValue, min(value, maxValue))
    }
}
