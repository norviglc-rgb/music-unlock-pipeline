#!/usr/bin/env python3
# stats-state.py — state.jsonl 每源最后一行的状态统计（总量/状态/按格式），纯打印。
import argparse
import collections
import json
import os
import sys


def main():
    ap = argparse.ArgumentParser(description="state.jsonl 状态统计(只读)")
    ap.add_argument("--music-root", default=os.environ.get("MUSIC_ROOT", "./Music"),
                    help="音乐库根(默认 ./Music 或环境变量 MUSIC_ROOT)")
    ap.add_argument("--state-file", default=None,
                    help="state.jsonl 路径(默认 <music-root>/.pipeline/state/state.jsonl)")
    args = ap.parse_args()

    music_root = os.path.abspath(args.music_root)
    state_file = args.state_file or os.path.join(
        music_root, ".pipeline", "state", "state.jsonl")
    if not os.path.isfile(state_file):
        print(f"state 文件不存在: {state_file} (先运行 bin/music-convert.sh 生成状态)", file=sys.stderr)
        return 1

    last = {}
    with open(state_file, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            last[d.get("rel_path", "")] = d

    by = collections.Counter()
    byfmt = collections.defaultdict(collections.Counter)
    for r, d in last.items():
        st = d.get("status", "?")
        by[st] += 1
        ext = r.rsplit(".", 1)[-1].lower() if "." in r else "?"
        byfmt[ext]["total"] += 1
        if st == "done":
            byfmt[ext]["done"] += 1
        elif st == "failed_permanent":
            byfmt[ext]["failed_permanent"] += 1
        elif st == "failed_transient":
            byfmt[ext]["failed_transient"] += 1
        else:
            byfmt[ext]["pending_or_other"] += 1

    print("status:", dict(by))
    for ext in sorted(byfmt):
        print(" fmt", ext, dict(byfmt[ext]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
