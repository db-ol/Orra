import glob, json, os, re, statistics, sys, unicodedata

ROOT = os.environ.get("ORRA_EVAL_DIR", os.path.expanduser("~/projects/orra-project/eval"))
CJK = "㐀-䶿一-鿿豈-﫿"
TOKEN = re.compile(rf"[{CJK}]|[^\W_{CJK}]+")
FILLERS = "呃嗯啊哦唔诶欸噢哈"
FINAL = tuple("。！？.!?")
TRADITIONAL = set("們個這來時會國對開關發點學長問題機電話說還沒為與從後過現實當經動種應裡麼東車書見聽買賣讀寫錯難遠進運連邊門間陽隊雙雲電頭顯風飛館馬驗魚鳥黃齊龍員諾蘭將業費爾蘇聯總統選舉議區縣鎮鄉廣場報紙網絡絲紅綠藍級組織結構線條處離復雜項節約認識讓誰調護資質貨賽輸贏軍辦務師歲歷壓廠廳強張彈態戰戶擁擊攝數斷晝曉權樹樣橋檢歐殺氣漢潔濟灣災無燈爐爭狀獨獻畢畫異盤眾礦碼確稱穩窮競筆築簡糧紀終綜維緊績繼續羅職聲腦臉興舊號蟲衛補製複覺觀視訂計記許論設訪證評譯讚貝負財貢貧販貫責貴貸貿賀賓賞賠賢購趕趙跡蹤躍軌軟較輕載輔輪輯轉農適遲遷選遺鄰鄭醫釋針鈴銀銷錢錄鍵鐘閃閉閒閱闊闖陸陰陳險隨隱雖雜雞霧靜響頁頂順須預頓領頻額顏願類顧飄餘饑駕騎體髮鬆鬥鬧鳴鷹麥黨齒")

def tokens(text, setname):
    t = unicodedata.normalize("NFKC", text).replace("[UNK]", " ").lower().replace("'", "").replace("’", "")
    if setname == "ascend_mixed":
        t = re.sub(f"[{FILLERS}]", " ", t)
    out = []
    for tok in TOKEN.findall(t):
        # Acronyms spelled letter by letter ("i s m") count as one word ("ism").
        if re.fullmatch(r"[a-z]", tok) and out and re.fullmatch(r"[a-z]+", out[-1]) and getattr(tokens, "_single", False):
            out[-1] += tok
        else:
            out.append(tok)
        tokens._single = bool(re.fullmatch(r"[a-z]", tok)) or (tokens._single and re.fullmatch(r"[a-z]+", out[-1]) is not None and len(tok) == 1)
    tokens._single = False
    return out
tokens._single = False

def is_cjk(tok):
    return re.fullmatch(f"[{CJK}]", tok) is not None

def edits(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]

def load_refs(setname):
    refs = {}
    for line in open(os.path.join(ROOT, "sets", setname, "refs.tsv")):
        fn, text = line.rstrip("\n").split("\t", 1)
        refs[fn[:-4]] = text
    return refs

def load_qwen(path):
    hyps, times, durs = {}, {}, {}
    blob = open(path).read()
    found = []
    for line in blob.splitlines():
        if line.startswith("{"):
            try:
                found.append(json.loads(line, strict=False))
            except json.JSONDecodeError:
                pass
    # The speech CLI can print raw newlines inside text, which splits a line.
    for m in re.finditer(r'\{"file":.*?"duration":[\d.]+[^}]*\}', blob, re.S):
        try:
            found.append(json.loads(m.group(0), strict=False))
        except json.JSONDecodeError:
            pass
    for d in found:
        if "file" in d and "text" in d:
            hyps[d["file"]] = d["text"]; times[d["file"]] = d["time"]; durs[d["file"]] = d["duration"]
    err = open(path[:-6] + ".err").read()
    load = re.search(r"Model load: ([\d.]+)s", err)
    return hyps, times, durs, (float(load.group(1)) if load else None), err

def load_sherpa(path):
    text = open(path).read() + "\n" + open(path[:-4] + ".err").read()
    names = re.findall(r"^sets/[^/]+/(.+)\.wav$", text, re.M)
    results = [json.loads(l) for l in re.findall(r'^\{"lang".*\}$', text, re.M)]
    if len(names) != len(results):
        raise SystemExit(f"{path}: {len(names)} names but {len(results)} results")
    hyps = {n: r["text"] for n, r in zip(names, results)}
    rtf = re.search(r"Real time factor \(RTF\): ([\d.]+) / ([\d.]+)", text)
    load = re.search(r"recognizer created in ([\d.]+) s", text)
    return hyps, float(rtf.group(1)), float(rtf.group(2)), (float(load.group(1)) if load else None), text

def peak_gb(err):
    m = re.search(r"(\d+)\s+peak memory footprint", err)
    return int(m.group(1)) / 1e9 if m else None

def score(engine, setname):
    refs = load_refs(setname)
    qpath = os.path.join(ROOT, "results", f"{engine}.{setname}.jsonl")
    spath = os.path.join(ROOT, "results", f"{engine}.{setname}.out")
    if os.path.exists(qpath):
        hyps, times, durs, load, err = load_qwen(qpath)
        busy, audio = sum(times.values()), sum(durs.values())
        tens = sorted(t for f, t in times.items() if 8 <= durs[f] <= 12)
        p95_10s = tens[int(0.95 * (len(tens) - 1))] if tens else None
    elif os.path.exists(spath):
        hyps, busy, audio, load, err = load_sherpa(spath)
        p95_10s = None
    else:
        return None
    if len(hyps) < len(refs) or not audio:
        return None  # run not finished yet
    tot_e = tot_n = nd_e = nd_n = cap_e = 0
    flips = lost_en = empty = final = loops = trad_n = 0
    en_ref = en_hit = 0
    rows = []
    for f, ref in refs.items():
        hyp = hyps.get(f, "")
        r, h = tokens(ref, setname), tokens(hyp, setname)
        e = edits(r, h)
        tot_e += e; tot_n += len(r); cap_e += min(e, len(r))
        if len(h) > 2 * len(r) + 20 or re.search(r"(.{1,8})\1{7,}", hyp):
            loops += 1
        clean = not re.search(r"\d", ref) and (setname != "fleurs_zh" or not re.search(r"[A-Za-z]", ref))
        if clean:
            nd_e += e; nd_n += len(r)
        if any(c in TRADITIONAL for c in hyp):
            trad_n += 1
        r_cjk = sum(map(is_cjk, r)) / max(len(r), 1)
        h_cjk = sum(map(is_cjk, h)) / max(len(h), 1)
        r_lat = [t for t in r if not is_cjk(t)]
        h_lat = [t for t in h if not is_cjk(t)]
        if not h:
            empty += 1
        elif r_cjk >= 0.5 and h_cjk < 0.2:
            flips += 1
        elif "mixed" in setname and len(r_lat) >= 2 and not h_lat:
            lost_en += 1
        if "mixed" in setname:
            pool = list(h_lat)
            for t in r_lat:
                en_ref += 1
                if t in pool:
                    en_hit += 1; pool.remove(t)
        if hyp.strip().endswith(FINAL):
            final += 1
        rows.append((e / max(len(r), 1), f, ref, hyp))
    rows.sort(reverse=True)
    with open(os.path.join(ROOT, "results", f"{engine}.{setname}.scored.tsv"), "w") as out:
        for er, f, ref, hyp in rows:
            out.write(f"{er:.2f}\t{f}\t{ref}\t{hyp}\n")
    return {
        "engine": engine, "set": setname, "n": len(refs),
        "err": 100 * tot_e / tot_n, "err_capped": 100 * cap_e / tot_n, "err_nodigit": 100 * nd_e / max(nd_n, 1),
        "loops": loops, "traditional": trad_n, "flips": flips, "lost_en": lost_en, "empty": empty,
        "en_recall": (100 * en_hit / en_ref) if en_ref else None,
        "final_mark": 100 * final / len(refs),
        "rtf": busy / audio, "p95_10s": p95_10s, "load": load, "peak_gb": peak_gb(err),
    }

ENGINES = ["q06_auto", "q06_zh", "q06_8bit_auto", "q17_auto", "q17_zh", "xasr", "sensevoice", "funasr_nano", "apple"]
# Pass set names to score other folders under sets/, for example your own recordings.
SETS = sys.argv[1:] or ["fleurs_zh", "fleurs_en", "ascend_mixed"]
results = [r for s in SETS for e in ENGINES if (r := score(e, s))]
json.dump(results, open(os.path.join(ROOT, "results", "summary.json"), "w"), indent=1, ensure_ascii=False)
for s in SETS:
    print(f"\n### {s}")
    print("| engine | error % | capped error % | error % on clean refs | loops | traditional | flips to English | English lost | empty | English word recall % | ends with a mark % | RTF | p95 s for 8 to 12 s clips | peak GB |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in results:
        if r["set"] != s: continue
        f = lambda v, d=1: "" if v is None else (f"{v:.{d}f}" if isinstance(v, float) else str(v))
        print(f"| {r['engine']} | {f(r['err'])} | {f(r['err_capped'])} | {f(r['err_nodigit'])} | {r['loops']} | {r['traditional']} | {r['flips']} | {r['lost_en']} | {r['empty']} | {f(r['en_recall'])} | {f(r['final_mark'],0)} | {f(r['rtf'],3)} | {f(r['p95_10s'],2)} | {f(r['peak_gb'],2)} |")
