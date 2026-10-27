#!/usr/bin/env python3
"""Fails when one of the checked values that need the maintainer's approval changes.

AGENTS.md says that signing, the Development Team, the bundle IDs, entitlements, App
Sandbox, the deployment target and the dependencies change only with the maintainer's
approval. This script compares the build settings, package references and linked
products listed below with project.pbxproj, the pins with Package.resolved, the update
keys with Orra/Info.plist, and checks that docs/dependencies.md names every pinned package. It covers the settings listed here,
not every way a build can change signing. When the maintainer approves a change, the same
commit updates the expected values here.

It also checks the source rules for Projects code in AGENTS.md (Runtime rules and
Continuous integration), see check_sources. Tools/ci/test_check_rules.py tests that check.

Run from anywhere, with Python 3.8 or later and nothing outside the standard library:

    python3 Tools/ci/check_rules.py [repository folder]
"""

import json
import os
import plistlib
import re
import sys
from collections import namedtuple
from pathlib import Path

# The expected values, all in one place.
#
# Build settings in project.pbxproj. Each setting maps an owner of build configurations,
# "project" for the project itself or a target by name, to the value it must have in
# every one of its configurations. An owner that is not listed must not set the setting,
# so an empty map means that nobody sets it. Conditional forms such as
# PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*] count as the setting itself.
EXPECTED_BUILD_SETTINGS = {
    # Set once on the project, which both targets inherit. The paid team, whose Developer
    # ID signs and notarizes the releases.
    "DEVELOPMENT_TEAM": {
        "project": "X77KW5VYFJ",
    },
    "PRODUCT_BUNDLE_IDENTIFIER": {
        "Orra": "io.github.db-ol.Orra",
        "OrraTests": "io.github.db-ol.OrraTests",
    },
    "MACOSX_DEPLOYMENT_TARGET": {
        "project": "15.6",
        "Orra": "15.6",
        "OrraTests": "15.6",
    },
    "ENABLE_APP_SANDBOX": {
        "Orra": "NO",
    },
    # Notarization needs the hardened runtime. Under it the microphone needs the audio
    # input entitlement, and Projects needs the Apple Events entitlement to read mail in the
    # Mail app (AUTOMATION_APPLE_EVENTS below). Nothing else is allowed. Xcode writes the
    # other choices of the Hardened Runtime capability out as NO, which they must stay.
    "ENABLE_HARDENED_RUNTIME": {
        "Orra": "YES",
    },
    "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT": {
        "Orra": "YES",
    },
    "ENABLE_RESOURCE_ACCESS_CALENDARS": {
        "Orra": "NO",
    },
    "ENABLE_RESOURCE_ACCESS_CAMERA": {
        "Orra": "NO",
    },
    "ENABLE_RESOURCE_ACCESS_CONTACTS": {
        "Orra": "NO",
    },
    "ENABLE_RESOURCE_ACCESS_LOCATION": {
        "Orra": "NO",
    },
    "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY": {
        "Orra": "NO",
    },
    "RUNTIME_EXCEPTION_ALLOW_DYLD_ENVIRONMENT_VARIABLES": {
        "Orra": "NO",
    },
    "RUNTIME_EXCEPTION_ALLOW_JIT": {
        "Orra": "NO",
    },
    "RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY": {
        "Orra": "NO",
    },
    "RUNTIME_EXCEPTION_DEBUGGING_TOOL": {
        "Orra": "NO",
    },
    "RUNTIME_EXCEPTION_DISABLE_EXECUTABLE_PAGE_PROTECTION": {
        "Orra": "NO",
    },
    "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION": {
        "Orra": "NO",
    },
    "CODE_SIGN_ENTITLEMENTS": {},
    # The Info.plist file whose update keys INFO_PLIST below checks.
    "INFOPLIST_FILE": {
        "Orra": "Orra/Info.plist",
    },
    "CODE_SIGN_STYLE": {
        "Orra": "Automatic",
        "OrraTests": "Automatic",
    },
    # These change the signature, the hardened runtime or the entitlements without the
    # settings above, so nobody may set them.
    "OTHER_CODE_SIGN_FLAGS": {},
    "CODE_SIGN_IDENTITY": {},
    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": {},
    "CODE_SIGN_RESTRICT": {},
    "ENABLE_LIBRARY_VALIDATION": {},
    "PROVISIONING_PROFILE": {},
    "PROVISIONING_PROFILE_SPECIFIER": {},
    # Projects reads mail in the Mail app through Apple Events, approved by the maintainer on
    # 2026-10-18. The usage description is in INFO_PLIST below.
    "AUTOMATION_APPLE_EVENTS": {
        "Orra": "YES",
    },
    "ENABLE_USER_SELECTED_FILES": {},
    "ENABLE_INCOMING_NETWORK_CONNECTIONS": {},
    "ENABLE_OUTGOING_NETWORK_CONNECTIONS": {},
}

# Families of settings that add entitlements. Nobody may set any of them, except the ones
# listed with their values above.
FORBIDDEN_SETTING_PREFIXES = ("ENABLE_RESOURCE_ACCESS_", "ENABLE_FILE_ACCESS_", "RUNTIME_EXCEPTION_")

# Every package the project refers to, by location, with its requirement.
EXPECTED_PACKAGE_REFERENCES = {
    "https://github.com/soniqo/speech-swift": {
        "kind": "revision",
        "revision": "1f54e56cf137078ed681a03e0955e777f7314610",
    },
    "https://github.com/sparkle-project/Sparkle": {
        "kind": "exactVersion",
        "version": "2.10.0",
    },
    "https://github.com/ml-explore/mlx-swift-lm": {
        "kind": "exactVersion",
        "version": "3.31.4",
    },
    "https://github.com/huggingface/swift-transformers": {
        "kind": "exactVersion",
        "version": "1.3.4",
    },
}

# The package products each target links, as (product, package location).
EXPECTED_PRODUCTS = {
    "Orra": {
        ("Qwen3ASR", "https://github.com/soniqo/speech-swift"),
        # Speak Translation, approved and linked in Xcode by the maintainer on 2026-10-15.
        ("Qwen3TTS", "https://github.com/soniqo/speech-swift"),
        ("Sparkle", "https://github.com/sparkle-project/Sparkle"),
        ("MLXLLM", "https://github.com/ml-explore/mlx-swift-lm"),
        ("MLXLMCommon", "https://github.com/ml-explore/mlx-swift-lm"),
        ("Tokenizers", "https://github.com/huggingface/swift-transformers"),
    },
    "OrraTests": set(),
}

# Every package in Package.resolved, by identity, with the revision it is pinned to.
EXPECTED_PINS = {
    "sparkle": "eef1a539a373c1f1a320624b1130fc5de7b2e100",
    "async-http-client": "4c005f955e83f888d5616e579717a36d2dfc6301",
    "compress-nio": "e1caa19077dda4b00441142ef57da3db02acd466",
    "eventsource": "86b5096ac59ab46e66bd1f6377c604bc1dab0bc2",
    "hummingbird": "3ae359b1bb1e72378ed43b59fdcd4d44cac5d7a4",
    "hummingbird-websocket": "716c54294152c6d3301a6239a1d74db57cbcd6dc",
    "mlx-swift": "0bb916c67f4b9e5c682cbe02a42c701c93ab5021",
    "mlx-swift-lm": "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57",
    "speech-swift": "1f54e56cf137078ed681a03e0955e777f7314610",
    "swift-algorithms": "87e50f483c54e6efd60e885f7f5aa946cee68023",
    "swift-argument-parser": "6a52f3251125d74daf04fcbd5e6f08a75d074382",
    "swift-asn1": "3b6410f7dee09eb33cdd26260c5fd47fda19b0e2",
    "swift-async-algorithms": "13713a4ffdee8abd929f92568ee9462a46ae26e0",
    "swift-atomics": "0442cb5a3f98ab802acb777929fdb446bda11a34",
    "swift-certificates": "ff86b924ead66f853b8baf91f3c41926a8f36177",
    "swift-collections": "98ef3c98609a1e31b7e157b5b619579001a789d6",
    "swift-configuration": "8bae88f79dbddec793390c5bf3e2abb4ac2ece42",
    "swift-crypto": "da9d28d69ebe3894b18376c8f2395c2f37b8448f",
    "swift-distributed-tracing": "cc504a45f6ce73ce6067837d7ac19fa67b229a56",
    "swift-http-structured-headers": "933538faa42c432d385f02e07df0ace7c5ecfc47",
    "swift-http-types": "bff4b6903cdc99dda49649dd52f46c11cfd3ed50",
    "swift-huggingface": "f0a0cb43cb1b402d2bbf6fb10d8981328c449c48",
    "swift-jinja": "4588064a20f3fc093c95f2f7d3359999bf30cae5",
    "swift-log": "9c6fb14227f55d8f711ce3847dc2f419fb0ecacb",
    "swift-metrics": "087e8074afa97040c3b870c8664fe5482fb87cc4",
    "swift-nio": "21de5f08c1a166a6dd293d0e587ad977bf8dac5d",
    "swift-nio-extras": "41449336c8ecfadac6b4b5be75f9c3c306e61ced",
    "swift-nio-http2": "0f3e54e29c944c2e835ad52159da7d9e1c94ac69",
    "swift-nio-ssl": "322f3c2a4a21df31c84ca416bf65ee5e9059e440",
    "swift-nio-transport-services": "67787bb645a5e67d2edcdfbe48a216cc549222d5",
    "swift-numerics": "0c0290ff6b24942dadb83a929ffaaa1481df04a2",
    "swift-sdk": "a0ae212ebf6eab5f754c3129608bc5557637e605",
    "swift-service-context": "d0997351b0c7779017f88e7a93bc30a1878d7f29",
    "swift-service-lifecycle": "c55297914e26ce3085b73ca88c521ef99136f6ad",
    "swift-syntax": "79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1",
    "swift-system": "869129b7bf4ecc57b97d0193ad29690ca2134750",
    "swift-transformers": "c21fdcde390313a6d98d8e33a346f2c3486c3ab0",
    "swift-websocket": "ca48d46c25f8fa948d37eaa480c73172182cf90f",
    "whisperkit": "1e2a163736dfa5a198e637ae44c114e1c6d5cc2d",
    "xgrammar": "82505d0d987c36a4209fb3d8571cf6b0f28b5acd",
    "yyjson": "8b4a38dc994a110abaec8a400615567bd996105f",
}

PROJECT_FILE = "Orra.xcodeproj/project.pbxproj"
INFO_PLIST_FILE = "Orra/Info.plist"

# The whole Info.plist that Xcode merges into the generated one. Its keys decide where
# updates come from and which key must have signed them, so a changed feed or key would
# hand the users' Macs to whoever holds it.
INFO_PLIST = {
    "SUFeedURL": "https://github.com/db-ol/Orra/releases/latest/download/appcast.xml",
    "SUPublicEDKey": "knDawRcymzzet6JvlPGr9OstB1K25ERxKr3nwdGLsZw=",
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
    "SUEnableSystemProfiling": False,
    # Every install waits for the user's choice: Sparkle offers no automatic installs.
    "SUAllowsAutomaticUpdates": False,
    # The system audio recording prompt for meeting captions, approved on 2026-10-15.
    "NSAudioCaptureUsageDescription": "Orra listens to the sound your Mac plays, such as a call, to show live captions and translations. The audio stays on this Mac.",
    # The Automation prompt for Mail, which Projects needs, approved on 2026-10-18.
    "NSAppleEventsUsageDescription": "Orra reads mail in the Mail app only for Projects, and only from the mailboxes you choose. The mail it reads stays on this Mac.",
}
RESOLVED_FILE = "Orra.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
DEPENDENCIES_DOC = "docs/dependencies.md"


class ParseError(Exception):
    pass


class PropertyListParser:
    """Reads the old style property list that Xcode writes to project.pbxproj."""

    UNQUOTED = re.compile(r"[A-Za-z0-9_$+/:.-]+")
    ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}

    def __init__(self, text):
        self.text = text
        self.pos = 0

    def parse(self):
        value = self.value()
        self.skip()
        if self.pos != len(self.text):
            raise self.error("text after the end of the property list")
        return value

    def error(self, message):
        line = self.text.count("\n", 0, self.pos) + 1
        return ParseError(f"{PROJECT_FILE} line {line}: {message}")

    def skip(self):
        """Moves past white space and comments."""
        text = self.text
        while self.pos < len(text):
            if text[self.pos].isspace():
                self.pos += 1
            elif text.startswith("//", self.pos):
                end = text.find("\n", self.pos)
                self.pos = len(text) if end < 0 else end + 1
            elif text.startswith("/*", self.pos):
                end = text.find("*/", self.pos + 2)
                if end < 0:
                    raise self.error("comment without an end")
                self.pos = end + 2
            else:
                return

    def take(self, token):
        self.skip()
        if not self.text.startswith(token, self.pos):
            raise self.error(f"expected {token}")
        self.pos += len(token)

    def at(self, token):
        self.skip()
        return self.text.startswith(token, self.pos)

    def value(self):
        if self.at("{"):
            self.take("{")
            result = {}
            while not self.at("}"):
                key = self.string()
                self.take("=")
                result[key] = self.value()
                self.take(";")
            self.take("}")
            return result
        if self.at("("):
            self.take("(")
            result = []
            while not self.at(")"):
                result.append(self.value())
                if not self.at(")"):
                    self.take(",")
            self.take(")")
            return result
        return self.string()

    def string(self):
        self.skip()
        text = self.text
        if not text.startswith('"', self.pos):
            match = self.UNQUOTED.match(text, self.pos)
            if not match:
                raise self.error("expected a value")
            self.pos = match.end()
            return match.group()
        self.pos += 1
        characters = []
        while self.pos < len(text):
            character = text[self.pos]
            self.pos += 1
            if character == '"':
                return "".join(characters)
            if character == "\\" and self.pos < len(text):
                character = self.ESCAPES.get(text[self.pos], text[self.pos])
                self.pos += 1
            characters.append(character)
        raise self.error("string without an end")


def build_configurations(project):
    """Yields (owner, configuration name, build settings) for the project and its targets."""
    objects = project["objects"]
    root = objects[project["rootObject"]]
    owners = [("project", root)]
    for target_id in root.get("targets", []):
        target = objects[target_id]
        owners.append((target.get("name", target_id), target))
    for owner, item in owners:
        configuration_list = objects[item["buildConfigurationList"]]
        for configuration_id in configuration_list.get("buildConfigurations", []):
            configuration = objects[configuration_id]
            yield owner, configuration.get("name", configuration_id), configuration


def check_build_settings(project):
    problems = []
    owners_seen = set()
    count = 0
    for owner, name, configuration in build_configurations(project):
        owners_seen.add(owner)
        count += 1
        where = f"{PROJECT_FILE}: {owner} {name}"
        # Settings in an .xcconfig file would escape this check, so none may be used. A
        # file in a synchronized folder is referenced through keys that only start the
        # same way.
        if any(key.startswith("baseConfigurationReference") for key in configuration):
            problems.append(f"{where} uses an .xcconfig file, which this check does not read")
        settings = configuration.get("buildSettings", {})
        for key, value in sorted(settings.items()):
            listed = key.split("[")[0] in EXPECTED_BUILD_SETTINGS
            if key.startswith(FORBIDDEN_SETTING_PREFIXES) and not listed:
                problems.append(f"{where}: {key} is {value}, expected it not to be set")
        for setting, expected_by_owner in EXPECTED_BUILD_SETTINGS.items():
            expected = expected_by_owner.get(owner)
            found = {
                key: value
                for key, value in settings.items()
                if key == setting or key.startswith(setting + "[")
            }
            if expected is not None and setting not in found:
                problems.append(f"{where}: {setting} is not set, expected {expected}")
            for key, value in sorted(found.items()):
                if expected is None:
                    problems.append(f"{where}: {key} is {value}, expected it not to be set")
                elif value != expected:
                    problems.append(f"{where}: {key} is {value}, expected {expected}")
    named_owners = {owner for expected in EXPECTED_BUILD_SETTINGS.values() for owner in expected}
    for owner in sorted(named_owners - owners_seen):
        problems.append(f"{PROJECT_FILE}: no build configurations for {owner}, which the expected values name")
    return problems, count


def package_location(objects, package_id):
    package = objects.get(package_id, {})
    return package.get("repositoryURL") or package.get("relativePath") or str(package_id)


def check_packages(project):
    """Compares the package references and the linked products with the expected ones.

    Package.resolved alone misses a local package, which gets no pin, and another product
    of a package that is already pinned.
    """
    problems = []
    objects = project["objects"]
    root = objects[project["rootObject"]]
    referenced = root.get("packageReferences", [])
    found = {}
    for object_id, item in objects.items():
        if not str(item.get("isa", "")).endswith("SwiftPackageReference"):
            continue
        location = package_location(objects, object_id)
        if object_id not in referenced:
            problems.append(f"{PROJECT_FILE}: package {location} is in the file but not in the project's package list")
        found[location] = (item.get("isa"), item.get("requirement"))
    for location in sorted(set(found) | set(EXPECTED_PACKAGE_REFERENCES)):
        expected = EXPECTED_PACKAGE_REFERENCES.get(location)
        if location not in found:
            problems.append(f"{PROJECT_FILE}: package {location} is gone, expected {expected}")
        elif expected is None:
            problems.append(f"{PROJECT_FILE}: package {location} is new ({found[location][0]})")
        elif found[location] != ("XCRemoteSwiftPackageReference", expected):
            problems.append(f"{PROJECT_FILE}: package {location} is {found[location]}, expected a remote package at {expected}")
    every_product = set()
    for item in objects.values():
        if item.get("isa") == "XCSwiftPackageProductDependency":
            every_product.add((item.get("productName"), package_location(objects, item.get("package"))))
    for target_id in root.get("targets", []):
        target = objects[target_id]
        name = target.get("name", target_id)
        linked = {
            (objects[product].get("productName"), package_location(objects, objects[product].get("package")))
            for product in target.get("packageProductDependencies", [])
        }
        expected = EXPECTED_PRODUCTS.get(name, set())
        for product, location in sorted(linked - expected):
            problems.append(f"{PROJECT_FILE}: {name} links {product} from {location}, which is not expected")
        for product, location in sorted(expected - linked):
            problems.append(f"{PROJECT_FILE}: {name} does not link {product} from {location} any more")
    allowed = set().union(*EXPECTED_PRODUCTS.values())
    for product, location in sorted(every_product - allowed):
        problems.append(f"{PROJECT_FILE}: product {product} from {location} is used, which is not expected")
    return problems


def check_pins(resolved):
    problems = []
    pins = {}
    for pin in resolved["pins"]:
        pins[pin["identity"]] = pin
    for identity in sorted(set(EXPECTED_PINS) | set(pins)):
        expected = EXPECTED_PINS.get(identity)
        revision = pins[identity].get("state", {}).get("revision") if identity in pins else None
        if expected is None:
            problems.append(f"{RESOLVED_FILE}: {identity} is a new package, at {revision}")
        elif revision is None:
            problems.append(f"{RESOLVED_FILE}: {identity} is gone, expected at {expected}")
        elif revision != expected:
            problems.append(f"{RESOLVED_FILE}: {identity} is at {revision}, expected {expected}")
    return problems, pins


def repository_name(location):
    """owner/name from a package URL, the way docs/dependencies.md writes it."""
    path = re.sub(r"\.git$", "", location.rstrip("/"))
    return "/".join(path.split("/")[-2:])


def check_info_plist(info):
    problems = []
    for key in sorted(set(info) | set(INFO_PLIST)):
        expected = INFO_PLIST.get(key)
        if key not in info:
            problems.append(f"{INFO_PLIST_FILE}: {key} is not set, expected {expected!r}")
        elif expected is None:
            problems.append(f"{INFO_PLIST_FILE}: {key} is {info[key]!r}, expected it not to be set")
        elif info[key] != expected:
            problems.append(f"{INFO_PLIST_FILE}: {key} is {info[key]!r}, expected {expected!r}")
    return problems


def check_dependency_doc(doc, pins):
    problems = []
    for identity, pin in sorted(pins.items()):
        name = repository_name(pin.get("location", identity))
        # Whole names only, so apple/swift-nio-ssl does not count for apple/swift-nio.
        if not re.search(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", doc, re.IGNORECASE):
            problems.append(f"{DEPENDENCIES_DOC}: does not name {name}, which Package.resolved pins")
    return problems


# The source rules for Projects code (AGENTS.md, Runtime rules and Continuous integration).
#
# check_sources reads every file under Orra/, OrraTests/ and Tools/. It reads Swift files
# through swift_views, so a name in a comment never counts. Rules 1 to 4, 6 to 8 and 11 look
# at code only, outside string literals, so English words in a prompt never trip them. Rule
# 5 also looks inside string literals, and reads every other file whole. Names match on word
# boundaries. Rules 1 to 9 and 11 name paths only, never the syntax of a file they allow, so
# a file that does not exist yet passes. Rule 10 reads the syntax of the one file it is
# about, Orra/Projects/Mail/MailEvents.swift, once it exists, and looks for attach requests
# in the code of every Swift file under Orra/. A failure names the file, the line, the rule
# and the name it matched, never the rest of the line.

PROJECTS_FOLDER = "Orra/Projects/"
PROJECTS_TESTS_FOLDER = "OrraTests/Projects/"

# The file of the Mail bridge that builds and sends Mail's events (rule 10).
MAIL_EVENTS_FILE = "Orra/Projects/Mail/MailEvents.swift"
# The file whose attach alone may make an attach request (rule 10).
MAIL_BRIDGE_FILE = "Orra/Projects/Mail/MailBridge.swift"
# The only Swift files under Orra/ that may build or send an Apple Event (rule 3).
APPLE_EVENT_FILES = frozenset({MAIL_EVENTS_FILE})

# The only file in Orra that may open another app, Mail on the user's click (rule 11).
MAIL_APP_FILE = "Orra/MailApp.swift"
# The only file in Orra/Projects that may make an NSAttributedString (rule 2).
FILE_TEXT_FILE = "Orra/Projects/Index/FileText.swift"
# The only file in Orra/Projects that may remove, move, replace or trash files (rule 7).
STORAGE_FILE = "Orra/Projects/ProjectsStorage.swift"
# The only file in Orra/Projects that may read a file by a URL with Foundation, Orra's own
# list of projects, which never lies in a project folder (rule 1).
PROJECT_LIST_FILE = "Orra/Projects/Store/ProjectList.swift"
# The only files in Orra/Projects that may use UserDefaults (rule 8).
DEFAULTS_FILES = frozenset({"Orra/Projects/ProjectsSwitch.swift", "Orra/Projects/Mail/MailChoice.swift"})
# This check and its tests name the script words of rule 5.
SCRIPT_RULE_EXCEPTIONS = frozenset({"Tools/ci/check_rules.py", "Tools/ci/test_check_rules.py"})

SOURCE_FOLDERS = ("Orra", "OrraTests", "Tools")
# Python caches and build output under Tools/, which git ignores. Nothing is skipped under
# Orra/ or OrraTests/, since Xcode builds whatever is there.
SKIPPED_TOOLS_FOLDERS = frozenset({"__pycache__", ".build", "build", "DerivedData", ".swiftpm"})
# Finder's folder settings, which git ignores.
SKIPPED_FILES = frozenset({".DS_Store"})

SOURCE_RULES = {
    1: "Code in Orra/Projects never types, uses Accessibility or the pasteboard, runs a process, "
       "loads code by name, shows web content, Markdown or remote images, opens a URL, connects "
       "to the network, quits an app, removes a file with a C call or resolves XML entities. It "
       "hands no URL or path to a reader of files, such as Data(contentsOf:) or "
       "PDFDocument(url:), except in Store/ProjectList.swift, which reads Orra's list of "
       "projects. No member there may be named html or webArchive, the document types that read "
       "through WebKit.",
    2: "In Orra/Projects only Index/FileText.swift makes an NSAttributedString, from data with the "
       "documentType named in the same call, never from a URL, a path or HTML.",
    3: "In Orra only the files in APPLE_EVENT_FILES build or send an Apple Event. Reading the launch event is fine.",
    4: "Tests never send an Apple Event, use the live Mail bridge, bring Mail to the front or "
       "open Mail. Building a descriptor is fine.",
    5: "No file in Orra, OrraTests or Tools runs or holds script text.",
    6: "Only Orra/Projects and OrraTests/Projects use SQLite.",
    7: "In Orra/Projects only ProjectsStorage.swift removes, moves, replaces or trashes files.",
    8: "In Orra/Projects only ProjectsSwitch.swift and Mail/MailChoice.swift use UserDefaults.",
    9: "Orra/Projects holds Swift files only, since Xcode would copy any other file into the app.",
    10: "MailEvents.swift builds only the get, count, reply and attach events of its MailEvent enum, "
        "sets their parameters only where it builds them, and sends them only from sendNow, after the "
        "check of the Mail session. It opens a window with every reply, makes nothing but an attachment "
        "with only its file at the end of a reply's content, and holds no other code of a Mail command "
        "that changes mail, sends it, or opens, prints or quits something, nor the code of content "
        "outside that one place. In Orra only MailBridge's attach makes an attach request.",
    11: "In Orra only MailApp.swift opens another app, and tests open none.",
}

# Rule 10. The four events the Mail bridge may build, by their names in the MailEvent enum,
# each the event class and the event ID as Mail.sdef writes them. get and count, from the
# standard suite, only read. reply, from Mail's suite, makes a reply in a window of its own.
# attach is make, from the standard suite, which check_mail_events holds to one use: an
# attachment, with only its file, at the end of the content of a reply.
MAIL_EVENTS = {"get": "coregetd", "count": "corecnte", "reply": "emalrpms", "attach": "corecrel"}
# The commands that change mail, send it, or open, print or quit something, from
# /System/Applications/Mail.app/Contents/Resources/Mail.sdef (Mail 16.0 on macOS 26.6) and
# the standard suite it includes from /System/Library/ScriptingDefinitions/CocoaStandard.sdef.
# set is in neither, since AppleScript sends it for any property, so its code comes from
# AERegistry.h (kAECoreSuite and kAESetData). make is the attach event of MAIL_EVENTS, so it
# is not here, and its event ID is banned on its own below.
MAIL_CHANGING_COMMANDS = {
    "coresetd": "set",
    "coredelo": "delete",
    "coremove": "move",
    "coreclon": "duplicate",
    "coresave": "save",
    "coreclos": "close",
    "emsgsend": "send",
    "emalfwms": "forward",
    "emalrdms": "redirect",
    "emalbcms": "bounce",
    "emalsyac": "synchronize",
    "emalchma": "check for new mail",
    "emalimmx": "import Mail mailbox",
    "emalemtg": "GetURL",
    "emalemto": "mailto",
    "emalcpma": "perform mail action with messages",
    "aevtodoc": "open",
    "aevtpdoc": "print",
    "aevtquit": "quit",
}
# The four letter codes rule 10 bans: the event ID of each of those commands, the event class
# of those whose class no event of MAIL_EVENTS shares, the event ID of make, which only the
# attach case of MailEvent may hold as part of its whole code, and content, the message
# property Mail renders, which the model must never read (AGENTS.md). content stands only
# as the place of a new attachment, see check_mail_events.
MAIL_BANNED_CODES = {
    **{command[4:]: name for command, name in MAIL_CHANGING_COMMANDS.items()},
    **{
        command[:4]: name
        for command, name in MAIL_CHANGING_COMMANDS.items()
        if command[:4] not in {event[:4] for event in MAIL_EVENTS.values()}
    },
    "crel": "make",
    "ctnt": "content",
}
# The codes of the parameters of make and of an insertion location, and of the positions
# other than the end, which MailEvents.swift must name through the SDK's names that
# check_mail_events reads, never through their four letters.
MAKE_CODES = {
    "kocl": "the class of a new object",
    "insh": "the place of a new object",
    "prdt": "the properties of a new object",
    "kobj": "the object of an insertion location",
    "kpos": "the position of an insertion location",
    "befo": "the position before",
    "afte": "the position after",
    "bgng": "the position at the beginning",
    "rplc": "the position that replaces",
}


def _import(module):
    """An import of the module, also with an attribute such as @preconcurrency, an access
    level, or a kind such as import class WebKit.WKWebView."""
    return r"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?" + module + r"\b"


def _system_call(code, match):
    """system( counts unless it is a member, such as .font(.system(size: 12)). Darwin.system(
    and its like still count."""
    before = code[max(0, match.start() - 200):match.start()].rstrip()
    if not before.endswith("."):
        return True
    owner = re.search(r"(\w+)\s*$", before[:-1])
    return owner is not None and owner.group(1) in ("Darwin", "Foundation", "Glibc")


def _c_call(code, match):
    """remove(, rename( and kill( count as the C calls, as system( does, unless they declare
    a function or pass no argument or a labeled one, which no C call does. So
    projects.remove(at: 0), func remove(_ id: UUID) and remove(project: id) pass."""
    if not _system_call(code, match):
        return False
    if re.search(r"\bfunc\s*$", code[max(0, match.start() - 200):match.start()]):
        return False
    arguments = _arguments(code, match.end() - 1)
    if arguments is None:
        return True
    return bool(arguments.strip()) and all(label is None for label in _labels(arguments))


def _not_array_literal(code, match):
    """perform( counts unless its first argument is a whole array literal, as in Vision's
    handler.perform([request]). NSObject's perform(_:) takes a selector, which is never an
    array, while an element of one, as in perform([#selector(run)][0]), still counts."""
    arguments = _arguments(code, match.end() - 1)
    if arguments is None:
        return True
    first = _top_level_items(arguments)[0].strip()
    if not first.startswith("["):
        return True
    inner = _arguments(first, 0)
    return inner is None or len(inner) + 2 != len(first)


def _rule(*patterns, flags=0):
    """Compiles the patterns of a rule. A pattern is a regular expression, or a pair of one
    and a function of the view and the match that says whether the match counts."""
    compiled = []
    for pattern in patterns:
        check = None
        if isinstance(pattern, tuple):
            pattern, check = pattern
        compiled.append((re.compile(pattern, flags), check))
    return compiled


# Rule 1, in the code of Orra/Projects.
PROJECTS_BANNED = _rule(
    r"\bTextInserter\b",
    r"\bCGEvent\w*",
    r"\bk?AX[A-Z]\w*",
    r"\bNSWorkspace\b",
    r"\bNSPasteboard\b",
    # The concealed copy of Orra/ConcealedClipboard.swift. Projects gets it as a closure.
    r"\bConcealedClipboard\b",
    r"\bProcess\b",
    r"\bNSTask\b",
    r"\bposix_spawnp?\b",
    (r"\bsystem\s*\(", _system_call),
    r"\bpopen\b",
    r"\bexecv\w*",
    r"\bfork\b",
    r"\bdlopen\b",
    r"\bdlsym\b",
    r"\bNSClassFromString\b",
    r"\bNSSelectorFromString\b",
    # Every Selector initializer takes a string. #selector( is checked by the compiler.
    r"\bSelector\s*\(",
    (r"\.\s*perform\s*\(", _not_array_literal),
    r"\bperformSelector\w*",
    # The Objective-C runtime and Bundle find a class by its name, and these attributes bind
    # a C function by its name.
    r"\bobjc_\w+",
    r"\bclassNamed\b",
    r"@_silgen_name\b",
    r"@_extern\b",
    r"\bWKWebView\b",
    _import("WebKit"),
    r"\bURLSession\b",
    _import("Network"),
    r"\bNWConnection\b",
    r"\bAsyncImage\b",
    r"\bLink\s*\(",
    r"\bopenURL\b",
    r"\bOpenURLAction\b",
    r"\bLSOpen\w*",
    r"\b(?:NS)?AttributedString\s*(?:\.\s*init\s*)?\(\s*markdown\b",
    # The HTML and web archive document types, which read through WebKit, also when a
    # value of the type comes from another file. ".html" in a string literal is fine. A
    # document type made from its raw value could be either.
    r"\.\s*html\b",
    r"\.\s*webArchive\b",
    r"\bDocumentType\s*(?:\.\s*init\s*)?\(",
    r"\bterminate\s*\(",
    r"\bforceTerminate\b",
    (r"\bkill(?:pg)?\s*\(", _c_call),
    r"\bunlink(?:at)?\b",
    r"\brmdir\b",
    (r"\b(?:remove|rename)\s*\(", _c_call),
    r"\brename(?:at|x_np|atx_np)\b",
    r"\bremovefile\b",
    # Readers that open a file by a URL or a path follow links and download a file that is
    # not on this Mac. A file in a project folder is read only through the checked read of
    # Index/FileText.swift, and its bytes are handed to the reader.
    r"\bPDFDocument\s*\(\s*url",
    r"\bCGPDFDocumentCreateWithURL\b",
    r"\bCGImageSourceCreateWithURL\b",
    r"\bCGDataProviderCreateWith(?:URL|Filename)\b",
    r"\bVNImageRequestHandler\s*\(\s*url",
    r"\bXMLParser\s*\(\s*contentsOf",
    r"\bXMLDocument\s*\(\s*contentsOf",
    r"\bNSImage\s*\(\s*(?:contentsOf|byReferencing)",
    # XMLParser resolves no external entity unless told to.
    r"\bexternalEntityResolvingPolicy\b",
    r"\bshouldResolveExternalEntities\b",
    r"\ballowedExternalEntityURLs\b",
)

# Rule 1, in the code of Orra/Projects but PROJECT_LIST_FILE: the readers of Foundation and C
# that read a file by a URL or a path, which follow links and download a file that is not on
# this Mac.
PROJECTS_FILE_READERS = _rule(
    r"\b(?:NS)?(?:Mutable)?(?:Data|String)\s*\(\s*contentsOf",
    r"\bNS(?:Mutable)?(?:Dictionary|Array)\s*\(\s*contentsOf",
    r"\bFileHandle\s*\(\s*for(?:Reading|Updating)",
    r"\.\s*contents\s*\(\s*atPath",
    r"\b(?:NS)?InputStream\s*\(\s*(?:url|fileAtPath)",
    r"\.\s*resourceBytes\b",
    r"\bfopen\b",
)

# Rule 2, in the code of Orra/Projects.
ATTRIBUTED_STRING = re.compile(r"\bNS(?:Mutable)?AttributedString\s*(?:\.\s*init\s*)?\(")
# The first argument labels FileText.swift may use: data with a documentType, text, or
# no label, which converts an AttributedString. Every other one may read a file, a URL or
# HTML, or guess the format.
ATTRIBUTED_STRING_LABELS = frozenset({"data", "string", "attributedString", None})
ARGUMENT_LABEL = re.compile(r"\s*(\w+)\s*:")

# Scripting Bridge sends an Apple Event for each call on its objects. A sendEvent that is
# not called right away, such as let send = event.sendEvent, could be called later with
# any options. An NSEvent's sendEvent(_:) is always called and stays fine.
SENDING = (
    r"\bsendEvent\s*\(\s*options\b",
    r"\bsendEvent\b(?!\s*\()",
    _import("ScriptingBridge"),
    r"\bSB(?:Application|Object|ElementArray)\b",
    r"\bAESendMessage\b",
    r"\bAESend\b",
)

# Rule 3, in the code of Orra/.
APPLE_EVENT_BUILDING = _rule(
    r"\bNSAppleEventDescriptor\s*\.\s*appleEvent\b",
    r"\bappleEvent\s*\(\s*withEventClass\b",
    r"\bNSAppleEventDescriptor\s*(?:\.\s*init\s*)?\(\s*eventClass\b",
    *SENDING,
    r"\bAECreateAppleEvent\b",
    r"\bAEBuildAppleEvent\b",
    r"\bAEDeterminePermissionToAutomateTarget\b",
)

# Rule 4, in the code of OrraTests/.
APPLE_EVENT_SENDING = _rule(
    *SENDING,
    r"\bAEDeterminePermissionToAutomateTarget\b",
    r"\bMailBridge\s*\.\s*live\b",
    r"\bMailEvents\s*\.\s*live\b",
    # The real activation of Mail, which tests replace with a fake.
    r"\bReplyHandoff\s*\.\s*bringMailToFront\b",
    # The real Open Mail, which tests replace with a fake too.
    r"\bMailApp\s*\.\s*open\b",
)

# Rule 5, in code and string literals, and in every other file. AppleScript ignores case.
SCRIPT_TEXT = _rule(
    r"\bNSAppleScript\b",
    r"\bOSAScript\b",
    _import("OSAKit"),
    r"\bosacompile\b",
    r"\btell\s+application\b",
    r"\bNSUser(?:AppleScript|Unix|Automator|Script)Task\b",
    flags=re.IGNORECASE,
)

# Rule 6, in the code of Orra/ and OrraTests/ outside the Projects folders.
SQLITE = _rule(_import("SQLite3"), r"\bsqlite3_\w*")

# Rule 7, in the code of Orra/Projects.
FILE_REMOVAL = _rule(r"\bremoveItem\b", r"\bmoveItem\b", r"\breplaceItem\w*", r"\btrashItem\b")

# Rule 8, in the code of Orra/Projects. @AppStorage, CFPreferences and
# NSUserDefaultsController reach the same values.
DEFAULTS = _rule(r"\bUserDefaults\b", r"\bAppStorage\b", r"\bCFPreferences\w*", r"\bNSUserDefaults\w*")

# Rule 11, in the code of Orra/ outside MailApp.swift and of OrraTests/. The ways to open or
# launch an app. NSWorkspace's open with an app's URL would pass, which review covers, and
# rule 1 bans NSWorkspace in Orra/Projects.
APP_OPENING = _rule(r"\bopenApplication\b", r"\blaunchApplication\w*", r"\bLSOpen\w*")

# Rule 10, in MailEvents.swift. Other ways to build an event, whose codes the rule cannot
# read, and ways to change the class, the ID or a parameter of an event after it is built.
MAIL_EVENTS_BANNED = _rule(
    r"\bAECreateAppleEvent\b",
    r"\bAEBuildAppleEvent\b",
    r"\btypeAppleEvent\b",
    r"\bsetAttribute\b",
    r"\bAEPut\w*",
    r"\bAEReplaceDescData\b",
    r"\bkeyEventClassAttr\b",
    r"\bkeyEventIDAttr\b",
)
# The calls that build an event, with the labels of their event class and event ID.
EVENT_BUILDERS = (
    (re.compile(r"\bappleEvent\s*\(\s*withEventClass\b"), "withEventClass", "appleEvent(withEventClass:"),
    (re.compile(r"\bNSAppleEventDescriptor\s*(?:\.\s*init\s*)?\(\s*eventClass\b"), "eventClass", "NSAppleEventDescriptor(eventClass:"),
)
# A reply opens its window: the opening window parameter ropw is set to true, and only so.
OPENING_WINDOW = re.compile(
    r'\.\s*setParam\s*\(\s*NSAppleEventDescriptor\s*\(\s*boolean\s*:\s*true\s*\)\s*,\s*'
    r'forKeyword\s*:\s*(?:(?:MailEvents|Self)\s*\.\s*)?code\s*\(\s*"ropw"\s*\)\s*\)'
)
INTEGER_LITERAL = re.compile(r"(?<![\w.])(0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|[0-9][0-9_]*)(?![\w.])")
# The calls of attach that check_mail_events allows, each once. make makes only an attachment:
# its class is the attachment class atts, and keyAEObjectClass names no other class but the
# class the count event counts. It goes only at the end of a reply's content, built by
# endOfContent(ofReply:). Its properties are only its file, built by fileProperties(_:).
_CODE_CALL = r'(?:(?:MailEvents|Self)\s*\.\s*)?code\s*\(\s*"{}"\s*\)'
ATTACHMENT_CLASS = re.compile(
    r'\.\s*setParam\s*\(\s*NSAppleEventDescriptor\s*\(\s*typeCode\s*:\s*' + _CODE_CALL.format("atts")
    + r'\s*\)\s*,\s*forKeyword\s*:\s*keyAEObjectClass\s*\)'
)
COUNTED_CLASS = re.compile(
    r'\.\s*setParam\s*\(\s*NSAppleEventDescriptor\s*\(\s*typeCode\s*:\s*elementClass\s*\)\s*,\s*forKeyword\s*:\s*keyAEObjectClass\s*\)'
)
END_OF_CONTENT_PLACE = re.compile(
    r'\.\s*setParam\s*\(\s*try\s+Self\s*\.\s*endOfContent\s*\(\s*ofReply\s*:\s*\w+\s*\)\s*,\s*forKeyword\s*:\s*keyAEInsertHere\s*\)'
)
AT_THE_END = re.compile(
    r'\.\s*setDescriptor\s*\(\s*NSAppleEventDescriptor\s*\(\s*enumCode\s*:\s*kAEEnd\s*\)\s*,\s*forKeyword\s*:\s*keyAEPosition\s*\)'
)
# The name of the reply's id in the declaration of endOfContent(ofReply:).
REPLY_PARAMETER = re.compile(r"\bfunc\s+endOfContent\s*\(\s*ofReply\s+(\w+)\s*:\s*Int\s*\)")
# The content of outgoing message id <reply> of the application, kept in a constant, and the
# one place of the insertion location that names it. {} stands for the reply's id.
REPLY_CONTENT = (
    r'\blet\s+(\w+)\s*=\s*MailEvents\s*\.\s*Specifier\s*\.\s*property\s*\(\s*' + _CODE_CALL.format("ctnt")
    + r'\s*,\s*of\s*:\s*\.\s*id\s*\(\s*MailEvents\s*\.\s*Code\s*\.\s*outgoingMessage\s*,\s*{}\s*,\s*of\s*:\s*\.\s*application\s*\)\s*\)'
)
CONTENT_PLACE = r'\.\s*setDescriptor\s*\(\s*try\s+{}\s*\.\s*descriptor\s*\(\s*\)\s*,\s*forKeyword\s*:\s*keyAEObject\s*\)'
FILE_PROPERTIES = re.compile(
    r'\.\s*setParam\s*\(\s*try\s+Self\s*\.\s*fileProperties\s*\(\s*\w+\s*\)\s*,\s*forKeyword\s*:\s*keyAEPropData\s*\)'
)
ONLY_THE_FILE = re.compile(
    r'\.\s*setDescriptor\s*\(\s*NSAppleEventDescriptor\s*\(\s*fileURL\s*:\s*\w+\s*\)\s*,\s*forKeyword\s*:\s*' + _CODE_CALL.format("atfn") + r'\s*\)'
)
# The positions of an insertion location other than the end.
OTHER_POSITIONS = _rule(r"\bkAEBefore\b", r"\bkAEAfter\b", r"\bkAEBeginning\b", r"\bkAEReplace\b")
# The attach case of appleEvent(target:) and the bodies of its two builders as rule 10 allows
# them, compared without white space. A helper called from them, another parameter or another
# object fails, and a change of these lines takes a change of these values too.
PINNED_ATTACH_CASE = """
    case .attach(let file, let reply, _):
        event.setParam(NSAppleEventDescriptor(typeCode: MailEvents.code("atts")), forKeyword: keyAEObjectClass)
        event.setParam(try Self.endOfContent(ofReply: reply), forKeyword: keyAEInsertHere)
        event.setParam(try Self.fileProperties(file), forKeyword: keyAEPropData)
"""
PINNED_END_OF_CONTENT = """
    let content = MailEvents.Specifier.property(MailEvents.code("ctnt"), of: .id(MailEvents.Code.outgoingMessage, reply, of: .application))
    guard let location = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeInsertionLoc) else {
        throw MailEvents.Failure(code: errAECoercionFail)
    }
    location.setDescriptor(try content.descriptor(), forKeyword: keyAEObject)
    location.setDescriptor(NSAppleEventDescriptor(enumCode: kAEEnd), forKeyword: keyAEPosition)
    return location
"""
PINNED_FILE_PROPERTIES = """
    guard file.isFileURL else {
        throw MailEvents.Failure(code: errAECoercionFail)
    }
    let properties = NSAppleEventDescriptor.record()
    properties.setDescriptor(NSAppleEventDescriptor(fileURL: file), forKeyword: MailEvents.code("atfn"))
    return properties
"""
# appleEvent(target:) makes the event, fills it in one switch over the request and returns it,
# with nothing else before or after the switch.
MAKE_THE_EVENT = re.compile(r"\s*let\s+event\s*=\s*NSAppleEventDescriptor\s*\.\s*appleEvent\s*\(")
# sendNow(_ request:) sends every event, in these steps and in this order: it finds the running
# Mail, refuses a request bound to another Mail session, builds the event for that Mail's
# process id and sends it. Each step stands once in sendNow, sendEvent and a call of
# appleEvent(target:) stand nowhere else, and sendNow never binds request, mail, target or event
# again.
SEND_NOW = re.compile(r"\bfunc\s+sendNow\s*\(")
SEND_NOW_SIGNATURE = re.compile(r"\bfunc\s+sendNow\s*\(\s*_\s+request\s*:\s*Request\s*\)\s*throws\s*->\s*Value\s*\{")
SEND_NOW_STEPS = (
    ("the running Mail", re.compile(r"\bguard\s+let\s+mail\s*=\s*runningMail\s*\(\s*\)\s*else\s*\{")),
    ("the check of the Mail session", re.compile(
        r"\bif\s+let\s+code\s*=\s*refusal\s*\(\s*of\s*:\s*request\s*,\s*by\s*:\s*Session\s*\(\s*mail\s*\)\s*\)\s*\{"
        r"[^{}]*\bthrow\s+Failure\s*\(\s*code\s*:\s*code\s*\)\s*\}"
    )),
    ("the target", re.compile(r"\blet\s+target\s*=\s*NSAppleEventDescriptor\s*\(\s*processIdentifier\s*:\s*mail\s*\.\s*processIdentifier\s*\)")),
    ("the event", re.compile(r"\blet\s+event\s*=\s*try\s+request\s*\.\s*appleEvent\s*\(\s*target\s*:\s*target\s*\)")),
    ("the send", re.compile(r"\btry\s+event\s*\.\s*sendEvent\s*\(\s*options\s*:\s*request\s*\.\s*sendOptions\s*,\s*timeout\s*:\s*request\s*\.\s*timeout\s*\)")),
)
# A name of sendNow bound again: declared, assigned or taken as a closure's parameter.
SEND_NOW_NAMES = re.compile(r"\b(request|mail|target|event)\b(?=\s*(?:=(?!=)|\bin\b|,[^)]*\bin\b))")
# The functions whose bodies may set a key of a record: the place and the properties of make,
# and the builders of an object specifier.
DESCRIPTOR_BUILDERS = (r"\bfunc\s+endOfContent\s*\(", r"\bfunc\s+fileProperties\s*\(", r"\bfunc\s+descriptor\s*\(", r"\bfunc\s+object\s*\(")
# An attach request across Orra/: the case attach of MailEvents.Request named through its type,
# or made with the label toReply, which only its declaration may hold besides.
REQUEST_ATTACH = re.compile(r"\bRequest\s*\.\s*attach\b")
TO_REPLY = re.compile(r"\btoReply\b")
ATTACH_DECLARATION = re.compile(r"\s*case\s+attach\s*\(")

SourceProblem = namedtuple("SourceProblem", "path line rule name")


class SwiftLexError(Exception):
    def __init__(self, offset, message):
        super().__init__(message)
        self.offset = offset
        self.message = message


# Where the lexer stops in code, in the code of an interpolation, in a block comment and in
# a literal. #" starts a raw string and #/ a regex literal, each with any number of #. A
# slash alone may start a /.../ regex literal. A backtick starts a name such as `default`
# or a raw identifier such as `drops https:// links`, which may hold //, /* and quotes.
_CODE_STOP = re.compile(r'//|/\*|#+["/]|"|[/`]')
_INTERPOLATION_STOP = re.compile(r'//|/\*|#+["/]|"|[()/`]')
_COMMENT_STOP = re.compile(r"/\*|\*/")
_STRING_STOP = re.compile(r'[\\"\n]')
_MULTILINE_STRING_STOP = re.compile(r'[\\"]')
_REGEX_STOP = re.compile(r"[\\/\n]")
_MULTILINE_REGEX_STOP = re.compile(r"[\\/]")
_NOT_NEWLINE = re.compile(r"[^\n]")
# Swift's operator characters, without the dot, which only an operator that starts with a
# dot holds.
_OPERATOR_CHARACTERS = frozenset("/=-+!*%<>&|^~?")
# What may stand right before a /.../ regex literal, and what makes the operator before it
# end, as Swift binds operators.
_BEFORE_PREFIX = frozenset(" \t\r\n([{,;:") | _OPERATOR_CHARACTERS
_AFTER_OPERATOR_END = frozenset(" \t\r\n)]},;:")
# Keywords after which an expression starts, so a slash right after one starts a regex
# literal, as in return/"/. Words such as then and yield are names outside a few places,
# and a slash after a name divides.
_KEYWORDS_BEFORE_EXPRESSION = frozenset(
    {"return", "throw", "try", "await", "case", "in", "where", "if", "guard", "while", "switch", "repeat", "else"}
)
# What may end an expression right before a postfix ! or ?, as in a!/2, where the slash
# divides.
_EXPRESSION_END = frozenset(')]}"`')


def swift_views(text):
    """Returns (code, uncommented), two copies of a Swift file with its length and lines.

    code blanks the comments and the text of string and regex literals, and keeps the code
    of string interpolations. uncommented blanks the comments only. Comments nest. Strings
    may be raw, with any number of #, and multi-line. A literal or comment without an end
    raises SwiftLexError, so the lexer can never be led to skip code. A #/.../# regex literal
    is a literal. A /.../ regex literal stays in the code view, since telling it from a
    division takes Swift's rules for operators, see _bare_regex_end. The lexer only steps
    over it, so a quote in it starts no string. A name in backticks stays in the code view
    too, and the lexer steps over it the same way.
    """
    comments, literals = _lex(text)
    return _blanked(text, comments + literals), _blanked(text, comments)


def _lex(text):
    """The spans of the comments and of the literals of a Swift file, see swift_views. The
    text of a string around an interpolation is a span of its own, from the opening quote or
    the closing parenthesis of an interpolation."""
    comments = []
    literals = []
    # One entry per open interpolation: the hashes and the kind of its string, and the
    # parenthesis depth of the code around the string.
    open_strings = []
    depth = 0
    pos = 0
    while True:
        stop = (_INTERPOLATION_STOP if open_strings else _CODE_STOP).search(text, pos)
        if stop is None:
            if open_strings:
                raise SwiftLexError(len(text), "string literal without an end")
            break
        token = stop.group()
        start = stop.start()
        if token == "//":
            end = text.find("\n", start)
            pos = len(text) if end < 0 else end
            comments.append((start, pos))
        elif token == "/*":
            pos = _block_comment_end(text, start)
            comments.append((start, pos))
        elif token == "(":
            depth += 1
            pos = stop.end()
        elif token == ")":
            if depth > 0:
                depth -= 1
                pos = stop.end()
                continue
            # The end of an interpolation. Its string goes on.
            hashes, multiline, depth = open_strings.pop()
            pos, interpolation = _string_end(text, start, start + 1, hashes, multiline, literals)
            if interpolation:
                open_strings.append((hashes, multiline, depth))
                depth = 0
        elif token == "`":
            pos = _backtick_name_end(text, start)
        elif token == "/":
            pos = _bare_regex_end(text, start) or start + 1
        elif token.endswith("/"):
            pos = _regex_end(text, start, len(token) - 1, literals)
        else:
            hashes = len(token) - 1
            content = stop.end()
            multiline = text.startswith('""', content)
            if multiline:
                content += 2
                line_end = text.find("\n", content)
                if line_end < 0 or text[content:line_end].strip(" \t\r"):
                    raise SwiftLexError(start, "multi-line string literal that does not start on a new line")
            pos, interpolation = _string_end(text, start, content, hashes, multiline, literals)
            if interpolation:
                open_strings.append((hashes, multiline, depth))
                depth = 0
    return comments, literals


def _block_comment_end(text, start):
    depth = 0
    pos = start
    while True:
        stop = _COMMENT_STOP.search(text, pos)
        if stop is None:
            raise SwiftLexError(start, "block comment without an end")
        depth += 1 if stop.group() == "/*" else -1
        pos = stop.end()
        if depth == 0:
            return pos


def _string_end(text, start, pos, hashes, multiline, literals):
    """Reads string text from pos up to the end of the literal or an interpolation.

    Returns the position after it and whether it was an interpolation. Adds the literal
    text from start to literals.
    """
    closer = ('"""' if multiline else '"') + "#" * hashes
    escape = "\\" + "#" * hashes
    stops = _MULTILINE_STRING_STOP if multiline else _STRING_STOP
    while True:
        stop = stops.search(text, pos)
        if stop is None or stop.group() == "\n":
            raise SwiftLexError(start, "string literal without an end")
        index = stop.start()
        if stop.group() == "\\":
            if not text.startswith(escape, index):
                pos = index + 1
                continue
            after = index + len(escape)
            if text.startswith("(", after):
                literals.append((start, after + 1))
                return after + 1, True
            if not multiline and text.startswith("\n", after):
                raise SwiftLexError(start, "string literal without an end")
            pos = after + 1
        elif text.startswith(closer, index):
            literals.append((start, index + len(closer)))
            return index + len(closer), False
        else:
            pos = index + 1


def _regex_end(text, start, hashes, literals):
    """Reads a #/.../# regex literal and returns the position after it. One whose #/ ends
    its line may span lines."""
    content = start + hashes + 1
    closer = "/" + "#" * hashes
    line_end = text.find("\n", content)
    multiline = line_end >= 0 and not text[content:line_end].strip(" \t\r")
    stops = _MULTILINE_REGEX_STOP if multiline else _REGEX_STOP
    pos = content
    while True:
        stop = stops.search(text, pos)
        if stop is None or stop.group() == "\n":
            raise SwiftLexError(start, "regex literal without an end")
        index = stop.start()
        if stop.group() == "\\":
            if not multiline and text.startswith("\n", index + 1):
                raise SwiftLexError(start, "regex literal without an end")
            pos = index + 2
        elif text.startswith(closer, index):
            literals.append((start, index + len(closer)))
            return index + len(closer)
        else:
            pos = index + 1


def _backtick_name_end(text, start):
    """The position after a name in backticks at start. Swift ends it at the next backtick
    on the same line."""
    end = text.find("`", start + 1)
    if end < 0 or "\n" in text[start + 1:end]:
        raise SwiftLexError(start, "name in backticks without an end")
    return end + 1


def _word_before(text, end):
    """The word that ends at end, and where it starts."""
    start = end
    while start > 0 and (text[start - 1].isalnum() or text[start - 1] == "_"):
        start -= 1
    return text[start:end], start


def _is_keyword_before(text, end):
    """Whether a keyword that starts an expression ends at end. After a dot, as in
    .return, it is a member name."""
    word, start = _word_before(text, end)
    return word in _KEYWORDS_BEFORE_EXPRESSION and (start == 0 or text[start - 1] not in ".$#@`")


def _bare_regex_end(text, start):
    """The position after a /.../ regex literal at start, or None where the slash is an
    operator.

    As in Swift, the slash starts a regex literal only where an operator would be a prefix
    operator: nothing that ends an expression right before it, such as a name, a number or
    a closing bracket, and no white space or closing punctuation right after the operator
    it starts, such as /= in x /= y. A keyword such as return does not end an expression,
    while a postfix ! or ?, as in a!/2, does. The literal ends at the next slash without a
    backslash before it, on the same line.
    """
    if start > 0 and text[start - 1] not in _BEFORE_PREFIX and not _is_keyword_before(text, start):
        return None
    postfix = start
    while postfix > 0 and text[postfix - 1] in "!?":
        postfix -= 1
    if 0 < postfix < start:
        before = text[postfix - 1]
        if (before.isalnum() or before == "_" or before in _EXPRESSION_END) and not _is_keyword_before(text, postfix):
            return None
    operator_end = start + 1
    while operator_end < len(text) and text[operator_end] in _OPERATOR_CHARACTERS:
        operator_end += 1
    if operator_end >= len(text) or text[operator_end] in _AFTER_OPERATOR_END:
        return None
    pos = start + 1
    while pos < len(text):
        character = text[pos]
        if character == "\n" or (character == "\\" and text.startswith("\n", pos + 1)):
            return None
        if character == "/":
            return pos + 1
        pos += 2 if character == "\\" else 1
    return None


def _blanked(text, spans):
    """text with every character in the spans but line breaks turned into a space."""
    parts = []
    last = 0
    for start, end in sorted(spans):
        parts.append(text[last:start])
        parts.append(_NOT_NEWLINE.sub(" ", text[start:end]))
        last = end
    parts.append(text[last:])
    return "".join(parts)


def _line(text, offset):
    return text.count("\n", 0, offset) + 1


def _find(view, path, rule, patterns):
    """The names the patterns find in view, one problem for each place. Where two patterns
    find the same place, such as NSAppleEventDescriptor.appleEvent(withEventClass:, the
    first one counts."""
    matches = []
    for pattern, check in patterns:
        for match in pattern.finditer(view):
            if check is None or check(view, match):
                matches.append(match)
    matches.sort(key=lambda match: (match.start(), -match.end()))
    problems = []
    taken_up_to = -1
    for match in matches:
        if match.start() < taken_up_to:
            continue
        taken_up_to = match.end()
        problems.append(SourceProblem(path, _line(view, match.start()), rule, " ".join(match.group().split())))
    return problems


def _arguments(code, opening):
    """The text between the parenthesis at opening and the one that closes it, or None."""
    depth = 0
    for index in range(opening, len(code)):
        character = code[index]
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
            if depth == 0:
                return code[opening + 1:index]
    return None


def _labels(arguments):
    """The label of each argument, None where it has none."""
    segments = []
    depth = 0
    segment_start = 0
    for index, character in enumerate(arguments):
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        elif character == "," and depth == 0:
            segments.append(arguments[segment_start:index])
            segment_start = index + 1
    segments.append(arguments[segment_start:])
    labels = []
    for segment in segments:
        label = ARGUMENT_LABEL.match(segment)
        labels.append(label.group(1) if label else None)
    return labels


def _attributed_strings(code, path):
    """Rule 2 for one file of Orra/Projects."""
    problems = []
    for match in ATTRIBUTED_STRING.finditer(code):
        name = match.group().split("(")[0].split(".")[0].strip() + "("
        line = _line(code, match.start())
        if path != FILE_TEXT_FILE:
            problems.append(SourceProblem(path, line, 2, name))
            continue
        arguments = _arguments(code, match.end() - 1)
        labels = _labels(arguments) if arguments is not None else []
        first = labels[0] if labels else None
        if arguments is None:
            problems.append(SourceProblem(path, line, 2, name + " without an end"))
        elif "url" in labels:
            problems.append(SourceProblem(path, line, 2, name + "url:"))
        elif first not in ATTRIBUTED_STRING_LABELS:
            problems.append(SourceProblem(path, line, 2, name + first + ":"))
        elif first == "data" and not re.search(r"\bdocumentType\b", arguments):
            problems.append(SourceProblem(path, line, 2, name + "data: without documentType"))
    return problems


def _string_value(text, start, end):
    """The text of a one line string literal at text[start:end], with its escapes read, or
    None for a multi-line string, a regex literal or the text around an interpolation."""
    literal = text[start:end]
    hashes = len(literal) - len(literal.lstrip("#"))
    closer = '"' + "#" * hashes
    body = literal[hashes:]
    if not body.startswith('"') or body.startswith('"""') or len(body) < 2 * len(closer) or not body.endswith(closer):
        return None
    escape = "\\" + "#" * hashes
    named = {"0": "\0", "n": "\n", "r": "\r", "t": "\t", '"': '"', "'": "'", "\\": "\\"}

    def read(match):
        if match.group(1).startswith("u"):
            return chr(int(match.group(2), 16))
        return named[match.group(1)]

    return re.sub(re.escape(escape) + r"(u\{([0-9A-Fa-f]{1,8})\}|[0nrt\"'\\])", read, body[1:len(body) - len(closer)])


def _top_level_items(arguments):
    """The arguments of a call, split at its top level commas."""
    items = []
    depth = 0
    start = 0
    for index, character in enumerate(arguments):
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        elif character == "," and depth == 0:
            items.append(arguments[start:index])
            start = index + 1
    items.append(arguments[start:])
    return items


def _labeled(arguments):
    """The labeled arguments of a call, label to value."""
    values = {}
    for item in _top_level_items(arguments):
        match = re.match(r"\s*(\w+)\s*:(.*)\Z", item, re.DOTALL)
        if match:
            values[match.group(1)] = match.group(2).strip()
    return values


def _enum_body(code, name):
    """The span of the body of enum name between its braces in the code view, or None."""
    match = re.search(r"\benum\s+" + name + r"\b[^{]*\{", code)
    if match is None:
        return None
    depth = 0
    for index in range(match.end() - 1, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return match.end(), index
    return None


def _mail_event_cases(code, uncommented, body):
    """The case declarations at the top level of the MailEvent body: (offset, text) for each
    case, the text running to the end of its line, or on while the line ends in a comma."""
    start, end = body
    cases = []
    depth = 0
    index = start
    while index < end:
        character = code[index]
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        elif depth == 0 and code.startswith("case", index) and _word_before(code, index)[0] == "" \
                and not (code[index + 4:index + 5].isalnum() or code[index + 4:index + 5] == "_"):
            stop = index + 4
            while True:
                line_end = code.find("\n", stop)
                line_end = end if line_end < 0 or line_end > end else line_end
                if line_end >= end or not uncommented[index + 4:line_end].rstrip().endswith(","):
                    break
                stop = line_end + 1
            cases.append((index, uncommented[index + 4:line_end]))
            index = line_end
            continue
        index += 1
    return cases


def _function_bodies(code, signature):
    """The spans of the bodies of the functions whose declaration matches signature, a
    pattern that runs to the parenthesis that opens the parameters, in the code view."""
    bodies = []
    for match in re.finditer(signature, code):
        opening = match.end() - 1
        if _arguments(code, opening) is None:
            continue
        depth = 0
        index = opening
        while index < len(code):
            if code[index] == "(":
                depth += 1
            elif code[index] == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        brace = code.find("{", index)
        if brace < 0:
            continue
        depth = 0
        for end in range(brace, len(code)):
            if code[end] == "{":
                depth += 1
            elif code[end] == "}":
                depth -= 1
                if depth == 0:
                    bodies.append((brace + 1, end))
                    break
    return bodies


def _inside(offset, spans):
    return any(start <= offset < end for start, end in spans)


def _without_space(text):
    return re.sub(r"\s+", "", text)


def _case_blocks(code, start, end):
    """The cases of a switch whose body runs from start to end: (start, end) of each, from its
    case to the next one at the top level of the body."""
    starts = []
    depth = 0
    for index in range(start, end):
        character = code[index]
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth -= 1
        elif depth == 0 and code.startswith("case", index) and _word_before(code, index)[0] == "" \
                and not (code[index + 4:index + 5].isalnum() or code[index + 4:index + 5] == "_"):
            starts.append(index)
    return [(first, starts[number + 1] if number + 1 < len(starts) else end) for number, first in enumerate(starts)]


def _switch_of_apple_event(code):
    """The span of the body of the switch in appleEvent(target:), and whether the function
    holds nothing but the making of the event, that switch and `return event`."""
    bodies = _function_bodies(code, r"\bfunc\s+appleEvent\s*\(")
    if len(bodies) != 1:
        return None, False
    start, end = bodies[0]
    make = MAKE_THE_EVENT.match(code, start)
    match = re.search(r"\bswitch\s+self\s*\{", code[start:end])
    if match is None:
        return None, False
    opening = start + match.end() - 1
    depth = 0
    for index in range(opening, end):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                arguments = _arguments(code, make.end() - 1) if make else None
                made = make is not None and arguments is not None and code[make.end() + len(arguments) + 1:start + match.start()].strip() == ""
                returned = re.fullmatch(r"\s*return\s+event\s*", code[index + 1:end]) is not None
                return (opening + 1, index), made and returned
    return None, False


def _check_attach(text, code, uncommented, literals, problem):
    """The attach event of rule 10: make makes an attachment and nothing else, at the end
    of a reply's content only, with only its file."""
    values = []
    for start, end in literals:
        value = _string_value(text, start, end)
        if value is not None:
            values.append((start, value))

    def spans(pattern, view):
        return [match.span() for match in pattern.finditer(view)]

    def once(pattern, view, name):
        found = spans(pattern, view)
        if len(found) != 1:
            problem(found[1][0] if len(found) > 1 else None, name)
        return found

    def words(name):
        return [match.start() for match in re.finditer(r"\b" + name + r"\b", code)]

    # appleEvent(target:) builds the attach event in its attach case only, as pinned, and
    # sets the count's class in its count case only.
    switch, plain = _switch_of_apple_event(code)
    attach_case = count_case = None
    if switch is None:
        problem(None, "appleEvent(target:) without its switch over the request")
    else:
        for block in _case_blocks(code, *switch):
            if re.match(r"case\s+\.attach\b", code[block[0]:block[1]]):
                attach_case = block
            elif re.match(r"case\s+\.count\b", code[block[0]:block[1]]):
                count_case = block
        if attach_case is None or _without_space(uncommented[attach_case[0]:attach_case[1]]) != _without_space(PINNED_ATTACH_CASE):
            problem(attach_case[0] if attach_case else switch[0], "the attach case of appleEvent(target:) differs from what rule 10 allows")
        if not plain:
            problem(switch[0], "appleEvent(target:) does more than make the event, fill it in its switch and return it")
    for name, pinned in (("endOfContent", PINNED_END_OF_CONTENT), ("fileProperties", PINNED_FILE_PROPERTIES)):
        bodies = _function_bodies(code, r"\bfunc\s+" + name + r"\s*\(")
        if len(bodies) == 1 and _without_space(uncommented[bodies[0][0]:bodies[0][1]]) != _without_space(pinned):
            problem(bodies[0][0], name + " differs from what rule 10 allows")

    # make makes only an attachment, and keyAEObjectClass names no other class but the one
    # the count event counts.
    attachment_class = once(ATTACHMENT_CLASS, uncommented, "make without the attachment class atts")
    counted_class = [span for span in spans(COUNTED_CLASS, uncommented) if count_case and _inside(span[0], [count_case])]
    for start, value in values:
        if value == "atts" and not _inside(start, attachment_class[:1]):
            problem(start, '"atts" outside the class of make')
    for offset in words("keyAEObjectClass"):
        if not _inside(offset, attachment_class[:1] + counted_class[:1]):
            problem(offset, "keyAEObjectClass outside the classes of make and count")

    # At the end of a reply's content only.
    end_of_content = _function_bodies(code, r"\bfunc\s+endOfContent\s*\(")
    if len(end_of_content) != 1:
        problem(None, "not one endOfContent(ofReply:)")
    place = once(END_OF_CONTENT_PLACE, uncommented, "make without its place at the end of a reply's content")
    for offset in words("endOfContent"):
        declared = re.match(r"endOfContent\s*\(\s*ofReply\b", code[offset:]) is not None and \
            re.search(r"\bfunc\s+$", code[max(0, offset - 40):offset]) is not None
        if not declared and not _inside(offset, place[:1]):
            problem(offset, "endOfContent outside the place of make")
    for offset in words("keyAEInsertHere"):
        if not _inside(offset, place[:1]):
            problem(offset, "keyAEInsertHere outside the place of make")
    at_the_end = spans(AT_THE_END, uncommented)
    for name in ("keyAEPosition", "kAEEnd"):
        for offset in words(name):
            if not (_inside(offset, at_the_end) and _inside(offset, end_of_content[:1])):
                problem(offset, name + " outside the end of a reply's content")
    if not any(_inside(start, end_of_content[:1]) for start, _ in at_the_end):
        problem(None, "endOfContent(ofReply:) without the position at the end")
    # The object of the place is the content of the reply, outgoing message id <reply> of the
    # application, never of another message, and keyAEObject names it in one call only.
    parameter = REPLY_PARAMETER.search(code)
    contents = []
    if parameter and end_of_content:
        start, end = end_of_content[0]
        body = uncommented[start:end]
        reply_content = re.compile(REPLY_CONTENT.format(re.escape(parameter.group(1))))
        contents = [match for match in reply_content.finditer(body)]
    content_places = []
    if len(contents) == 1:
        start = end_of_content[0][0]
        place_pattern = re.compile(CONTENT_PLACE.format(re.escape(contents[0].group(1))))
        content_places = [(start + match.start(), start + match.end()) for match in place_pattern.finditer(uncommented[start:end_of_content[0][1]])]
    if len(contents) != 1 or len(content_places) != 1:
        problem(end_of_content[0][0] if end_of_content else None, "endOfContent(ofReply:) not at the content of outgoing message id reply")
    for offset in words("keyAEObject"):
        if not _inside(offset, content_places[:1]):
            problem(offset, "keyAEObject outside the content of the reply")
    for start, value in values:
        if value == "ctnt" and not _inside(start, end_of_content[:1]):
            problem(start, '"ctnt", the code of content, outside endOfContent(ofReply:)')

    # With only its file.
    file_properties = _function_bodies(code, r"\bfunc\s+fileProperties\s*\(")
    if len(file_properties) != 1:
        problem(None, "not one fileProperties(_:)")
    properties = once(FILE_PROPERTIES, uncommented, "make without its file as its properties")
    for offset in words("keyAEPropData"):
        if not _inside(offset, properties[:1]):
            problem(offset, "keyAEPropData outside the properties of make")
    for offset in words("fileProperties"):
        declared = re.search(r"\bfunc\s+$", code[max(0, offset - 40):offset]) is not None
        if not declared and not _inside(offset, properties[:1]):
            problem(offset, "fileProperties outside the properties of make")
    only_the_file = [span for span in spans(ONLY_THE_FILE, uncommented) if _inside(span[0], file_properties[:1])]
    keys = [match.start() for match in re.finditer(r"\bsetDescriptor\s*\(", code) if _inside(match.start(), file_properties[:1])]
    if len(only_the_file) != 1 or len(keys) != 1:
        problem(file_properties[0][0] if file_properties else None, "fileProperties(_:) with more than its file")
    for start, value in values:
        if value == "atfn" and not _inside(start, [span for span in only_the_file[:1]]):
            problem(start, '"atfn" outside the file of the attachment')

    # The parameters and positions only through the names read above.
    for start, value in values:
        if value in MAKE_CODES:
            problem(start, f'"{value}", the code of {MAKE_CODES[value]}')
    for pattern, _ in OTHER_POSITIONS:
        for match in pattern.finditer(code):
            problem(match.start(), match.group())


def _check_sending(code, problem):
    """Rule 10: MailEvents.swift sets an event's parameters only in the switch of
    appleEvent(target:), sets a key of a record only in the builders that make the place, the
    properties and the object specifiers, and sends an event only from sendNow, in its steps,
    after the check of the Mail session."""
    switch, _ = _switch_of_apple_event(code)
    for match in re.finditer(r"\bsetParam\s*\(", code):
        if switch is None or not _inside(match.start(), [switch]):
            problem(match.start(), "setParam outside the switch of appleEvent(target:)")
    builders = [span for signature in DESCRIPTOR_BUILDERS for span in _function_bodies(code, signature)]
    for match in re.finditer(r"\bsetDescriptor\s*\(", code):
        if not _inside(match.start(), builders):
            problem(match.start(), "setDescriptor outside the builders of the place, the properties and the specifiers")

    bodies = _function_bodies(code, SEND_NOW.pattern)
    if len(bodies) != 1 or SEND_NOW_SIGNATURE.search(code) is None:
        problem(None, "not one sendNow(_ request: Request) throws -> Value")
        return
    start, end = bodies[0]
    body = code[start:end]
    steps = []
    for name, pattern in SEND_NOW_STEPS:
        found = list(pattern.finditer(body))
        if len(found) != 1:
            problem(start + found[1].start() if len(found) > 1 else start, "sendNow without " + name + " once")
        else:
            steps.append((name, found[0].start()))
    # A step that stands after a step that must follow it.
    for number, (name, offset) in enumerate(steps):
        if any(offset > later for _, later in steps[number + 1:]):
            problem(start + offset, "sendNow with " + name + " out of its order")
    # request is the parameter, and mail, target and event are each bound once, by their step.
    for match in SEND_NOW_NAMES.finditer(body):
        name = match.group(1)
        declared = re.search(r"\blet\s+$", body[max(0, match.start() - 12):match.start()]) is not None
        if name == "request" or not declared or len(re.findall(r"\blet\s+" + name + r"\b", body)) != 1:
            problem(start + match.start(), "sendNow binds " + name + " again")
    for match in re.finditer(r"\bsendEvent\b", code):
        if not _inside(match.start(), [bodies[0]]):
            problem(match.start(), "sendEvent outside sendNow")
    if len(re.findall(r"\bsendEvent\b", body)) != 1:
        problem(start, "sendNow without one sendEvent")
    calls = []
    for match in re.finditer(r"\bappleEvent\s*\(\s*target\b", code):
        if re.search(r"\bfunc\s+$", code[max(0, match.start() - 40):match.start()]) is not None:
            continue
        calls.append(match.start())
        if not _inside(match.start(), [bodies[0]]):
            problem(match.start(), "appleEvent(target:) outside sendNow")
    if len(calls) > 1:
        problem(calls[1], "more than one call of appleEvent(target:)")


def check_attach_requests(text, code, path):
    """Rule 10 for a Swift file of Orra/: an attach request is made only in MailBridge's
    attach, once. A request names the case through its type, as Request.attach, or with the
    label toReply, which outside that place only the declaration of the case may hold. A
    member of a value, such as mail.attach(file, reply), calls the bridge. It reads names,
    not every way around them."""
    problems = []

    def problem(offset, name):
        problems.append(SourceProblem(path, _line(text, offset), 10, name))

    allowed = _function_bodies(code, r"\bfunc\s+attach\s*\(") if path == MAIL_BRIDGE_FILE else []
    for match in REQUEST_ATTACH.finditer(code):
        problem(match.start(), "an attach request outside MailBridge's attach")
    inside = []
    for match in TO_REPLY.finditer(code):
        line = code[code.rfind("\n", 0, match.start()) + 1:match.start()]
        if ATTACH_DECLARATION.match(line):
            continue
        if _inside(match.start(), allowed[:1]):
            inside.append(match.start())
        else:
            problem(match.start(), "an attach request outside MailBridge's attach")
    if len(inside) > 1:
        problem(inside[1], "more than one attach request in MailBridge's attach")
    return problems


def check_mail_events(text, path=MAIL_EVENTS_FILE):
    """Rule 10 for MailEvents.swift: only the events of MAIL_EVENTS, every reply with its
    window, make only as the attach event, and no code of MAIL_BANNED_CODES outside it."""
    comments, literals = _lex(text)
    code = _blanked(text, comments + literals)
    uncommented = _blanked(text, comments)
    problems = _find(code, path, 10, MAIL_EVENTS_BANNED)

    def problem(offset, name):
        problems.append(SourceProblem(path, None if offset is None else _line(text, offset), 10, name))

    # The enum holds exactly the four events, and its codes come from its raw values.
    body = _enum_body(code, "MailEvent")
    declared = set()
    if body is None:
        problem(None, "no MailEvent enum")
    else:
        for offset, declaration in _mail_event_cases(code, uncommented, body):
            for item in _top_level_items(declaration):
                case = re.fullmatch(r'\s*(\w+)\s*=\s*"([^"\\\n]*)"\s*', item)
                if case is None:
                    problem(offset, "MailEvent case " + " ".join(item.split()) + " without its code")
                    continue
                event, event_code = case.groups()
                if MAIL_EVENTS.get(event) != event_code or event in declared:
                    problem(offset, f"MailEvent case {event} = {event_code}")
                declared.add(event)
        for event in MAIL_EVENTS:
            if event not in declared:
                problem(body[0], f"MailEvent without case {event}")
        enum_code = code[body[0]:body[1]]
        for name, part in (("eventClass", "prefix"), ("eventID", "suffix")):
            getter = re.search(r"\bvar\s+" + name + r"\b[^{]*\{([^{}]*)\}", enum_code)
            if getter is None or not re.search(r"\brawValue\s*\.\s*" + part + r"\s*\(\s*4\s*\)", getter.group(1)):
                problem(body[0], f"MailEvent {name} not from rawValue.{part}(4)")

    # Every event takes its event class and event ID from a MailEvent.
    for pattern, class_label, name in EVENT_BUILDERS:
        for match in pattern.finditer(code):
            opening = code.index("(", match.start())
            arguments = _arguments(code, opening)
            values = _labeled(arguments) if arguments is not None else {}
            bases = []
            for label, member in ((class_label, "eventClass"), ("eventID", "eventID")):
                value = re.fullmatch(r"(?:self\s*\.\s*)?([\w.\s]*?)\s*\.\s*" + member, values.get(label, ""))
                bases.append(None if value is None else re.sub(r"\s+", "", value.group(1)))
            base = bases[0]
            from_mail_event = base is not None and bases[1] == base and (
                re.fullmatch(r"MailEvent\.(?:" + "|".join(MAIL_EVENTS) + r")", base) is not None
                or (re.fullmatch(r"\w+", base) is not None and re.search(r"\b" + base + r"\s*:\s*MailEvent\b", code) is not None)
            )
            if not from_mail_event:
                problem(match.start(), name + " not from MailEvent")

    # Every reply opens its window.
    allowed = [match.span() for match in OPENING_WINDOW.finditer(uncommented)]
    mentions = [match.start() for match in re.finditer(r'"ropw"', uncommented)]
    if not mentions:
        problem(None, "reply without ropw true")
    for offset in mentions:
        if not any(start <= offset < end for start, end in allowed):
            problem(offset, "ropw not set to true")

    # make makes only an attachment, at the end of a reply's content, with only its file.
    _check_attach(text, code, uncommented, literals, problem)
    # The parameters only where the event is built, and the send only from sendNow.
    _check_sending(code, problem)

    # No code of a command that changes mail, in a string or as a number. content, which
    # _check_attach allows as the place of an attachment, counts there.
    for start, end in literals:
        value = _string_value(text, start, end)
        if value is None or value == "ctnt":
            continue
        name = MAIL_CHANGING_COMMANDS.get(value) if len(value) == 8 else MAIL_BANNED_CODES.get(value) if len(value) == 4 else None
        if name is not None:
            problem(start, f'"{value}", the code of {name}')
    numbered = {**MAIL_BANNED_CODES, **MAKE_CODES}
    banned_numbers = {int.from_bytes(code_text.encode("latin-1"), "big"): (code_text, name) for code_text, name in numbered.items()}
    for match in INTEGER_LITERAL.finditer(code):
        literal = match.group(1).replace("_", "")
        number = int(literal, 0) if literal[:2].lower() in ("0x", "0o", "0b") else int(literal, 10)
        if number in banned_numbers:
            code_text, name = banned_numbers[number]
            problem(match.start(), f"{match.group(1)}, the code {code_text} of {name}")
    return problems


def source_files(root):
    """(path relative to root, path) of every file the source rules read, in a fixed order."""
    for top in SOURCE_FOLDERS:
        folder = root / top
        if not folder.is_dir():
            continue
        for folder_path, folder_names, file_names in os.walk(folder):
            if top == "Tools":
                folder_names[:] = [name for name in folder_names if name not in SKIPPED_TOOLS_FOLDERS]
            folder_names.sort()
            for name in sorted(file_names):
                if name not in SKIPPED_FILES:
                    path = Path(folder_path) / name
                    yield path.relative_to(root).as_posix(), path


def check_sources(root, apple_event_files=APPLE_EVENT_FILES):
    """Checks the Projects source rules under root, the repository folder.

    Returns the problems and the counts of Swift files and other files read.
    """
    problems = []
    swift_count = 0
    other_count = 0
    for path, file in source_files(root):
        in_projects = path.startswith(PROJECTS_FOLDER)
        in_app = path.startswith("Orra/")
        in_tests = path.startswith("OrraTests/")
        scripts_checked = path not in SCRIPT_RULE_EXCEPTIONS
        if not path.endswith(".swift"):
            other_count += 1
            if in_projects:
                problems.append(SourceProblem(path, None, 9, Path(path).suffix or "a file without an extension"))
            if scripts_checked:
                text = file.read_bytes().decode("utf-8", errors="replace")
                problems += _find(text, path, 5, SCRIPT_TEXT)
            continue
        swift_count += 1
        try:
            text = file.read_bytes().decode("utf-8")
            code, uncommented = swift_views(text)
        except UnicodeDecodeError:
            problems.append(SourceProblem(path, None, None, "not UTF-8"))
            continue
        except SwiftLexError as error:
            problems.append(SourceProblem(path, _line(text, error.offset), None, error.message))
            continue
        if scripts_checked:
            problems += _find(uncommented, path, 5, SCRIPT_TEXT)
        if in_projects:
            problems += _find(code, path, 1, PROJECTS_BANNED)
            if path != PROJECT_LIST_FILE:
                problems += _find(code, path, 1, PROJECTS_FILE_READERS)
            problems += _attributed_strings(code, path)
            if path != STORAGE_FILE:
                problems += _find(code, path, 7, FILE_REMOVAL)
            if path not in DEFAULTS_FILES:
                problems += _find(code, path, 8, DEFAULTS)
        if in_app and path not in apple_event_files:
            problems += _find(code, path, 3, APPLE_EVENT_BUILDING)
        if path == MAIL_EVENTS_FILE:
            problems += check_mail_events(text, path)
        if in_app:
            problems += check_attach_requests(text, code, path)
        if in_tests:
            problems += _find(code, path, 4, APPLE_EVENT_SENDING)
        if (in_app and path != MAIL_APP_FILE) or in_tests:
            problems += _find(code, path, 11, APP_OPENING)
        if (in_app or in_tests) and not in_projects and not path.startswith(PROJECTS_TESTS_FOLDER):
            problems += _find(code, path, 6, SQLITE)
    problems.sort(key=lambda problem: (problem.path, problem.line or 0, problem.rule or 0, problem.name))
    return problems, swift_count, other_count


def format_source_problem(problem):
    where = problem.path if problem.line is None else f"{problem.path} line {problem.line}"
    if problem.rule is None:
        return f"{where}: {problem.name}, so the source rules cannot read it"
    return f"{where}: rule {problem.rule}, {problem.name}"


def main(arguments):
    root = Path(arguments[1]) if len(arguments) > 1 else Path(__file__).resolve().parents[2]
    try:
        project = PropertyListParser((root / PROJECT_FILE).read_text(encoding="utf-8")).parse()
        resolved = json.loads((root / RESOLVED_FILE).read_text(encoding="utf-8"))
        doc = (root / DEPENDENCIES_DOC).read_text(encoding="utf-8")
        info = plistlib.loads((root / INFO_PLIST_FILE).read_bytes())
        setting_problems, configuration_count = check_build_settings(project)
        package_problems = check_packages(project)
        pin_problems, pins = check_pins(resolved)
        doc_problems = check_dependency_doc(doc, pins)
        info_problems = check_info_plist(info)
        source_problems, swift_count, other_count = check_sources(root)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, ParseError, plistlib.InvalidFileException) as error:
        print(f"Rules check could not read the repository at {root}. {type(error).__name__}: {error}")
        return 2
    problems = setting_problems + package_problems + pin_problems + doc_problems + info_problems
    if problems:
        print("Rules check failed:")
        for problem in problems:
            print(f"  {problem}")
        print("These values change only with the maintainer's approval (AGENTS.md, Needs maintainer approval).")
        print("After approval, the same commit updates the expected values in Tools/ci/check_rules.py")
        print("and the list in docs/dependencies.md.")
    if source_problems:
        print("Source check failed:")
        for problem in source_problems:
            print(f"  {format_source_problem(problem)}")
        for rule in sorted({problem.rule for problem in source_problems if problem.rule is not None}):
            print(f"Rule {rule}: {SOURCE_RULES[rule]}")
        print("AGENTS.md, Runtime rules, says what Projects code and the tests must not do.")
    if problems or source_problems:
        return 1
    print(
        f"Rules check passed: {len(EXPECTED_BUILD_SETTINGS)} build settings in {configuration_count} "
        f"build configurations, {len(EXPECTED_PACKAGE_REFERENCES)} package references with their "
        f"linked products, {len(pins)} pinned packages, all named in {DEPENDENCIES_DOC}, and the "
        f"update keys in {INFO_PLIST_FILE}."
    )
    print(
        f"Source check passed: the {len(SOURCE_RULES)} source rules in {swift_count} Swift files "
        f"and {other_count} other files under {', '.join(SOURCE_FOLDERS)}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
