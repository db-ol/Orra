"""Tests of the release notes in each language. Standard library only, no network:

    python3 -I -m unittest discover -s Tools/release -p 'test_*.py' -v
"""

import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

import release_notes

REPOSITORY = Path(__file__).resolve().parents[2]

NOTES = {
    "en": "Captions start faster.\n\n- One click turns them on.",
    "zh-Hans": "字幕启动更快。\n\n- 点一下就能打开。",
    "ja": "字幕がすばやく始まります。\n\n- クリック一回でオンになります。",
    "es": "Los subtítulos empiezan antes.\n\n- Un clic los activa.",
}


def write_notes(folder, version, languages, texts=NOTES):
    """Writes the files of the given languages and returns the path of the English one."""
    english = os.path.join(folder, f"{version}.md")
    for code in languages:
        with open(release_notes.path_for(english, code), "w", encoding="utf-8") as file:
            file.write(texts[code] + "\n")
    return english


class LoadTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)

    def test_translations_sit_next_to_the_english_file(self):
        english = os.path.join("docs", "release-notes", "0.5.0.md")
        self.assertEqual(release_notes.path_for(english, "en"), english)
        self.assertEqual(release_notes.path_for(english, "zh-Hans"), os.path.join("docs", "release-notes", "0.5.0.zh-Hans.md"))
        self.assertEqual(release_notes.path_for(english, "ja"), os.path.join("docs", "release-notes", "0.5.0.ja.md"))
        self.assertEqual(release_notes.path_for(english, "es"), os.path.join("docs", "release-notes", "0.5.0.es.md"))

    def test_a_new_version_has_every_language_english_first(self):
        english = write_notes(self.folder.name, "0.5.0", ["es", "ja", "zh-Hans", "en"])
        notes = release_notes.load("0.5.0", english)
        self.assertEqual([code for code, _ in notes], ["en", "zh-Hans", "ja", "es"])
        self.assertEqual(dict(notes), NOTES)

    def test_a_new_version_names_every_missing_file(self):
        english = write_notes(self.folder.name, "0.5.0", ["en", "ja"])
        with self.assertRaises(release_notes.NotesError) as raised:
            release_notes.load("0.5.0", english)
        message = str(raised.exception)
        self.assertIn(f"{self.folder.name}/0.5.0.zh-Hans.md is missing", message)
        self.assertIn(f"{self.folder.name}/0.5.0.es.md is missing", message)
        self.assertNotIn("0.5.0.ja.md", message)

    def test_a_new_version_needs_more_than_the_english_file(self):
        english = write_notes(self.folder.name, "0.4.3", ["en"])
        with self.assertRaises(release_notes.NotesError) as raised:
            release_notes.load("0.4.3", english)
        self.assertEqual(str(raised.exception).count(" is missing"), 3)

    def test_an_empty_or_blank_file_counts_as_missing(self):
        english = write_notes(self.folder.name, "1.0.0", ["en", "zh-Hans", "ja", "es"], dict(NOTES, ja="", es=" \n\n "))
        with self.assertRaises(release_notes.NotesError) as raised:
            release_notes.load("1.0.0", english)
        message = str(raised.exception)
        self.assertIn("1.0.0.ja.md is empty", message)
        self.assertIn("1.0.0.es.md is empty", message)

    def test_an_old_version_keeps_its_single_file(self):
        both = "Captions start faster.\n\n字幕启动更快。"
        english = write_notes(self.folder.name, "0.4.2", ["en"], {"en": both})
        self.assertEqual(release_notes.load("0.4.2", english), [(None, both)])

    def test_an_old_version_needs_its_file(self):
        english = os.path.join(self.folder.name, "0.4.2.md")
        with self.assertRaises(release_notes.NotesError):
            release_notes.load("0.4.2", english)
        write_notes(self.folder.name, "0.4.2", ["en"], {"en": "\n"})
        with self.assertRaises(release_notes.NotesError):
            release_notes.load("0.4.2", english)

    def test_an_old_version_with_one_translation_needs_them_all(self):
        english = write_notes(self.folder.name, "0.4.2", ["en", "zh-Hans"])
        with self.assertRaises(release_notes.NotesError) as raised:
            release_notes.load("0.4.2", english)
        self.assertIn("0.4.2.ja.md is missing", str(raised.exception))

    def test_versions_compare_as_numbers(self):
        self.assertLess(release_notes.parse_version("0.4.2"), release_notes.parse_version("0.4.10"))
        self.assertLessEqual(release_notes.parse_version("0.4.2"), release_notes.LAST_SINGLE_FILE_VERSION)
        self.assertGreater(release_notes.parse_version("0.10.0"), release_notes.LAST_SINGLE_FILE_VERSION)
        for version in ("0.5", "v0.5.0", "0.5.0-beta", ""):
            with self.assertRaises(release_notes.NotesError):
                release_notes.parse_version(version)


class BodyTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)

    def test_each_language_under_a_heading_in_its_own_language(self):
        english = write_notes(self.folder.name, "0.5.0", ["en", "zh-Hans", "ja", "es"])
        self.assertEqual(
            release_notes.release_body("0.5.0", english),
            "## English\n\n" + NOTES["en"] + "\n\n"
            "## 简体中文\n\n" + NOTES["zh-Hans"] + "\n\n"
            "## 日本語\n\n" + NOTES["ja"] + "\n\n"
            "## Español\n\n" + NOTES["es"] + "\n",
        )

    def test_an_old_version_is_its_file_as_it_is(self):
        both = "Captions start faster.\n\n字幕启动更快。"
        english = write_notes(self.folder.name, "0.4.2", ["en"], {"en": both})
        self.assertEqual(release_notes.release_body("0.4.2", english), both + "\n")

    def test_the_command_line(self):
        english = write_notes(self.folder.name, "0.5.0", ["en", "zh-Hans", "ja", "es"])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(release_notes.main(["release_notes.py", "check", "0.5.0", english]), 0)
        self.assertEqual(output.getvalue(), "")
        with contextlib.redirect_stdout(output):
            self.assertEqual(release_notes.main(["release_notes.py", "body", "0.5.0", english]), 0)
        self.assertEqual(output.getvalue(), release_notes.release_body("0.5.0", english))

        os.remove(release_notes.path_for(english, "es"))
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            self.assertEqual(release_notes.main(["release_notes.py", "check", "0.5.0", english]), 1)
            self.assertEqual(release_notes.main(["release_notes.py", "publish", "0.5.0", english]), 1)
        self.assertIn("0.5.0.es.md is missing", errors.getvalue())


class RepositoryTests(unittest.TestCase):
    def test_every_published_version_loads(self):
        folder = REPOSITORY / "docs" / "release-notes"
        versions = [path.name[: -len(".md")] for path in folder.glob("*.md") if path.name.count(".") == 3]
        self.assertIn("0.4.2", versions)
        for version in versions:
            notes = release_notes.load(version, str(folder / f"{version}.md"))
            if release_notes.parse_version(version) <= release_notes.LAST_SINGLE_FILE_VERSION:
                self.assertEqual(len(notes), 1, version)
            else:
                self.assertEqual(len(notes), len(release_notes.LANGUAGES), version)

    def test_every_interface_language_has_release_notes(self):
        # A language added to Orra's interface needs its notes too, or the update window
        # shows English to those who see the rest of Orra in their language.
        codes = {language.code for language in release_notes.LANGUAGES}
        for catalog in ("Localizable.xcstrings", "InfoPlist.xcstrings"):
            with open(REPOSITORY / "Orra" / catalog, encoding="utf-8") as file:
                strings = json.load(file)
            languages = {strings["sourceLanguage"]}
            for entry in strings["strings"].values():
                languages.update(entry.get("localizations", {}))
            self.assertLessEqual(languages, codes, catalog)

    def test_sparkle_picks_among_orras_own_localizations(self):
        # macOS limits Sparkle's pick of the notes, and of its own buttons, to Orra's
        # localizations. This key lifts that limit, so an Orra without Japanese would show
        # Japanese notes around an English interface. It can come from Info.plist or from an
        # INFOPLIST_KEY_ build setting.
        for path in ("Orra/Info.plist", "Orra.xcodeproj/project.pbxproj"):
            with open(REPOSITORY / path, encoding="utf-8") as file:
                self.assertNotIn("CFBundleAllowMixedLocalizations", file.read(), path)


if __name__ == "__main__":
    unittest.main()
