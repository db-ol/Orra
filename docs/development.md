# Developing Orra

This guide is for people who build, test or change Orra. [AGENTS.md](../AGENTS.md) has the rules every change follows, and the README and the [user guide](user-guide.md) describe Orra for its users.

## Requirements

- A Mac with Apple Silicon and macOS 15.6 or later.
- Xcode 27, with the Metal Toolchain component (Xcode > Settings > Components). The speech-swift dependency pulls in mlx-swift, which compiles Metal shaders at build time.
- The first build in Xcode asks you to Trust & Enable CudaBuild, a build tool plugin of mlx-swift. After that the command line builds work as they are, until a package update changes mlx-swift.

## Build and test

Run from the repository root:

    xcodebuild -project Orra.xcodeproj -scheme Orra -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build

Replace `build` with `-testLanguage en -testRegion US test` to run the unit tests. They compare English text, so they run in English whatever the Mac's language. docs/manual-testing.md lists what the tests cover and the checks to make by hand.

A build from Xcode and a release from GitHub are signed differently, and macOS ties Accessibility, the microphone and Orra's access to Mail for Projects (Privacy & Security, Automation) to the signature. Quit one before running the other, and grant access again when Orra asks. Both builds have the same bundle ID, so they share Orra's settings, the choices of Projects among them.

## A faster build for daily use

A Release build transcribes about a quarter faster than a Debug build. To keep one in ~/Applications, quit Orra, then run from the repository root:

    xcodebuild -project Orra.xcodeproj -scheme Orra -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
    rm -rf ~/Applications/Orra.app
    ditto build/DerivedData/Build/Products/Release/Orra.app ~/Applications/Orra.app

## How the code is organized

Orra is one app target, Orra/, with its unit tests in OrraTests/. The flow is: talk key (HotkeyTap, TalkKeyDetector) → recording (AudioRecorder, InputUnit) → transcription (Qwen3Engine, Transcription) → paste (TextInserter), driven by PushToTalkController and its state machine. Around it are the model download (ModelDownload, ModelInstaller), the feedback while dictating (RecordingFeedback, RecordingIndicator), the vocabulary and learning from corrections (Vocabulary, Corrections, CorrectionLearning, LearnedNotice), names on the screen as context for the speech model (ScreenReader, ScreenNames, ListEcho), updates (AppUpdater) and the interface (StatusMenu, SettingsView, WelcomeView).

Projects, the optional part for mail and project folders, is in Orra/Projects, with its tests in OrraTests/Projects. Mail talks to the Mail app through three Apple Events, two that read and one that opens a reply window (MailEvents, MailBridge), reads the chosen mailboxes (MailScan) and parses each message's source with its attachments (MIMEMessage, VisibleText, QuotedHistory, MailAttachment). Index keeps the text of the project folders and the names of all their files in a SQLite database (FolderWalk, FileText with ZipArchive and OfficeXMLText for Excel and PowerPoint files, TextRecognition for the text of images and scanned pages, FolderIndex, FileNameSearch, ProjectsDatabase). Sorting files new mail with rules and then the model (SortingService) and groups the mail of Needs a Project into suggested projects that the model names (ProjectSuggestions, ProjectSuggestionService, ProjectSuggestionPrompt, MailStoreSuggestions), Explain explains an email and revises its draft (ExplainService, ReviseService), and Check checks what the model wrote (DraftCheck, OutputChecks). Store keeps the projects, the mail, the explanations and the drafts with the text the user typed into them, and their retention (ProjectList, MailStore, Retention). Handoff opens the reply in Mail (ReplyHandoff), and Window is the Projects window, with ProjectsRuntime starting and stopping everything with the switch. ProjectsModelQueue runs every Projects prompt on the cleanup model in slices and pauses while you dictate, so dictation goes first. The Projects page of Settings is Orra/ProjectsSettings.swift, outside the folder, since only it may open a link. AGENTS.md lists the rules Projects code follows, and Tools/ci/check_rules.py checks part of them.

The interface is in English, Simplified Chinese, Japanese and Spanish. AGENTS.md explains how to add or change a string.

## Projects in a Debug build

A Debug build ticks no mailbox until you choose one, so it reads only what you tick, such as a test mailbox you imported into Mail. It also reads two preferences that release builds ignore, which make a person of your test mail count as you, so Orra does not read the addresses of your Mail accounts:

    defaults write io.github.db-ol.Orra projectsDebugOwnAddresses -array someone@example.com
    defaults write io.github.db-ol.Orra projectsDebugOwnName "Some One"

When you are done, choose Delete All Projects Data… in Settings, Projects, turn Projects off, and delete the two keys with `defaults delete`, so a test choice of mailboxes does not carry into a release. To see the question about Mail access again, quit Orra and run `tccutil reset AppleEvents io.github.db-ol.Orra`, which resets the answer of every build of Orra.

Debug and release builds also share the Projects data in Application Support. A change of the Projects database schema adds a step to it, and a build that does not know a step refuses the data. Projects then says that it could not open its data on this Mac, until you choose Delete All Projects Data… in Settings, Projects. So once a newer build has opened the data, keep using a build at least that new, or delete the data before you go back to an older one.

The opt in evaluations of Projects, SortingEvaluationTests, ProjectSuggestionsEvaluationTests, ExplainEvaluationTests, ReviseEvaluationTests and ProjectsGateEvaluationTests, read a synthetic set of mail and project folders that stays outside the repository and run with the real cleanup model. [release-gate.md](release-gate.md) describes the set and the attack items. ProjectsLatencyMeasurementTests, also opt in and in a Release build, measures dictation while Projects keeps the model busy, and the memory it takes, with the real speech and cleanup models. Its comment has the command. FolderIndexMeasurementTests, opt in and in a Release build too, makes a large synthetic project folder of every kind of file and checks that the sheets, slides and names of its files are found. FolderSweepMeasurementTests times the first sweep of the folder's 0.6.0 formats, here and on a build that reads only those, in turns, and the first test holds the branch to 1.15 times as long. Their comments have the commands. TextRecognitionMeasurementTests, opt in as well, measures text recognition with Vision on synthetic scans and images it makes, and its comment has its command too. VisionTextRecognitionTests reads one image with Vision only with `TEST_RUNNER_ORRA_RECOGNITION=1`, since Vision cannot read it on the virtual machine of CI, and its comment has its command.

## Background documents

- [dependencies.md](dependencies.md): the approved packages and why.
- [model-download.md](model-download.md): where the speech model comes from and how it is checked.
- [asr-options.md](asr-options.md), [asr-baseline.md](asr-baseline.md), [local-asr-models.md](local-asr-models.md): how the speech model was chosen and measured.
- [hotkey-options.md](hotkey-options.md), [microphone-choice.md](microphone-choice.md): design notes.
- [releasing.md](releasing.md): signing, notarization, updates and publishing.
- [release-gate.md](release-gate.md): the evaluations a release must pass, the Projects attack set among them.
- [manual-testing.md](manual-testing.md): what the tests cover and what to check by hand.
- [Tools/readme-media](../Tools/readme-media/README.md): draws the animations in the README's Features table.

## Contributing

Open an issue or a pull request on GitHub. Pull requests are squash merged, so the title and the description should explain the whole change. Continuous integration runs the rules check and the tests on every pull request.
