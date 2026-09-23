#!/usr/bin/env python3
# fail-summary.py — 失败台账聚合: 读 state.jsonl, 按状态取每源最后一行,
# 聚合 failed_permanent 按 (扩展名, err_class, um 报错关键短语) 计数并附一例,
# 写 <report-dir>/fail-summary-latest.txt 并打印。零删除; 可重跑(覆盖重建)。
import argparse
import collections
import json
import os
import re
import sys
from datetime import date


def main():
    ap = argparse.ArgumentParser(description="失败台账聚合(failed_permanent)")
    ap.add_argument("--music-root", default=os.environ.get("MUSIC_ROOT", "./Music"),
                    help="音乐库根(默认 ./Music 或环境变量 MUSIC_ROOT)")
    ap.add_argument("--state-file", default=None,
                    help="state.jsonl 路径(默认 <music-root>/.pipeline/state/state.jsonl)")
    ap.add_argument("--report-dir", default=None,
                    help="报告输出目录(默认 <music-root>/.pipeline/reports)")
    args = ap.parse_args()

    music_root = os.path.abspath(args.music_root)
    state_file = args.state_file or os.path.join(
        music_root, ".pipeline", "state", "state.jsonl")
    report_dir = os.path.abspath(args.report_dir or os.path.join(
        music_root, ".pipeline", "reports"))

    if not os.path.isfile(state_file):
        print(f"state 文件不存在: {state_file} (先运行 bin/music-convert.sh 生成状态)", file=sys.stderr)
        return 1
    os.makedirs(report_dir, exist_ok=True)

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

    agg = collections.Counter()
    examples = {}
    for r, d in last.items():
        if d.get("status") != "failed_permanent":
            continue
        ext = r.rsplit(".", 1)[-1].lower()
        err = d.get("err", "") or ""
        # 提取 um 报错关键短语（去掉时间戳/颜色码/字段名包装）
        phrases = re.findall(r'"error":\s*"([^"]+)"', err.replace('\\"', '"'))
        key = " | ".join(dict.fromkeys(phrases)) if phrases else err[:80]
        k = (ext, d.get("err_class", ""), key)
        agg[k] += 1
        examples.setdefault(k, r)

    lines = []
    lines.append("失败台账汇总 (failed_permanent=%d)  生成于 %s" % (sum(agg.values()), date.today().isoformat()))
    lines.append("=" * 72)
    for (ext, cls, key), n in sorted(agg.items(), key=lambda x: (-x[1], x[0])):
        lines.append("[%d 个] 格式=.%s  类别=%s" % (n, ext, cls))
        lines.append("  报错: %s" % key)
        lines.append("  例: %s" % examples[(ext, cls, key)].encode("unicode_escape").decode()[:100])
        lines.append("")

    out_path = os.path.join(report_dir, "fail-summary-latest.txt")
    if os.path.exists(out_path):
        os.remove(out_path)
    with open(out_path, "a", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("\n".join(lines))
    print("已写入:", out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
