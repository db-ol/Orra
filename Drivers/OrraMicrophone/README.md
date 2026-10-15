# Orra Microphone

A virtual microphone for speaking translations into a call. Orra plays the translated speech to the output
side of this device, and a call app such as Google Meet picks the device as its microphone.
The other people in the call then hear the translation.

It is an Audio Server plug in (a HAL plug in) that coreaudiod loads from
/Library/Audio/Plug-Ins/HAL. It lives outside Orra/ and OrraTests/, so the Xcode project
does not see it, and the app neither builds nor installs it. Nothing in this folder runs
on its own.

Status: the source builds, and an in process test loads the bundle the way coreaudiod finds
it and checks the properties and the loopback. It has not been installed on a Mac yet, so
it has not been tried with coreaudiod, Google Meet or Orra.

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
    ./check.sh      # all of the above, plus plutil and nm checks

check.sh is meant for CI as well. It installs nothing and needs no sudo. It checks that
the driver compiles with no warnings, that Info.plist is valid, that the factory named in
Info.plist (OrraMicrophone_Create) is the only exported function in both slices, that the
ad hoc signature verifies, and that Tests/loopback_test.c passes.

## Install by hand

Only on a Mac where you want the device. Installing restarts coreaudiod, which stops every
app's audio for a moment.

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

    sudo rm -rf /Library/Audio/Plug-Ins/HAL/OrraMicrophone.driver
    sudo launchctl kickstart -k system/com.apple.audio.coreaudiod

(or `sudo killall coreaudiod` as above). If a .pkg installed it, also run
`sudo pkgutil --forget io.github.db-ol.Orra.Microphone.pkg`.

## Signing and notarization

A release build is signed with the Developer ID of team X77KW5VYFJ, with the hardened
runtime and a secure timestamp. The driver needs no entitlements.

    make clean
    make SIGN_ID="Developer ID Application: <name> (X77KW5VYFJ)" \
        SIGN_FLAGS="--options runtime --timestamp"
    codesign --verify --strict --verbose=2 build/OrraMicrophone.driver

Notarize the .pkg that carries the driver (next section), which covers the driver inside
it. To notarize the driver alone, zip it with `ditto -c -k --keepParent` and submit the zip
with `xcrun notarytool submit --keychain-profile <profile> --wait`. A bare .driver bundle
cannot be stapled, a .pkg can.

## What a .pkg would need

Copying into /Library needs administrator rights, so the driver would ship as a signed
installer package, separate from Orra.app or offered by it as a download.

1. A staging folder with `Library/Audio/Plug-Ins/HAL/OrraMicrophone.driver`, signed as
   above, owned by root:wheel.
2. A postinstall script that restarts coreaudiod
   (`launchctl kickstart -k system/com.apple.audio.coreaudiod`, falling back to
   `killall coreaudiod`).
3. `pkgbuild --root <staging> --identifier io.github.db-ol.Orra.Microphone.pkg --version
   <version> --install-location / --scripts <scripts> OrraMicrophone-component.pkg`.
4. `productbuild` with a distribution file that sets the minimum macOS to 15.6 and the
   title, signed with a Developer ID Installer certificate of the team
   (`--sign "Developer ID Installer: <name> (X77KW5VYFJ)"`). That certificate is separate
   from the Developer ID Application certificate that signs Orra.app.
5. `xcrun notarytool submit` on the product, then `xcrun stapler staple`.
6. An uninstall path: either a documented command (above) or an uninstall script in Orra.

## How Orra would use it

Phase 3 work in the app, not part of this folder:

- Find the device with kAudioHardwarePropertyTranslateUIDToDevice and the UID above, and
  show an install hint when it is missing.
- Point an AVAudioEngine (or an output audio unit through kAudioOutputUnitProperty_CurrentDevice)
  at the device, and play the synthesized speech converted to 48 kHz stereo.
- Never set the device as the system default output.

## License

MIT, the license of the repository (LICENSE in the root).
