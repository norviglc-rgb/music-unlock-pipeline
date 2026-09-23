#!/usr/bin/env python3
# ============================================================================
# near-dup.py — 近似重复报告(只报告, 零删除)
#
# 范围: <music-root> 全库既有通用音频(mp3/flac/m4a/ogg/ape/wav) + _unlocked
#       转换产物; lstat 排除 symlink 镜像条目(镜像与原件同内容, 天然重复,
#       不进报告——报告的是"跨平台疑似同一首"这类人工裁决项)。
# 采集: ffprobe 逐文件 codec/duration/bit_rate/采样率/位深/title/artist 标签。
#       文件名约定「歌手 - 标题.扩展名」时按 " - " 首次出现拆分, 缺失时回落
#       ffprobe tags(若两种来源都缺, 该文件无法参与分组, 见 README 限制说明)。
# 规范化: NFKC 全半角统一 → 小写 → 去 feat. → 去括号注(（）()【】[] 内) →
#         压空白; 按 (title_norm, artist_norm) 分组。
# 判定: 组内两两 |Δ时长|<=2s 高置信; 2–10s 低置信。误报固有, 代价仅人工看报告。
# keeper 建议: 无损(flac/wav/ape)>有损 → 位深×采样率 → 码率 → 标签完整度 → 路径字节序。
# 输出: <report-dir>/near-dup-<日期>.csv (+ latest 副本), utf-8-sig 便于 Excel 直开。
#       零删除; 可重跑(重跑覆盖当日报告); 独立 .neardup.lock, 与转换不互斥。
#
# 用法:
#   near-dup.py [--music-root DIR] [--report-dir DIR] [--limit N] [--report]
#   --report 为兼容旧 crontab 保留的无操作参数(默认动作即生成报告), 不再静默忽略。
# ============================================================================
import argparse
import csv
import fcntl
import json
import os
import re
import shutil
import stat as stat_mod
import subprocess
import sys
import unicodedata
from datetime import date

AUDIO_EXTS = {".mp3", ".flac", ".m4a", ".ogg", ".ape", ".wav"}
LOSSLESS = {"flac", "wav", "ape"}


def in_root(p, root):
    """p 必须位于 root 之内: commonpath 校验 + 定长切片取相对段。
    越界/等于根本身 → 返回 None(调用方丢弃); 返回值绝不含 .. 段。"""
    root_real = os.path.realpath(root)
    p_real = os.path.realpath(p)
    if p_real == root_real:
        return None
    if os.path.commonpath([p_real, root_real]) != root_real:
        return None
    rel = p_real[len(root_real):]
    if rel.startswith(os.sep):
        rel = rel[len(os.sep):]
    if not rel:
        return None
    return rel


def norm_text(s):
    if not s:
        return ""
    s = unicodedata.normalize("NFKC", s).lower()
    s = re.sub(r"feat\.?.*$", "", s)
    s = re.sub(r"[（(【\[].*?[）)】\]]", "", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip(" -_~")


def parse_name(path):
    stem = os.path.splitext(os.path.basename(path))[0]
    if " - " in stem:
        artist, title = stem.split(" - ", 1)
        return artist.strip(), title.strip()
    return "", stem


def ffprobe_meta(path):
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries",
             "stream=codec_name,sample_rate,bits_per_raw_sample,bit_rate",
             "-show_entries", "format=duration,bit_rate",
             "-show_entries", "format_tags=title,artist",
             "-of", "json", path],
            capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        j = json.loads(r.stdout)
        st = (j.get("streams") or [{}])[0]
        fmt = j.get("format") or {}
        tags = fmt.get("tags") or {}
        return {
            "codec": st.get("codec_name") or "",
            "sample_rate": int(st.get("sample_rate") or 0),
            "bits": int(st.get("bits_per_raw_sample") or 0),
            "bit_rate": int(fmt.get("bit_rate") or st.get("bit_rate") or 0),
            "duration": float(fmt.get("duration") or 0),
            "title": tags.get("title") or "",
            "artist": tags.get("artist") or "",
        }
    except Exception:
        return None


def collect(music_root, unlocked_root, limit=None):
    items = []
    seen = set()
    for root in (music_root, unlocked_root):
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            if os.path.realpath(dirpath) == os.path.realpath(music_root):
                dirnames[:] = [d for d in dirnames if d != "_unlocked"]
            for fn in sorted(filenames):
                ext = os.path.splitext(fn)[1].lower()
                if ext not in AUDIO_EXTS:
                    continue
                p = os.path.join(dirpath, fn)
                rel = in_root(p, music_root)
                if rel is None:
                    continue          # 防路径穿越: 音乐根之外一律丢弃
                rp = os.path.realpath(p)
                if rp in seen:
                    continue
                seen.add(rp)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                if not stat_mod.S_ISREG(st.st_mode):   # symlink 镜像排除
                    continue
                artist, title = parse_name(p)
                items.append({"path": p, "rel": rel,
                              "title": title, "artist": artist})
                if limit and len(items) >= limit:
                    return items
    return items


def keeper_key(m, path):
    lossless = 1 if m["codec"] in LOSSLESS else 0
    depth = m["bits"] * m["sample_rate"]
    tag = 1 if (m["title"] and m["artist"]) else 0
    return (lossless, depth, m["bit_rate"], tag, path)


def guarded_report_path(report_dir, file_name):
    """输出路径显式守卫: 文件名禁分隔符与 ..; 结果必须落在 report_dir 内。"""
    if ".." in file_name or "/" in file_name or os.sep in file_name:
        raise SystemExit("path guard: bad report file name")
    candidate = os.path.abspath(os.path.join(report_dir, file_name))
    if os.path.dirname(candidate) != os.path.abspath(report_dir):
        raise SystemExit("path guard: report path escapes report dir")
    return candidate


def main():
    ap = argparse.ArgumentParser(
        description="近似重复报告(只报告, 零删除): 按 规范化(标题,歌手) 分组, "
                    "组内时长差 <=10s 输出疑似对。")
    ap.add_argument("--music-root", default=os.environ.get("MUSIC_ROOT", "./Music"),
                    help="音乐库根(默认 ./Music 或环境变量 MUSIC_ROOT)")
    ap.add_argument("--report-dir", default=None,
                    help="报告输出目录(默认 <music-root>/.pipeline/reports)")
    ap.add_argument("--limit", type=int, default=None,
                    help="只采集前 N 个文件(小样本试跑)")
    ap.add_argument("--report", action="store_true",
                    help="无操作兼容参数: 默认动作即生成报告(为旧 crontab 保留, 不静默忽略)")
    args = ap.parse_args()

    music_root = os.path.abspath(args.music_root)
    if not os.path.isdir(music_root):
        print(f"音乐库根不存在: {music_root}", file=sys.stderr)
        return 1
    unlocked_root = os.path.join(music_root, "_unlocked")
    report_dir = args.report_dir or os.path.join(music_root, ".pipeline", "reports")
    report_dir = os.path.abspath(report_dir)

    os.makedirs(report_dir, exist_ok=True)
    pipeline_home = os.path.dirname(report_dir) if os.path.basename(report_dir) == "reports" else report_dir
    lockf = open(os.path.join(pipeline_home, ".neardup.lock"), "a")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("another-run: .neardup.lock 占用", file=sys.stderr)
        return 2

    items = collect(music_root, unlocked_root, args.limit)
    print(f"采集 {len(items)} 个常规音频文件", file=sys.stderr)
    for it in items:
        it["meta"] = ffprobe_meta(it["path"])
    items = [it for it in items if it["meta"]]

    groups = {}
    for it in items:
        t = norm_text(it["meta"]["title"] or it["title"])
        a = norm_text(it["meta"]["artist"] or it["artist"])
        if not t:
            continue
        groups.setdefault((t, a), []).append(it)

    rows = []
    for (t, a), lst in sorted(groups.items()):
        if len(lst) < 2:
            continue
        for i in range(len(lst)):
            for j in range(i + 1, len(lst)):
                A, B = lst[i], lst[j]
                ma, mb = A["meta"], B["meta"]
                if not ma["duration"] or not mb["duration"]:
                    continue
                delta = abs(ma["duration"] - mb["duration"])
                if delta > 10:
                    continue
                conf = "high" if delta <= 2 else "low"
                ka, kb = keeper_key(ma, A["path"]), keeper_key(mb, B["path"])
                a_first = ka >= kb
                keep, drop = (A, B) if a_first else (B, A)
                mk, md = (ma, mb) if a_first else (mb, ma)
                rows.append({
                    "confidence": conf, "title_norm": t, "artist_norm": a,
                    "delta_s": f"{delta:.2f}",
                    "keep(建议保留)": keep["rel"], "drop(仅建议,零删除)": drop["rel"],
                    "dur_keep": f"{mk['duration']:.2f}", "dur_drop": f"{md['duration']:.2f}",
                    "codec_keep": mk["codec"], "codec_drop": md["codec"],
                    "bitrate_keep": mk["bit_rate"], "bitrate_drop": md["bit_rate"],
                    "cross_unlocked": str(
                        A["rel"].startswith("_unlocked/") != B["rel"].startswith("_unlocked/")),
                })

    cols = ["confidence", "title_norm", "artist_norm", "delta_s",
            "keep(建议保留)", "drop(仅建议,零删除)", "dur_keep", "dur_drop",
            "codec_keep", "codec_drop", "bitrate_keep", "bitrate_drop", "cross_unlocked"]
    dated_path = guarded_report_path(report_dir, "near-dup-" + date.today().isoformat() + ".csv")
    if os.path.exists(dated_path):
        os.remove(dated_path)          # 重跑覆盖(报告可重跑)
    with open(dated_path, "a", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    latest_path = guarded_report_path(report_dir, "near-dup-latest.csv")
    shutil.copyfile(dated_path, latest_path)
    high = sum(1 for r in rows if r["confidence"] == "high")
    print(f"报告: {dated_path} (latest 副本: {latest_path})  组对={len(rows)} 高置信={high} (只报告, 零删除)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
