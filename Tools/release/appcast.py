#!/usr/bin/env python3
"""Writes the Sparkle feed for one release of Orra to standard output.

    appcast.py <version> <build> <dmg> <EdDSA signature> <release notes .md>

make-release.sh runs it. The feed lists only the newest release, which is all Sparkle needs,
and goes on that GitHub release as appcast.xml, where SUFeedURL finds it through
releases/latest. make-release.sh signs the feed afterwards, since Orra requires a signed feed.

The release notes are the English file and the translations next to it (release_notes.py).
The feed has one description for each language, English first, and Sparkle shows the one in
the language of Orra's interface. The notes of a version up to 0.4.2 are one file, English
and then Chinese, and go in one description as before.
"""

import os
import sys
from email.utils import formatdate
from xml.sax.saxutils import escape, quoteattr

# Python run with -I leaves this folder out of the module search path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release_notes  # noqa: E402

REPOSITORY = "https://github.com/db-ol/Orra"
MINIMUM_SYSTEM_VERSION = "15.6"


def description(language, notes):
    """One description element. Sparkle picks among several by xml:lang, so the single
    description of an old version has none."""
    # CDATA cannot hold its own end marker.
    notes = notes.replace("]]>", "]]]]><![CDATA[>")
    language_attribute = "" if language is None else f" xml:lang={quoteattr(language)}"
    return f'<description{language_attribute} sparkle:format="markdown"><![CDATA[{notes}]]></description>'


def main(arguments):
    if len(arguments) != 6:
        print(__doc__, file=sys.stderr)
        return 1
    version, build, dmg, signature, notes_path = arguments[1:]
    try:
        notes = release_notes.load(version, notes_path)
    except release_notes.NotesError as error:
        print(error, file=sys.stderr)
        return 1
    descriptions = "\n      ".join(description(language, text) for language, text in notes)
    url = f"{REPOSITORY}/releases/download/v{version}/{os.path.basename(dmg)}"
    print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Orra</title>
    <link>{escape(REPOSITORY)}</link>
    <item>
      <title>{escape(f"Orra {version}")}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{escape(f"{REPOSITORY}/releases/tag/v{version}")}</sparkle:fullReleaseNotesLink>
      {descriptions}
      <enclosure url={quoteattr(url)} length="{os.path.getsize(dmg)}" type="application/x-apple-diskimage" sparkle:edSignature={quoteattr(signature)}/>
    </item>
  </channel>
</rss>""")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
