# Changelog

本项目的所有显著变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本遵循语义化版本。

## [1.0.0] - 2026-09-24

首个公开发布版本。由长期在私有 NAS 上运行的内部流水线标准化而来。

### 新增
- `bin/music-convert.sh`：主流水线（加密容器解锁、状态机、幂等检查、原件保护 manifest、symlink 镜像农场、产物审计）。
- `bin/dedup-exact.sh`：`_unlocked/` 产物精确去重（内容哈希一致；五步安全删除流水，零误删设计）。
- `scripts/near-dup.py`：近似重复**报告**（零删除，人工裁决）。
- `scripts/fail-summary.py` / `scripts/stats-state.py`：失败台账聚合与状态统计。
- `bin/install-cron.sh`：追加式（绝不重置）crontab 安装器，含追加前后完整性校验。
- `scripts/leak-scan.sh`：发布红线泄露扫描门禁（14 类私有信息模式零命中才放行）。
- `docs/lessons.md`：工程经验与踩坑实录。

### CLI 契约（相对内部版的标准化）
- `--help`：列出全部参数，退出码 0。
- `--music-root <dir>`：音乐库根可配置，默认 `./Music`（内部版为写死的机器路径）。
- `--um-path <path>` / `UM_BIN`：解锁器路径可配置，缺省从 `PATH` 查找，缺失时给出明确指引。
- `--qmc-mmkv <path>`：密钥库通道落实为真实参数（内部版仅有注释与 `EXTRA_UM_ARGS` 间接通道）。

### 变更
- 所有状态/日志/报告默认收敛到 `<music-root>/.pipeline/`，一库一份状态。
- `state.jsonl` 的 `out_path`/`kept_path` 由绝对路径改为相对音乐库根的路径（可移植）。
- keeper 保留优先级由私有目录名硬编码改为 `DEDUP_KEEPER_PREFIXES` 配置 + 通用「更浅优先、字节序定序」。
- 去重/反查改为 JSON 字段精确比较（修复含引号/反斜杠文件名的失配）。
- 依赖面可移植：GNU `find -printf`/`stat -c`/`timeout`/`flock`/`tac` 均有 POSIX 或运行时探测的回退实现（bash 3.2+ 可运行）。

### 移除
- 全部机器私有路径、内部任务校验、私有统计注释与内部抽样启发式（详见 docs/lessons.md）。
