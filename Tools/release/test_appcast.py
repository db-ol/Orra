"""Tests of the Sparkle feed that appcast.py writes. Standard library only, no network:

    python3 -I -m unittest discover -s Tools/release -p 'test_*.py' -v

They run appcast.py the way make-release.sh does, as python3 -I with the same arguments.
"""

import os
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ElementTree
from pathlib import Path

import release_notes
from test_release_notes import NOTES, write_notes

APPCAST = Path(__file__).resolve().with_name("appcast.py")
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"


class AppcastTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = folder.name
        self.dmg = os.path.join(self.folder, "Orra-9.9.9.dmg")
        with open(self.dmg, "wb") as file:
            file.write(b"\0" * 1234)

    def run_appcast(self, version, notes_path):
        return subprocess.run(
            [sys.executable, "-I", str(APPCAST), version, "42", self.dmg, "c2lnbmF0dXJl==", notes_path],
            capture_output=True,
            text=True,
            encoding="utf-8",
            cwd=self.folder,
        )

    def feed(self, version, notes_path):
        result = self.run_appcast(version, notes_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout, ElementTree.fromstring(result.stdout.encode("utf-8")).find("channel/item")

    def test_one_description_for_each_language_english_first(self):
        english = write_notes(self.folder, "0.5.0", ["en", "zh-Hans", "ja", "es"])
        _, item = self.feed("0.5.0", english)
        descriptions = item.findall("description")
        self.assertEqual([element.get(XML_LANG) for element in descriptions], ["en", "zh-Hans", "ja", "es"])
        self.assertEqual([language.code for language in release_notes.LANGUAGES], ["en", "zh-Hans", "ja", "es"])
        for element in descriptions:
            self.assertEqual(element.get(f"{SPARKLE}format"), "markdown")
            self.assertEqual(element.text, NOTES[element.get(XML_LANG)])

    def test_the_rest_of_the_item(self):
        english = write_notes(self.folder, "0.5.0", ["en", "zh-Hans", "ja", "es"])
        _, item = self.feed("0.5.0", english)
        self.assertEqual(item.findtext("title"), "Orra 0.5.0")
        self.assertEqual(item.findtext(f"{SPARKLE}version"), "42")
        self.assertEqual(item.findtext(f"{SPARKLE}shortVersionString"), "0.5.0")
        self.assertEqual(item.findtext(f"{SPARKLE}minimumSystemVersion"), "15.6")
        self.assertEqual(item.findtext(f"{SPARKLE}fullReleaseNotesLink"), "https://github.com/db-ol/Orra/releases")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://github.com/db-ol/Orra/releases/download/v0.5.0/Orra-9.9.9.dmg")
        self.assertEqual(enclosure.get("length"), "1234")
        self.assertEqual(enclosure.get(f"{SPARKLE}edSignature"), "c2lnbmF0dXJl==")

    def test_notes_that_hold_the_end_of_cdata(self):
        texts = dict(NOTES, ja="「]]>」と書いても、そのまま表示されます。")
        english = write_notes(self.folder, "0.5.0", ["en", "zh-Hans", "ja", "es"], texts)
        _, item = self.feed("0.5.0", english)
        self.assertEqual(item.findall("description")[2].text, texts["ja"])

    def test_a_missing_translation_writes_no_feed(self):
        english = write_notes(self.folder, "0.5.0", ["en", "zh-Hans", "es"])
        result = self.run_appcast("0.5.0", english)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("0.5.0.ja.md is missing", result.stderr)

    def test_an_old_version_keeps_one_description(self):
        both = "Captions start faster.\n\n字幕启动更快。"
        english = write_notes(self.folder, "0.4.2", ["en"], {"en": both})
        output, item = self.feed("0.4.2", english)
        descriptions = item.findall("description")
        self.assertEqual(len(descriptions), 1)
        self.assertIsNone(descriptions[0].get(XML_LANG))
        self.assertEqual(descriptions[0].text, both)
        # The feed as appcast.py wrote it before notes came in several files, apart from the
        # Version History link and the date.
        self.assertEqual(
            re.sub(r"<pubDate>.*</pubDate>", "<pubDate/>", output),
            """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Orra</title>
    <link>https://github.com/db-ol/Orra</link>
    <item>
      <title>Orra 0.4.2</title>
      <pubDate/>
      <sparkle:version>42</sparkle:version>
      <sparkle:shortVersionString>0.4.2</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.6</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/db-ol/Orra/releases</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[Captions start faster.

字幕启动更快。]]></description>
      <enclosure url="https://github.com/db-ol/Orra/releases/download/v0.4.2/Orra-9.9.9.dmg" length="1234" type="application/x-apple-diskimage" sparkle:edSignature="c2lnbmF0dXJl=="/>
    </item>
  </channel>
</rss>
""",
        )

    def test_the_published_notes_of_0_4_2(self):
        notes = Path(__file__).resolve().parents[2] / "docs" / "release-notes" / "0.4.2.md"
        _, item = self.feed("0.4.2", str(notes))
        descriptions = item.findall("description")
        self.assertEqual(len(descriptions), 1)
        self.assertEqual(descriptions[0].text, notes.read_text(encoding="utf-8").strip())


if __name__ == "__main__":
    unittest.main()
