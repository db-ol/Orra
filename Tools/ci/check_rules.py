#!/usr/bin/env python3
"""Fails when one of the checked values that need the maintainer's approval changes.

AGENTS.md says that signing, the Development Team, the bundle IDs, entitlements, App
Sandbox, the deployment target and the dependencies change only with the maintainer's
approval. This script compares the build settings, package references and linked
products listed below with project.pbxproj, the pins with Package.resolved, the update
keys with Orra/Info.plist, and checks that docs/dependencies.md names every pinned package. It covers the settings listed here,
not every way a build can change signing. When the maintainer approves a change, the same
commit updates the expected values here.

Run from anywhere, with Python 3.8 or later and nothing outside the standard library:

    python3 Tools/ci/check_rules.py [repository folder]
"""

import json
import plistlib
import re
import sys
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
    # input entitlement, and nothing else is allowed. Xcode writes the other choices of the
    # Hardened Runtime capability out as NO, which they must stay.
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
    "AUTOMATION_APPLE_EVENTS": {
        "Orra": "NO",
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
}

# The package products each target links, as (product, package location).
EXPECTED_PRODUCTS = {
    "Orra": {
        ("Qwen3ASR", "https://github.com/soniqo/speech-swift"),
        ("Sparkle", "https://github.com/sparkle-project/Sparkle"),
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
        return 1
    print(
        f"Rules check passed: {len(EXPECTED_BUILD_SETTINGS)} build settings in {configuration_count} "
        f"build configurations, {len(EXPECTED_PACKAGE_REFERENCES)} package references with their "
        f"linked products, {len(pins)} pinned packages, all named in {DEPENDENCIES_DOC}, and the "
        f"update keys in {INFO_PLIST_FILE}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
