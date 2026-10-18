#!/usr/bin/env python3
"""Reads the release notes of one version of Orra, in each language of its interface.

    release_notes.py check <version> <release notes .md>
    release_notes.py body <version> <release notes .md>

The notes of a version are docs/release-notes/<version>.md in English, and next to it one
file for each other language, such as <version>.zh-Hans.md. The update window shows the
one in the language of Orra's interface. Versions up to 0.4.2 have only the English file,
with English and then Chinese in it, and keep it as it is.

check fails, naming each file, when one is missing or empty. make-release.sh runs it before
anything is notarized. body prints the text of the GitHub release, every language under a
heading in its own language, English first. appcast.py reads the notes through load.
"""

import os
import sys
from collections import namedtuple

# The localizations of Orra's interface, English first. Sparkle shows the notes whose
# xml:lang it picks from these codes for the user's languages, and limits that pick to the
# localizations of Orra itself, so the codes must be the localization names exactly. The
# heading names the language in its own words, for the GitHub release.
Language = namedtuple("Language", "code heading")
LANGUAGES = (
    Language("en", "English"),
    Language("zh-Hans", "简体中文"),
    Language("ja", "日本語"),
    Language("es", "Español"),
)

# The last version whose notes are one file in English and Chinese.
LAST_SINGLE_FILE_VERSION = (0, 4, 2)


class NotesError(Exception):
    pass


def parse_version(version):
    parts = version.split(".")
    if len(parts) != 3 or not all(part.isdigit() for part in parts):
        raise NotesError(f"The version must look like 0.1.0, not {version}")
    return tuple(int(part) for part in parts)


def path_for(notes_path, code):
    """The file of one language, next to the English one: 0.5.0.md gives 0.5.0.ja.md."""
    if code == LANGUAGES[0].code:
        return notes_path
    stem, extension = os.path.splitext(notes_path)
    return f"{stem}.{code}{extension}"


def read_text(path):
    with open(path, encoding="utf-8") as file:
        return file.read().strip()


def load(version, notes_path):
    """The notes as (language code, text) pairs, English first. The code is None for the
    single file of a version up to 0.4.2, which the update window shows whole.

    Raises NotesError naming every file that is missing or empty. A version after 0.4.2
    needs all of them, and so does an older one that has any translation."""
    single_file = parse_version(version) <= LAST_SINGLE_FILE_VERSION
    translations = [path_for(notes_path, language.code) for language in LANGUAGES[1:]]
    if single_file and not any(os.path.exists(path) for path in translations):
        if not os.path.exists(notes_path) or not read_text(notes_path):
            raise NotesError(f"Write the release notes in {notes_path}. The update window shows them.")
        return [(None, read_text(notes_path))]

    notes = []
    problems = []
    for language in LANGUAGES:
        path = path_for(notes_path, language.code)
        if not os.path.exists(path):
            problems.append(f"{path} is missing")
        elif not read_text(path):
            problems.append(f"{path} is empty")
        else:
            notes.append((language.code, read_text(path)))
    if problems:
        raise NotesError(
            "The update window shows the release notes in the language of Orra's interface, "
            "so they need a file for each language (docs/releasing.md):\n"
            + "\n".join(f"  {problem}" for problem in problems)
        )
    return notes


def release_body(version, notes_path):
    """The text of the GitHub release: the single file as it is, or each language under a
    heading in its own language, English first."""
    notes = load(version, notes_path)
    if notes[0][0] is None:
        return notes[0][1] + "\n"
    headings = {language.code: language.heading for language in LANGUAGES}
    return "\n\n".join(f"## {headings[code]}\n\n{text}" for code, text in notes) + "\n"


def main(arguments):
    if len(arguments) != 4 or arguments[1] not in ("check", "body"):
        print(__doc__, file=sys.stderr)
        return 1
    command, version, notes_path = arguments[1:]
    try:
        if command == "check":
            load(version, notes_path)
        else:
            sys.stdout.write(release_body(version, notes_path))
    except NotesError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
