import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Renders the README animations into docs/images/readme/<language>/<name>.gif.
//
//     readme-media <repository root>                     every GIF
//     readme-media <repository root> <name>              one GIF, in every language
//     readme-media <repository root> <name> <lang>       one GIF, in one language
//     readme-media <repository root> <name> <lang> <t>   one frame as a PNG in the
//                                                        current folder, to check a layout
//
// The name all stands for every scene, so readme-media . all ja writes every Japanese GIF.

let framesPerSecond = 10.0

@MainActor
func render(_ scene: Scene, _ lang: Lang, at t: Double) -> CGImage? {
    let view = scene.frame(t, lang)
        .frame(width: scene.size.width, height: scene.size.height)
        .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    return renderer.cgImage
}

func pixels(_ image: CGImage) -> Data? {
    image.dataProvider?.data as Data?
}

@MainActor
func writeGIF(_ scene: Scene, _ lang: Lang, to url: URL) throws {
    // Identical frames in a row become one longer frame, which keeps the file small.
    var frames: [(image: CGImage, delay: Double)] = []
    var last: Data?
    let count = Int((scene.duration(lang) * framesPerSecond).rounded())
    for index in 0..<count {
        guard let image = render(scene, lang, at: Double(index) / framesPerSecond) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let data = pixels(image)
        if let data, data == last, !frames.isEmpty {
            frames[frames.count - 1].delay += 1 / framesPerSecond
        } else {
            frames.append((image, 1 / framesPerSecond))
            last = data
        }
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
    CGImageDestinationSetProperties(destination, loop)
    for frame in frames {
        let delay = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: frame.delay,
            kCGImagePropertyGIFUnclampedDelayTime: frame.delay,
        ]] as CFDictionary
        CGImageDestinationAddImage(destination, frame.image, delay)
    }
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("\(url.path): \(frames.count) frames, \(size / 1024) KB")
}

@MainActor
func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

@MainActor
func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        print("usage: readme-media <repository root> [name [lang [t]]]")
        exit(2)
    }
    let root = URL(fileURLWithPath: arguments[1])
    let icon = NSImage(contentsOf: root.appendingPathComponent("site/icon.png"))
    var scenes = allScenes(icon: icon)
    if arguments.count >= 3, arguments[2] != "all" {
        scenes = scenes.filter { $0.name == arguments[2] }
        guard !scenes.isEmpty else {
            print("no scene named \(arguments[2])")
            exit(2)
        }
    }
    var langs = Lang.allCases
    if arguments.count >= 4 {
        guard let lang = Lang(rawValue: arguments[3]) else {
            print("no language \(arguments[3]), use en, zh, ja or es")
            exit(2)
        }
        langs = [lang]
    }
    if arguments.count >= 5 {
        guard let t = Double(arguments[4]), scenes.count == 1 else {
            print("a frame needs one scene and a time in seconds")
            exit(2)
        }
        // The first frame a process draws can come out slightly different while the fonts
        // load, so this frame is drawn once before the one that is written.
        _ = render(scenes[0], langs[0], at: t)
        guard let image = render(scenes[0], langs[0], at: t) else { exit(1) }
        let url = URL(fileURLWithPath: "\(scenes[0].name)-\(langs[0].rawValue)-\(arguments[4]).png")
        writePNG(image, to: url)
        print(url.path)
        return
    }
    // The first frames a process draws can come out slightly different while the fonts
    // load, so every frame is drawn once before any GIF is written.
    for lang in langs {
        for scene in scenes {
            for index in 0..<Int((scene.duration(lang) * framesPerSecond).rounded()) {
                _ = render(scene, lang, at: Double(index) / framesPerSecond)
            }
        }
    }
    for lang in langs {
        let folder = root.appendingPathComponent("docs/images/readme/\(lang.rawValue)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for scene in scenes {
            try writeGIF(scene, lang, to: folder.appendingPathComponent("\(scene.name).gif"))
        }
    }
}

try MainActor.assumeIsolated {
    try main()
}
