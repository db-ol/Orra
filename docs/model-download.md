# Model download

How Orra gets its speech model, Qwen3-ASR 1.7B in the 8 bit MLX build
(aufklarer/Qwen3-ASR-1.7B-MLX-8bit), and what it does on the network to get it. The code
is in Orra/ModelFiles.swift (pinned files, folders, launch), Orra/ModelDownload.swift (the
network) and Orra/ModelInstaller.swift (the menu's state).

## When Orra goes online

- Only after the user chooses Download Speech Model, Resume Download or Try Again in the
  menu. Before that, the menu names the size, 2.47 GB, and says that speech stays on the
  Mac. During the download it names the server in use.
- Launching never connects. At launch Orra looks at local files only: it checks the
  installed folder by file sizes, finishes an install that a quit interrupted, or reuses
  the copy speech-swift left in ~/Library/Caches/qwen3-speech.
- Loading the model uses speech-swift's offline mode on the installed folder, so it makes
  no request either.
- The menu shows the download before Accessibility is granted, so it can start first.

## Servers

Tried in this order, set in one place, `ModelSource.order` in Orra/ModelFiles.swift:

1. huggingface.co:
   `https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/resolve/e5450a26d1fd417c45fc9c405651ddc3180a27a6/<file>`
2. modelscope.cn:
   `https://modelscope.cn/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/resolve/c38cf3b531e3cdf954823174e8ab32b6a182751c/<file>`
3. hf-mirror.com:
   `https://hf-mirror.com/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/resolve/e5450a26d1fd417c45fc9c405651ddc3180a27a6/<file>`

Why this order:

- Hugging Face publishes the model. From mainland China it could not be reached: on
  2026-10-07 six of six probes on Chinese consumer networks failed, with wrong DNS answers,
  connection timeouts and one reset.
- ModelScope carries the same files under the same id, in an organization it runs as a
  community mirror of Hugging Face repositories. It sends the large files from its own
  servers in China (cdn-lfs-cn-1.modelscope.cn), which answered the same probes in 72 to
  130 ms, and once in 1.1 s.
- hf-mirror.com serves the small files itself in mainland China, but hands the weights on
  to Hugging Face's own download servers (cas-bridge.xethub.hf.co). Outside mainland China
  it redirects every request to huggingface.co. It runs on donations.
- Like any download, each server sees the user's IP address. Orra sends no account, token
  or cookie, and keeps no cookie a server sets.

Download speed from either mirror has not been measured.

## How a server is chosen

- Strictly in order, with no requests to several servers at once. While Hugging Face
  works, no other server sees a request.
- The first request to a server waits at most 8 s for data, later requests 30 s.
  The timer restarts whenever data arrives, so a slow connection still finishes. A fresh
  download asks each server for config.json, 7 KB, first. A resumed one may ask for the
  weights first.

| What happened | What Orra does |
|---|---|
| No network at all (URLError notConnectedToInternet, dataNotAllowed or internationalRoamingOff) | Stops at once and says the Mac is offline. |
| A server that has sent nothing in this download fails, whatever the reason | Moves to the next server at once. |
| HTTP 4xx other than 408 and 429, a wrong Content-Range, more bytes than pinned, or an empty range | Moves to the next server at once. |
| A server that was sending fails: dropped connection, timeout, 5xx, 408 or 429 | Pauses 2 s and asks again, then 10 s, then moves on, so each server gets three tries in a row. The weights continue from the bytes on disk, and a try that gets past the most bytes this server delivered for them resets the count. The five small files start over from byte 0 on every try and never reset it. |
| The disk is full | Stops and says how much space the rest of the download needs. |
| Any other write error | Stops and says the files could not be saved. |
| A file does not match its SHA-256 | Deletes it and fetches it from the next server. After the last server, stops and says so. |
| No server is left | Stops. Try Again starts at the first server again and keeps the bytes on disk. |
| The user cancels | Keeps every byte on disk. Resume Download continues. |

During the download and the check, Orra holds a `.userInitiated` process activity, so
the Mac does not fall asleep while idle. Closing the lid or choosing Sleep still sleeps.

## Ranges and resume

- Only model.safetensors, 2.46 GB, continues from the bytes on disk with
  `Range: bytes=<n>-`. The five small files, 2.8 MB at most, are always fetched from
  byte 0. modelscope.cn answers a Range request on config.json, tokenizer_config.json
  and model.safetensors.index.json, which it serves itself, with a 200 whose body starts
  at the asked offset and ends short, or with a 502. merges.txt, vocab.json and the
  weights come from its download servers, which answer ranges correctly.
- A 206 must start at the asked byte and end inside the file. A shorter range is fine:
  Orra asks again for the rest.
- A 200 means the whole file, so the file starts over, but only when the answer has no
  Content-Range header.
- A 200 that ends short of the pinned size counts as a failure. When it answered a Range
  request, its bytes are dropped, because they may start anywhere in the file.
- Nothing is ever written past the pinned size. Content-Length is not compared with it,
  because servers may compress the small files.
- Every attempt starts at the stable address above. The servers redirect to signed links
  that expire after about an hour, so a retry always gets a fresh one.

## What is checked

The six files are pinned in `ModelManifest.qwen3` with their size and SHA-256:

| File | Bytes | SHA-256 |
|---|---|---|
| config.json | 7,188 | 1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7 |
| tokenizer_config.json | 12,487 | 4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c |
| model.safetensors.index.json | 78,968 | 0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5 |
| merges.txt | 1,671,853 | 8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5 |
| vocab.json | 2,776,833 | ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910 |
| model.safetensors | 2,463,307,541 | bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c |

In all 2,467,854,870 bytes, shown as 2.47 GB.

- Before the first request, the free space must cover the rest of the download plus
  500 MB, 2.97 GB for a fresh download. Orra reads the space available for important
  files (`volumeAvailableCapacityForImportantUsage`), which counts space macOS can free.
- Before the install, every file is hashed and compared with the pin. The hashes in
  Orra's source decide which bytes are used, never a server, so a mirror or a network in
  between cannot change the model.

## Where the files live

- Installed:
  `~/Library/Application Support/io.github.db-ol.Orra/Models/Qwen3-ASR-1.7B-MLX-8bit-e5450a26/`.
  The name carries the pinned revision, so files of another pin are never mistaken for
  these.
- Staging: `Models/.download-Qwen3-ASR-1.7B-MLX-8bit-e5450a26/`, next to it. Files
  arrive here and stay across relaunches, which is what lets a download resume. Once all
  six match, one rename installs the folder.
- Both are left out of Time Machine backups. The flag is set when the staging folder is
  created and stays on through the rename.
- Launch checks the installed folder by sizes only. When a file is missing, the rest goes
  back to the staging folder, and the old cache copy or a download fills the gap, so only
  that file is fetched. After the model fails to load, Try Again hashes the installed
  files as well, and a damaged file is deleted and handled the same way.
- Once the model is installed, leftover staging folders and the folders of other
  revisions of the same model are removed. Orra never deletes anything outside its Models
  folder.

## Reusing the copy in the old cache

Before the download existed, Orra loaded the model from speech-swift's cache,
`~/Library/Caches/qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit` or the legacy
`~/Library/Caches/qwen3-speech/aufklarer_Qwen3-ASR-1.7B-MLX-8bit`.

- At launch, each pinned file found there at its pinned size is cloned into the staging
  folder with `clonefile`. On APFS the clone shares the data blocks, so it takes no extra
  space. Where cloning is not possible, Orra copies the file only when the free space
  covers it plus 500 MB.
- Then all six are hashed and installed, without the network. Files that do not match are
  deleted, and the others stay as a head start for the download.
- The old folder is never changed or deleted. Orra ignores `QWEN3_CACHE_DIR` and
  `QWEN3_ASR_CACHE_DIR`.
- After a clone, `du` counts both folders, but the disk holds the data once until both are
  deleted.

## Removing the model

Quit Orra and delete `~/Library/Application Support/io.github.db-ol.Orra/Models`. Also
delete the two old cache folders named above if they exist. While either exists, Orra
installs the model again from it at its next launch, and a clone shares its space with
them, so the space comes back only when all copies are gone. The rest of
~/Library/Caches/qwen3-speech may hold other models that Orra does not use.

## Log

    /usr/bin/log stream --predicate 'subsystem == "io.github.db-ol.Orra" AND category == "model-download"'

The model-download category logs states, file names, byte counts, server names and error
codes, never file contents or paths.

## Trying one server by hand

A Debug build launched with `-ModelServer <host>` downloads only from that server, so
each path can be tried. In Xcode, add the argument under Product > Scheme > Edit Scheme >
Run > Arguments. From Terminal:

    open build/DerivedData/Build/Products/Debug/Orra.app --args -ModelServer hf-mirror.com

The host is one of huggingface.co, modelscope.cn and hf-mirror.com. Other values, and the
argument in a Release build, are ignored.

## Moving the pin

1. Pick the Hugging Face commit and read the sizes and LFS SHA-256 values from
   `https://huggingface.co/api/models/<id>/tree/<commit>?recursive=true&expand=true`.
2. Download the small files at that commit and hash them with `shasum -a 256`.
3. Find ModelScope's commit with the same files, and check that
   `https://modelscope.cn/api/v1/models/<id>/repo/files?Revision=<commit>&Recursive=true`
   lists the same sizes and SHA-256 values.
4. Edit `ModelManifest.qwen3`. The new revision gets a new installed folder, and the old
   one is removed once the new one is installed. Mark a file resumable only when every
   server answers ranges on it correctly.
5. Run the tests and the model download checks in docs/manual-testing.md.

A new server, or any other network use, needs the maintainer's approval, see AGENTS.md.
