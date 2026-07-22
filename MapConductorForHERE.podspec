Pod::Spec.new do |s|
  s.name = "MapConductorForHERE"
  s.version = "1.0.0"
  s.summary = "MapConductor's HERE Maps provider."
  s.license = { :type => "Apache-2.0", :file => "LICENSE" }
  s.author = "MapConductor"
  s.homepage = "https://github.com/MapConductor/ios-for-here"
  s.source = { :path => __dir__ }
  s.platform = :ios, "16.0"
  s.swift_version = "5.9"
  s.source_files = "Sources/MapConductorForHERE/**/*.swift"
  s.dependency "MapConductorCore"
  # ios-sdk/CLAUDE.md's "iOS Provider Distribution" section says a *dynamic* vendor framework
  # (heresdk.xcframework is confirmed dynamic - `file .../heresdk` reports "Mach-O 64-bit
  # dynamically linked shared library") should normally stay a plain `s.dependency "VendorSDK"`
  # resolved from that vendor's own public podspec, same as `s.dependency "MapLibre"` in
  # ios-for-maplibre's podspec. HERE has no such public pod - the SDK is only distributed as a
  # binary you download from the HERE developer portal - so there is nothing to `s.dependency`
  # against. Vendor it directly instead.
  #
  # CocoaPods silently drops `vendored_frameworks` paths that escape the pod's own directory tree
  # (a plain `../heresdk/frameworks/heresdk.xcframework` resolves on disk but never gets copied
  # into PODS_XCFRAMEWORKS_BUILD_DIR or added to FRAMEWORK_SEARCH_PATHS - confirmed by grepping
  # the generated Pods.xcodeproj for "heresdk" after `pod install` and finding nothing) - so
  # Frameworks/heresdk.xcframework here is a symlink back to the real proprietary binary in
  # ../heresdk/frameworks, keeping this path pod's own directory as the one CocoaPods reference.
  # Package.swift's `.binaryTarget` does not have this restriction and still points directly at
  # ../heresdk/frameworks/heresdk.xcframework.
  s.vendored_frameworks = "Frameworks/heresdk.xcframework"
end
