# README animations

This tool draws the animations in the Features table of README.md, README.zh-CN.md,
README.ja.md and README.es.md. It is not part of the app and the Xcode project does not see it.

Each animation is a small SwiftUI scene, styled like Orra's own interface (the dark capsule
with white bars, the translation badge, the notice after a learned word, the caption window).
The tool renders the scene frame by frame with ImageRenderer and writes a GIF with ImageIO.
They are drawings, not screen recordings, so they need no permission and no running Orra.

- Kit.swift: the shared pieces, drawn with plain shapes, since ImageRenderer cannot draw
  AppKit controls or blurred backgrounds.
- Scenes.swift: the six scenes and their timing. Speech appears at about 8.5 Chinese or
  Japanese characters or 15 Latin characters a second, as on the website.
- main.swift: renders the frames, merges identical frames in a row and writes the GIFs.

## Make the GIFs again

From the repository root:

    swiftc -O -swift-version 6 Tools/readme-media/*.swift -o /tmp/readme-media
    /tmp/readme-media .

It writes docs/images/readme/en, zh, ja and es, one GIF of each scene in each, 600 pixels
wide at 10 frames a second, and prints the size of each. Each one is well under 100 KB.

A run can write a scene that did not change with other bytes, since the text of a few frames
can come out slightly different while the fonts load. Put back the GIFs you did not mean to
change with git checkout.

To check one frame of one scene as a PNG in the current folder:

    /tmp/readme-media . meeting zh 7.5

The scene names are dictation, vocabulary, cleanup, translation, meeting and updates, and the
languages are en, zh, ja and es.

## Rules for the content

- Keep the GIFs of a scene the same in every language, apart from the language of the
  interface and of what is said. The English GIFs of translation and meeting show the
  Chinese speaker.
- Show only what Orra does with the dictation language of the GIF. The Japanese and Spanish
  GIFs say their own language, except where a step works on English sentences only:
  - dictation says no filler, since the filler rule knows Chinese and English fillers and
    does not run on a Japanese or Spanish sentence. The sentence is pasted as it is said.
  - vocabulary corrects an English sentence and then says one, since with Japanese or
    Spanish Orra learns from corrections of English sentences only.
  - cleanup says an English sentence, since with Japanese or Spanish Clean Up Text works on
    English sentences only.
  - Their interface is in Japanese or Latin American Spanish, with Orra's own strings and
    Sparkle's own texts in the update window.
- The Japanese and Spanish GIFs draw a few details closer to the app than the English and
  Chinese ones (see Lang.keepsFirstDrawing in Kit.swift). Give the English and Chinese GIFs
  these details the next time they are made.
- Use the names the app uses (Live Captions, Speak Translations to Others) and the website's
  example sentences where a scene has one.
- Make up no numbers, and show no real person, company or other project.
