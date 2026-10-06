import os, shutil, subprocess

# Picks 15 Chinese clips of 8 to 12 s and 15 mixed clips of 2 to 6 s for bench.sh.
os.chdir(os.environ.get("ORRA_EVAL_DIR", os.path.expanduser("~/projects/orra-project/eval")))

def duration(path):
    out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    return float([l for l in out.splitlines() if "estimated duration" in l][0].split(":")[1].split()[0])

picked = []
for setname, low, high in [("fleurs_zh", 8, 12), ("ascend_mixed", 2, 6)]:
    count = 0
    for name in sorted(os.listdir(f"sets/{setname}")):
        if not name.endswith(".wav"):
            continue
        path = f"sets/{setname}/{name}"
        seconds = duration(path)
        if low <= seconds <= high:
            clip = f"{setname}__{name[:-4]}"
            os.makedirs(f"bench/clips/{clip}", exist_ok=True)
            shutil.copy(path, f"bench/clips/{clip}/{clip}.wav")
            picked.append((clip, seconds))
            count += 1
            if count == 15:
                break
os.makedirs("bench", exist_ok=True)
with open("bench/clips.tsv", "w") as out:
    for clip, seconds in picked:
        out.write(f"{clip}\t{seconds}\n")
print(len(picked), "clips")
