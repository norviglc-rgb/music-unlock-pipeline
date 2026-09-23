#!/usr/bin/env bash
# ============================================================================
# install-cron.sh — 追加式安装 crontab 行(幂等: 已存在的行跳过)
#
# 设计原则(docs/lessons.md「运维模式」):
#   1) 绝不重置/清空 crontab —— 只做"读当前 → 追加缺失行 → 写回";
#   2) 追加前整份备份;
#   3) 追加后校验: 追加前已有的每一行仍在位 + 目标行全部在位,
#      任一缺失 exit 1(通用校验, 不绑定任何特定既有任务)。
#
# 用法:
#   install-cron.sh <lines-file> [--backup-dir <dir>] [-h]
#     <lines-file>       要追加的 crontab 行(每行一条; 空行与 # 注释忽略);
#                        示例见 examples/crontab.txt
#     --backup-dir <dir> 备份目录(默认与 lines-file 同目录)
# ============================================================================
set -u -o pipefail
export LC_ALL=C

LINES_FILE=
BACKUP_DIR=
# crontab 命令可用 CRONTAB_BIN 覆盖(容器/CI 无 crontab 或测试沙盒时有用)
CRONTAB_BIN=${CRONTAB_BIN:-crontab}

show_usage() {
  cat <<'USAGE'
用法: install-cron.sh <lines-file> [--backup-dir <dir>]

  <lines-file>        要追加的 crontab 行文件(空行与 # 注释忽略)
  --backup-dir <dir>  备份目录(默认与 lines-file 同目录)
  -h, --help          显示本帮助

行为: 备份当前 crontab → 幂等追加缺失行 → 校验旧行完好且新行在位(失败 exit 1)
安全: 绝不重置/清空 crontab; 全程只追加。
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) show_usage; exit 0 ;;
    --backup-dir)
      [ $# -ge 2 ] || { echo "--backup-dir 需要参数" >&2; exit 1; }
      BACKUP_DIR=$2; shift ;;
    --*)
      echo "未知参数: $1" >&2; show_usage >&2; exit 1 ;;
    *)
      if [ -z "$LINES_FILE" ]; then LINES_FILE=$1; else
        echo "只接受一个 lines-file 参数(已有 $LINES_FILE, 又传入 $1)" >&2
        exit 1
      fi ;;
  esac
  shift
done

[ -n "$LINES_FILE" ] || { show_usage >&2; exit 1; }
[ -f "$LINES_FILE" ] || { echo "lines 文件不存在: $LINES_FILE" >&2; exit 1; }

BACKUP_DIR=${BACKUP_DIR:-$(cd -- "$(dirname -- "$LINES_FILE")" && pwd)}
mkdir -p "$BACKUP_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
BAK="$BACKUP_DIR/crontab-backup-$STAMP.txt"

# 1) 备份(无 crontab 时落空文件, 保证后续校验有基准)
echo "=== 追加前 crontab (备份到 $BAK) ==="
"$CRONTAB_BIN" -l > "$BAK" 2>/dev/null || : > "$BAK"
cat "$BAK"

# 2) 幂等追加(grep -qF 精确子串匹配; 绝不重置)
ADD=0 SKIP=0
APPEND_FAIL=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  if "$CRONTAB_BIN" -l 2>/dev/null | grep -qF -- "$line"; then
    echo "已存在，跳过: $line"
    SKIP=$((SKIP+1))
  else
    if { "$CRONTAB_BIN" -l 2>/dev/null; printf '%s\n' "$line"; } | "$CRONTAB_BIN" -; then
      ADD=$((ADD+1))
      echo "已追加: $line"
    else
      echo "[FAIL] 追加失败: $line" >&2
      APPEND_FAIL=1
    fi
  fi
done < "$LINES_FILE"
echo "本次新增 $ADD 行，跳过 $SKIP 行"

# 3) 通用完整性校验: 既有行逐行仍在位 + 目标行全部在位
FAIL=0
echo "=== 完整性校验(追加前行不丢失 + 目标行在位) ==="
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  if "$CRONTAB_BIN" -l 2>/dev/null | grep -qF -- "$line"; then
    :
  else
    echo "[MISSING] 既有行丢失: $line"
    FAIL=1
  fi
done < "$BAK"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  if "$CRONTAB_BIN" -l 2>/dev/null | grep -qF -- "$line"; then
    echo "[OK] 目标行在位"
  else
    echo "[MISSING] 目标行缺失: $line"
    FAIL=1
  fi
done < "$LINES_FILE"

echo "=== 行数: 备份 $(wc -l < "$BAK" | tr -d '[:space:]') -> 现 $("$CRONTAB_BIN" -l 2>/dev/null | wc -l | tr -d '[:space:]') ==="
if [ "$FAIL" -ne 0 ] || [ "$APPEND_FAIL" -ne 0 ]; then
  echo "校验失败! 请从备份恢复: crontab $BAK" >&2
  exit 1
fi
echo "校验通过。"
