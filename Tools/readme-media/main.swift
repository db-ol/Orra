import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Renders the README animations into docs/images/readme/<language>/<name>.gif.
//
//     readme-media <repository root>                     every GIF
//     readme-media <repository root> <name>              one GIF, in every language
//     readme-media <repository root> <name> <lang> <t>   one frame as a PNG in the
//                                                        current folder, to check a layout

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
        print("usage: readme-media <repository root> [name [lang t]]")
        exit(2)
    }
    let root = URL(fileURLWithPath: arguments[1])
    let icon = NSImage(contentsOf: root.appendingPathComponent("site/icon.png"))
    var scenes = allScenes(icon: icon)
    if arguments.count >= 3 {
        scenes = scenes.filter { $0.name == arguments[2] }
        guard !scenes.isEmpty else {
            print("no scene named \(arguments[2])")
            exit(2)
        }
    }
    if arguments.count >= 5, let lang = Lang(rawValue: arguments[3]), let t = Double(arguments[4]) {
        guard let image = render(scenes[0], lang, at: t) else { exit(1) }
        let url = URL(fileURLWithPath: "\(scenes[0].name)-\(lang.rawValue)-\(arguments[4]).png")
        writePNG(image, to: url)
        print(url.path)
        return
    }
    for lang in Lang.allCases {
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
