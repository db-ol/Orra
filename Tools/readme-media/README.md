# README animations

This tool draws the animations in the Features table of README.md, README.zh-CN.md,
README.ja.md and README.es.md. It is not part of the app and the Xcode project does not see it.

Each animation is a small SwiftUI scene, styled like Orra's own interface (the dark capsule
with white bars, the translation badge, the notice after a learned word, the caption window).
The tool renders the scene frame by frame with ImageRenderer and writes a GIF with ImageIO.
They are drawings, not screen recordings, so they need no permission and no running Orra.

- Kit.swift: the shared pieces, drawn with plain shapes, since ImageRenderer cannot draw
  AppKit controls or blurred backgrounds.
- Scenes.swift: the six scenes and their timing. Speech appears at about 8.5 Chinese
  characters or 3 English words a second, as on the website. Japanese goes at the rate of
  Chinese and Spanish at the rate of English.
- main.swift: renders the frames, merges identical frames in a row and writes the GIFs.

## Make the GIFs again

From the repository root:

    swiftc -O -swift-version 6 Tools/readme-media/*.swift -o /tmp/readme-media
    /tmp/readme-media .

It writes docs/images/readme/en, zh, ja and es, one GIF of each scene in each, 600 pixels
wide at 10 frames a second, and prints the size of each. Each one is well under 100 KB.

To make the GIFs of one language, or one GIF in one language:

    /tmp/readme-media . all ja
    /tmp/readme-media . vocabulary es

The tool draws every frame once before it writes a GIF, since the first frames a run draws
can come out slightly different while the fonts load. So a run writes the same bytes for a
scene that did not change. The English GIFs of dictation, vocabulary and updates were written
before that and come out with other bytes that look the same. Put back the GIFs you did not
mean to change with git checkout.

To check one frame of one scene as a PNG in the current folder:

    /tmp/readme-media . meeting zh 7.5

The scene names are dictation, vocabulary, cleanup, translation, meeting and updates, and the
languages are en, zh, ja and es.

## Rules for the content

- Keep the GIFs of a scene the same in every language, apart from the language of the
  interface and of what is said. The English GIFs of translation and meeting show the
  Chinese speaker.
- Show only what Orra does with the dictation language of the GIF. The Japanese and Spanish
  GIFs have their interface in Japanese or Latin American Spanish, with Orra's own strings
  and Sparkle's own texts in the update window. Their speech is in their own language, with
  these limits:
  - dictation says no filler, since the filler rule knows Chinese and English fillers and
    does not run on a Japanese or Spanish sentence. The sentence is pasted as it is said.
  - vocabulary corrects an English sentence, since with Japanese or Spanish Orra learns
    from corrections of English sentences only. The next dictation is in the GIF's
    language, since the vocabulary and the learned word work in every language.
  - cleanup says an English sentence, since with Japanese or Spanish Clean Up Text works on
    English sentences only.
- Japanese speech is quoted with 「」, any other with “”.
- The talk key is in Hold, as for everyone who set Orra up before 0.5.0. The translation key
  is in Press to start and stop, the mode it starts in since 0.5.1 for everyone who never
  turned Translation on: a tap starts, the person speaks, and a second tap pastes. The text
  under each key is the hint of its mode without the key's name, which is on the key. The
  Spanish talk key shows its name, Tecla para hablar, since its hint does not fit there.
  While the translation key records, the capsule shows Press right Option to finish in the
  language of the GIF, as the app does.
- The caption window shows the three display modes with Both chosen, the caption target,
  which is the dictation language of the GIF, and Copy, dimmed until the first sentence.
  A sentence shows its original in the small style while its translation is pending.
- The Japanese and Spanish GIFs of vocabulary and updates draw a few details closer to the
  app than the English and Chinese ones (see Lang.keepsFirstDrawing in Kit.swift). Give the
  English and Chinese GIFs these details the next time they are made.
- Use the names the app uses (Live Captions, Speak Translations to Others) and the website's
  example sentences where a scene has one.
- Make up no numbers, and show no real person, company or other project.
