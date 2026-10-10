# Website

The product website lives in site/ and is published with GitHub Pages at
https://db-ol.github.io/Orra/.

## Files

- site/index.html is the English page.
- site/zh/index.html is the Simplified Chinese page.
- site/style.css is the one style sheet for both. It follows the system's light or dark mode.
- site/icon.png and site/favicon.png are the app icon at 512 and 64 pixels. They are exported
  from Orra/AppIcon.icon with the ictool that ships inside Icon Composer.

The site is plain HTML and CSS. There is no build step, no script, no web font, no cookie,
no analytics and no tracker. Keep it that way.

## Editing

1. Change both pages together, so the English and the Chinese page say the same thing.
2. Keep every claim in line with README.md. Describe what the latest release does, not what
   is still in a pull request. Make up no numbers or quotes.
3. English text uses no em dash, en dash or semicolon. Chinese text uses full width
   punctuation (，。：？！（）“”) and a space between Chinese and a Latin word or a number.
4. Open site/index.html in a browser to check it. Links between the pages are relative, so
   they work from the file system too.
5. Merge to main. The Website workflow (.github/workflows/pages.yml) deploys site/ when a
   push to main changes it. Actions > Website > Run workflow deploys it by hand.

The Download button points to
https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg, so every release must
upload a copy of its DMG named Orra.dmg, as docs/releasing.md describes. A new release
needs no change to the site.

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
4. Verify the domain for the account or organization (Settings > Pages > Verified domains),
   so nobody else can claim it.
5. Update the canonical and alternate links at the top of both pages to the new address.
