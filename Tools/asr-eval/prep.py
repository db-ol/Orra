import csv, json, os, subprocess, sys, tarfile, urllib.request, urllib.parse, time

ROOT = os.environ.get("ORRA_EVAL_DIR", os.path.expanduser("~/projects/orra-project/eval"))
SETS = os.path.join(ROOT, "sets")
N = 200

def to_pcm16(src, dst):
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src, dst], check=True)

def duration(path):
    out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "estimated duration" in line:
            return float(line.split(":")[1].split()[0])
    return 0.0

def prep_fleurs(name, lang_dir):
    out = os.path.join(SETS, name); os.makedirs(out, exist_ok=True)
    rows = []
    with open(os.path.join(ROOT, "datasets", lang_dir, "test.tsv"), newline="") as f:
        for r in csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            rows.append((r[1], r[2]))
    rows.sort()
    rows = rows[:N]
    wanted = {"test/" + fn for fn, _ in rows}
    tmp = os.path.join(out, "_raw"); os.makedirs(tmp, exist_ok=True)
    with tarfile.open(os.path.join(ROOT, "datasets", lang_dir, "test.tar.gz")) as t:
        for m in t:
            if m.name in wanted:
                m.name = os.path.basename(m.name)
                t.extract(m, tmp)
    total = 0.0
    with open(os.path.join(out, "refs.tsv"), "w") as refs:
        for fn, text in rows:
            dst = os.path.join(out, fn)
            to_pcm16(os.path.join(tmp, fn), dst)
            total += duration(dst)
            refs.write(f"{fn}\t{text}\n")
    subprocess.run(["rm", "-rf", tmp])
    print(name, len(rows), "files", round(total, 1), "s audio")

def fetch_json(url):
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return json.load(r)
        except Exception as e:
            time.sleep(3)
    raise RuntimeError("failed " + url)

def prep_ascend():
    out = os.path.join(SETS, "ascend_mixed"); os.makedirs(out, exist_ok=True)
    rows = []
    for offset in range(0, 1315, 100):
        q = urllib.parse.urlencode({"dataset": "CAiRE/ASCEND", "config": "main", "split": "test", "offset": offset, "length": 100})
        d = fetch_json("https://datasets-server.huggingface.co/rows?" + q)
        for r in d["rows"]:
            rows.append(r["row"])
    langs = {}
    for r in rows:
        langs[r["language"]] = langs.get(r["language"], 0) + 1
    print("ASCEND test rows", len(rows), "by language", langs)
    mixed = sorted([r for r in rows if r["language"] == "mixed"], key=lambda r: r["id"])[:N]
    total = 0.0
    with open(os.path.join(out, "refs.tsv"), "w") as refs:
        for r in mixed:
            src_url = r["audio"][0]["src"]
            fn = r["id"] + ".wav"
            raw = os.path.join(out, "_" + fn)
            urllib.request.urlretrieve(src_url, raw)
            dst = os.path.join(out, fn)
            to_pcm16(raw, dst)
            os.remove(raw)
            total += duration(dst)
            refs.write(f"{fn}\t{r['transcription']}\n")
    print("ascend_mixed", len(mixed), "files", round(total, 1), "s audio")

which = sys.argv[1:] or ["fleurs_zh", "fleurs_en", "ascend"]
if "fleurs_zh" in which: prep_fleurs("fleurs_zh", "fleurs_zh")
if "fleurs_en" in which: prep_fleurs("fleurs_en", "fleurs_en")
if "ascend" in which: prep_ascend()
