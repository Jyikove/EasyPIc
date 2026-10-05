import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Make the local EasyPic build the default for formats its ImageIO viewer supports.
@main
struct SetDefaultImageApp {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "EasyPicDefaults", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: set-default-image-app APP_PATH BACKUP_PATH"])
        }
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let backupURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        guard Bundle(url: appURL)?.bundleIdentifier == "local.jyikove.easypic" else {
            throw NSError(domain: "EasyPicDefaults", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The app path does not point to EasyPic"])
        }
        let registration = LSRegisterURL(appURL as CFURL, true)
        guard registration == noErr else {
            throw NSError(domain: "EasyPicDefaults", code: Int(registration),
                          userInfo: [NSLocalizedDescriptionKey: "Could not register EasyPic with macOS"])
        }

        // JPG/JPEG/JPE, TIF/TIFF and BMP/DIB aliases share a UTType; APNG shares PNG.
        let identifiers = ["public.jpeg", "public.png", "com.compuserve.gif",
                           "org.webmproject.webp", "public.heic", "public.heif",
                           "public.heics", "public.tiff", "com.microsoft.bmp", "public.avif"]
        let workspace = NSWorkspace.shared
        let previous = identifiers.map { identifier -> [String: String] in
            let type = UTType(identifier)!
            return ["type": identifier,
                    "application": workspace.urlForApplication(toOpen: type)?.path ?? ""]
        }
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            let data = try JSONSerialization.data(withJSONObject: previous, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: backupURL, options: .atomic)
        }

        var failed = false
        for identifier in identifiers {
            let type = UTType(identifier)!
            let error: Error? = await withCheckedContinuation { continuation in
                workspace.setDefaultApplication(at: appURL, toOpen: type) { error in
                    continuation.resume(returning: error)
                }
            }
            let current = workspace.urlForApplication(toOpen: type)?.standardizedFileURL
            let applied = error == nil && current == appURL
            print("\(applied ? "OK" : "FAILED") \(identifier) -> \(current?.path ?? "none")" +
                  (error.map { " (\($0.localizedDescription))" } ?? ""))
            if !applied { failed = true }
        }
        if failed {
            throw NSError(domain: "EasyPicDefaults", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Some default application changes did not apply"])
        }
        print("Previous associations saved at \(backupURL.path)")
    }
}
