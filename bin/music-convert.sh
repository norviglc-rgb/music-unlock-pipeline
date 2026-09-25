#!/usr/bin/env bash
# ============================================================================
# music-convert.sh — 加密音乐容器(ncm/mflac/mgg)本地解锁流水线
#
# 定位: 纯编排层(状态机/幂等/原件保护/去重协调)。解锁能力来自外部开源工具
#       unlock-music CLI(um, MIT), 由用户自行获取——本脚本不附带、不分发任何
#       密钥数据库或 DRM 对抗组件; 获取指引见 README。
#
# 铁律(详细原理见 docs/lessons.md):
#   1. 原件神圣不可侵犯 —— 绝不 remove-source, 绝不移动/覆盖加密原件;
#      manifest 每次自检 size+mtime, 变化即 exit 3。
#   2. 去重只作用于 _unlocked/ 产物(见 bin/dedup-exact.sh)。
#   3. 幂等: 磁盘事实优先 + state.jsonl 辅助; 主锁防重入。
#   4. 输出固定镜像布局 _unlocked/<源相对父目录>/。
#   5. 失败分层: no-key/corrupt/conflict 永久跳过; permission/io/timeout/other
#      自动重试, attempts 总数>=3 转 permanent(有界例外, --refresh-failed 重置)。
#   6. --check-idempotent: pending>0 → exit 1; 全处理完(含永久跳过) → exit 0。
#   7. 解锁是字节级无损解密, 非转码。
#
# um 关键行为(编排层依赖, 实测于 um v0.2.12):
#   - 成功日志(zap ConsoleEncoder)写 stdout → 必须 stdout+stderr 合并捕获;
#   - 单文件输入时必须逐源显式传 -o <镜像父目录>, 不依赖默认回写行为;
#   - 恒加 --overwrite(半截输出自愈); 绝不传 --remove-source;
#   - 纯解密输出以 O_TRUNC 打开会跟随 symlink → worker 前置 symlink 拒写
#     (写穿防护三件套, 见 do_worker 与 docs/lessons.md)。
#
# 退出码: 0 成功/检查通过   1 用法错误或 pending>0   2 主锁占用
#         3 原件保护自检失败   4 依赖缺失(um 等)
# ============================================================================
set -u -o pipefail
export LC_ALL=C

# ---------------------------------------------------------------- 配置解析
# 优先级: CLI 选项 > 环境变量 > 默认值。所有默认值均通用化, 不含任何机器私有路径。
SCRIPT_SELF=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")

MUSIC_ROOT=${MUSIC_ROOT:-./Music}
PIPELINE_HOME=${PIPELINE_HOME:-}
UM_BIN=${UM_BIN:-}
TRASH_ROOT=${TRASH_ROOT:-}
UPDATE_METADATA=${UPDATE_METADATA:-0}
EXTRA_UM_ARGS=${EXTRA_UM_ARGS:-}
UM_PARALLEL=${UM_PARALLEL:-4}
UM_TIMEOUT=${UM_TIMEOUT:-600}
MIN_FREE_GB=${MIN_FREE_GB:-500}
QMC_MMKV=${QMC_MMKV:-}

ACTION=
LIMIT_N=0
PILOT_N=4
INCLUDE_FILE=
WORKER_REL=
MAIN_LOCK_MINE=0

# 库内加密容器扩展名集合(如需扩展在此与 find_encrypted_nul 的参数保持一致)
ENCRYPT_EXTS="ncm mflac mgg"
# um 输出嗅探集(flac mp3 ogg wav wma m4a mp4 dff, 回落 mp3) + 保险项
AUDIO_OUT_EXTS="flac mp3 ogg m4a wav wma mp4 dff aac opus ape"
# --sync-symlinks 镜像的通用扩展(通用音频 + lrc 歌词)
MIRROR_EXTS="mp3 flac m4a ogg ape lrc"

set_action() {
  if [ -n "$ACTION" ]; then
    warn "只能指定一个动作参数: 已有 $ACTION, 又传入 $1" >&2
    show_usage >&2
    exit 1
  fi
  ACTION=$1
}

need_value() { # $1=选项名 $2=值
  [ $# -ge 2 ] || { warn "$1 需要一个参数" >&2; show_usage >&2; exit 1; }
}

# 注意: show_usage 必须在参数解析循环之前定义(脚本加载即执行解析)。
show_usage() {
  cat <<'USAGE'
用法: music-convert.sh <动作> [选项]

动作(每次一个):
  --auto                 全量增量转换 + sync-symlinks + manifest 自检 + check
  --limit N              小样本: ncm/mflac/mgg 三格式轮转取 N 个
  --pilot [N]            配额抽样: 每格式各取前 N 个(默认 4)
  --include <file>       NUL 分隔明细列表
  --worker <rel>         单文件处理(内部用, 不取主锁; rel 相对音乐库根)
  --check-idempotent     幂等检查: pending>0 → exit 1 且打印 pending=N;
                         全部处理完(含永久跳过) → 打印 pending=0 且 exit 0
  --sync-symlinks        为非加密源建 symlink 镜像(取主锁)
  --unlink-symlinks      拆除全部镜像链接
  --refresh-failed       重置 failed_permanent → pending
  --manifest-init        生成加密源 manifest 基线
  --manifest-check       原件保护自检(变化 → exit 3)
  --audit                _unlocked 产物全量 ffprobe 校验

选项:
  --music-root <dir>     音乐库根(默认 ./Music; 加密原件所在目录, 只读)
  --um-path <path>       解锁器 um 可执行文件路径(缺省从 PATH 查找)
  --qmc-mmkv <path>      透传 um 的 --qmc-mmkv <path>(自有密钥库, 可选)
  --help, -h             显示本帮助

环境变量:
  MUSIC_ROOT=<dir>       同 --music-root(CLI 优先)
  PIPELINE_HOME=<dir>    状态/日志/报告目录(默认 <music-root>/.pipeline)
  UM_BIN=<path>          同 --um-path(CLI 优先)
  TRASH_ROOT=<dir>       去重回收目录(默认 <music-root>/.mc-trash; 供 dedup-exact.sh)
  DEDUP_KEEPER_PREFIXES= 去重保留优先目录前缀, 冒号分隔(供 dedup-exact.sh)
  UPDATE_METADATA=0|1    传 um --update-metadata(默认 0; =1 失败自动降级纯解密)
  EXTRA_UM_ARGS="..."    额外 um 参数(空格分词, 不支持含空格的路径)
  UM_PARALLEL=N          并发 worker 数(默认 4)
  UM_TIMEOUT=S           单文件超时秒(默认 600)
  MIN_FREE_GB=N          可用空间低于此值(GiB)时拒绝新转换(默认 500)

依赖: bash 3.2+ / python3 / ffmpeg+ffprobe / um(unlock-music CLI, 获取见 README)
状态与日志: 默认写在 <music-root>/.pipeline/{state,logs,reports}
退出码: 0 成功  1 用法错误或 pending>0  2 主锁占用  3 原件保护自检失败  4 缺 um
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)          show_usage; exit 0 ;;
    --auto|--check-idempotent|--sync-symlinks|--unlink-symlinks|\
    --refresh-failed|--manifest-init|--manifest-check|--audit)
      set_action "$1" ;;
    --pilot)
      # 可选跟一个数字: 每格式抽样配额(默认 4)
      if [ $# -ge 2 ]; then
        case "$2" in -*) : ;; *)
          case "$2" in ''|*[!0-9]*) warn "--pilot 配额需为数字: $2" >&2; show_usage >&2; exit 1 ;; esac
          PILOT_N=$2; shift
        ;; esac
      fi
      set_action "--pilot" ;;
    --limit)
      need_value "$1" "${2:-}"
      case "$2" in ''|*[!0-9]*) warn "--limit 需要正整数, 得到: $2" >&2; show_usage >&2; exit 1 ;; esac
      set_action "--limit"; LIMIT_N=$2; shift ;;
    --include)
      need_value "$1" "${2:-}"; set_action "--include"; INCLUDE_FILE=$2; shift ;;
    --worker)
      need_value "$1" "${2:-}"; set_action "--worker"; WORKER_REL=$2; shift ;;
    --music-root)  need_value "$1" "${2:-}"; MUSIC_ROOT=$2; shift ;;
    --um-path)     need_value "$1" "${2:-}"; UM_BIN=$2; shift ;;
    --qmc-mmkv)    need_value "$1" "${2:-}"; QMC_MMKV=$2; shift ;;
    *) warn "未知参数: $1" >&2; show_usage >&2; exit 1 ;;
  esac
  shift
done
[ -n "$ACTION" ] || { show_usage >&2; exit 1; }

# 音乐库根必须已存在(本工具绝不创建/改动原件树根)
if ! MUSIC_ROOT=$(cd -- "$MUSIC_ROOT" 2>/dev/null && pwd -P); then
  warn "音乐库根不存在或不可进入: $MUSIC_ROOT (用 --music-root 指定已存在的目录)" >&2
  exit 1
fi
# 管线工作目录: 状态/日志/报告(默认与音乐库同放, 一库一份状态)
PIPELINE_HOME=${PIPELINE_HOME:-$MUSIC_ROOT/.pipeline}
case "$PIPELINE_HOME" in /*) ;; *) PIPELINE_HOME="$PWD/$PIPELINE_HOME" ;; esac

OUT_ROOT="$MUSIC_ROOT/_unlocked"
STATE_DIR="$PIPELINE_HOME/state"
LOGS="$PIPELINE_HOME/logs"
REPORTS="$PIPELINE_HOME/reports"
STATE="$STATE_DIR/state.jsonl"
STATE_LOCK="$STATE_DIR/state.lock"
MAIN_LOCK="$PIPELINE_HOME/.lock"
MAIN_LOCK_DIR="$PIPELINE_HOME/.lock.d"
MANIFEST="$STATE_DIR/manifest-sources.txt"
PIDFILE="$STATE_DIR/run.pid"
DELETED_LOG="$STATE_DIR/deleted.log"

export MUSIC_ROOT PIPELINE_HOME STATE_DIR UPDATE_METADATA EXTRA_UM_ARGS QMC_MMKV

# ---------------------------------------------------------------- 基础工具
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(ts)" "$*" >&2; }
die() { warn "$*"; exit "$2"; }

HAVE_FLOCK=0
if command -v flock >/dev/null 2>&1; then HAVE_FLOCK=1; fi

file_size() { wc -c < "$1" 2>/dev/null | tr -d '[:space:]'; }

# 绝对路径 → 相对 MUSIC_ROOT(越界路径原样返回; state.jsonl 存相对路径以保可移植)
rel_of() {
  case "$1" in
    "$MUSIC_ROOT")   printf '%s\n' . ;;
    "$MUSIC_ROOT"/*) printf '%s\n' "${1#"$MUSIC_ROOT"/}" ;;
    *)               printf '%s\n' "$1" ;;
  esac
}

# 逆序输出文件各行(tac 的可移植替代; BSD/macOS 无 tac)
reverse_file() { awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'; }

# NUL 分隔文本 → 换行分隔(日志展示用)
nul_to_nl() { python3 -c 'import sys;sys.stdout.buffer.write(sys.stdin.buffer.read().replace(b"\0",b"\n"))'; }

ensure_dirs() { mkdir -p "$STATE_DIR" "$LOGS" "$REPORTS"; }

# ---------------------------------------------------------------- 主锁(防重入)
# flock 可用时按原版语义; 否则用 mkdir 原子性兜底(macOS 等), 持有者 PID 记录在
# 锁目录内, 持有进程已退出时自动清理陈旧锁。
# 锁目录删除前做结构性校验: 只允许清理以 .lock.d 结尾且非根的路径,
# 防止 PIPELINE_HOME 误配(如指向 /)时 rm -rf 误伤。
remove_lock_dir() {
  case "$MAIN_LOCK_DIR" in
    ""|"/"|"/.lock.d") warn "主锁目录路径异常, 跳过清理: $MAIN_LOCK_DIR" ;;
    */.lock.d) rm -rf "$MAIN_LOCK_DIR" ;;
    *) warn "主锁目录路径异常, 跳过清理: $MAIN_LOCK_DIR" ;;
  esac
}

acquire_main_lock() {
  if [ "$HAVE_FLOCK" = "1" ]; then
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
  fi
  MAIN_LOCK_MINE=1
  trap 'rm -f "$PIDFILE" 2>/dev/null; release_main_lock' EXIT
  return 0
}

release_main_lock() {
  [ "$MAIN_LOCK_MINE" = "1" ] || return 0
  if [ "$HAVE_FLOCK" = "1" ]; then
    flock -u 9 2>/dev/null
  else
    remove_lock_dir
  fi
  MAIN_LOCK_MINE=0
  return 0
}

# ---------------------------------------------------------------- 状态台账
# state.jsonl 追加式 JSONL, 10 字段:
#   rel_path/size/status/out_path/out_size/kept_path/err_class/err/attempts/last_ts
# out_path/kept_path 一律存相对 MUSIC_ROOT 的路径(可移植; 与磁盘事实口径一致)。
state_append() { # rel size status out_path out_size kept_path err_class err attempts
  local line
  line=$(python3 -c '
import json,sys,time
a=sys.argv
def i(x):
    try: return int(x)
    except Exception: return 0
print(json.dumps({
 "rel_path":a[1],"size":i(a[2]),"status":a[3],"out_path":a[4],
 "out_size":i(a[5]),"kept_path":a[6],"err_class":a[7],"err":a[8],
 "attempts":i(a[9]),"last_ts":time.strftime("%Y-%m-%dT%H:%M:%S%z")},
 ensure_ascii=False,separators=(",",":")))
' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9") || { warn "state_append: python 序列化失败"; return 1; }
  # flock 可用时在 state.lock 内串行追加; 否则单条 O_APPEND 写本身即原子
  if [ "$HAVE_FLOCK" = "1" ]; then
    if [ -z "${STATE_LOCK_OPEN:-}" ]; then exec 8>>"$STATE_LOCK"; STATE_LOCK_OPEN=1; fi
    flock -w 15 8 || { warn "state.lock 获取超时"; return 1; }
  fi
  printf '%s\n' "$line" >> "$STATE"
  if [ "$HAVE_FLOCK" = "1" ]; then flock -u 8; fi
  return 0
}

# 查询某源最后状态行 → 输出 status<US>attempts<US>out_path<US>out_size<US>kept_path
# (无行输出空)。匹配键按 JSON 转义(引号/反斜杠), 含特殊字符的文件名不失配。
state_lookup() {
  local pat row esc
  [ -s "$STATE" ] || return 0
  esc=${1//\\/\\\\}
  esc=${esc//\"/\\\"}
  pat=$(printf '"rel_path":"%s"' "$esc")
  row=$(reverse_file < "$STATE" 2>/dev/null | grep -a -F -m1 -- "$pat" | head -n 1)
  [ -n "$row" ] || return 0
  printf '%s' "$row" | python3 -c '
import json,sys
try:
    d=json.loads(sys.stdin.read())
    print("\x1f".join(str(d.get(k,"")) for k in
        ("status","attempts","out_path","out_size","kept_path")))
except Exception:
    print("parse_error\x1f0\x1f\x1f\x1f")
'
}

# ---------------------------------------------------------------- 校验与分类
# ffprobe 音频校验 → 输出 codec<US>duration, 失败输出空
ffprobe_audio() {
  local out codec dur
  out=$(ffprobe -v error -show_entries stream=codec_name -show_entries format=duration \
        -of default=noprint_wrappers=1 "$1" 2>/dev/null) || return 1
  codec=$(printf '%s\n' "$out" | sed -n 's/^codec_name=//p' | head -n 1)
  dur=$(printf '%s\n' "$out" | sed -n 's/^duration=//p' | head -n 1)
  [ -n "$codec" ] || return 1
  awk -v d="${dur:-0}" 'BEGIN{exit !((d+0)>0)}' || return 1
  printf '%s\x1f%s' "$codec" "$dur"
}

# ②磁盘枚举: 在镜像目标目录找 stem 的既有产出(必须常规文件, 排除 symlink)
#   mode=fast 只列; mode=probe 每个候选先过 ffprobe
disk_find_output() { # rel mode
  local rel=$1 mode=$2 base stem dirrel outdir cand c f
  base=${rel##*/}
  stem=${base%.*}
  case "$rel" in */*) dirrel=${rel%/*} ;; *) dirrel=. ;; esac
  outdir="$OUT_ROOT/$dirrel"
  for c in $AUDIO_OUT_EXTS; do
    cand="$outdir/$stem.$c"
    if [ -L "$cand" ]; then continue; fi        # symlink 非磁盘事实(三件套③)
    if [ -f "$cand" ] && [ -s "$cand" ]; then
      if [ "$mode" = "probe" ]; then
        f=$(ffprobe_audio "$cand") || continue
        printf '%s\n' "$cand"
        return 0
      else
        printf '%s\n' "$cand"
        return 0
      fi
    fi
  done
  return 1
}

# 前置写穿防护①: 候选输出路径全集(嗅探集+保险项+__from变体)凡 symlink → 拒写
find_symlink_conflict() { # rel → 输出命中的 symlink 路径, 命中 return 0
  local rel=$1 base stem dirrel outdir cand c
  base=${rel##*/}; stem=${base%.*}
  case "$rel" in */*) dirrel=${rel%/*} ;; *) dirrel=. ;; esac
  outdir="$OUT_ROOT/$dirrel"
  for c in $AUDIO_OUT_EXTS "__from${rel##*.}"; do
    cand="$outdir/$stem.$c"
    if [ -L "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
  done
  return 1
}

# 分类决策: decision<US>detail
#   skip-done / skip-disk-done / skip-deduped / skip-permanent / pending-*
classify() { # rel mode(fast|probe)
  local rel=$1 mode=$2 look status attempts out_path out_size kept_path sz cand abs
  look=$(state_lookup "$rel")
  if [ -n "$look" ]; then
    IFS=$'\x1f' read -r status attempts out_path out_size kept_path <<< "$look"
    case "$status" in
      done)
        abs="$MUSIC_ROOT/$out_path"
        if [ -n "$out_path" ] && [ -f "$abs" ] && [ ! -L "$abs" ] && [ -s "$abs" ]; then
          sz=$(file_size "$abs")
          if [ "$sz" = "$out_size" ] && [ "$sz" -gt 0 ]; then
            printf 'skip-done\x1f%s\n' "$out_path"; return 0
          fi
        fi
        ;; # done 失效 → 落到②/重转
      deduped)
        if [ -n "$kept_path" ] && grep -a -q -F -- "$kept_path" "$DELETED_LOG" 2>/dev/null; then
          printf 'skip-deduped\x1f%s\n' "$kept_path"; return 0
        fi
        warn "deduped 行 $rel 的 kept_path=$kept_path 在 deleted.log 无记录, 降级 pending"
        printf 'pending-dedup-degraded\x1f\n'; return 0
        ;;
      failed_permanent)
        printf 'skip-permanent\x1f\n'; return 0 ;;
      failed_transient|in_progress|pending|"parse_error")
        : ;;
      *)
        warn "未知 status=$status ($rel), 视同 pending" ;;
    esac
  fi
  # ② 磁盘事实
  if cand=$(disk_find_output "$rel" "$mode"); then
    printf 'skip-disk-done\x1f%s\n' "$(rel_of "$cand")"; return 0
  fi
  printf 'pending-new\x1f\n'
}

# ---------------------------------------------------------------- um 解锁器
# 解析顺序: --um-path > UM_BIN > PATH 中的 um。仅在真正要转换时调用(懒解析),
# --check-idempotent 等只读动作不依赖 um。
require_um() {
  if [ -n "$UM_BIN" ]; then
    if [ ! -x "$UM_BIN" ]; then
      warn "解锁器不可执行: $UM_BIN (--um-path / UM_BIN 指定)"
      warn "  um = unlock-music CLI, 获取指引见 README「获取 unlock-music (um)」"
      exit 4
    fi
  else
    UM_BIN=$(command -v um 2>/dev/null)
    if [ -z "$UM_BIN" ]; then
      warn "未找到解锁器 um (unlock-music CLI)。请任选其一:"
      warn "  1) --um-path <路径> 指定 um 可执行文件;"
      warn "  2) export UM_BIN=<路径>;"
      warn "  3) 将 um 装入 PATH (go install unlock-music.dev/cli/cmd/um@master"
      warn "     或官方 release 下载, 详见 README)。"
      exit 4
    fi
  fi
  export UM_BIN
  log "um: $UM_BIN"
}

# 单文件超时(GNU timeout 可用则用之; 否则后台看门狗兜底, 语义对齐: 超时=124)
# 看门狗标志语义: 标志文件存在=未超时; 看门狗触发时删除标志再杀进程。
run_with_timeout() { # $1=秒数, 其余=命令
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  local flag pid rc watchdog
  flag=$(mktemp "$STATE_DIR/tmo.XXXXXX")
  "$@" &
  pid=$!
  (
    sleep "$secs"
    if kill -0 "$pid" 2>/dev/null; then
      rm -f -- "$flag"
      kill -TERM "$pid" 2>/dev/null
      sleep 5
      kill -KILL "$pid" 2>/dev/null
    fi
  ) 2>/dev/null &
  watchdog=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  if [ ! -e "$flag" ]; then
    return 124
  fi
  rm -f -- "$flag"
  return "$rc"
}

# ---------------------------------------------------------------- worker
do_worker() { # $1 = rel path (相对 MUSIC_ROOT)
  local rel=$1 src base stem dirrel outdir logf rc dest="" dsz ff="" cand="" abs
  local look status attempts new_attempts taillog errclass errline err_meta
  local meta_degraded=0
  src="$MUSIC_ROOT/$rel"
  base=${rel##*/}; stem=${base%.*}
  case "$rel" in */*) dirrel=${rel%/*} ;; *) dirrel=. ;; esac
  outdir="$OUT_ROOT/$dirrel"

  require_um

  # 扩展名合法性(防 xargs 误入非加密文件)
  case " $ENCRYPT_EXTS " in *" ${base##*.} "*) ;; *) warn "worker 收到非加密源, 跳过: $rel"; return 0 ;; esac
  [ -f "$src" ] || { state_append "$rel" 0 failed_permanent "" 0 "" io "source-missing" 0; warn "源缺失: $rel"; return 0; }
  [ -L "$src" ] && { warn "源是 symlink, 跳过(不在管辖): $rel"; return 0; }
  local srcsize; srcsize=$(file_size "$src")

  look=$(state_lookup "$rel")
  attempts=0
  if [ -n "$look" ]; then
    IFS=$'\x1f' read -r status attempts _ _ _ <<< "$look"
    case "$status" in
      failed_permanent) warn "permanent 跳过(worker 不应收到): $rel"; return 0 ;;
      done|deduped)
        case "$(classify "$rel" fast)" in skip-*) warn "已处理, 跳过: $rel"; return 0 ;; esac ;;
    esac
  fi

  # ② 磁盘事实回写(state 无有效行时先走; 日志解析失败时也是兜底)
  if [ -z "$look" ]; then
    if cand=$(disk_find_output "$rel" probe); then
      dsz=$(file_size "$cand")
      ff=$(ffprobe_audio "$cand")
      state_append "$rel" "$srcsize" "done" "$(rel_of "$cand")" "$dsz" "" "" "" 0
      log "[worker] $rel -> done(disk) out=$cand ffprobe=$ff"
      return 0
    fi
  fi

  state_append "$rel" "$srcsize" in_progress "" 0 "" "" "" "$attempts"

  # ① symlink 拒写(写穿防护, um 不运行则写穿不可能发生)
  if cand=$(find_symlink_conflict "$rel"); then
    printf '%s\t%s\t%s\n' "$(ts)" "$rel" "$(rel_of "$cand")" >> "$REPORTS/conflict.log"
    new_attempts=$((attempts+1))
    state_append "$rel" "$srcsize" failed_permanent "" 0 "" conflict "symlink at candidate output: $(rel_of "$cand")" "$new_attempts"
    warn "CONFLICT: $rel 的候选输出存在 symlink($(rel_of "$cand")), 拒绝调用 um (原件保护)"
    return 0
  fi

  mkdir -p "$outdir"
  logf=$(mktemp "$STATE_DIR/umlog.XXXXXX")

  build_um_flags() { # $1=1 首次(按 UPDATE_METADATA 决定加参), 0=降级重试
    UM_FLAGS=(--overwrite)
    if [ "${1:-1}" = "1" ] && [ "$UPDATE_METADATA" = "1" ]; then
      UM_FLAGS+=(--update-metadata)
    fi
    if [ -n "$QMC_MMKV" ]; then
      UM_FLAGS+=(--qmc-mmkv "$QMC_MMKV")
    fi
    if [ -n "$EXTRA_UM_ARGS" ]; then
      local extra
      read -r -a extra <<< "$EXTRA_UM_ARGS"
      UM_FLAGS+=("${extra[@]}")
    fi
    return 0
  }

  run_um() {
    build_um_flags "$1"
    run_with_timeout "$UM_TIMEOUT" "$UM_BIN" "${UM_FLAGS[@]}" -o "$outdir" "$src" >"$logf" 2>&1
  }

  run_um 1
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$UPDATE_METADATA" = "1" ]; then
    warn "update-metadata 失败(rc=$rc), 降级纯解密重试一次: $rel"
    run_um 0
    rc=$?
    meta_degraded=1
  fi

  # 产出定位主路径: 解析成功日志(zap 写 stdout, 已合并捕获于 logf)
  dest=""
  if grep -a -q -F 'successfully converted' "$logf" 2>/dev/null; then
    dest=$(grep -a -F 'successfully converted' "$logf" | tail -n 1 | python3 -c '
import json,sys
line=sys.stdin.buffer.read().decode("utf-8","replace").rstrip("\n")
try:
    d=json.loads(line.rsplit("\t",1)[-1])
    sys.stdout.write(d.get("destination",""))
except Exception:
    sys.stdout.write("")
')
  fi

  verify_output() { # $1=输出路径 → 成功则 echo codec<US>dur
    [ -n "$1" ] && [ -f "$1" ] && [ ! -L "$1" ] && [ -s "$1" ] || return 1
    ffprobe_audio "$1"
  }

  if [ "$rc" -eq 0 ] && [ -n "$dest" ] && ff=$(verify_output "$dest"); then
    dsz=$(file_size "$dest")
    err_meta="meta=0"
    [ "$meta_degraded" = "1" ] && err_meta="meta=0,meta-degraded"
    state_append "$rel" "$srcsize" "done" "$(rel_of "$dest")" "$dsz" "" "" "$err_meta" "$attempts"
    log "[worker] $rel -> done out=$dest codec_dur=$ff"
    rm -f "$logf"; return 0
  fi

  if [ "$rc" -eq 0 ]; then
    # 日志解析失败或输出异常 → ② 枚举兜底(丢失权威路径但功能不坏)
    if cand=$(disk_find_output "$rel" probe); then
      dsz=$(file_size "$cand")
      err_meta="outpath-fallback"
      [ "$meta_degraded" = "1" ] && err_meta="outpath-fallback,meta-degraded"
      state_append "$rel" "$srcsize" "done" "$(rel_of "$cand")" "$dsz" "" "" "$err_meta" "$attempts"
      log "[worker] $rel -> done(fallback) out=$cand ffprobe=$ff"
      rm -f "$logf"; return 0
    fi
  fi

  # 失败分类(按 um 日志尾部片段; 永久类: no-key/corrupt/conflict)
  new_attempts=$((attempts+1))
  taillog=$(tail -c 3000 "$logf" 2>/dev/null | tr '\n' ' ' | tr '\r' ' ')
  errline=$(printf '%s' "$taillog" | cut -c1-300)
  if [ "$rc" -eq 124 ]; then
    errclass=timeout
  else
    errclass=other
    case "$taillog" in
      *"permission denied"*|*"Permission denied"*) errclass=permission ;;
      *MusicEx*|*"magic mismatch"*) errclass=no-key ;;
      *"unexpected EOF"*|*invalid*|*corrupt*|*malformed*|*sniff*|*unsupported*|*"bad magic"*) errclass=corrupt ;;
      *key*|*Key*|*KEY*|*MMKV*|*mmkv*|*cex*|*CEX*|*STag*|*stag*|*QMC*|*kgg*|*KGG*) errclass=no-key ;;
      *"no such file"*|*"input/output error"*|*"I/O error"*) errclass=io ;;
    esac
  fi
  local final=failed_transient
  case "$errclass" in no-key|corrupt|conflict) final=failed_permanent ;; *)
    [ "$new_attempts" -ge 3 ] && final=failed_permanent ;;
  esac
  state_append "$rel" "$srcsize" "$final" "" 0 "" "$errclass" "$errline" "$new_attempts"
  log "[worker] $rel -> $final class=$errclass attempts=$new_attempts err=${errline:0:160}"
  rm -f "$logf"
  return 0
}

# ---------------------------------------------------------------- 任务列表
find_encrypted_nul() { # 输出 NUL 分隔 rel 列表(字节序排序; 常规文件; 大小写不敏感)
  python3 - "$MUSIC_ROOT" "$ENCRYPT_EXTS" <<'PYEOF'
import os, stat, sys
root = sys.argv[1]
exts = {e.lower() for e in sys.argv[2].split()}
out = sys.stdout.buffer
found = []
for dirpath, dirnames, filenames in os.walk(root):
    for fn in filenames:
        parts = fn.rsplit(".", 1)
        if len(parts) != 2 or parts[1].lower() not in exts:
            continue
        p = os.path.join(dirpath, fn)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        found.append(os.path.relpath(p, root))
found.sort()
for rel in found:
    out.write(rel.encode("utf-8", "surrogateescape") + b"\0")
PYEOF
}

select_sample() { # $1=pilot|limit $2=N → stdout NUL 列表(输入经管道送入)
  find_encrypted_nul | python3 -c '
import sys
mode = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else 0
exts = sys.argv[3].split()
buckets = {e: [] for e in exts}
for p in sys.stdin.buffer.read().split(b"\0"):
    if not p:
        continue
    low = p.decode("utf-8", "surrogateescape").lower()
    for e in buckets:
        if low.endswith("." + e):
            buckets[e].append(p)
            break
for e in buckets:
    buckets[e].sort()
out = []
if mode == "pilot":
    # 每个格式各取排序后的前 N 个(确定性抽样)
    for e in buckets:
        out += buckets[e][:N]
else:
    i = 0
    while len(out) < N:
        added = False
        for e in buckets:
            if i < len(buckets[e]) and len(out) < N:
                out.append(buckets[e][i])
                added = True
        if not added:
            break
        i += 1
buf = sys.stdout.buffer
for p in out:
    buf.write(p + b"\0")
' "$1" "$2" "$ENCRYPT_EXTS"
}

# 音乐库所在卷可用空间(GiB; df POSIX 选项, 兼容 GNU/BSD)
music_root_free_gb() { df -Pk "$MUSIC_ROOT" 2>/dev/null | awk 'NR==2 {printf "%d", $4 / 1048576}'; }

# 统一执行入口: 持主锁 → 任务构建 → 并发 worker → sync → manifest → check
do_run_list() { # $1=listfile(NUL rel)
  if ! acquire_main_lock; then
    log "another-run: 主锁被占用(可能有 run 进行中), exit 2"
    exit 2
  fi
  echo $$ > "$PIDFILE"
  local listfile=$1 tasks=0 free

  # in_progress 残留 → pending(崩溃恢复; 仅"最后一行"为 in_progress 的源)
  if [ -s "$STATE" ]; then
    python3 -c '
import json,sys
last={}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    last[d.get("rel_path","")]=d.get("status","")
for r,s in last.items():
    if s=="in_progress": print(r)
' "$STATE" | while IFS= read -r r; do
      [ -n "$r" ] || continue
      local lk at
      lk=$(state_lookup "$r"); at=0
      [ -n "$lk" ] && { IFS=$'\x1f' read -r _ at _ _ _ <<< "$lk"; }
      state_append "$r" 0 pending "" 0 "" "" "resumed-from-in_progress" "$at"
    done
  fi

  free=$(music_root_free_gb)
  if [ "${free:-0}" -lt "$MIN_FREE_GB" ]; then
    warn "音乐库所在卷余量 ${free}G < ${MIN_FREE_GB}G, 拒绝新转换(仅做 sync/check/自检)"
    : > "$listfile"
  fi

  tasks=$(tr -dc '\0' < "$listfile" | wc -c | tr -d '[:space:]')
  log "pending tasks: $tasks (可用=${free}G, UM_PARALLEL=$UM_PARALLEL, UPDATE_METADATA=$UPDATE_METADATA)"
  if [ "$tasks" -gt 0 ]; then
    require_um
    xargs -0 -r -P "$UM_PARALLEL" -n 1 "$SCRIPT_SELF" --worker < "$listfile"
  fi

  sync_symlinks_impl

  manifest_check_impl || { warn "原件保护自检失败(exit 3)"; exit 3; }

  log "---- check-idempotent ----"
  do_check || true
  log "run 完成"
}

do_auto() {
  local listf keepf
  listf=$(mktemp "$STATE_DIR/list.XXXXXX")
  find_encrypted_nul > "$listf"
  # 预扫描: 只留 pending(避免为已处理源各起一个 worker 进程)
  keepf=$(mktemp "$STATE_DIR/keep.XXXXXX")
  : > "$keepf"
  while IFS= read -r -d '' rel; do
    case "$(classify "$rel" fast)" in
      pending-*) printf '%s\0' "$rel" >> "$keepf" ;;
    esac
  done < "$listf"
  do_run_list "$keepf"
  rm -f "$listf" "$keepf"
}

do_include() { # $1=NUL listfile
  [ -f "$1" ] || die "--include 文件不存在: $1" 1
  local keepf
  keepf=$(mktemp "$STATE_DIR/keep.XXXXXX")
  : > "$keepf"
  while IFS= read -r -d '' rel; do
    case "$(classify "$rel" fast)" in
      pending-*) printf '%s\0' "$rel" >> "$keepf" ;;
    esac
  done < "$1"
  do_run_list "$keepf"
  rm -f "$keepf"
}

do_limit() { # $1=N
  local f
  f=$(mktemp "$STATE_DIR/sample.XXXXXX")
  select_sample limit "$1" > "$f"
  log "--limit $1 抽样列表:"
  nul_to_nl < "$f" | sed 's/^/    /'
  do_include "$f"
  rm -f "$f"
}

do_pilot() {
  local f
  f=$(mktemp "$STATE_DIR/sample.XXXXXX")
  select_sample pilot "$PILOT_N" > "$f"
  log "--pilot 抽样列表(每格式前 $PILOT_N 个):"
  nul_to_nl < "$f" | sed 's/^/    /'
  do_include "$f"
  rm -f "$f"
}

# ---------------------------------------------------------------- check
do_check() {
  local total=0 done_c=0 perm_c=0 pend_c=0 rel dec
  while IFS= read -r -d '' rel; do
    total=$((total+1))
    dec=$(classify "$rel" fast)
    case "$dec" in
      skip-done*|skip-disk-done*|skip-deduped*) done_c=$((done_c+1)) ;;
      skip-permanent*) perm_c=$((perm_c+1)) ;;
      pending-*) pend_c=$((pend_c+1));
        [ "$pend_c" -le 20 ] && printf '  pending: %s (%s)\n' "$rel" "${dec%%$'\x1f'*}" ;;
      *) warn "classify 未归类输出: $rel -> $dec" ;;
    esac
  done < <(find_encrypted_nul)
  printf 'total=%d done=%d permanent_skip=%d pending=%d\n' "$total" "$done_c" "$perm_c" "$pend_c"
  if [ "$pend_c" -gt 0 ]; then
    printf 'pending=%d\n' "$pend_c"
    return 1
  fi
  printf 'pending=0\n'
  return 0
}

# ---------------------------------------------------------------- symlink 镜像
find_mirror_nul() { # NUL 分隔 rel 列表(已 prune _unlocked; 常规文件)
  python3 - "$MUSIC_ROOT" "$MIRROR_EXTS" <<'PYEOF'
import os, stat, sys
root = sys.argv[1]
exts = {e.lower() for e in sys.argv[2].split()}
out = sys.stdout.buffer
found = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d != "_unlocked"]
    for fn in filenames:
        parts = fn.rsplit(".", 1)
        if len(parts) != 2 or parts[1].lower() not in exts:
            continue
        p = os.path.join(dirpath, fn)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        found.append(os.path.relpath(p, root))
found.sort()
for rel in found:
    out.write(rel.encode("utf-8", "surrogateescape") + b"\0")
PYEOF
}

sync_symlinks_impl() {
  [ -d "$OUT_ROOT" ] || mkdir -p "$OUT_ROOT"
  local created=0 kept=0 relinked=0 shadowed=0 regular_skip=0 rel base stem dirrel link target d enc ext e
  # 枚举 Music 根(排除 _unlocked 自身, 防产物自镜像)的通用音频+lrc
  while IFS= read -r -d '' rel; do
    base=${rel##*/}; stem=${base%.*}; ext=${base##*.}
    case "$rel" in */*) dirrel=${rel%/*} ;; *) dirrel=. ;; esac
    # ② 构造性规避(仅音频扩展): 转换产物只会是音频容器扩展, 与同目录加密源同
    #    stem 的通用音频可能被产物遮蔽 → 不建镜像; lrc 永不与产物同名
    #    (歌词配加密歌是常态), 一律镜像。
    enc=0
    if [ "$ext" != "lrc" ]; then
      for e in $ENCRYPT_EXTS; do
        [ -e "$MUSIC_ROOT/$dirrel/$stem.$e" ] && enc=1 && break
      done
    fi
    if [ "$enc" = "1" ]; then
      shadowed=$((shadowed+1)); continue
    fi
    link="$OUT_ROOT/$rel"
    # 链接位于 _unlocked/<dirrel>/: 上跳 (dirrel 组件数 + 1) 级到 Music 根, 再接 rel
    #   dirrel="." → 1 级; "a" → 2 级; "a/b" → 3 级
    d=1
    if [ "$dirrel" != "." ]; then
      local rest=$dirrel
      d=2
      while [ "${rest#*/}" != "$rest" ]; do d=$((d+1)); rest=${rest#*/}; done
    fi
    target=""
    while [ "$d" -gt 0 ]; do target="../$target"; d=$((d-1)); done
    target="$target$rel"
    if [ -L "$link" ]; then
      if [ "$(readlink "$link")" = "$target" ] && [ -e "$link" ]; then
        kept=$((kept+1))
      else
        ln -sfn "$target" "$link" && relinked=$((relinked+1))
      fi
    elif [ -e "$link" ]; then
      regular_skip=$((regular_skip+1))   # 常规文件(自有产物), 不动
    else
      mkdir -p "$OUT_ROOT/$dirrel"
      ln -s "$target" "$link" && created=$((created+1))
    fi
  done < <(find_mirror_nul)
  # 悬空清理(_unlocked 内指向不存在的链接)
  local dangling=0 l
  while IFS= read -r -d '' l; do
    [ -e "$l" ] || { rm -f -- "$l" && dangling=$((dangling+1)); }
  done < <(find "$OUT_ROOT" -type l -print0 2>/dev/null)
  log "sync-symlinks: created=$created kept=$kept relinked=$relinked shadow_skip=$shadowed regular_skip=$regular_skip dangling_removed=$dangling"
}

do_sync_entry() {
  if ! acquire_main_lock; then
    warn "another-run: 主锁占用, exit 2"
    exit 2
  fi
  sync_symlinks_impl
}

do_unlink_symlinks() {
  if ! acquire_main_lock; then
    warn "another-run: 主锁占用, exit 2"
    exit 2
  fi
  local n=0 l
  [ -d "$OUT_ROOT" ] || { log "无 _unlocked 目录, 无需拆除"; return 0; }
  while IFS= read -r -d '' l; do
    rm -f -- "$l" && n=$((n+1))
  done < <(find "$OUT_ROOT" -type l -print0 2>/dev/null)
  log "unlink-symlinks: removed=$n"
}

# ---------------------------------------------------------------- manifest
find_encrypted_manifest() { # rel<TAB>size<TAB>mtime(字节序排序)
  python3 - "$MUSIC_ROOT" "$ENCRYPT_EXTS" <<'PYEOF'
import os, stat, sys
root = sys.argv[1]
exts = {e.lower() for e in sys.argv[2].split()}
rows = []
for dirpath, dirnames, filenames in os.walk(root):
    for fn in filenames:
        parts = fn.rsplit(".", 1)
        if len(parts) != 2 or parts[1].lower() not in exts:
            continue
        p = os.path.join(dirpath, fn)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        rows.append((os.path.relpath(p, root), st.st_size, st.st_mtime))
rows.sort(key=lambda r: r[0])
out = sys.stdout.buffer
for rel, size, mt in rows:
    out.write(("%s\t%d\t%s\n" % (rel, size, mt)).encode("utf-8", "surrogateescape"))
PYEOF
}

do_manifest_init() {
  mkdir -p "$STATE_DIR"
  find_encrypted_manifest > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  log "manifest 初始化: $(wc -l < "$MANIFEST" | tr -d '[:space:]') 条加密源"
}

manifest_check_impl() {
  [ -f "$MANIFEST" ] || { warn "manifest 不存在, 先初始化"; do_manifest_init; return 0; }
  local cur changed newrc=0
  cur=$(mktemp "$STATE_DIR/mcur.XXXXXX")
  changed=$(mktemp "$STATE_DIR/mchg.XXXXXX")
  find_encrypted_manifest > "$cur"
  join -t "$(printf '\t')" -j 1 "$MANIFEST" "$cur" 2>/dev/null \
    | awk -F'\t' '$2!=$4 || $3!=$5 {print $1"\t old_size="$2" old_mtime="$3"\t new_size="$4" new_mtime="$5}' > "$changed"
  if [ -s "$changed" ]; then
    warn "!!! 原件保护自检失败: 已登记加密源 size/mtime 发生变化:"
    cat "$changed" >&2
    rm -f "$cur" "$changed"; return 3
  fi
  # 新增加密源 → 并入 manifest(正常增量, 不告警)
  comm -13 "$MANIFEST" "$cur" > "$changed"
  if [ -s "$changed" ]; then
    newrc=$(wc -l < "$changed" | tr -d '[:space:]')
    cat "$changed" >> "$MANIFEST" && LC_ALL=C sort -t "$(printf '\t')" -k1,1 -o "$MANIFEST" "$MANIFEST"
    log "manifest 新增加密源 $newrc 条(正常增量)"
  fi
  rm -f "$cur" "$changed"
  log "manifest 自检通过: $(wc -l < "$MANIFEST" | tr -d '[:space:]') 条, 变化 0"
  return 0
}

do_manifest_entry() { manifest_check_impl; }

# ---------------------------------------------------------------- refresh
do_refresh_failed() {
  [ -s "$STATE" ] || { log "state 为空, 无可重置"; return 0; }
  local n=0 rel lk at
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    lk=$(state_lookup "$rel")
    at=0; [ -n "$lk" ] && { IFS=$'\x1f' read -r _ at _ _ _ <<< "$lk"; }
    state_append "$rel" 0 pending "" 0 "" "" "refreshed" 0
    n=$((n+1))
  done < <(grep -a '"status":"failed_permanent"' "$STATE" 2>/dev/null | python3 -c '
import json,sys
seen=set()
for line in sys.stdin:
    try:
        r=json.loads(line)["rel_path"]
        if r not in seen: seen.add(r); print(r)
    except Exception: pass
')
  log "refresh-failed: 重置 $n 个 permanent → pending"
}

# ---------------------------------------------------------------- audit
do_audit() {
  local bad=0 total=0 f ff
  [ -d "$OUT_ROOT" ] || { log "无 _unlocked, 无需 audit"; return 0; }
  while IFS= read -r -d '' f; do
    total=$((total+1))
    ff=$(ffprobe_audio "$f") || { bad=$((bad+1)); warn "audit 失败: $f"; continue; }
    printf 'ok\t%s\t%s\n' "$f" "$ff"
  done < <(find "$OUT_ROOT" -type f -print0 2>/dev/null)
  log "audit: total=$total bad=$bad"
  [ "$bad" -eq 0 ]
}

# ---------------------------------------------------------------- cron 日志轮转
rotate_cron_log() {
  local f=$1 sz
  [ -f "$f" ] || return 0
  sz=$(file_size "$f")
  [ "${sz:-0}" -gt 20971520 ] || return 0
  [ -f "$f.2" ] && mv -f "$f.2" "$f.3"
  [ -f "$f.1" ] && mv -f "$f.1" "$f.2"
  mv -f "$f" "$f.1"
  log "cron 日志轮转: $f"
}

# ---------------------------------------------------------------- main
main() {
  case "$ACTION" in
    --check-idempotent|--audit) ;;  # 只读动作, 不落任何文件
    *) ensure_dirs ;;
  esac
  case "$ACTION" in
    --auto)              rotate_cron_log "$LOGS/cron-convert.log"; do_auto ;;
    --pilot)             rotate_cron_log "$LOGS/cron-convert.log"; do_pilot ;;
    --limit)             rotate_cron_log "$LOGS/cron-convert.log"; do_limit "$LIMIT_N" ;;
    --include)           rotate_cron_log "$LOGS/cron-convert.log"; do_include "$INCLUDE_FILE" ;;
    --worker)            do_worker "$WORKER_REL" ;;
    --check-idempotent)  do_check; exit $? ;;
    --sync-symlinks)     do_sync_entry ;;
    --unlink-symlinks)   do_unlink_symlinks ;;
    --refresh-failed)    do_refresh_failed ;;
    --manifest-init)     do_manifest_init ;;
    --manifest-check)    do_manifest_entry ;;
    --audit)             do_audit ;;
  esac
}

main "$@"
