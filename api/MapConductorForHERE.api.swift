import Combine
import CoreGraphics
import Foundation
import MapConductorCore
import QuartzCore
import Swift
import SwiftUI
import UIKit
import _Concurrency
import _StringProcessing
import _SwiftConcurrencyShims
import heresdk
public protocol HereMapDesignTypeProtocol : MapConductorCore.MapDesignTypeProtocol where Self.Identifier == heresdk.MapScheme {
}
public typealias HereMapDesignType = any MapConductorForHERE.HereMapDesignTypeProtocol
public struct HereMapDesign : MapConductorForHERE.HereMapDesignTypeProtocol, Swift.Hashable {
  public let id: heresdk.MapScheme
  public let attributionRules: [MapConductorCore.AttributionRule]
  public init(id: heresdk.MapScheme, attributionRules: [MapConductorCore.AttributionRule] = [])
  public func getValue() -> heresdk.MapScheme
  public static let NormalDay: MapConductorForHERE.HereMapDesign
  public static let NormalNight: MapConductorForHERE.HereMapDesign
  public static let Satellite: MapConductorForHERE.HereMapDesign
  public static let HybridDay: MapConductorForHERE.HereMapDesign
  public static let HybridNight: MapConductorForHERE.HereMapDesign
  public static let LiteDay: MapConductorForHERE.HereMapDesign
  public static let LiteNight: MapConductorForHERE.HereMapDesign
  public static let LiteHybridDay: MapConductorForHERE.HereMapDesign
  public static let LiteHybridNight: MapConductorForHERE.HereMapDesign
  public static let LogisticsDay: MapConductorForHERE.HereMapDesign
  public static let LogisticsNight: MapConductorForHERE.HereMapDesign
  public static let LogisticsHybridDay: MapConductorForHERE.HereMapDesign
  public static let LogisticsHybridNight: MapConductorForHERE.HereMapDesign
  public static let RoadNetworkDay: MapConductorForHERE.HereMapDesign
  public static let RoadNetworkNight: MapConductorForHERE.HereMapDesign
  public static func Create(id: heresdk.MapScheme) -> MapConductorForHERE.HereMapDesign
  public static func == (a: MapConductorForHERE.HereMapDesign, b: MapConductorForHERE.HereMapDesign) -> Swift.Bool
  public typealias Identifier = heresdk.MapScheme
  public func hash(into hasher: inout Swift.Hasher)
  public var hashValue: Swift.Int {
    get
  }
}
@_Concurrency.MainActor @preconcurrency public struct HereMapView : SwiftUICore.View {
  @_Concurrency.MainActor @preconcurrency public init(state: MapConductorForHERE.HereMapViewState, projection: MapConductorCore.MapProjection = .globe, cameraRestriction: MapConductorCore.CameraRestriction? = nil, onMapLoaded: MapConductorCore.OnMapLoadedHandler<MapConductorForHERE.HereMapViewState>? = nil, onMapClick: MapConductorCore.OnMapEventHandler? = nil, onMapLongClick: MapConductorCore.OnMapEventHandler? = nil, onCameraMoveStart: MapConductorCore.OnCameraMoveHandler? = nil, onCameraMove: MapConductorCore.OnCameraMoveHandler? = nil, onCameraMoveEnd: MapConductorCore.OnCameraMoveHandler? = nil, sdkInitialize: (() -> Swift.Void)? = nil, @MapConductorCore.MapViewContentBuilder content: @escaping () -> MapConductorCore.MapViewContent = { MapViewContent() })
  @_Concurrency.MainActor @preconcurrency public var body: some SwiftUICore.View {
    get
  }
  public typealias Body = @_opaqueReturnTypeOf("$s19MapConductorForHERE04HereA4ViewV4bodyQrvp", 0) __
}
final public class HereMapViewState : MapConductorCore.MapViewState<MapConductorForHERE.HereMapDesignType> {
  final public var mapViewHolder: MapConductorForHERE.HereViewHolder? {
    get
  }
  override final public var mapDesignType: MapConductorForHERE.HereMapDesignType {
    get
    set
  }
  public init(id: Swift.String, mapDesignType: MapConductorForHERE.HereMapDesignType = HereMapDesign.NormalDay, cameraPosition: MapConductorCore.MapCameraPosition = .Default, uiSettings: MapConductorCore.MapUISettings = MapUISettings())
  convenience public init(mapDesignType: MapConductorForHERE.HereMapDesignType = HereMapDesign.NormalDay, cameraPosition: MapConductorCore.MapCameraPosition = .Default, uiSettings: MapConductorCore.MapUISettings = MapUISettings())
  override final public func getMapViewHolder() -> MapConductorCore.AnyMapViewHolder?
  @objc deinit
}
public typealias HereViewState = MapConductorForHERE.HereMapViewState
public func initializeHERE(accessKeyId: Swift.String, accessKeySecret: Swift.String) throws
public func hereKeyInitialize(accessKeyId: Swift.String, accessKeySecret: Swift.String) throws
public typealias HereActualMarker = heresdk.MapMarker
public typealias HereActualPolyline = heresdk.MapPolyline
public typealias HereActualPolygon = [heresdk.MapPolygon]
public typealias HereActualCircle = heresdk.MapPolygon
public typealias HereActualGroundImage = MapConductorForHERE.HereGroundImageHandle
extension MapConductorCore.MapCameraPosition {
  final public func toMapCameraUpdate() -> heresdk.MapCameraUpdate
}
final public class HereZoomAltitudeConverter : MapConductorCore.ZoomAltitudeConverterProtocol {
  public static let hereZoomToGoogleZoomAtEquator: Swift.Double
  final public let zoom0Altitude: Swift.Double
  public init(zoom0Altitude: Swift.Double = 171_319_879.0)
  public static func hereZoomToGoogleZoom(_ hereZoom: Swift.Double, latitude: Swift.Double) -> Swift.Double
  public static func googleZoomToHereZoom(_ googleZoom: Swift.Double, latitude: Swift.Double) -> Swift.Double
  final public func zoomLevelToAltitude(zoomLevel: Swift.Double, latitude: Swift.Double, tilt: Swift.Double) -> Swift.Double
  final public func altitudeToZoomLevel(altitude: Swift.Double, latitude: Swift.Double, tilt: Swift.Double) -> Swift.Double
  @objc deinit
}
@_hasMissingDesignatedInitializers @_Concurrency.MainActor final public class HereViewHolder : @preconcurrency MapConductorCore.MapViewHolderProtocol {
  public typealias ActualMapView = heresdk.MapView
  public typealias ActualMap = heresdk.MapScene
  @_Concurrency.MainActor final public let mapView: heresdk.MapView
  @_Concurrency.MainActor final public var map: heresdk.MapScene {
    get
  }
  @_Concurrency.MainActor final public func toScreenOffset(position: any MapConductorCore.GeoPointProtocol) -> CoreFoundation.CGPoint?
  @_Concurrency.MainActor final public func fromScreenOffset(offset: CoreFoundation.CGPoint) async -> MapConductorCore.GeoPoint?
  @_Concurrency.MainActor final public func fromScreenOffsetSync(offset: CoreFoundation.CGPoint) -> MapConductorCore.GeoPoint?
  @objc deinit
}
@_hasMissingDesignatedInitializers final public class HereGroundImageHandle {
  @objc deinit
}
extension MapConductorForHERE.HereMapView : Swift.Sendable {}
extension MapConductorForHERE.HereViewHolder : Swift.Sendable {}
