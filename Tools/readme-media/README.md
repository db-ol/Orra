# README animations

This tool draws the animations in the Features table of README.md and README.zh-CN.md. It is
not part of the app and the Xcode project does not see it.

Each animation is a small SwiftUI scene, styled like Orra's own interface (the dark capsule
with white bars, the 译 badge, the notice after a learned word, the caption window). The tool
renders the scene frame by frame with ImageRenderer and writes a GIF with ImageIO. They are
drawings, not screen recordings, so they need no permission and no running Orra.

- Kit.swift: the shared pieces, drawn with plain shapes, since ImageRenderer cannot draw
  AppKit controls or blurred backgrounds.
- Scenes.swift: the six scenes and their timing. Speech appears at about 8.5 Chinese
  characters or 15 Latin characters a second, as on the website.
- main.swift: renders the frames, merges identical frames in a row and writes the GIFs.

## Make the GIFs again

From the repository root:

    swiftc -O -swift-version 6 Tools/readme-media/*.swift -o /tmp/readme-media
    /tmp/readme-media .

It writes docs/images/readme/en/*.gif and docs/images/readme/zh/*.gif, 600 pixels wide at
10 frames a second, and prints the size of each. Each one is well under 100 KB.

To check one frame of one scene as a PNG in the current folder:

    /tmp/readme-media . meeting zh 7.5

The scene names are dictation, vocabulary, cleanup, translation, meeting and updates.

## Rules for the content

- Keep the English and the Chinese GIF of a scene the same, apart from the language of the
  interface.
- Use the names the app uses (Live Captions, Speak Translations to Others) and the website's
  example sentences where a scene has one.
- Make up no numbers, and show no real person, company or other project.
