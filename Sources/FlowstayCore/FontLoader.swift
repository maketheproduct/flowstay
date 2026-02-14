import AppKit
import CoreText

/// Utility to register custom fonts bundled with the app
public class FontLoader {
    public static func registerFonts() {
        // Get the bundle for FlowstayUI where fonts are located
        var bundle: Bundle?

        // Approach 1: Look for resource bundle by name
        if let resourcePath = Bundle.main.resourcePath {
            let bundlePath = (resourcePath as NSString).appendingPathComponent("Flowstay_FlowstayUI.bundle")
            bundle = Bundle(path: bundlePath)
            if bundle != nil {
                print("[FontLoader] ✅ Found bundle via main.resourcePath")
            }
        }

        // Approach 2: Search all bundles
        if bundle == nil {
            bundle = Bundle.allBundles.first(where: { $0.bundlePath.contains("FlowstayUI") })
            if bundle != nil {
                print("[FontLoader] ✅ Found bundle via allBundles search")
            }
        }

        guard let resourceBundle = bundle else {
            print("[FontLoader] ⚠️ FlowstayUI bundle not found - using system fonts as fallback")
            print("[FontLoader] This is acceptable; app will use system default fonts")
            return
        }

        // Find all TTF font files in the bundle root (SPM flattens resources)
        let fontURLs = [
            resourceBundle.url(forResource: "AlbertSans-VariableFont_wght", withExtension: "ttf"),
            resourceBundle.url(forResource: "AlbertSans-Italic-VariableFont_wght", withExtension: "ttf"),
        ].compactMap(\.self)

        if fontURLs.isEmpty {
            print("[FontLoader] ⚠️ No font files found in bundle - using system fonts as fallback")
            return
        }

        print("[FontLoader] Found \(fontURLs.count) font files")

        var successCount = 0
        for fontURL in fontURLs {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error) {
                if let error = error?.takeRetainedValue() {
                    print("[FontLoader] ❌ Failed to register font: \(fontURL.lastPathComponent) - \(error)")
                }
            } else {
                print("[FontLoader] ✅ Registered font: \(fontURL.lastPathComponent)")
                successCount += 1
            }
        }

        if successCount == 0 {
            print("[FontLoader] ⚠️ No fonts registered successfully - app will use system fonts")
        } else {
            print("[FontLoader] ✅ Successfully registered \(successCount)/\(fontURLs.count) fonts")
        }
    }
}
