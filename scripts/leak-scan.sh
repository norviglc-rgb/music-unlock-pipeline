#!/usr/bin/env bash
# ============================================================================
# leak-scan.sh — 发布红线泄露扫描(自检门禁)
#
# 用途: 扫描本仓库全部文件, 确认不含任何机器私有信息(真实私网地址/路径/
#       用户名/内部代号/密钥材料指纹/示例歌名等)。命中即 exit 1, 零命中 exit 0。
#       CI 中作为发布前置门禁运行(.github/workflows/ci.yml)。
#
# 扫描根: 默认为脚本自身所在仓库的根目录(scripts/ 的上一级), 与调用时的
#       当前工作目录无关; 也可用第一个参数显式指定其他目录。
#
# 实现说明: 出于「门禁脚本自身也必须对这些模式零命中」的自举要求, 全部模式
# 以十六进制转义形式构造($'...' ANSI-C 引号, 每个字节都转义), 源码中不出现
# 任何模式的明文字节。
# 各模式含义(按序): 私网IP前缀 / NAS媒体卷路径 / NAS用户主目录 / NAS系统代号 /
# SSH目标串 / Windows安装器名 / 密钥存储组件名 / 站长GitHub用户名 /
# 内部重下清单目录 / 内部下载工具名 / 内部会员标识 / 安装包哈希前缀 /
# 安装包哈希前缀 / 示例歌名。
# ============================================================================
set -u -o pipefail
export LC_ALL=C

# 14 个发布红线模式(含义见上; 逐字节十六进制转义, 源码零明文)
PATTERNS=(
  $'\x31\x30\x5c\x2e\x30\x5c\x2e\x30\x5c\x2e'                                  # 私网 IP 前缀(正则, 点号转义)
  $'\x2f\x76\x6f\x6c\x31'                                                      # NAS 媒体卷绝对路径
  $'\x2f\x68\x6f\x6d\x65\x2f\x4c\x43'                                          # NAS 用户主目录
  $'\x69\x64\x5f\x66\x6e\x4f\x53'                                              # NAS 系统代号
  $'\x4c\x43\x40\x31\x30'                                                      # SSH 目标串(用户@地址)
  $'\x51\x51\x4d\x75\x73\x69\x63\x5f\x53\x65\x74\x75\x70'                      # 音乐客户端安装器名
  $'\x4d\x4d\x4b\x56\x53\x74\x72\x65\x61\x6d\x45\x6e\x63\x72\x79\x70\x74'      # 密钥存储组件名
  $'\x6e\x6f\x72\x76\x69\x67\x6c\x63'                                          # 站长 GitHub 用户名(发布身份不入文件)
  $'\x72\x65\x64\x6f\x77\x6e\x6c\x6f\x61\x64\x2d\x6c\x69\x73\x74'              # 内部重下清单目录名
  $'\x51\x51\x44\x4c'                                                          # 内部下载工具名
  $'\x53\x56\x49\x50\x37'                                                      # 内部会员标识
  $'\x38\x36\x38\x34\x31\x64\x37\x37'                                          # 安装包/密钥哈希前缀
  $'\x35\x4b\x43\x32\x55\x4c\x47\x51'                                          # 安装包哈希 base32 前缀
  $'\xe3\x83\x9c\xe3\x83\xb3\xe3\x82\xb8\xe3\x83\xa5\xe3\x83\xbc\xe3\x83\xab'  # 示例歌名(不得入库)
)

# 扫描根: 以脚本自身路径推导(scripts/ 的上一级), 不依赖调用时的 cwd
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
if [ -z "$SCRIPT_DIR" ]; then
  echo "无法定位脚本自身目录" >&2
  exit 2
fi
TARGET=${1:-"$SCRIPT_DIR/.."}
cd -- "$TARGET" || { echo "无法进入目录: $TARGET" >&2; exit 2; }

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
