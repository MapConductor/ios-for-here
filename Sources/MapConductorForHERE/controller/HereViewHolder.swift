import CoreGraphics
import heresdk
import MapConductorCore

@MainActor
public final class HereViewHolder: @preconcurrency MapViewHolderProtocol {
    public typealias ActualMapView = MapView
    public typealias ActualMap = MapScene

    public let mapView: MapView
    public var map: MapScene { mapView.mapScene }

    init(mapView: MapView) {
        self.mapView = mapView
    }

    public func toScreenOffset(position: GeoPointProtocol) -> CGPoint? {
        guard let point = mapView.geoToViewCoordinates(geoCoordinates: position.toGeoCoordinates()) else { return nil }
        return point.toUIKitPoint(pixelScale: mapView.pixelScale)
    }

    public func fromScreenOffset(offset: CGPoint) async -> GeoPoint? {
        fromScreenOffsetSync(offset: offset)
    }

    public func fromScreenOffsetSync(offset: CGPoint) -> GeoPoint? {
        let point = Point2D.fromUIKitPoint(offset, pixelScale: mapView.pixelScale)
        return mapView.viewToGeoCoordinates(viewCoordinates: point)?.toGeoPoint()
    }
}

extension Point2D {
    func toUIKitPoint(pixelScale: Double) -> CGPoint {
        let scale = pixelScale > 0.0 ? pixelScale : 1.0
        return CGPoint(x: x / scale, y: y / scale)
    }

    static func fromUIKitPoint(_ point: CGPoint, pixelScale: Double) -> Point2D {
        let scale = pixelScale > 0.0 ? pixelScale : 1.0
        return Point2D(x: point.x * scale, y: point.y * scale)
    }
}
