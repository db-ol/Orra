# Orra engineering guide

Orra is an open source voice input app for macOS. Transcription runs on the user's Mac.
Projects, an optional module for mail and project folders, ships as a preview.
Projects code must keep it off by default, read mail only through the Mail app and files
only in the folders the user adds, and use no language model on them but the local cleanup model.
This file is the guide for anyone, human or agent, who changes this repository.

## Platform
- macOS 15.6 or later. Apple Silicon first.
- Swift 6 with strict concurrency. The project sets default actor isolation to MainActor.
- SwiftUI by default. AppKit only where SwiftUI cannot do the job (menu bar, window control, events).
- SwiftPM for approved dependencies only. docs/dependencies.md lists them. speech-swift
  (product Qwen3ASR, pinned commit) is approved for Qwen3-ASR 1.7B.
- Distributed outside the Mac App Store. App Sandbox is off because Orra will use Accessibility APIs.
- Signed by team X77KW5VYFJ. Releases use its Developer ID and are notarized. The hardened
  runtime is on with two exceptions: the audio input entitlement, which the microphone
  needs, and the Apple Events entitlement, which Projects needs to read mail in the Mail
  app, approved by the maintainer on 2026-10-18.

## Intended flow
Hotkey -> Audio Capture -> TranscriptionEngine -> optional RewriteEngine -> Text Injection
Projects (optional, a preview): Mail app (Apple Events) and project folders -> local index -> cleanup model -> Projects window -> Mail's reply window and the clipboard, on the user's click

Keep it simple. Do not add a protocol, layer, or abstraction without a concrete need in the code today.

## Out of scope
No backend, no Orra accounts, no analytics, no cloud transcription, and no platforms other
than macOS. No database, except the Projects index (SQLite from macOS, in Application
Support), which Projects code may create and use only while Projects is on. No cloud LLM,
neither for rewriting nor for Projects. Optional rewriting on this Mac with a local model, with the dictated
text always recoverable, is allowed. It is off by default, except that on a Mac with 16 GB
of memory or more, a new user's Download Models in the welcome window also downloads the
cleanup model and turns cleanup on. The button shows the total size of both models, and
the user can turn cleanup off in Settings. A saved choice is never changed. The
maintainer approved this on 2026-10-15.

## Build discipline
Build (run in the repository root):

    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

Test: the same command with `-testLanguage en -testRegion US test` in place of `build`. The
tests compare English text, so they run in English whatever the Mac's language. Product >
Test in Xcode uses the Mac's language instead, unless the scheme's Test options set App
Language to English.

The build needs Xcode's Metal Toolchain component and the CudaBuild plugin of mlx-swift
trusted once in Xcode. docs/dependencies.md has the details.

- Build and test after every meaningful change. Read every warning instead of counting them.
- Never silence Swift concurrency warnings to get a green build. Fix the isolation instead.
- Never claim behavior works unless a build or a test verified it. Say what was verified and what was not.
- Orra/ and OrraTests/ are synchronized folder groups. New .swift files placed there are picked up
  automatically. Do not edit project.pbxproj by hand.

## Localization
- The interface is in English, Simplified Chinese (zh-Hans), Japanese (ja) and Spanish
  (es-419). Orra/Localizable.xcstrings holds the strings, and Orra/InfoPlist.xcstrings the
  microphone, system audio and Mail automation prompts. Spanish is Latin American Spanish,
  which a Mac in any Spanish falls back to, and it matches the menu items SwiftUI adds.
- SwiftUI text literals are localized on their own. Text built in code uses
  `String(localized:)`, and SwiftUI shows text that is already localized with
  `Text(verbatim:)`.
- Every new or changed string needs all three translations in the catalog, marked
  translated. Each names menu items, settings panes and keys as macOS does in that
  language.
  - Chinese: full width punctuation (，。：？！（）“”) and a space between Chinese and a
    Latin word or a number.
  - Japanese: です and ます in sentences, the plain form on buttons and menu items. 、 and
    。, full width parentheses, a half width ? and :, and “ ” around the names of buttons
    and settings and around quoted words, as macOS writes them, not 「」. No space between
    Japanese and a Latin word, a number or an argument, as in Orraを終了 and %lld秒.
    Dictation is 音声入力.
  - Spanish: tú, sentence case, ¿? and ¡!, “ ” around quoted words but no quotes around
    the names of buttons and settings. Latin American words, as macOS uses them in es-419:
    Configuración, la Mac, presionar, agregar.
- Keep the keys in the order Xcode writes them, sorted with `localizedStandardCompare`, and
  remove a string the code no longer uses, which Xcode marks stale. LocalizationTests
  checks the strings in the catalog and their order. Xcode adds new strings to the catalog
  when it builds, a command line build does not. This lists every string the code uses, in
  build/Localizations:

      xcodebuild -exportLocalizations -project Orra.xcodeproj -scheme Orra -derivedDataPath build/DerivedData -localizationPath build/Localizations -exportLanguage zh-Hans -exportLanguage ja -exportLanguage es-419 ARCHS=arm64

## Runtime rules
- The keyboard tap runs on the main thread, so every key press on the Mac waits for it. Never
  block the main thread, and keep audio and transcription work off the main actor.
- Quit Orra before turning off or removing its Accessibility access. Revoking access while the
  tap is installed can freeze keyboard and mouse input (Apple Developer Forums thread 844416).
- Orra reads another app's text only for two features, both off until the user turns them on,
  never from a password field or an app holding secure input. Learning from corrections reads the
  field it pasted into, for 3 minutes and only while that field has the focus. It stores the word
  pairs only, never the text, and never logs either. Use names on screen reads up to 1,000
  characters before the cursor in the focused field and the title of its window at the press that
  starts a dictation, and never reads a password manager. In an app that cannot give part of a
  field, it reads the whole field when it holds 20,000 characters or fewer and keeps only the last
  1,000 characters before the cursor. A field that does not say where its cursor is gives only the
  window title. It keeps what it read in memory for that dictation only, gives the speech model
  only the names and rare words taken from it, and never logs or saves the text or the names.
- Projects code must read mail only through the Mail app's scripting, only from the mailboxes
  the user chose and only while Mail runs. It must read files only in the folders the user
  added to any project, and nothing at all while Projects is off. An explanation may use
  passages of other projects' folders, labeled with their project. A draft's text never
  carries another project's passages or facts unless the user chose that file for the email.
  Orra opens Mail only when the user clicks Open Mail, through MailApp.open() in
  Orra/MailApp.swift, which code in Orra/Projects gets as a closure. Nothing else launches
  Mail. Projects code must never read ~/Library/Mail or ask for Full Disk Access. It must
  never log mail or file text, subjects, addresses, names or file names, only counts,
  timings and error codes.
- Projects code recognizes text in images and scanned pages only with Vision on this Mac,
  which is no language model, sends nothing, downloads nothing and runs only between
  dictations. It reads the bytes of a file in a project folder only through the checked read
  of Index/FileText.swift, never by a URL or a path, so no link is followed and no file that
  is not on this Mac is downloaded, and it never resolves an XML entity.
- The Projects model must have no tools. Projects code must treat the model's output as data
  and show it in the Projects window as plain text only. Code in Orra/Projects must never call
  TextInserter, post keyboard events, perform Accessibility actions, open URLs or run
  processes. The Mail bridge must send only its fixed read requests and `reply` with
  `opening window`, with every value passed as an Apple Event parameter, never inside script
  text. Tools/ci/check_rules.py checks these rules.
- Dictation goes first. Projects code must have the model read a long prompt in slices, and
  must start no model call from the press of the talk key or the translation key until the
  dictation is pasted or cancelled, as captions do, see EngineTurns. Every call of a language
  model in Projects must go through ModelGate. Text recognition is no language model and keeps
  out of dictation's way by its own pauses. No model whose trace calls another compiled
  function, such as a mixture of experts model, may join the shared group of ModelGate, see
  docs/dependencies.md. Projects code must load the cleanup model only while the Projects
  window is open or a Projects request runs.
- Orra never writes audio to disk or to the log. The one exception, approved by the maintainer
  on 2026-10-15, is Remember my voice in Settings, off until the user turns it on. It keeps
  the voice sample's audio, never what is said in it, in
  ~/Library/Application Support/io.github.db-ol.Orra/Voice (folder 0700, file 0600, left out
  of backups) until the user removes the sample or turns the switch off. VoiceSampleFile is
  the only code that writes it.
- Orra goes online only for the speech model download the user starts from the menu or the
  welcome window, the cleanup model download the user agrees to in Settings, for Clean Up
  Text, Translation or Projects, or starts in the welcome window (with the speech model
  through Download Models, or alone while cleanup is on), and for
  update checks through Sparkle that the user allowed or started.
  Launching must never touch the network before the user allowed update checks. Any other
  network use needs the maintainer's approval. docs/model-download.md describes the
  download, and docs/releasing.md the update feed. Projects code must never connect to a
  mail server. It must read mail only through the Mail app, which syncs on its own, and
  must never render email HTML or load remote content. Reading mail over IMAP or a provider
  API needs the maintainer's approval first.

## Needs maintainer approval
Do not change signing, the Development Team, the Bundle ID, entitlements, App Sandbox, or the
deployment target, and do not add a dependency or a new download server, without the
maintainer's approval. If a task needs one of these, write docs/BLOCKED.md with the question
and the options, commit it, and stop.

## Continuous integration
.github/workflows/ci.yml runs two jobs on every pull request and every push to main.
.github/workflows/pages.yml deploys the website in site/ to GitHub Pages when a push to main
changes site/. Keep the site in line with README.md, the user guide in docs/user-guide.md and
docs/privacy.md, as docs/website.md describes.

- Rules check, on Linux: `python3 Tools/ci/check_rules.py`. It fails when one of the values it
  lists at the top differs: the team, bundle IDs, deployment target, App Sandbox, hardened
  runtime, entitlements and signing settings in project.pbxproj, the package references and
  linked products, and the packages and revisions in Package.resolved. It also fails on an
  .xcconfig file and when docs/dependencies.md does not name a pinned package. It covers the
  settings it lists, not every way to change signing, so review signing changes by hand too.
  It also checks the Projects source rules of Runtime rules: the names code in Orra/Projects
  must not use, readers there that open a file by a URL or a path or resolve XML entities
  among them, where NSAttributedString may appear, that Orra/Projects holds Swift files
  only, Apple Events built or sent in Orra outside the files it allows or sent from tests,
  the three events the Mail bridge may build and the window each reply opens,
  script text in any file under Orra, OrraTests or Tools, apps opened outside
  Orra/MailApp.swift and Mail opened from tests, and where SQLite, removing files and
  UserDefaults may appear. It reads names in code, not every way around them, so review
  Projects changes by hand too. The same job runs the tests of the rules check in Tools/ci
  and of the speech evaluation scorer in Tools/speech-eval.
- Build and test, on the xcode-27 runner, a GitHub hosted Mac with Xcode 27.0. It runs the test
  command above with code signing off and plugin validation skipped, downloads the Metal Toolchain
  when the runner lacks it, and skips RealModelTests, which need the model. The wired input test
  in InputUnitTests skips itself without microphone access.
- Never run the tests from an unsigned build on a Mac where a person is logged in without that
  skip in place. Setting up an audio unit asks for microphone access, and answering the prompt
  rewrites Orra's microphone permission for the unsigned build.
- Tests never send Apple Events. Projects code must keep the Mail bridge behind closures, and
  tests pass fakes, as they do for the models.

Changing one of the checked values still needs the maintainer's approval first. The commit that
makes the approved change also updates the expected values in Tools/ci/check_rules.py, or the
rules check fails.

## Git
- Focused commits with clear messages. One concern per commit.
- No force push, no history rewriting, and no push unless the maintainer asks for it.
- No Xcode user state (xcuserdata) and no build output in commits. Shared schemes under
  xcshareddata are fine to track.
- No secrets, tokens, or personal data in the repository.
