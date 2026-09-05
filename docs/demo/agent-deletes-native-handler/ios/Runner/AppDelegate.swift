import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        // The registration an agent would also remove once the class is gone.
        CameraPlugin.register(with: registrar(forPlugin: "CameraPlugin")!)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}
