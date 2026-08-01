import heresdk

public typealias HereActualMarker = MapMarker
public typealias HereActualPolyline = MapPolyline
/// 1 つの論理ポリゴン = 塗り（穴ありはブリッジ済み単一リング）＋輪郭（外周・各穴）の
/// MapPolygon 群。穴なしは fill+outline の 1 枚のみ。
public typealias HereActualPolygon = [MapPolygon]
public typealias HereActualCircle = MapPolygon
public typealias HereActualGroundImage = HereGroundImageHandle
