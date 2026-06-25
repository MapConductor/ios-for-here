import heresdk
import MapConductorCore

extension GeoPointProtocol {
    func toGeoCoordinates() -> GeoCoordinates {
        GeoCoordinates(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude ?? 0.0
        )
    }
}

extension GeoPoint {
    static func from(_ coordinates: GeoCoordinates) -> GeoPoint {
        GeoPoint(
            latitude: coordinates.latitude,
            longitude: coordinates.longitude,
            altitude: coordinates.altitude ?? 0.0
        )
    }
}

extension GeoCoordinates {
    func toGeoPoint() -> GeoPoint {
        GeoPoint.from(self)
    }

    func toUpdate() -> GeoCoordinatesUpdate {
        GeoCoordinatesUpdate(self)
    }
}

extension GeoOrientation {
    func toUpdate() -> GeoOrientationUpdate {
        GeoOrientationUpdate(self)
    }
}

extension GeoBox {
    func toGeoRectBounds() -> GeoRectBounds {
        GeoRectBounds(
            southWest: southWestCorner.toGeoPoint(),
            northEast: northEastCorner.toGeoPoint()
        )
    }
}

extension GeoRectBounds {
    func toGeoBox() -> GeoBox? {
        guard let sw = southWest, let ne = northEast else { return nil }
        return GeoBox(
            southWestCorner: GeoCoordinates(latitude: sw.latitude, longitude: sw.longitude),
            northEastCorner: GeoCoordinates(latitude: ne.latitude, longitude: ne.longitude)
        )
    }
}
