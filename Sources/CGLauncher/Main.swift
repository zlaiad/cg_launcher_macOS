import Foundation
import CGLauncherCore
import SwiftUI

@main
struct LauncherMain {
    @MainActor static func main() {
        if !CommandLine.arguments.contains("--probe") && !CommandLine.arguments.contains("--diagnose") && !CommandLine.arguments.contains("--assets") {
            CGLauncherApp.main()
            return
        }
        do {
            let installation = try Installation.discover()
            if CommandLine.arguments.contains("--probe") {
                let bridge: WineNetworkConfiguration?
                if CommandLine.arguments.contains("--native-network") { bridge = nil }
                else {
                    guard let helper = Bundle.main.url(forResource: "cg_network", withExtension: "exe") else {
                        throw LauncherError.message("请从应用包执行 --probe，或指定 --native-network。")
                    }
                    bridge = WineNetworkConfiguration(installation: installation, helper: helper)
                }
                for region in installation.regions {
                    try NativeAuthenticator.probe(endpoint: region.billing[0], bridge: bridge)
                    print("NATIVE_SWIFT_PROTOCOL_PING_OK region=\(region.id) transport=\(bridge == nil ? "macOS" : "CrossOver")")
                }
            } else if CommandLine.arguments.contains("--assets") {
                print(try installation.assetArguments().joined(separator: "\n"))
            } else {
                print("INSTALLATION_OK regions=\(installation.regions.count) assets=\(try installation.assetArguments().count)")
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
