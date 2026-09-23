# PostgreSQL 主从集群巡检脚本（零依赖）

用纯 shell 编写的 PostgreSQL 主从巡检工具，**不需要安装任何依赖**（只用 bash + `df`/`awk`/`sed`/`grep` 等系统自带命令），
只执行只读查询，不写库、不改配置。

**核心用法：在配置文件里填好主库和备库的 IP、账号，执行一条命令即可完成整组主从的巡检。**

## 文件清单

| 文件 | 说明 |
| --- | --- |
| `pg_health_check.sh` | 主巡检脚本（可执行，唯一部署文件） |
| `pg_health_check.conf.example` | 配置样例，复制为 `~/.pg_health_check.conf` 后只改节点 IP 和账号 |
| `tests/mocks/psql` | 测试用 psql 桩（伪数据，不连真实库，生产无需部署） |
| `tests/run_tests.sh` | 自测脚本，46 项用例 |

## 三步上手

```bash
# 1) 放置脚本
mkdir -p /opt/pg-inspect && cp pg_health_check.sh /opt/pg-inspect/ && chmod +x /opt/pg-inspect/pg_health_check.sh

# 2) 生成配置，只改「节点清单 + 账号」
cp pg_health_check.conf.example ~/.pg_health_check.conf
vi ~/.pg_health_check.conf
#   PRIMARY_HOST="10.0.0.11"
#   PRIMARY_PORT="5432"
#   STANDBY_HOSTS="10.0.0.12 10.0.0.13"
#   PGUSER="monitor"
#   PGDATABASE="postgres"

# 3) 一键巡检整组主从
/opt/pg-inspect/pg_health_check.sh
```

口令不要写进配置文件，放到 `~/.pgpass`（权限 600），不同节点密码可以不同：

```
10.0.0.11:5432:*:monitor:pass1
10.0.0.12:5432:*:monitor:pass2
10.0.0.13:5432:*:monitor:pass2
```

### 节点清单写法

`STANDBY_HOSTS` 支持多行、空格、逗号分隔，一台备库一个地址：

```bash
STANDBY_HOSTS="
10.0.0.12                 # 默认端口 = PRIMARY_PORT
10.0.0.13:5433            # 备库单独指定端口
pg4=10.0.0.14:5432        # 别名=host:port，报告里显示 pg4
# 10.0.0.15               # 以 # 注释掉即跳过该节点
"
```

- 只填 `PRIMARY_HOST`、不填备库 → 按"1 主 0 备"巡检，并告警主库上没有备库连接。
- 两个都不填、只用 `-h 10.0.0.11` → 退化为**单节点巡检**（不校验角色），兼容老用法。

### 也可完全用命令行（不写配置文件）

```bash
./pg_health_check.sh --primary 10.0.0.11:5432 --standbys "10.0.0.12,10.0.0.13" -U monitor -d postgres
```

## 巡检内容

### 每个节点都做的 5 项检查

| # | 检查项 | 数据来源 | 默认阈值 |
| --- | --- | --- | --- |
| 1 | 磁盘空间 | `df -P -k`：PGDATA + `pg_tablespace_location()` 返回的每个表空间路径 | warn 80% / crit 90% |
| 2 | CPU | `nproc` + `/proc/loadavg`（负载/核归一化）+ `/proc/stat` 采样忙时占比 | 负载 1.5/3.0 每核；忙时 85%/95% |
| 2 | 内存 | `/proc/meminfo`（优先 `MemAvailable`，含 swap） | 内存 85%/95%；swap 60%/90% |
| 3 | inode | `df -P -i`，与磁盘同一批路径 | warn 80% / crit 90% |
| 4 | 连接数使用率 | `pg_stat_activity` vs `max_connections - superuser_reserved_connections` | warn 80% / crit 90% |
| 5 | 主备延迟 | 主库：`pg_stat_replication`（字节差 + `replay_lag`）；备库：`pg_last_wal_receive_lsn()`/`pg_last_wal_replay_lsn()` + `pg_stat_wal_receiver` | 秒 30/300；字节 16MB/256MB |

### 集群级检查（本次新增）

- **节点角色校验**：配置里写的主库必须不在恢复中（`pg_is_in_recovery()=f`），写的备库必须在恢复中；
  写反或发生主备切换会直接 CRIT。
- **备库连通性交叉核对**：把主库 `pg_stat_replication.client_addr` 与配置里的备库清单比对，
  有备库掉线立即告警（默认 WARN，可用 `REPL_MISSING_STANDBY_LEVEL` 调整，或 `REPL_EXPECT_CONFIGURED=0` 关闭）。

报告结构：先按节点输出明细与「节点小结」，最后给出「集群汇总」（每个节点的结论 + 总退出码）。

## 退出码（便于接监控）

| 退出码 | 含义 |
| --- | --- |
| 0 | 所有节点全部正常 |
| 1 | 至少一个节点存在 WARN |
| 2 | 至少一个节点存在 CRIT（优先级最高） |
| 3 | 存在 UNKNOWN 且无 WARN/CRIT（如 psql 缺失、某节点连不上、权限不足） |

## 定时巡检（crontab）

```cron
# 每小时 5 分巡检整组主从，落到当天日志
5 * * * * /opt/pg-inspect/pg_health_check.sh >> /var/log/pg_inspect/pg_$(date +\%F).log 2>&1
```

Nagios/Icinga/Zabbix 等可直接采集退出码；同时输出人可读文本便于排查。

## 监控账号权限建议

```sql
CREATE ROLE monitor LOGIN PASSWORD '***';
GRANT pg_monitor TO monitor;      -- PG10+，可读全部 pg_stat_* 视图（含 pg_stat_replication）
-- 8.x/9.x 老版本：需要超级用户或相应统计视图权限
```

## 配置优先级

`命令行(--set/-h/--primary/--standbys)` > `环境变量` > `配置文件` > `内置默认值`

例如临时放宽某次巡检的磁盘阈值：

```bash
./pg_health_check.sh --set DISK_WARN=70 --set DISK_CRIT=85 --set REPL_SECS_CRIT=120
```

## 自测

```bash
bash tests/run_tests.sh
```

46 项用例全部使用 `tests/mocks/psql` 桩注入场景，不连真实数据库、不安装依赖，覆盖：

- 单个节点的 5 项检查与各类阈值越限（磁盘/inode/内存/负载/连接数/空闲事务）
- 主备延迟（主库侧、备库侧、WARN/CRIT、无备库、时间戳取不到的老版本）
- 集群模式（配置文件驱动、命令行驱动、别名+端口写法、逐节点连接断言）
- 集群级校验（备库掉线交叉核对、关闭核对、备库角色写反）
- 异常与降级（psql 缺失、连接失败、参数非法、配置文件路径写错）
- 版本分支（PG 9.6 用 `pg_xlog_*`，PG 10+ 用 `pg_wal_*`）

## 实现说明与已知边界

- **数据库不可用时优雅降级**：某节点 psql 连不上时，该节点的磁盘/CPU/内存/inode 仍检查（数据来自巡检机本机）；
  依赖数据库的项记 UNKNOWN 并打印原始错误，其它节点不受影响。
- **磁盘/CPU/内存/inode 是"巡检机视角"**：脚本读的是执行它的那台机器的 `/proc` 和 `df`。
  若脚本跑在跳板机上而非数据库主机上，请把脚本部署到各节点分别执行（或用 `ZABBIX` 类采集），
  只有连接数、主备延迟、PGDATA 路径等是通过数据库连接获取的。
- **版本兼容**：PG 10+ 使用 `pg_current_wal_lsn/pg_wal_lsn_diff/pg_last_wal_*` 与 `replay_lag`；
  PG 9.x 自动切换到 `pg_*_xlog_*` 系列，此时时间延迟不可得（只有字节差），会明确标注。
- **连接数口径**：`count(*)` 含巡检自身这一个连接；有效上限已扣除 `superuser_reserved_connections`。
- **表空间**：对 PGDATA 与所有非默认表空间路径分别检查磁盘与 inode，路径不存在时记 UNKNOWN。
- **临时目录**：`mktemp -d` 失败时回退到当前目录下的 `.pg_health_check_tmp.$$`，退出时自动清理。
