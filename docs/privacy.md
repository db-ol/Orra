# Orra privacy

English · [简体中文](privacy.zh-CN.md)

The [README](../README.md) has a short summary. This page has the details.

Orra turns your speech into text on your Mac and never sends your recordings or their text anywhere. It has no account, no analytics and no server of its own. The text it pastes stays on this Mac's clipboard, so Universal Clipboard does not offer it to your other devices.

**Learning from your corrections** is off until you turn it on. While it is on, Orra reads the text of the field it just pasted into, through macOS Accessibility, once a second for up to 3 minutes after each paste, and only while you are in that field. It reads at most 20,000 characters, keeps the text in memory during those minutes only, and never writes it anywhere. It never reads password fields or an app with secure input on. It keeps only the word pairs, such as 奥拉 and Orra, with how often and when each was seen, in ~/Library/Application Support/io.github.db-ol.Orra/corrections.json, and forgets a pair seen once after a week. Runs of three or more digits, such as codes, amounts and years, are never kept. Orra changes dictated text only where a kept pair's misheard spelling appears. Forget Learned Corrections in Settings deletes all pairs.

**Use names on screen** is off until you turn it on. While it is on, each time you start a dictation, Orra reads through macOS Accessibility up to 1,000 characters before the cursor in the field you dictate into, and the title of its window. It never reads password fields or an app with secure input on, and never Orra's own windows. It takes up to 40 names and rare words from that text and gives them to the speech model on your Mac, never the text itself. It keeps the text and the names in memory for that dictation only, and never saves or logs them.

**Meeting Interpretation** keeps captions and the words said in the voice sample in memory only. It keeps the voice sample in memory too, unless you turn on Remember my voice, which is off until you do. It never logs text or audio.

**Orra uses the internet for model downloads you ask for and for update checks only.**

- **The speech model**, only after you choose Download Speech Model, or Download Models in the welcome window: six files, 2.47 GB, from Hugging Face (huggingface.co). If Hugging Face cannot be reached, for example from mainland China, Orra tries ModelScope (modelscope.cn) and then hf-mirror.com, which carry the same files. Orra checks the size and SHA-256 hash of every file against values in its source code, so a mirror cannot change the model. The files live in ~/Library/Application Support/io.github.db-ol.Orra/Models, left out of Time Machine backups.
- **The cleanup model**, only after you click Download Models or Download Cleanup Model in the welcome window, which offers them to a new user on a Mac with 16 GB of memory or more or while cleanup is on, or turn on Clean Up Text or Translation in Settings and agree to its download: four files of mlx-community/Qwen3.5-4B-4bit, 3.05 GB, from the same servers, checked the same way, into its own folder under Models.
- **The voice model**, only after you start its download for Speak Translations to Others: Qwen3-TTS, about 2 GB, from Hugging Face or hf-mirror.com, checked the same way.
- **Update checks**, only after you allow them. At its second launch Orra asks whether to check automatically, and Settings, About has the choice. A check reads https://github.com/db-ol/Orra/releases/latest/download/appcast.xml about once a day. Orra installs an update only when you choose it, each time, and only when the update and its feed are signed with the project's update key.

The models run on your Mac and never go online. Launching Orra never connects to the network until you allowed update checks. Like any download, these services see your IP address, and an update check also shows Orra's version and, as every web request does, your preferred languages. Orra sends no account, token or cookie, and nothing else about your Mac. [docs/model-download.md](model-download.md) describes the servers and the checks in detail.

**Report a Problem** writes a text file on your Mac with Orra's version, settings and permissions, the Mac's model, chip, memory, macOS version and languages, the microphone's name, Orra's own log from the last hour and its crash reports from the last 7 days. It holds no dictated text, audio, clipboard, vocabulary or learned words. Your home folder, account name, full name and computer name are taken out. Orra sends nothing itself. It opens the GitHub page in your browser, and the file reaches GitHub only if you attach it.

To remove the models, quit Orra and delete the Models folder above. To remove only the cleanup model, turn cleanup and translation off first and delete its folder, Qwen3.5-4B-4bit-0e7ffd5c, inside it. If ~/Library/Caches/qwen3-speech holds a copy from another app, delete that too, or Orra installs the model again from it.
