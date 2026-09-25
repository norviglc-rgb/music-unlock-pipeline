#!/usr/bin/env bash
# ============================================================================
# dedup-exact.sh — _unlocked/ 转换产物的精确去重(解密后内容哈希一致)
#
# 范围铁律: 只作用于 <music-root>/_unlocked/ 内的转换产物; 加密原件与库内
#           既有通用文件一律不删(脚本无从接触, 见 docs/lessons.md 铁律2)。
#
# 工具: rmlint (-T df = duplicate files)
#   symlink 机理: rmlint 默认不跟随 symlink, 也不把 symlink 与其目标构造成
#   重复组 → 镜像链接不进 df 组; 消费侧仍逐组 lstat 校验(全部常规文件 +
#   前缀 _unlocked/), 双保险。
#
# keeper 确定性排序(可配置):
#   ① DEDUP_KEEPER_PREFIXES(冒号分隔的相对目录前缀, 靠前者优先保留);
#   ② 路径更浅者优先;  ③ 平级按路径字节序最小。
#   默认无前缀表 → 纯 ②+③。
#
# 删除流程(每副本): state(out_path 反查源) → deleted.log 追加+fsync
#   → mv 到回收批次目录(默认 <music-root>/.mc-trash/<批次>/, 同文件系统原子 rename)
#   → 复核 keeper 在且 sha256 一致 → rm 副本 → 源 state 行置 deduped + kept_path
#   任何一步校验不过 → 告警跳过该副本(绝不删)。
#
# 回收量不预设: 只以 deleted.log 合计为准。文件系统快照 pin 使 df 回收滞后数天属预期。
#
# 用法:
#   dedup-exact.sh --auto            扫描+删除(持主锁, 与转换互斥)
#   dedup-exact.sh --dry-run         只扫描报告, 不删(默认)
#   dedup-exact.sh --help
# 选项/环境: --music-root <dir>(默认 ./Music, 同 MUSIC_ROOT)
#            --trash-root <dir>(同 TRASH_ROOT, 默认 <music-root>/.mc-trash)
# 退出码: 0 成功  1 用法错误  2 主锁占用  4 缺 rmlint  5 rmlint 扫描失败
# ============================================================================
set -u -o pipefail
export LC_ALL=C

MUSIC_ROOT=${MUSIC_ROOT:-./Music}
PIPELINE_HOME=${PIPELINE_HOME:-}
TRASH_ROOT=${TRASH_ROOT:-}
KEEPER_PREFIXES=${DEDUP_KEEPER_PREFIXES:-}
ACTION=
MAIN_LOCK_MINE=0

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(ts)" "$*" >&2; }

show_usage() {
  cat <<'USAGE'
用法: dedup-exact.sh [--auto | --dry-run] [选项]

  --auto                扫描并删除重复副本(持主锁, 与转换互斥)
  --dry-run             只扫描报告, 不删(默认)
  -h, --help            显示本帮助

选项:
  --music-root <dir>    音乐库根(默认 ./Music 或环境变量 MUSIC_ROOT)
  --trash-root <dir>    回收目录(默认 <music-root>/.mc-trash)

环境变量: MUSIC_ROOT / PIPELINE_HOME / TRASH_ROOT / DEDUP_KEEPER_PREFIXES
退出码: 0 成功  1 用法错误  2 主锁占用  4 缺 rmlint  5 rmlint 扫描失败
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --auto)     ACTION="--auto" ;;
    --dry-run)  ACTION="--dry-run" ;;
    -h|--help)  show_usage; exit 0 ;;
    --music-root)
      [ $# -ge 2 ] || { warn "--music-root 需要参数" >&2; exit 1; }
      MUSIC_ROOT=$2; shift ;;
    --trash-root)
      [ $# -ge 2 ] || { warn "--trash-root 需要参数" >&2; exit 1; }
      TRASH_ROOT=$2; shift ;;
    *) warn "未知参数: $1" >&2; show_usage >&2; exit 1 ;;
  esac
  shift
done
[ -n "$ACTION" ] || ACTION="--dry-run"

if ! MUSIC_ROOT=$(cd -- "$MUSIC_ROOT" 2>/dev/null && pwd -P); then
  warn "音乐库根不存在或不可进入: $MUSIC_ROOT (用 --music-root 指定已存在的目录)" >&2
  exit 1
fi
PIPELINE_HOME=${PIPELINE_HOME:-$MUSIC_ROOT/.pipeline}
case "$PIPELINE_HOME" in /*) ;; *) PIPELINE_HOME="$PWD/$PIPELINE_HOME" ;; esac

OUT_ROOT="$MUSIC_ROOT/_unlocked"
STATE_DIR="$PIPELINE_HOME/state"
LOGS="$PIPELINE_HOME/logs"
STATE="$STATE_DIR/state.jsonl"
DELETED_LOG="$STATE_DIR/deleted.log"
RMLINT_JSON="$STATE_DIR/rmlint.json"
MAIN_LOCK="$PIPELINE_HOME/.lock"
MAIN_LOCK_DIR="$PIPELINE_HOME/.lock.d"
TRASH_ROOT=${TRASH_ROOT:-$MUSIC_ROOT/.mc-trash}

# ---------------------------------------------------------------- 主锁(与转换互斥)
remove_lock_dir() {
  case "$MAIN_LOCK_DIR" in
    ""|"/"|"/.lock.d") warn "主锁目录路径异常, 跳过清理: $MAIN_LOCK_DIR" ;;
    */.lock.d) rm -rf "$MAIN_LOCK_DIR" ;;
    *) warn "主锁目录路径异常, 跳过清理: $MAIN_LOCK_DIR" ;;
  esac
}

acquire_main_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$MAIN_LOCK"
    flock -n 9 || return 1
  else
    if ! mkdir "$MAIN_LOCK_DIR" 2>/dev/null; then
      local stale_pid
      stale_pid=$(cat "$MAIN_LOCK_DIR/pid" 2>/dev/null)
      if [ -n "$stale_pid" ] && ! kill -0 "$stale_pid" 2>/dev/null; then
        warn "清理陈旧主锁目录(持有进程 $stale_pid 已退出)"
        remove_lock_dir
        mkdir "$MAIN_LOCK_DIR" || return 1
      else
        return 1
      fi
    fi
    printf '%s\n' "$$" > "$MAIN_LOCK_DIR/pid"
    MAIN_LOCK_MINE=1
    trap 'release_main_lock' EXIT
  fi
  return 0
}

release_main_lock() {
  [ "$MAIN_LOCK_MINE" = "1" ] || return 0
  if command -v flock >/dev/null 2>&1; then
    flock -u 9 2>/dev/null
  else
    remove_lock_dir
  fi
  MAIN_LOCK_MINE=0
  return 0
}

rotate_cron_log() {
  local f="$LOGS/cron-dedup.log" sz
  [ -f "$f" ] || return 0
  sz=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')
  [ "${sz:-0}" -gt 20971520 ] || return 0
  [ -f "$f.2" ] && mv -f "$f.2" "$f.3"
  [ -f "$f.1" ] && mv -f "$f.1" "$f.2"
  mv -f "$f" "$f.1"
}

dedup_apply() { # $1=dry(1/0)
  local dry=$1 batch tmpdir
  batch="dedup-$(date '+%Y%m%d-%H%M%S')-$$"
  tmpdir="$TRASH_ROOT/$batch"

  python3 - "$RMLINT_JSON" "$OUT_ROOT" "$dry" "$tmpdir" "$DELETED_LOG" "$STATE" "$KEEPER_PREFIXES" <<'PYEOF'
import hashlib
import json
import os
import stat as stat_mod
import sys
import time

rmlint_json, out_root, dry, tmpdir, deleted_log, state_file, keeper_prefixes = sys.argv[1:8]
dry = dry == "1"
prefixes = [p.strip("/") for p in keeper_prefixes.split(":") if p.strip()]


def lstat_regular(p):
    try:
        st = os.lstat(p)
    except OSError:
        return None
    return st if stat_mod.S_ISREG(st.st_mode) else None


def prio(rel):
    # ① 显式前缀表优先(冒号分隔, 靠前优先) → ② 路径更浅优先 → ③ 字节序
    for i, pref in enumerate(prefixes):
        if rel == pref or rel.startswith(pref + "/"):
            return (0, i, rel.count("/"), rel)
    return (1, 0, rel.count("/"), rel)


def rel_of(abs_path):
    # 绝对路径 → 相对 out_root(越界原样返回)
    try:
        r = os.path.relpath(abs_path, out_root)
    except ValueError:
        return abs_path
    return None if r.startswith("..") else r


# 读 rmlint json 输出(-o json: 带缩进的 JSON 数组 [header, 条目..., footer];
# 条目含 type/path/size/checksum), 按 (checksum, size) 分组 type=duplicate_file
groups = {}
with open(rmlint_json, "r", encoding="utf-8", errors="replace") as f:
    doc = json.load(f)
if not isinstance(doc, list):
    raise SystemExit("rmlint json 格式异常: 期望数组")
for e in doc:
    if not isinstance(e, dict) or e.get("type") != "duplicate_file":
        continue
    p, sz, ck = e.get("path"), e.get("size"), e.get("checksum")
    if not p or not sz or not ck:
        continue
    groups.setdefault((ck, sz), []).append(p)


def state_src_rel(victim_rel):
    # 精确反查: 该产物必须是某加密源记录在案的 out_path(取最后一次出现;
    # 按 JSON 字段精确相等比较, 含特殊字符的文件名不失配)
    last = None
    try:
        with open(state_file, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("out_path") == victim_rel:
                    last = d
    except OSError:
        return None
    return (last or {}).get("rel_path")


def sha256(p):
    h = hashlib.sha256()
    try:
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def fsync_log():
    try:
        fd = os.open(deleted_log, os.O_RDONLY)
        os.fsync(fd)
        os.close(fd)
    except OSError:
        pass


n_groups = n_del = n_skip = 0
freed = 0
if not dry:
    os.makedirs(tmpdir, exist_ok=True)
for (ck, sz), paths in sorted(groups.items()):
    # 双保险: 任一路径越界 out_root 或非常规文件 → 整组跳过
    ok_paths = []
    for p in paths:
        if os.path.realpath(p) == p and not p.startswith(out_root + "/"):
            ok_paths = None
            break
        if not p.startswith(out_root + "/"):
            ok_paths = None
            break
        if lstat_regular(p) is None:
            ok_paths = None
            break
        ok_paths.append(p)
    if not ok_paths or len(ok_paths) < 2:
        continue
    n_groups += 1
    keyed = sorted((prio(os.path.relpath(p, out_root)), p) for p in ok_paths)
    keeper = keyed[0][1]
    keeper_rel = os.path.relpath(keeper, out_root)
    k_hash = sha256(keeper)
    for _, victim in keyed[1:]:
        victim_rel = os.path.relpath(victim, out_root)
        v_hash = sha256(victim)
        if not k_hash or not v_hash or v_hash != k_hash:
            print(f"SKIP(hash-mismatch)\t{victim_rel}\tkept={keeper_rel}", flush=True)
            n_skip += 1
            continue
        src_rel = state_src_rel(victim_rel)
        if not src_rel:
            print(f"SKIP(no-state-out_path)\t{victim_rel}\tkept={keeper_rel}", flush=True)
            n_skip += 1
            continue
        freed += sz
        if dry:
            print(f"DRY-DEL\t{victim_rel}\tsize={sz}\tkept={keeper_rel}", flush=True)
            continue
        # 1) 日志先行 + fsync
        with open(deleted_log, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')}\t{victim_rel}\t{sz}\t{v_hash}\t{keeper_rel}\texact-hash\n")
            f.flush()
            os.fsync(f.fileno())
        # 2) mv 到回收批次目录(同文件系统原子 rename)
        try:
            os.makedirs(tmpdir, exist_ok=True)
            dst = os.path.join(tmpdir, os.path.basename(victim))
            os.rename(victim, dst)
        except OSError as e:
            print(f"SKIP(mv-failed:{e})\t{victim_rel}", flush=True)
            n_skip += 1
            continue
        # 3) keeper 复核
        if lstat_regular(keeper) is None or sha256(keeper) != k_hash:
            print(f"SKIP(keeper-check-failed, 副本留在 {tmpdir})\t{victim_rel}", flush=True)
            n_skip += 1
            continue
        # 4) rm
        try:
            os.remove(dst)
        except OSError as e:
            print(f"SKIP(rm-failed:{e})\t{dst}", flush=True)
            n_skip += 1
            continue
        # 5) state 回写 deduped + kept_path(防转换-去重抖动; flock 串行)
        try:
            import fcntl
            lockf = open(state_file + ".lock", "a")
            fcntl.flock(lockf, fcntl.LOCK_EX)
            row = json.dumps({
                "rel_path": src_rel, "size": sz, "status": "deduped",
                "out_path": victim_rel, "out_size": sz, "kept_path": keeper_rel,
                "err_class": "", "err": "exact-hash-dedup",
                "attempts": 0, "last_ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            }, ensure_ascii=False, separators=(",", ":"))
            with open(state_file, "a", encoding="utf-8") as f:
                f.write(row + "\n")
                f.flush()
                os.fsync(f.fileno())
            fcntl.flock(lockf, fcntl.LOCK_UN)
            lockf.close()
        except OSError as e:
            print(f"SKIP(state-write-failed:{e})\t{victim_rel}", flush=True)
            n_skip += 1
            continue
        n_del += 1
        print(f"DEL\t{victim_rel}\tsize={sz}\tkept={keeper_rel}", flush=True)

fsync_log()
print(f"groups={n_groups} deleted={n_del} skipped={n_skip} freed_bytes={freed} dry={dry}")
if not dry:
    try:
        os.rmdir(tmpdir)
    except OSError:
        print(f"NOTE: 回收批次目录非空, 保留待人工处理: {tmpdir}")
PYEOF
}

main() {
  mkdir -p "$STATE_DIR" "$LOGS"
  if ! acquire_main_lock; then
    warn "another-run: 主锁占用(与转换互斥), exit 2"
    exit 2
  fi
  rotate_cron_log
  command -v rmlint >/dev/null 2>&1 || { warn "rmlint 未安装(Debian/Ubuntu: apt-get install rmlint; macOS: brew install rmlint)"; exit 4; }
  [ -d "$OUT_ROOT" ] || { log "无 _unlocked 目录, 无需去重"; exit 0; }
  log "rmlint 扫描中: $OUT_ROOT (-T df)"
  rmlint -T df -o "json:$RMLINT_JSON" "$OUT_ROOT" || { warn "rmlint 失败 rc=$?"; exit 5; }
  case "$ACTION" in
    --auto)
      log "dedup --auto 开始"
      dedup_apply 0
      log "dedup 完成(回收量以 deleted.log 合计为准)"
      ;;
    --dry-run)
      log "dedup --dry-run (只报告不删)"
      dedup_apply 1
      ;;
  esac
}

main "$@"
