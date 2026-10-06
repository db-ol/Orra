import os, re, statistics
os.chdir(os.environ.get("ORRA_EVAL_DIR", os.path.expanduser("~/projects/orra-project/eval")))
clips = [l.split("\t") for l in open("bench/clips.tsv").read().splitlines()]
ENGINES = [("q0.6B", "Qwen3-ASR 0.6B 4 bit"), ("q0.6B-8bit", "Qwen3-ASR 0.6B 8 bit"), ("q1.7B", "Qwen3-ASR 1.7B 8 bit"),
           ("xasr", "X-ASR"), ("sensevoice", "SenseVoice"), ("funasr_nano", "Fun-ASR-Nano")]
def parse(prefix, cid):
    out = open(f"bench/out/{prefix}.{cid}.out").read()
    err = open(f"bench/out/{prefix}.{cid}.err").read()
    both = out + "\n" + err
    peak = int(re.search(r"(\d+)\s+peak memory footprint", err).group(1)) / 1e9
    if prefix.startswith("q"):
        t = float(re.search(r'"time":([\d.]+)', out).group(1))
        m = re.search(r"Model load: ([\d.]+)s, Warmup: ([\d.]+)s", both)
        load = float(m.group(1)) + float(m.group(2))
    else:
        t = float(re.search(r"Elapsed seconds: ([\d.]+)", both).group(1))
        load = float(re.search(r"recognizer created in ([\d.]+) s", both).group(1))
    return t, load, peak
print("| engine | 8 to 12 s Chinese clips, median s | worst s | 2 to 6 s mixed clips, median s | worst s | load s, median | peak GB, max |")
print("|---|---|---|---|---|---|---|")
for prefix, name in ENGINES:
    rows = {"fleurs_zh": [], "ascend_mixed": []}
    loads, peaks = [], []
    for cid, d in clips:
        try:
            t, load, peak = parse(prefix, cid)
        except (FileNotFoundError, AttributeError):
            continue
        rows[cid.split("__")[0]].append(t); loads.append(load); peaks.append(peak)
    if not loads:
        continue
    zh, mx = rows["fleurs_zh"], rows["ascend_mixed"]
    f = lambda v: f"{v:.2f}"
    print(f"| {name} | {f(statistics.median(zh))} | {f(max(zh))} | {f(statistics.median(mx))} | {f(max(mx))} | {f(statistics.median(loads))} | {max(peaks):.2f} |")
