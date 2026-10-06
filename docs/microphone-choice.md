# Choosing the microphone

Added on 2026-10-05. Orra's menu bar menu has a Microphone submenu, and the Settings
window has the same choice. The maintainer asked for it after dictating with the
MacBook's lid closed, which turns the built in microphone off while it stays the
default input.

Facts marked "SDK" were read in the macOS 27.0 SDK headers that ship with Xcode 27.0.
Facts marked "this Mac" come from read only device surveys and logs on the
maintainer's Mac (macOS 26.6.2, build 25G83) on 2026-10-05. Nothing was recorded for
them. Facts marked "reported" come from other developers, not from Apple.

## What the menu lists

System Default comes first, with the name of the current default input. Then every
input Core Audio lists, in Core Audio's order, except:

- devices without input channels (kAudioDevicePropertyStreamConfiguration on the input
  scope)
- devices that are gone or hidden (kAudioDevicePropertyDeviceIsAlive,
  kAudioDevicePropertyIsHidden)
- devices that cannot be the default input (kAudioDevicePropertyDeviceCanBeDefaultDevice
  on the input scope). On this Mac that leaves out only Microsoft Teams Audio, a
  loopback device that is not a microphone.
- private aggregate devices. AVAudioEngine builds one named CADefaultDeviceAggregate
  inside Orra, and voice processing builds one named VPAUAggregateAudioDevice. Only the
  process that made one sees it, and that process is reported to find it in its own
  device list (coreaudio-api mailing list, 2016).
  Aggregates made in Audio MIDI Setup are public and stay in the list.

On this Mac the list read Brio 500 (USB, 2 channels), Administrator's iPhone Microphone
(Continuity) and MacBook Pro Microphone (built in, lid closed).

## How the choice is kept

The choice is saved as Core Audio's device UID and the device's name, under
`microphoneUID` and `microphoneName` in UserDefaults. No saved choice means System
Default.

Orra never keeps the AudioDeviceID. IDs change whenever a device reconnects, differ
between processes, and an old ID can later name another device. On this Mac one ID
named the display at 19:09 and the iPhone microphone at 19:21, and system daemons saw
the Brio under 19 different IDs in one day while its UID stayed the same.

At each hold Orra looks the UID up with kAudioHardwarePropertyTranslateUIDToDevice. For
a device that is not connected, Core Audio answers kAudioObjectUnknown without an error
(this Mac), and the system default records. The menu keeps the choice, marks it "(not
connected)", and the next dictation after the device returns uses it again. When the
default records instead of the chosen microphone, the menu names the device that
recorded, on a line of its own, so a note about the paste cannot hide it.

A USB device's UID carries its serial number when it has one, as the Brio does. A USB
device without a serial number may get a new UID on another port (Apple Developer
Forums thread 801522). Not tested here.

## How a chosen microphone records

AVAudioEngine has no documented way to record from a device other than the default
input on macOS. The header says the input and output nodes "communicate with the
system's default input and output devices" (SDK, AVAudioIONode.h). The usual workaround
sets kAudioOutputUnitProperty_CurrentDevice on the engine's input node, and it is
reported to fail for some devices: no frames from a Bluetooth headset, an error with
AirPods, and buffers from the wrong device. The engine also opens the default input
before the device can be changed, so a Bluetooth default input still switches to its
call profile (reported).

So a microphone chosen in Orra records through an input only audio unit (AUHAL) made
for each hold and bound to that device, which is how Apple's Technical Note TN2091
describes device input. `Orra/InputUnit.swift` follows it:

1. Enable input on element 1 and disable output on element 0.
2. Bind the device. TN2091 says this works only after IO is enabled. Orra always binds,
   also for the default input, because an unbound unit is reported to start without an
   error and deliver nothing.
3. Read the device's format and ask for 32 bit float mono at the device's own rate,
   because AUHAL does not resample input. AudioResampler makes it 16 kHz afterwards, as
   for the engine.
4. Take the device's first channel with a channel map, as the engine path does.
5. Set the input callback, initialize and start.

On release the unit is stopped, uninitialized and disposed, so the device is released
and the microphone indicator turns off.

The input callback runs on Core Audio's real time thread. It renders into scratch
memory set aside in advance and copies into a buffer for the whole recording, which is
allocated and touched before the start. It takes no lock, allocates nothing and logs
nothing.

During a hold Orra listens to the bound device. If the device goes away, runs at
another rate, or has no input channels left, the recording is cut, as a recording
through the engine is cut when its device changes. A change of the default input does
not matter for a chosen microphone. The listeners are removed at the end of the hold.
Core Audio matches a removal by its block, and Swift wraps a closure in a new block at
every call, so Orra passes one stored block through C function references. Calling the
functions directly left every hold's listeners behind (checked on this Mac in review,
and covered by a test since).

System Default still records through AVAudioEngine, as before. It is also the way out
if the unit misbehaves on some Mac: choose System Default and pick the device in System
Settings > Sound. When a chosen microphone cannot start, the menu says so, names both
steps and offers the Sound settings. Picking System Default alone is not enough while
the lid is closed, because the default input is then often the internal microphone.

When a chosen microphone records no sound at all, the menu points to Orra's own
Microphone choice instead of the Sound settings, because the input picked in Sound
settings does not change what a chosen microphone records.

The engine is rebuilt only when the default input changed since the engine was made.
Commit 084d272 compared the default input with the device read back from the engine's
input unit instead. Orra's log on this Mac shows that unit switching from the default
output to the engine's private aggregate, so the read back most likely never matched,
and the engine was rebuilt at every hold. Not verified, because Orra did not log the
value.

## The lid

With the lid closed, the MacBook's microphone stays listed, alive and able to be the
default input (this Mac), while Apple documents that the hardware disconnects it. Orra
marks it "(lid closed)" in the menu, and warns at the top of the menu while it is the
microphone Orra would record from. A recording without any sound names the microphone
that recorded, or says the lid is closed when that was the internal microphone.

The internal microphone is the built in device whose input data source is 'imic', or
whose UID is BuiltInMicrophoneDevice when it has no data source. A headset in the audio
jack is a built in device too, with the data source 'emic', and is expected to keep
working with the lid closed, so the transport type alone does not decide. Not tried
with a headset yet.

Orra does not switch to another microphone on its own while the lid is closed. It
records from the choice or the default and explains the silence afterwards.

## Not verified yet

- Recording through the unit on real hardware. InputUnitTests builds and initializes a
  unit for each wired input of this Mac and never starts it. On 2026-10-05 that was the
  Brio 500 (USB, 2 channels, 48 kHz) and the built in microphone (1 channel, 48 kHz).
- Units that record only zeros are reported on macOS 26.6.2, the build of this Mac, and
  on 27.0, with every Core Audio call succeeding. The cause is not known. Orra's silence
  check names the microphone when that happens.
- The iPhone microphone and Bluetooth inputs. A Bluetooth microphone is reported to
  deliver about half a second of silence at the first press after a pause.
- An output that cannot start, such as a display over HDMI or DisplayPort, is reported
  to leave input uncaptured where input and output run together. The engine runs input
  and output in one aggregate, so System Default may have the same problem. A chosen
  microphone does not, because its unit has no output.
- That the engine's private aggregate shows up in Orra's own device list, and would
  pass the other filters if the UID check did not leave it out. Orra never logged its
  own list. The rule itself is tested on made up devices.
- The Brio 500 dropped off Core Audio 21 times on 2026-10-05, for about half a second
  each (this Mac). A hold across a drop is cut, by design. A press during one records
  from the system default.

## Sources

- SDK: AVAudioIONode.h, AudioHardware.h, AudioHardwareBase.h, AudioUnitProperties.h.
- Apple Technical Note TN2091, Device input using the HAL Output Audio Unit.
- Apple Developer Forums threads 683348, 756169 and 801522.
- Apple Platform Security guide, Hardware microphone disconnect.
- Reports from other developers, marked "reported" above.
