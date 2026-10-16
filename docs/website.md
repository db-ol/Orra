# Website

The product website lives in site/ and is published with GitHub Pages at
https://db-ol.github.io/Orra/.

## Files

- site/index.html is the English page.
- site/zh/index.html is the Simplified Chinese page.
- site/style.css is the one style sheet for both. It follows the system's light or dark mode.
- site/site.js plays the three demos at the top of the page, dictation, cleanup and then
  translation, and fades sections in as they scroll into view. Without it, or when the Mac asks
  for reduced motion, the page shows all demos in their last frame and every section at once.
  The spoken line of each demo appears at about 8.5 Chinese characters or 3 English words a
  second, so a longer line takes longer. Keep each line and each pasted text to two lines at
  375 pixels wide. The cleanup demo shows an optional feature, so its caption says so.
- The Meeting Interpretation section draws the Live Captions window and a call in HTML and
  CSS, with the sentences of the meeting animation in the README. style.css plays it once
  when each part scrolls into view, through the class that site.js adds. Without site.js,
  or with reduced motion, it shows its last frame.
- site/icon.png and site/favicon.png are the app icon at 512 and 64 pixels. They are exported
  from Orra/AppIcon.icon with the ictool that ships inside Icon Composer.

The site is plain HTML and CSS with one small script of its own. There is no build step, no
framework, no web font, no cookie, no analytics and no tracker, and the page loads nothing
from another server. Keep it that way.

## Editing

1. Change both pages together, so the English and the Chinese page say the same thing.
2. Keep every claim in line with README.md and the user guide in docs/user-guide.md. Describe
   what the latest release does, not what is still in a pull request. Make up no numbers or
   quotes.
3. English text uses no em dash, en dash or semicolon. Chinese text uses full width
   punctuation (，。：？！（）“”) and a space between Chinese and a Latin word or a number.
4. Check the pages over HTTP, as GitHub Pages serves them. Run
   `python3 -m http.server -d site` and open http://localhost:8000/. The language and brand
   links point at folders, so they do not work when you open the files directly.
5. Merge to main. The Website workflow (.github/workflows/pages.yml) deploys site/ when a
   push to main changes it. Actions > Website > Run workflow deploys it by hand.

The Download button points to
https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg, so every release must
upload a copy of its DMG named Orra.dmg, as docs/releasing.md describes.

The version under the top Download button is plain text, once in each page ("Version 0.4.0"
and "版本 0.4.0"), next to the system requirements. After a release is published, change it
in both pages and merge, so the site never names a version that is not out yet. To find
every place:

    grep -rn "0\.4\.0" site

The grep also finds the Download Orra Microphone link in the Meeting Interpretation
section. It points at OrraMicrophone.pkg in the v0.4.0 release, as README.md does. Change
it only when a newer release attaches its own OrraMicrophone.pkg.

To export the icon again after the icon changes:

    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" Orra/AppIcon.icon --export-image --output-file /tmp/icon1024.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
    sips -Z 512 /tmp/icon1024.png --out site/icon.png
    sips -Z 64 /tmp/icon1024.png --out site/favicon.png

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
5. Update the canonical and alternate links at the top of both pages to the new address.
