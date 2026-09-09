import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)

        
        SecureStoragePlugin.register(with: flutterViewController.registrar(forPlugin: "SecureStoragePlugin"))
        NotificationPlugin.register(with: flutterViewController.registrar(forPlugin: "NotificationPlugin"))
        RegisterGeneratedPlugins(registry: flutterViewController)

        super.awakeFromNib()
    }
}
