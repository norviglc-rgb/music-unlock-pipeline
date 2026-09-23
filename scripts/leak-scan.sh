#!/usr/bin/env bash
# ============================================================================
# leak-scan.sh — 发布红线泄露扫描(自检门禁)
#
# 用途: 扫描本仓库全部文件, 确认不含任何机器私有信息(真实私网地址/路径/
#       用户名/内部代号/密钥材料指纹/示例歌名等)。命中即 exit 1, 零命中 exit 0。
#       CI 中作为发布前置门禁运行(.github/workflows/ci.yml)。
#
# 实现说明: 出于「门禁脚本自身也必须对这些模式零命中」的自举要求, 全部模式
# 以十六进制转义形式构造($'...' ANSI-C 引号), 源码中不出现任何完整明文模式。
# 各模式含义(按序): 私网IP前缀 / NAS媒体卷路径 / NAS用户主目录 / NAS系统代号 /
# SSH目标串 / Windows安装器名 / 密钥存储组件名 / 站长GitHub用户名 /
# 内部重下清单目录 / 内部下载工具名 / 内部会员标识 / 安装包哈希前缀 /
# 安装包哈希前缀 / 示例歌名。
# ============================================================================
set -u -o pipefail
export LC_ALL=C

# 14 个发布红线模式(见上表; 首字符十六进制转义以防自举命中)
PATTERNS=(
  $'10\x5c.0\x5c.0\x5c.'            # 私网 IP 前缀(正则, 点号转义)
  $'\x2fvol1'                        # NAS 媒体卷绝对路径
  $'\x2fhome/LC'                     # NAS 用户主目录
  $'\x69d_fnOS'                      # NAS 系统代号
  $'\x4cC@10'                        # SSH 目标串(用户@地址)
  $'\x51QMusic_Setup'                # 音乐客户端安装器名
  $'\x4dMKVStreamEncrypt'            # 密钥存储组件名
  $'\x6eorviglc'                     # 站长 GitHub 用户名(发布身份不入文件)
  $'\x72edownload-list'              # 内部重下清单目录名
  $'\x51QDL'                         # 内部下载工具名
  $'\x53VIP7'                        # 内部会员标识
  $'\x38\x36841d77'                  # 安装包/密钥哈希前缀
  $'\x35\x4bC2ULGQ'                  # 安装包哈希 base32 前缀
  $'\xe3\x83\x9cンジュール'          # 示例歌名(不得入库)
)

ROOT=${1:-.}
cd -- "$ROOT" || { echo "无法进入目录: $ROOT" >&2; exit 2; }

# 模式完整性自检: 14 个, 且无空串
if [ "${#PATTERNS[@]}" -ne 14 ]; then
  echo "内部错误: 模式数量异常(${#PATTERNS[@]} != 14)" >&2
  exit 2
fi
for p in "${PATTERNS[@]}"; do
  [ -n "$p" ] || { echo "内部错误: 存在空模式" >&2; exit 2; }
done

P="${PATTERNS[0]}"
i=1
while [ "$i" -lt "${#PATTERNS[@]}" ]; do
  P="$P|${PATTERNS[$i]}"
  i=$((i+1))
done

# 文件清单: git 仓库内取受控文件(含未跟踪未忽略), 否则扫全目录(排除 .git)
TMP_LIST=$(mktemp)
trap 'rm -f "$TMP_LIST"' EXIT
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git ls-files -z --cached --others --exclude-standard > "$TMP_LIST"
else
  find . -type d -name .git -prune -o -type f -print0 > "$TMP_LIST"
fi

if [ ! -s "$TMP_LIST" ]; then
  echo "泄露扫描: 没有可扫描的文件"
  exit 0
fi

HITS=$(xargs -0 -r grep -n -I -E -e "$P" -- < "$TMP_LIST")
FILES=$(tr '\0' '\n' < "$TMP_LIST" | wc -l | tr -d '[:space:]')

if [ -n "$HITS" ]; then
  echo "泄露扫描: 命中发布红线! ($FILES 个文件)"
  printf '%s\n' "$HITS"
  echo "处理: 删除或泛化上述内容; 私有信息绝不进仓库(见 CONTRIBUTING/README)。"
  exit 1
fi

echo "泄露扫描通过: $FILES 个文件对 ${#PATTERNS[@]} 个发布红线模式零命中。"
exit 0
