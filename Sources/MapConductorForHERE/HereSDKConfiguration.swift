import heresdk

public func initializeHERE(accessKeyId: String, accessKeySecret: String) throws {
    if SDKNativeEngine.sharedInstance != nil { return }
    let authenticationMode = AuthenticationMode.withKeySecret(
        accessKeyId: accessKeyId,
        accessKeySecret: accessKeySecret
    )
    try SDKNativeEngine.makeSharedInstance(options: SDKOptions(authenticationMode: authenticationMode))
}

public func hereKeyInitialize(accessKeyId: String, accessKeySecret: String) throws {
    try initializeHERE(accessKeyId: accessKeyId, accessKeySecret: accessKeySecret)
}
