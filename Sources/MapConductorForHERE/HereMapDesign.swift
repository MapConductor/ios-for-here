import heresdk
import MapConductorCore

public protocol HereMapDesignTypeProtocol: MapDesignTypeProtocol where Identifier == MapScheme {}

public typealias HereMapDesignType = any HereMapDesignTypeProtocol

public struct HereMapDesign: HereMapDesignTypeProtocol, Hashable {
    public let id: MapScheme

    public init(id: MapScheme) {
        self.id = id
    }

    public func getValue() -> MapScheme {
        id
    }

    public static let NormalDay = HereMapDesign(id: .normalDay)
    public static let NormalNight = HereMapDesign(id: .normalNight)
    public static let Satellite = HereMapDesign(id: .satellite)
    public static let HybridDay = HereMapDesign(id: .hybridDay)
    public static let HybridNight = HereMapDesign(id: .hybridNight)
    public static let LiteDay = HereMapDesign(id: .liteDay)
    public static let LiteNight = HereMapDesign(id: .liteNight)
    public static let LiteHybridDay = HereMapDesign(id: .liteHybridDay)
    public static let LiteHybridNight = HereMapDesign(id: .liteHybridNight)
    public static let LogisticsDay = HereMapDesign(id: .logisticsDay)
    public static let LogisticsNight = HereMapDesign(id: .logisticsNight)
    public static let LogisticsHybridDay = HereMapDesign(id: .logisticsHybridDay)
    public static let LogisticsHybridNight = HereMapDesign(id: .logisticsHybridNight)
    public static let RoadNetworkDay = HereMapDesign(id: .roadNetworkDay)
    public static let RoadNetworkNight = HereMapDesign(id: .roadNetworkNight)

    public static func Create(id: MapScheme) -> HereMapDesign {
        switch id {
        case .normalDay:
            return NormalDay
        case .normalNight:
            return NormalNight
        case .satellite:
            return Satellite
        case .hybridDay:
            return HybridDay
        case .hybridNight:
            return HybridNight
        case .liteDay:
            return LiteDay
        case .liteNight:
            return LiteNight
        case .liteHybridDay:
            return LiteHybridDay
        case .liteHybridNight:
            return LiteHybridNight
        case .logisticsDay:
            return LogisticsDay
        case .logisticsNight:
            return LogisticsNight
        case .logisticsHybridDay:
            return LogisticsHybridDay
        case .logisticsHybridNight:
            return LogisticsHybridNight
        case .roadNetworkDay:
            return RoadNetworkDay
        case .roadNetworkNight:
            return RoadNetworkNight
        @unknown default:
            return HereMapDesign(id: id)
        }
    }
}
