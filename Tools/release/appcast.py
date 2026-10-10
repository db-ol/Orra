#!/usr/bin/env python3
"""Writes the Sparkle feed for one release of Orra to standard output.

    appcast.py <version> <build> <dmg> <EdDSA signature> <release notes .md>

make-release.sh runs it. The feed lists only the newest release, which is all Sparkle needs,
and goes on that GitHub release as appcast.xml, where SUFeedURL finds it through
releases/latest. make-release.sh signs the feed afterwards, since Orra requires a signed feed.
"""

import os
import sys
from email.utils import formatdate
from xml.sax.saxutils import escape, quoteattr

REPOSITORY = "https://github.com/db-ol/Orra"
MINIMUM_SYSTEM_VERSION = "15.6"


def main(arguments):
    if len(arguments) != 6:
        print(__doc__, file=sys.stderr)
        return 1
    version, build, dmg, signature, notes_path = arguments[1:]
    with open(notes_path, encoding="utf-8") as file:
        notes = file.read().strip()
    url = f"{REPOSITORY}/releases/download/v{version}/{os.path.basename(dmg)}"
    # CDATA cannot hold its own end marker.
    notes = notes.replace("]]>", "]]]]><![CDATA[>")
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
      <description sparkle:format="markdown"><![CDATA[{notes}]]></description>
      <enclosure url={quoteattr(url)} length="{os.path.getsize(dmg)}" type="application/x-apple-diskimage" sparkle:edSignature={quoteattr(signature)}/>
    </item>
  </channel>
</rss>""")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
