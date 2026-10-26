# Website

The product website lives in site/ and is published with GitHub Pages at
https://db-ol.github.io/Orra/.

## Files

- site/index.html is the English page.
- site/zh/index.html is the Simplified Chinese page.
- site/ja/index.html is the Japanese page.
- site/es/index.html is the Spanish page, in the Latin American Spanish of the interface
  (es-419).
- site/style.css is the one style sheet for every page. It follows the system's light or dark
  mode. The Japanese page lists Japanese fonts first, or its kanji would take the Chinese
  shapes of PingFang SC.
- site/site.js plays the three demos at the top of the page, dictation, cleanup and then
  translation, and fades sections in as they scroll into view. Without it, or when the Mac asks
  for reduced motion, the page shows all demos in their last frame and every section at once.
  The spoken line of each demo appears at about 8.5 characters a second in Chinese and
  Japanese and 3 words a second in English and Spanish, read from the lang of the line, so a
  longer line takes longer. Keep each line and each pasted text to two lines at 375 pixels
  wide. The cleanup demo shows an optional feature, so its caption says so.
- Each page shows its demos in its own language, as Orra works for a reader of that page.
  On the Chinese, Japanese and Spanish pages the speaker dictates in the page's language and
  translates between it and English. On the English page the speaker speaks English and
  translates between English and Chinese.
  - The Japanese and Spanish pages use the sentences of the animations in README.ja.md and
    README.es.md. They say a Japanese or Spanish sentence, pasted as it was said, since the
    filler rule and the cleanup model take English and Chinese only. The translation key
    turns it into English, with the badge the app shows for Automatic, 訳 in Japanese and ⇄
    in Spanish. Live Captions show English sentences with Japanese or Spanish translations,
    and the reply is spoken in English. The cleanup demo keeps the English sentence, since
    with Japanese or Spanish as the dictation language cleanup works on English sentences
    only, and its caption says so. The tile on learning from corrections says the same of
    learning, as the READMEs do. Spoken Japanese is quoted with 「」, as in the README
    animations.
  - The English page shows an English speaker whose dictation language is
    中文（普通话和粤语）+ English, the one Orra picks on a Mac in English. The translation
    key turns English into Chinese, with the 译 badge. Live Captions show Chinese sentences
    with English translations, and the reply is spoken in Chinese. These are the sentences
    of the Chinese README turned around. The English README animations still show the
    Chinese speaker.
  - The Chinese page shows the Chinese speaker of the Chinese README.

  Each line in another language than the page's carries its own lang, which site.js reads
  for the timing above and style.css for the fonts. Japanese lines, and the Chinese lines of
  the English page, wrap only at a <wbr> between phrases (word-break: keep-all in
  style.css), so that no line ends with a character or two alone, in Safari too. Put a <wbr>
  between the phrases of any such line you change. In a spoken line it goes between the
  said-words spans, since site.js rebuilds each span from its text.
- The Meeting Interpretation section draws the Live Captions window and a call in HTML and
  CSS. style.css plays it once when each part scrolls into view, through the class that
  site.js adds. Without site.js, or with reduced motion, it shows its last frame.
  The caption window has the top row of the app: Original, Translated and Both with Both
  chosen, the language captions translate into, which is the page's language, and Copy,
  dimmed until the first sentence comes in. Its symbols are small SVGs in style.css. Where
  the row does not fit, the modes turn into a pop up menu with the chosen one, as in the
  app. style.css sets that width for each language, so change it when a label changes.
- The Projects section, after Meeting Interpretation, says in two short paragraphs what the
  Projects row of the README says. It also says, as Settings, Projects does, that
  assigning, editing and deleting in Projects change only what it keeps on the Mac, never
  the mail in Mail. It links the Projects part of the user guide in the page's language.
  Its heading carries the Preview label that Settings shows beside the name, the
  preview-label class in style.css, in the word Orra uses in that language. Remove the
  label from all four pages when Projects leaves the preview. The sections after it keep
  the plain and the soft background alternating.
- site/icon.png and site/favicon.png are the app icon at 512 and 64 pixels. They are exported
  from Orra/AppIcon.icon with the ictool that ships inside Icon Composer.

The site is plain HTML and CSS with one small script of its own. There is no build step, no
framework, no web font, no cookie, no analytics and no tracker, and the page loads nothing
from another server. Keep it that way.

## Editing

1. Change all four pages together, so they say the same thing.
2. Keep every claim in line with README.md, the user guide in docs/user-guide.md and
   docs/privacy.md. Describe what the latest release does, not what is still in a pull
   request. Make up no numbers or quotes.
3. English text uses no em dash, en dash or semicolon. Chinese text uses full width
   punctuation (，。：？！（）“”) and a space between Chinese and a Latin word or a number.
   Japanese text uses 、。（）, “ ” around the names of settings and around quoted words, as
   macOS does, and no space between Japanese and a Latin word or a number. Spanish text uses
   tú, ¿? and ¡!, and the Latin American words of the interface, such as Configuración and
   la Mac. Name menus and settings as Orra shows them in that language.
4. Check the pages over HTTP, as GitHub Pages serves them. Run
   `python3 -m http.server -d site` and open http://localhost:8000/. The language and brand
   links point at folders, so they do not work when you open the files directly.
5. Merge to main. The Website workflow (.github/workflows/pages.yml) deploys site/ when a
   push to main changes it. Actions > Website > Run workflow deploys it by hand.

The Download button points to
https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg, so every release must
upload a copy of its DMG named Orra.dmg, as docs/releasing.md describes.

The version under the top Download button is plain text, once in each page ("Version 0.6.0",
"版本 0.6.0", "バージョン0.6.0" and "Versión 0.6.0"), next to the system requirements. After a
release is published, change it in all four pages and merge, so the site never names a
version that is not out yet. To find every place:

    grep -rn "0\.6\.0" site

The Download Orra Microphone link in the Meeting Interpretation section points at
OrraMicrophone.pkg in the v0.4.0 release, as README.md does. Change it only when a newer
release attaches its own OrraMicrophone.pkg.

To export the icon again after the icon changes:

    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" Orra/AppIcon.icon --export-image --output-file /tmp/icon1024.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
    sips -Z 512 /tmp/icon1024.png --out site/icon.png
    sips -Z 64 /tmp/icon1024.png --out site/favicon.png

## Adding a language

1. Copy site/index.html to site/<code>/index.html and translate it. Set lang on the html
   element, point the canonical link at the new folder, and put ../ in front of the icons,
   the style sheet and the script.
2. Add an alternate link with the page's hreflang to the head of every page, and a link to
   the page in the top bar and the footer of every other page, in the same order on each.
3. Link the privacy details in that language, and show the demos in that language as above,
   with its own lang on each line in another language. A language written without spaces
   between words, as Chinese and Japanese are, goes into the rule of site.js that times
   the spoken line by character, and may need the keep-all rule of style.css, as Japanese
   has.
4. Add its version line to the list above. If the language needs its own fonts, add a :lang
   rule to style.css, as the Japanese page has.
5. Publish the page only once the interface in that language is released, so it names
   menus and settings as Orra shows them.

## Turning on Pages

This is a one time step for the maintainer, in the repository on GitHub.

1. Settings > Pages > Build and deployment > Source: choose GitHub Actions.
2. Run the Website workflow once (Actions > Website > Run workflow), or merge a change to site/.
3. The site appears at https://db-ol.github.io/Orra/. The deployment shows under the
   github-pages environment.

Until Pages uses GitHub Actions as its source, the deploy step of the workflow fails.

## A custom domain later

1. Add a DNS record at the domain's provider. For a subdomain such as orra.example.com, a
   CNAME record that points to db-ol.github.io. For an apex domain, A records to GitHub's
   Pages addresses, which GitHub's documentation lists.
2. Settings > Pages > Custom domain: enter the domain and save. With a workflow as the
   source, no CNAME file is needed in site/.
3. Once the certificate is ready, turn on Enforce HTTPS.
4. Verify the domain in your account's or organization's Settings > Pages (not the
   repository's), so nobody else can claim it.
5. Update the canonical and alternate links at the top of every page to the new address.
