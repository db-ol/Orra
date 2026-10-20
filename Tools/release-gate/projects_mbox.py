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
becomes a part with its name and type. Projects reads only the names and types of
attachments in phase 1 (decision 14), so a part holds the item's attachment text when it
has one and a placeholder line otherwise. A Received header carries the date too, in case
Mail takes the date received from it.

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
from datetime import datetime, timezone
from email import policy
from email.generator import BytesGenerator
from email.message import EmailMessage
from email.utils import format_datetime, parseaddr
from pathlib import Path

# Headers in UTF-8 become RFC 2047 words and text that is not ASCII becomes base64 or
# quoted printable, as most mail clients write them, and lines end with a line feed, as in
# an mbox file. An address that is not ASCII, such as one at a lookalike domain with a
# Cyrillic letter, cannot be written so. Its message keeps all its headers in UTF-8 instead
# (RFC 6532), as mail sent with SMTPUTF8 does.
POLICY = policy.default.clone(linesep="\n", cte_type="7bit")
UTF8_POLICY = POLICY.clone(utf8=True)

PLACEHOLDER = "Synthetic attachment of the Projects test set, without its content.\n"

# Each output, with the set file it comes from and how to take the messages out of a line.
OUTPUTS = (
    ("mail.jsonl", "orra-test.mbox", lambda item: [item]),
    ("adversarial.jsonl", "orra-attacks.mbox", lambda item: item["messages"]),
)


def read_lines(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as file:
        return [json.loads(line) for line in file if line.strip()]


def build_message(item: dict) -> EmailMessage:
    """One message of the set as an email, with its parts."""
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
        content = (attachment.get("text") or PLACEHOLDER).encode("utf-8")
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


def message_bytes(item: dict) -> bytes:
    """The message as it goes into the file. A body line that starts with "From " gets a
    ">" in front, so it never reads as the start of the next message."""
    message = build_message(item)
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


def write_mbox(path: Path, items: list[dict]) -> None:
    """Writes the messages to a new file next to path, then puts it in place."""
    partial = path.with_name(path.name + ".partial")
    try:
        with partial.open("wb") as file:
            for item in items:
                file.write(from_line(item).encode("ascii"))
                file.write(message_bytes(item))
                file.write(b"\n")
        os.replace(partial, path)
    finally:
        if partial.exists():
            partial.unlink()


def build(set_folder: Path, out_folder: Path) -> dict[str, int]:
    """Writes both files and returns the count of messages in each, by file name."""
    counts = {}
    for source, target, messages in OUTPUTS:
        items = [message for line in read_lines(set_folder / source) for message in messages(line)]
        write_mbox(out_folder / target, items)
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
