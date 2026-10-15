# Orra Microphone

A virtual microphone for speaking translations into a call. Orra plays the translated speech to the output
side of this device, and a call app such as Google Meet picks the device as its microphone.
The other people in the call then hear the translation.

It is an Audio Server plug in (a HAL plug in) that coreaudiod loads from
/Library/Audio/Plug-Ins/HAL. It lives outside Orra/ and OrraTests/, so the Xcode project
does not see it, and the app neither builds nor installs it. Nothing in this folder runs
on its own.

Status: the source builds, and an in process test loads the bundle the way coreaudiod finds
it and checks the properties and the loopback. pkg.sh builds an installer package. Neither
the driver nor the package has been installed on a Mac yet, so they have not been tried
with coreaudiod, Installer, Google Meet or Orra.

## The device

| | |
|---|---|
| Name | Orra Microphone |
| UID | io.github.db-ol.Orra.Microphone |
| Bundle ID | io.github.db-ol.Orra.Microphone |
| Format | 48 kHz, 32 bit float, 2 channels, interleaved |
| Streams | one input (terminal type microphone), one output |
| Transport type | virtual |
| Controls | none (no volume, no mute) |

- Audio written to the output side comes back on the input side about two IO buffers later.
  Several apps may read the input side at once.
- The input side may be the default microphone. The output side never becomes the default
  speaker, so system sounds and music never go into a call by accident. Orra picks the
  device by its UID.
- When nothing plays, the input side is silent. After a pause the input side never repeats
  old audio.

## How it works

The source is one C file, OrraMicrophone.c, written from the interface in
CoreAudio/AudioServerPlugIn.h. The objects follow the pattern of Apple's NullAudio sample:
the plug in (object 1), one device (2), the input stream (3) and the output stream (4), all
with fixed IDs. No code comes from BlackHole or any other GPL project.

- The device clock is the host clock. GetZeroTimeStamp returns a zero time stamp every
  16384 frames after the moment IO started, computed from mach_absolute_time with no
  stored state.
- One ring buffer of 16384 frames (about 340 ms) in static storage holds the audio. Frame f
  of the device timeline lives at f modulo 16384. WriteMix copies the mixed output into it,
  ReadInput copies it out. An atomic holds the end of the last write. Frames at or past it,
  or more than one ring before it, read as silence, and a write after a pause first clears
  the frames it skipped.
- The IO functions never allocate, never lock and never log. A mutex guards only the state
  that the control calls change (IO client count, stream active flags).
- One rate and one format. Setting the same rate or format again succeeds, any other value
  fails with kAudioDeviceUnsupportedFormatError.

## Build and check

Needs the Xcode command line tools. From this folder:

    make            # build/OrraMicrophone.driver, arm64 and x86_64, signed ad hoc
    make test       # loads the bundle in process and checks the loopback
    make pkg        # build/OrraMicrophone.pkg, the installer, unsigned
    ./check.sh      # all of the above, plus plutil, nm and package checks

check.sh is meant for CI as well. It installs nothing, needs no sudo and never signs with
a certificate. It checks that the driver compiles with no warnings, that Info.plist is
valid, that the factory named in Info.plist (OrraMicrophone_Create) is the only exported
function in both slices, that the ad hoc signature verifies, and that
Tests/loopback_test.c passes. Then it builds the unsigned package and checks it: the
payload holds the driver only, every item is root:wheel with mode 755 (folders and the
executable) or 644, it installs to /Library/Audio/Plug-Ins/HAL and cannot be relocated,
the minimum macOS is 15.6 for arm64 and x86_64, the postinstall script restarts
coreaudiod, and the unpacked driver's signature still verifies.

## Build the installer

    make pkg

This runs pkg.sh, which needs no sudo and installs nothing. It builds the driver again,
stages it with mode 755 or 644, and makes:

- build/pkg/OrraMicrophone-component.pkg with `pkgbuild`: identifier
  `io.github.db-ol.Orra.Microphone.pkg`, the version from Info.plist, install location
  /Library/Audio/Plug-Ins/HAL, every item owned by root:wheel (`--ownership recommended`),
  not relocatable (Package/component.plist), and the postinstall script
  Package/scripts/postinstall.
- build/OrraMicrophone.pkg with `productbuild` and Package/Distribution.xml: title Orra
  Microphone, macOS 15.6 or later, arm64 and x86_64, installed on the startup disk only.

The postinstall script restarts coreaudiod with `launchctl kickstart -k
system/com.apple.audio.coreaudiod`, and with `killall coreaudiod` when launchctl refuses.
Every app's audio stops for a moment.

Without the variables in the next section, the driver is signed ad hoc and the package is
not signed. Such a package is for a test on your own Mac only, Gatekeeper blocks it on
any other. To look inside it:

    pkgutil --payload-files build/OrraMicrophone.pkg
    pkgutil --expand build/OrraMicrophone.pkg /tmp/OrraMicrophone-expanded
    lsbom -p fMUG /tmp/OrraMicrophone-expanded/OrraMicrophone-component.pkg/Bom
    cat /tmp/OrraMicrophone-expanded/OrraMicrophone-component.pkg/Scripts/postinstall

The payload lists entries starting with `._` next to each file. They hold extended
attributes of the build folder, such as com.apple.provenance, and are applied as
attributes, not written as files (`pkgutil --expand-full` shows this).

To install it on a test Mac, open it in Finder, or:

    sudo installer -pkg build/OrraMicrophone.pkg -target /

## Install by hand

Without the package. Only on a Mac where you want the device. Installing restarts
coreaudiod, which stops every app's audio for a moment.

    make
    sudo cp -R build/OrraMicrophone.driver /Library/Audio/Plug-Ins/HAL/
    sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/OrraMicrophone.driver
    sudo launchctl kickstart -k system/com.apple.audio.coreaudiod

On some macOS versions launchctl refuses to restart coreaudiod while System Integrity
Protection is on. Then use `sudo killall coreaudiod`, and launchd starts it again.

Check that the device is there:

    system_profiler SPAudioDataType | grep -A 8 "Orra Microphone"

Then in Google Meet: Settings, Audio, Microphone, Orra Microphone. For a quick test
without Orra, start a recording in QuickTime Player (File, New Audio Recording) with Orra
Microphone as the input, and play a word to the output side:

    say -o /tmp/hello.aiff "Hello from Orra"
    swift Tests/play_to_device.swift "Orra Microphone" /tmp/hello.aiff

The recording should hold the spoken word. `say -a "Orra Microphone"` does not work: say
lists only devices that can be the default output, and the output side of Orra Microphone
never can.

A local ad hoc signed build is what other open source HAL plug ins use for testing, but it
has not been tried here. If coreaudiod does not list the device, `log stream --predicate
'process == "coreaudiod" OR process CONTAINS "Core-Audio-Driver-Service"'` shows why while
it restarts.

## Uninstall

Whether the package or a copy by hand installed it:

    sudo Drivers/OrraMicrophone/uninstall.sh

It removes /Library/Audio/Plug-Ins/HAL/OrraMicrophone.driver, restarts coreaudiod (with
`killall coreaudiod` when launchctl refuses) and runs `pkgutil --forget
io.github.db-ol.Orra.Microphone.pkg` when the package installed it. By hand, the same is:

    sudo rm -rf /Library/Audio/Plug-Ins/HAL/OrraMicrophone.driver
    sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
    sudo pkgutil --forget io.github.db-ol.Orra.Microphone.pkg

## Sign and notarize (maintainer)

A package for other Macs needs three things from team X77KW5VYFJ, all optional to pkg.sh
and read only from the environment. pkg.sh never sets them on its own.

- `DRIVER_IDENTITY`: the Developer ID Application certificate that signs Orra.app. pkg.sh
  signs the driver with it, with the hardened runtime and a secure timestamp. The driver
  needs no entitlements.
- `INSTALLER_IDENTITY`: a Developer ID Installer certificate, which is separate from the
  Application one. pkg.sh signs the package with `productsign`.
- `NOTARY_PROFILE`: the notarytool keychain profile that releases of Orra use
  (docs/releasing.md). pkg.sh runs `xcrun notarytool submit --wait`, then `xcrun stapler
  staple` and `xcrun stapler validate`. It needs both identities, since notarization
  rejects a driver without a Developer ID signature.

From the repository root, with both certificates in the login keychain:

    security find-identity -v -p basic | grep "Developer ID"
    cd Drivers/OrraMicrophone
    make clean
    DRIVER_IDENTITY="Developer ID Application: Jiayao Tang (X77KW5VYFJ)" \
    INSTALLER_IDENTITY="Developer ID Installer: Jiayao Tang (X77KW5VYFJ)" \
    NOTARY_PROFILE=orra-notary \
        make pkg

Use the names `security find-identity` prints. pkg.sh refuses an identity of another kind
or another team. Leave out `NOTARY_PROFILE` to sign without notarizing. Then check the
result:

    pkgutil --check-signature build/OrraMicrophone.pkg
    pkgutil --expand-full build/OrraMicrophone.pkg /tmp/OrraMicrophone-full
    codesign --verify --strict --verbose=2 /tmp/OrraMicrophone-full/OrraMicrophone-component.pkg/Payload/OrraMicrophone.driver
    spctl --assess --type install --verbose build/OrraMicrophone.pkg

A rejected notarization stops pkg.sh with the status, and the result and the log are in
build/pkg. The stapled ticket lets the package open on a Mac without a network
connection. A bare .driver bundle cannot be stapled, the package can.

To sign only the driver, without a package:

    make clean
    make SIGN_ID="Developer ID Application: Jiayao Tang (X77KW5VYFJ)" \
        SIGN_FLAGS="--options runtime --timestamp"
    codesign --verify --strict --verbose=2 build/OrraMicrophone.driver

## How Orra would use it

Phase 3 work in the app, not part of this folder:

- Find the device with kAudioHardwarePropertyTranslateUIDToDevice and the UID above, and
  show an install hint when it is missing.
- Point an AVAudioEngine (or an output audio unit through kAudioOutputUnitProperty_CurrentDevice)
  at the device, and play the synthesized speech converted to 48 kHz stereo.
- Never set the device as the system default output.

## License

MIT, the license of the repository (LICENSE in the root).
