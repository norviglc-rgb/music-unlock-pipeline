# music-unlock-pipeline

对个人音乐库中的加密音频容器（`.ncm` / `.mflac` / `.mgg` 等）做**本地批量解锁、去重与台账管理**的编排脚本集。

**这是什么**：编排层——状态机、幂等调度、原件保护、去重、失败台账、定时任务。生产环境长期运行后标准化开源。

**这不是什么**：不是解锁器。本仓库**不附带、不分发**任何解密密钥、密钥数据库或 DRM 对抗组件；核心解锁能力来自独立第三方开源项目 [unlock-music CLI（`um`）](https://git.unlock-music.dev/um/cli)（MIT），由你自行获取与安装。

> ⚠️ **使用前必读 [DISCLAIMER.md](DISCLAIMER.md)**：本工具仅用于对个人合法取得的音乐文件做本地格式互操作（自建库、自用播放），不用于任何形式的分发或盗版；使用者须遵守当地法律与音乐服务条款，责任自负。

`License MIT` · `Bash 3.2+` · `Python 3` · `Linux（全量）/ macOS（核心路径）` · CI 含发布红线泄露扫描门禁

---

## 功能

- **批量解锁**：多进程并发、单文件超时、失败分类（永久/瞬时）、自动重试有界化
- **幂等**：磁盘事实优先 + `state.jsonl` 台账；`--check-idempotent` 给出机器可判终态（全部处理完 → `pending=0` 退出码 0）
- **原件保护**：manifest 基线自检（size+mtime 变化即退出码 3）；symlink 写穿前置拦截（解锁器根本不启动）；绝不 remove-source
- **symlink 农场**：`_unlocked/` 镜像树 + 把通用音频/歌词链回原目录视角，播放器单根扫全库
- **两层去重**：精确去重（内容哈希一致，五步安全删除流水 + 回收目录 + 删除日志）；近似重复只出报告零删除
- **台账与审计**：失败台账聚合、状态统计、产物全量 ffprobe 审计、冲突日志
- **运维友好**：追加式 crontab 安装器（绝不重置）、主锁防重入、日志自动轮转、磁盘余量闸

## 依赖

| 依赖 | 用途 | 说明 |
|---|---|---|
| bash ≥ 3.2 | 主流水线 | 无 bash4 特性依赖 |
| python3 | 状态序列化/枚举/去重消费 | 系统自带即可 |
| ffmpeg / ffprobe | 产物校验、近似重复采集 | 必备 |
| [unlock-music CLI (`um`)](#获取-unlock-music-um) | 实际解锁 | **用户自备**，路径可配置 |
| rmlint（可选） | 精确去重扫描 | 仅 `dedup-exact.sh` 需要 |
| flock（可选） | 主锁/台账锁 | 缺失时自动用 mkdir 原子性兜底 |

## 获取 unlock-music (um)

只从官方渠道获取，下载后**自行校验来源与哈希**：

1. **官方 release 页**（浏览器访问）：<https://git.unlock-music.dev/um/cli/releases/latest>
   —— 该站点有访问防护，命令行直连可能被拦截，属正常现象；用浏览器下载即可。
2. **Go 安装**（需 Go ≥ 1.23）：`go install unlock-music.dev/cli/cmd/um@master`

注意：GitHub 上的历史镜像已因权利人投诉整体下架，本仓库不提供其链接，也**不建议**从不明镜像获取。um 为 MIT 许可（版权归 Unlock Music / MengYX / Unlock-Music Team），本项目与其无隶属关系。

安装后任选其一让流水线找到它：`--um-path <路径>`、环境变量 `UM_BIN=<路径>`，或放入 `PATH`。

## 快速开始

```bash
# 0) 准备一个音乐库根目录(下面假设 ./Music, 加密原件在库里, 本工具对其只读)
mkdir -p Music

# 1) 指定解锁器位置(三选一)
export UM_BIN=/path/to/um          # 或每次加 --um-path /path/to/um

# 小盘机器注: 可用空间不足默认阈值(500G)时, --auto/--limit 会拒绝新转换、
# 只做同步与自检后正常退出(输出里有 pending=N)。先把阈值调小再跑:
# export MIN_FREE_GB=10

# 2) 空库自检: 机器可判终态
bash bin/music-convert.sh --music-root ./Music --check-idempotent
# => total=0 done=0 permanent_skip=0 pending=0   (退出码 0)

# 3) 放入几个加密文件后, 先小样本试跑(三格式轮转取 3 个)
bash bin/music-convert.sh --music-root ./Music --limit 3

# 4) 试跑没问题后全量增量转换(含 symlink 镜像 + manifest 自检 + 幂等复核)
bash bin/music-convert.sh --music-root ./Music --auto

# 5) 幂等终验
bash bin/music-convert.sh --music-root ./Music --check-idempotent
# => 全部处理完(含永久跳过)时: pending=0, 退出码 0

# 6) 精确去重: 先干跑看报告, 确认后再真删
bash bin/dedup-exact.sh --music-root ./Music --dry-run
bash bin/dedup-exact.sh --music-root ./Music --auto

# 7) 近似重复报告(零删除, 人工裁决)
python3 scripts/near-dup.py --music-root ./Music
```

状态/日志/报告默认写在 `<music-root>/.pipeline/{state,logs,reports}/`——一库一份状态，多库互不干扰。

## English Quick Start

```bash
# Unlock capability comes from unlock-music CLI ("um", MIT) — get it yourself:
#   browser: https://git.unlock-music.dev/um/cli/releases/latest
#   or:      go install unlock-music.dev/cli/cmd/um@master

export UM_BIN=/path/to/um                 # or pass --um-path, or put um on PATH

# Small-disk note: with less free space than the default gate (500G), --auto/--limit
# refuse new conversions and exit normally (pending=N in output). Lower it first:
# export MIN_FREE_GB=10

mkdir -p Music                            # your music library root (treated read-only)

# Machine-checkable idempotence probe (empty library):
bash bin/music-convert.sh --music-root ./Music --check-idempotent   # => pending=0, exit 0

# Drop some .ncm/.mflac/.mgg files in, then:
bash bin/music-convert.sh --music-root ./Music --limit 3   # small sample
bash bin/music-convert.sh --music-root ./Music --auto      # full incremental run
bash bin/music-convert.sh --music-root ./Music --check-idempotent   # => pending=0 when done

bash bin/dedup-exact.sh --music-root ./Music --dry-run     # exact dedup, report only
python3 scripts/near-dup.py --music-root ./Music           # near-dup report, zero deletion
```

State, logs and reports live under `<music-root>/.pipeline/`. CLI options take precedence over environment variables, which take precedence over defaults. **Read [DISCLAIMER.md](DISCLAIMER.md) before use** — local, personal, non-distributive use only; you must comply with local law and your music service's terms.

## 配置参考

### 环境变量（CLI 选项优先）

| 变量 | 默认 | 说明 |
|---|---|---|
| `MUSIC_ROOT` | `./Music` | 音乐库根（同 `--music-root`） |
| `PIPELINE_HOME` | `<music-root>/.pipeline` | 状态/日志/报告根目录 |
| `UM_BIN` | 从 `PATH` 查找 `um` | 解锁器路径（同 `--um-path`） |
| `TRASH_ROOT` | `<music-root>/.mc-trash` | 去重回收目录 |
| `DEDUP_KEEPER_PREFIXES` | 空 | 保留优先的相对目录前缀（冒号分隔，靠前优先；其余按「更浅优先、字节序定序」） |
| `UPDATE_METADATA` | `0` | `1` 时透传 um `--update-metadata`，失败自动降级纯解密重试 |
| `EXTRA_UM_ARGS` | 空 | 额外 um 参数（空格分词；路径含空格不支持） |
| `UM_PARALLEL` | `4` | 并发 worker 数 |
| `UM_TIMEOUT` | `600` | 单文件超时（秒；超时归为瞬时失败可重试） |
| `MIN_FREE_GB` | `500` | 可用空间（GiB）低于该值时拒绝新转换（本轮任务列表置空并提示，随后的 `--auto` 正常退出 0） |

### music-convert.sh 动作一览

`--auto`（全量增量）· `--limit N`（小样本轮转抽样）· `--pilot [N]`（每格式前 N 个）· `--include <file>`（NUL 分隔明细）· `--worker <rel>`（内部单文件）· `--check-idempotent`（幂等终态）· `--sync-symlinks` / `--unlink-symlinks`（镜像农场）· `--refresh-failed`（重置永久失败）· `--manifest-init` / `--manifest-check`（原件保护基线）· `--audit`（产物 ffprobe 全检）

完整帮助：`bash bin/music-convert.sh --help`；退出码语义：`0` 成功 / `1` 用法错误或 `pending>0`（后者仅 `--check-idempotent`；`--auto`/`--limit`/`--pilot`/`--include` 等转换动作在仍有 pending 源时同样正常退出 0，终态以 `--check-idempotent` 复核为准）/ `2` 主锁占用 / `3` 原件保护自检失败 / `4` 缺 um。

## 定时任务

```bash
# 先编辑 examples/crontab.txt 替换为你的实际路径, 然后:
bash bin/install-cron.sh examples/crontab.txt
```

安装器是**追加式**的：备份当前 crontab → 已存在的行跳过 → 追加缺失行 → 校验旧行完好且新行在位。绝不重置 crontab。脚本自带 cron 日志 >20MB 三代轮转。

## 已知限制

- **解锁能力边界**：能否解锁取决于文件内是否仍内嵌密钥。新版客户端把密钥移入本地密钥库的文件，任何编排层都无能为力（`--qmc-mmkv` 只是把你自有的密钥库透传给 um，不改变这个事实）。
- **near-dup.py 分组依赖元数据**：标题/歌手取 ffprobe 标签；两者皆缺时回落「`歌手 - 标题.扩展名`」文件名约定，再缺就无法参与分组。
- **`EXTRA_UM_ARGS` 不支持含空格的路径**（空格分词）；需要时可给该路径建无空格的符号链接。
- **rmlint 仅 Linux/macOS**；全量流水线以 Linux 为一等公民，macOS 可运行核心路径（本仓库 CI 与本地烟测均在可移植回退路径上验证）。

## FAQ

**Q: `--check-idempotent` 退出码 1？**
看输出的 `pending:` 列表。若是 `failed_permanent` 计入 `permanent_skip` 属正常（永久跳过不算 pending）；确需重试永久失败：`--refresh-failed` 后再 `--auto`。

**Q: 提示"未找到解锁器 um"？**
按提示三选一：`--um-path`、`UM_BIN`、装进 PATH。获取方式见上文。

**Q: 会动我的原文件吗？**
设计目标就是不会：原件树只读，manifest 每次自检 size+mtime（变化即退出码 3），解锁器永远收不到 remove-source，输出只写 `_unlocked/`。发现候选输出位是 symlink 时直接拒写并留冲突日志。

**Q: 去重会不会误删？**
精确去重五步流水（state 反查 → 日志先行 → 原子 mv 进回收目录 → 复核保留份哈希 → 才删副本），只删 `_unlocked/` 内登记在案的产物；先用 `--dry-run` 看报告。

**Q: 多个音乐库？**
每库用各自的 `--music-root`，状态天然隔离（各库自己的 `.pipeline/`）。

## 致谢

- [unlock-music](https://git.unlock-music.dev/um/cli)（CLI `um`）与 [um-react](https://git.um-react.app/um/um-react)——MIT 许可，版权归 Unlock Music / MengYX / Unlock-Music Team 所有。本仓库与其无隶属关系，不修改、不再分发其任何代码或二进制。
- rmlint、ffmpeg 项目。

## License 与第三方声明

本项目以 [MIT](LICENSE) 许可发布（编排脚本本身）。第三方项目 unlock-music 为独立项目、MIT 许可，由用户自行获取；详见 [LICENSE](LICENSE) 末尾的第三方声明与 [DISCLAIMER.md](DISCLAIMER.md)。
