#!/usr/bin/env python3
"""Builds two mbox files from the synthetic Projects test set, for Mail to import.

    python3 -I Tools/release-gate/projects_mbox.py SET_FOLDER [--out FOLDER]

SET_FOLDER is the test set (bench/projects-testset, which stays out of this repository),
with mail.jsonl and adversarial.jsonl. The script writes orra-test.mbox from mail.jsonl and
orra-attacks.mbox from every message of adversarial.jsonl, into SET_FOLDER or the folder
given with --out, and replaces the files that are there. In Mail, File > Import
Mailboxes, "Files in mbox format", imports each under On My Mac. Whether Mail accepts them
is unverified until the first import.

Each message keeps the set's Message-ID, In-Reply-To, References and date, its From, To,
Cc and subject, and its plain text. An item with an HTML body gets it as the second part
of multipart/alternative, so Mail shows the HTML, as it shows real mail. Every attachment
becomes a part with its name and type. Projects reads the text of attachments, so a part
holds the item's attachment text when it has one, else the file of the set's project
folders with the attachment's name, as when a supplier mails the quote that is also in
the folder, and a placeholder line otherwise. An attachment text of a PDF or a docx
becomes a real file of that kind, made here, in which a line that starts with
"[white text] " is white without the mark, as the release gate's test makes them. Other
attachment text goes in as it is. A Received header carries the date too, in case Mail
takes the date received from it.

It prints counts only, never mail text. Standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import sys
import time
import zipfile
from datetime import datetime, timezone
from email import policy
from email.generator import BytesGenerator
from email.message import EmailMessage
from email.utils import format_datetime, parseaddr
from pathlib import Path
from xml.sax.saxutils import escape

# Headers in UTF-8 become RFC 2047 words and text that is not ASCII becomes base64 or
# quoted printable, as most mail clients write them, and lines end with a line feed, as in
# an mbox file. An address that is not ASCII, such as one at a lookalike domain with a
# Cyrillic letter, cannot be written so. Its message keeps all its headers in UTF-8 instead
# (RFC 6532), as mail sent with SMTPUTF8 does.
POLICY = policy.default.clone(linesep="\n", cte_type="7bit")
UTF8_POLICY = POLICY.clone(utf8=True)

PLACEHOLDER = "Synthetic attachment of the Projects test set, without its content.\n"

# The mark of a line of attachment text that is white in a PDF or docx, see attachment_file.
WHITE_MARK = "[white text] "
# The date inside each docx, so a second run writes the same bytes.
FIXED_ZIP_TIME = (2026, 10, 1, 0, 0, 0)
DOCX_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

# Each output, with the set file it comes from and how to take the messages out of a line.
OUTPUTS = (
    ("mail.jsonl", "orra-test.mbox", lambda item: [item]),
    ("adversarial.jsonl", "orra-attacks.mbox", lambda item: item["messages"]),
)


def read_lines(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as file:
        return [json.loads(line) for line in file if line.strip()]


def project_files(set_folder: Path) -> dict[str, Path]:
    """The files of the set's project folders, by name, the first of a name counting."""
    files: dict[str, Path] = {}
    for path in sorted((set_folder / "projects").glob("*/*")):
        if path.is_file():
            files.setdefault(path.name, path)
    return files


def marked_lines(text: str) -> list[tuple[str, bool]]:
    """The lines of an attachment text, each without the white mark and whether it had it."""
    return [(line[len(WHITE_MARK):], True) if line.startswith(WHITE_MARK) else (line, False) for line in text.split("\n")]


def docx_bytes(text: str) -> bytes:
    """A docx with one paragraph a line, white where marked: the three parts AppKit needs."""
    white_run = '<w:rPr><w:color w:val="FFFFFF"/></w:rPr>'
    paragraphs = "".join(
        f'<w:p><w:r>{white_run if white else ""}<w:t xml:space="preserve">{escape(line)}</w:t></w:r></w:p>'
        for line, white in marked_lines(text)
    )
    parts = {
        "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        "</Types>",
        "_rels/.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
        'Target="word/document.xml"/>'
        "</Relationships>",
        "word/document.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
        + paragraphs
        + "</w:body></w:document>",
    }
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, content in parts.items():
            info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, content.encode("utf-8"))
    return buffer.getvalue()


def pdf_bytes(text: str) -> bytes:
    """A PDF of one page with a line every 18 points, white where marked. The text is in
    STSong-Light with UCS-2 codes, one of the standard Chinese fonts PDF readers supply, so
    it holds Chinese and Latin text without embedding a font. Characters past U+FFFF are
    left out."""
    commands = ["BT", "/F1 10 Tf"]
    baseline = 740
    for line, white in marked_lines(text):
        codes = "".join(f"{ord(character):04X}" for character in line if ord(character) <= 0xFFFF)
        commands.append(f"{'1 1 1' if white else '0 0 0'} rg 1 0 0 1 40 {baseline} Tm <{codes}> Tj")
        baseline -= 18
    commands.append("ET")
    stream = "\n".join(commands).encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light /Encoding /UniGB-UCS2-H /DescendantFonts [6 0 R] >>",
        b"<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light"
        b" /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 2 >> /FontDescriptor 7 0 R /DW 1000 >>",
        b"<< /Type /FontDescriptor /FontName /STSong-Light /Flags 6 /FontBBox [-25 -254 1000 880]"
        b" /ItalicAngle 0 /Ascent 880 /Descent -120 /CapHeight 880 /StemV 93 >>",
    ]
    document = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(document))
        document += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    table = len(document)
    document += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    document += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    document += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, table)
    return bytes(document)


def attachment_file(text: str, name: str, mime_type: str) -> bytes:
    """The bytes of an attachment with text: a PDF or a docx by the name's extension, else
    by the type, and the text in UTF-8 for every other kind."""
    extension = Path(name).suffix.lower().lstrip(".")
    if extension == "pdf" or (not extension and mime_type == "application/pdf"):
        return pdf_bytes(text)
    if extension == "docx" or (not extension and mime_type == DOCX_TYPE):
        return docx_bytes(text)
    return text.encode("utf-8")


def build_message(item: dict, files: dict[str, Path] | None = None) -> EmailMessage:
    """One message of the set as an email, with its parts. An attachment without text gets
    the file of `files` with its name."""
    date = datetime.fromisoformat(item["date"])
    message = EmailMessage(policy=POLICY)
    message["Received"] = f"by synthetic.example; {format_datetime(date)}"
    message["Message-ID"] = item["message_id"]
    message["Date"] = format_datetime(date)
    message["From"] = item["from"]
    if item.get("to"):
        message["To"] = ", ".join(item["to"])
    if item.get("cc"):
        message["Cc"] = ", ".join(item["cc"])
    message["Subject"] = item["subject"]
    if item.get("in_reply_to"):
        message["In-Reply-To"] = item["in_reply_to"]
    if item.get("references"):
        message["References"] = " ".join(item["references"])
    message.set_content(item["body"])
    if item.get("body_html"):
        message.add_alternative(item["body_html"], subtype="html")
    for attachment in item.get("attachments") or []:
        maintype, _, subtype = attachment["type"].partition("/")
        file = (files or {}).get(attachment["name"])
        if attachment.get("text"):
            content = attachment_file(attachment["text"], attachment["name"], attachment["type"])
        elif file is not None:
            content = file.read_bytes()
        else:
            content = PLACEHOLDER.encode("utf-8")
        message.add_attachment(content, maintype=maintype, subtype=subtype or "octet-stream", filename=attachment["name"])
    # Boundaries made from the Message-ID, so a second run writes the same bytes.
    for number, part in enumerate(part for part in message.walk() if part.is_multipart()):
        seed = f"{item['message_id']} {number}".encode("utf-8")
        part.set_boundary(f"orra-{hashlib.sha256(seed).hexdigest()[:24]}")
    return message


def from_line(item: dict) -> str:
    """The mbox separator line: the sender's address and the date in asctime form, UTC."""
    address = parseaddr(item["from"])[1]
    if not address or not address.isascii() or any(character.isspace() for character in address):
        address = "MAILER-DAEMON"
    date = datetime.fromisoformat(item["date"]).astimezone(timezone.utc)
    return f"From {address} {time.asctime(date.timetuple())}\n"


def message_bytes(item: dict, files: dict[str, Path] | None = None) -> bytes:
    """The message as it goes into the file. A body line that starts with "From " gets a
    ">" in front, so it never reads as the start of the next message."""
    message = build_message(item, files)
    for chosen in (POLICY, UTF8_POLICY):
        buffer = io.BytesIO()
        try:
            BytesGenerator(buffer, mangle_from_=True, policy=chosen).flatten(message)
        except UnicodeEncodeError:
            if chosen is UTF8_POLICY:
                raise
            continue
        return buffer.getvalue()
    raise AssertionError("unreachable")


def write_mbox(path: Path, items: list[dict], files: dict[str, Path] | None = None) -> None:
    """Writes the messages to a new file next to path, then puts it in place."""
    partial = path.with_name(path.name + ".partial")
    try:
        with partial.open("wb") as file:
            for item in items:
                file.write(from_line(item).encode("ascii"))
                file.write(message_bytes(item, files))
                file.write(b"\n")
        os.replace(partial, path)
    finally:
        if partial.exists():
            partial.unlink()


def build(set_folder: Path, out_folder: Path) -> dict[str, int]:
    """Writes both files and returns the count of messages in each, by file name."""
    counts = {}
    files = project_files(set_folder)
    for source, target, messages in OUTPUTS:
        items = [message for line in read_lines(set_folder / source) for message in messages(line)]
        write_mbox(out_folder / target, items, files)
        counts[target] = len(items)
    return counts


def main(arguments: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Builds orra-test.mbox and orra-attacks.mbox from the Projects test set.")
    parser.add_argument("set_folder", type=Path, help="the test set, with mail.jsonl and adversarial.jsonl")
    parser.add_argument("--out", type=Path, help="where to write the files, the test set by default")
    options = parser.parse_args(arguments)
    for source, _, _ in OUTPUTS:
        if not (options.set_folder / source).is_file():
            print(f"{options.set_folder / source} is missing", file=sys.stderr)
            return 2
    out_folder = options.out or options.set_folder
    out_folder.mkdir(parents=True, exist_ok=True)
    for name, count in build(options.set_folder, out_folder).items():
        print(f"{out_folder / name}: {count} messages")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
