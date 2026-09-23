#!/usr/bin/env bash
# =============================================================================
#  pg_health_check.sh — PostgreSQL 主从集群一键巡检脚本
#
#  依赖：bash(>=4) + coreutils(df/awk/sed/grep/date) + psql 客户端
#        不安装任何第三方依赖；只执行只读查询，不写数据库、不改配置。
#
#  用法（集群模式，推荐）：
#    1) 复制配置样例并只填 IP/用户：cp pg_health_check.conf.example ~/.pg_health_check.conf
#       PRIMARY_HOST="10.0.0.11"
#       STANDBY_HOSTS="10.0.0.12 10.0.0.13"
#       PGUSER="monitor"  PGDATABASE="postgres"
#    2) 执行： ./pg_health_check.sh
#       脚本会自动连接主库与全部备库，逐个节点完成 5 项巡检。
#
#  单节点模式（兼容）：只给 -h/--host 一个地址时，仅巡检该节点。
#
#  每个节点检查项：
#    1. 磁盘空间    PGDATA + 各表空间所在文件系统
#    2. CPU / 内存  负载(按核归一化) + /proc/stat 使用率 + MemAvailable
#    3. inode       PGDATA + 表空间挂载点 inode 使用率
#    4. 连接数      pg_stat_activity vs max_connections - superuser_reserved
#    5. 主备延迟    主库 pg_stat_replication / 备库 pg_last_wal_* + wal receiver
#
#  集群级检查：
#    - 节点角色校验（主库必须不在恢复中，备库必须在恢复中）
#    - 主库 pg_stat_replication 与配置文件中的备库清单交叉核对（是否有备库掉线）
#
#  退出码（便于接监控/告警）：0=OK  1=WARN  2=CRIT  3=UNKNOWN
#
#  配置优先级：命令行 > 环境变量 > 配置文件 > 内置默认值
# =============================================================================

set -u
set -o pipefail

SCRIPT_VERSION="2.0.0"

# ------------------------------------------------------------------ 全局状态 --
N_OK=0; N_WARN=0; N_CRIT=0; N_UNKNOWN=0; WORST=0     # 集群合计
P_OK=0; P_WARN=0; P_CRIT=0; P_UNK=0; P_WORST=0       # 当前节点
DB_OK=0; DB_ERR=""; DB_VER_NUM=999999; ACTUAL_ROLE="unknown"
NODE_EXPECT_ROLE="auto"
PSQL_BIN=""; TIMEOUT_BIN=""; TMP_DIR=""; PG_ERR_FILE=""
GLOBAL_PGHOST=""; GLOBAL_PGPORT=""
MODE="single"
CONFIGURED_STANDBY_HOSTS=""
CONFIGURED_STANDBY_COUNT=0
STANDBY_LIST=""
ADDR_LIST=""

NODE_LABELS=(); NODE_HOSTS=(); NODE_PORTS=(); NODE_ROLES=()
NODE_RESULTS=()
DISK_LABELS=(); DISK_PATHS=(); DISK_MISSING=()
ENV_KEYS=(); ENV_VALS=()
LATE_LEVELS=(); LATE_NAMES=(); LATE_MSGS=()

# 允许通过环境变量/配置文件/--set 覆盖的全部配置项
KNOWN_VARS="
PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD PGDATA PGCONNECT_TIMEOUT
PGHC_ROLE PGHC_CONF PGHC_TIMEOUT PSQL_BIN
PRIMARY_HOST PRIMARY_PORT STANDBY_HOSTS
DISK_WARN DISK_CRIT INODE_WARN INODE_CRIT EXTRA_DISK_PATHS
CPU_WARN CPU_CRIT LOAD_WARN_PER_CORE LOAD_CRIT_PER_CORE CPU_SAMPLE
MEM_WARN MEM_CRIT SWAP_WARN SWAP_CRIT
CONN_WARN CONN_CRIT IDLE_IN_XACT_WARN
REPL_SECS_WARN REPL_SECS_CRIT REPL_BYTES_WARN REPL_BYTES_CRIT
REPL_MIN_STANDBYS REPL_NO_STANDBY_LEVEL
REPL_EXPECT_CONFIGURED REPL_MISSING_STANDBY_LEVEL
COLOR
"
# 压平成单行，用于 --set 的配置项白名单匹配
KNOWN_VARS_FLAT=$(printf '%s' "$KNOWN_VARS" | tr '\n' ' ')

# ============================================================ 一、配置处理 ==
snapshot_env() {
    ENV_KEYS=(); ENV_VALS=()
    local v i=0
    for v in $KNOWN_VARS; do
        if [ -n "${!v+set}" ]; then
            ENV_KEYS[$i]="$v"
            ENV_VALS[$i]="${!v}"
            i=$((i + 1))
        fi
    done
}

assign_defaults() {
    # --- 连接参数（备库/单节点共用；密码建议放 ~/.pgpass） ---
    PGHOST=""
    PGPORT=""
    PGUSER=""
    PGDATABASE=""
    PGPASSWORD=""
    PGDATA=""
    PGCONNECT_TIMEOUT="5"
    PSQL_BIN=""

    # --- 主从节点清单（集群模式的核心配置） ---
    PRIMARY_HOST=""                  # 主库地址
    PRIMARY_PORT=""                  # 主库端口（空=PGPORT/5432）
    STANDBY_HOSTS=""                 # 备库清单：空格/换行/逗号分隔，支持 host、host:port、别名=host:port

    PGHC_ROLE="auto"                 # cluster: 强制主库期望角色; single: 本节点期望角色
    PGHC_CONF="${HOME:-/root}/.pg_health_check.conf"
    PGHC_TIMEOUT="15"                # 单条 psql 命令超时(秒)

    # --- 磁盘 / inode 阈值(%) ---
    DISK_WARN="80";  DISK_CRIT="90"
    INODE_WARN="80"; INODE_CRIT="90"
    EXTRA_DISK_PATHS=""              # 额外巡检路径，空格分隔

    # --- CPU / 内存阈值 ---
    CPU_WARN="85";   CPU_CRIT="95"                 # /proc/stat 忙时占比(%)
    LOAD_WARN_PER_CORE="1.5"                       # 1 分钟负载 / 核数
    LOAD_CRIT_PER_CORE="3.0"
    CPU_SAMPLE="1"                                 # CPU 采样秒数, 0=不采样
    MEM_WARN="85";   MEM_CRIT="95"
    SWAP_WARN="60";  SWAP_CRIT="90"

    # --- 连接数阈值(%) ---
    CONN_WARN="80";  CONN_CRIT="90"
    IDLE_IN_XACT_WARN="10"                         # idle in transaction 个数告警线

    # --- 主备延迟阈值 ---
    REPL_SECS_WARN="30";   REPL_SECS_CRIT="300"                 # 秒
    REPL_BYTES_WARN="16777216"; REPL_BYTES_CRIT="268435456"     # 字节(16MB/256MB)
    REPL_MIN_STANDBYS="1"                                       # 主库最少备库数
    REPL_NO_STANDBY_LEVEL="CRIT"                                # 不满足时的级别
    REPL_EXPECT_CONFIGURED="1"                                  # 1=核对配置的备库是否都已连上主库
    REPL_MISSING_STANDBY_LEVEL="WARN"                           # 有备库未连上主库时的级别

    COLOR="1"
}

load_conf_file() {
    [ -n "${CONF_FILE:-}" ] || return 0
    if [ ! -r "$CONF_FILE" ]; then
        # 显式指定的配置文件不存在时不能静默降级，否则会误报“巡检正常”
        if [ "${CONF_REQUIRED:-0}" = "1" ]; then
            add_late UNKNOWN "配置" "指定的配置文件不存在或不可读: $CONF_FILE（请检查路径，或用 --no-conf 明确不使用配置文件）"
        fi
        return 0
    fi
    # shellcheck disable=SC1090
    if ! . "$CONF_FILE"; then
        add_late WARN "配置" "配置文件执行出错，已忽略其中的部分配置: $CONF_FILE"
    fi
    return 0
}

apply_env_overrides() {
    local i=0 n="${#ENV_KEYS[@]}"
    while [ "$i" -lt "$n" ]; do
        printf -v "${ENV_KEYS[$i]}" '%s' "${ENV_VALS[$i]}"
        i=$((i + 1))
    done
}

apply_set() {
    local kv="$1" k="${1%%=*}" v="${1#*=}"
    case " $KNOWN_VARS_FLAT " in
        *" $k "*) ;;
        *) printf '未知配置项: %s\n' "$k" >&2; exit 3 ;;
    esac
    [ "$k" != "$kv" ] || { printf -- '--set 需要 VAR=VALUE 形式: %s\n' "$kv" >&2; exit 3; }
    printf -v "$k" '%s' "$v"
}

# 只做一遍预扫描，确定配置文件路径（配置文件里的其它项由 load_conf_file 载入）
pre_parse_conf() {
    CONF_REQUIRED=0
    # 环境变量里显式指定了配置路径时，缺失即报错
    [ -n "${PGHC_CONF:-}" ] && CONF_REQUIRED=1
    CONF_FILE="${PGHC_CONF:-${HOME:-/root}/.pg_health_check.conf}"
    local arg prev=""
    for arg in "$@"; do
        case "$arg" in
            --no-conf) CONF_FILE=""; CONF_REQUIRED=0 ;;
            --conf=*)  CONF_FILE="${arg#--conf=}"; CONF_REQUIRED=1 ;;
        esac
    done
    for arg in "$@"; do
        [ "$prev" = "--conf" ] && { CONF_FILE="$arg"; CONF_REQUIRED=1; }
        prev="$arg"
    done
}

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

【集群模式】在配置文件里填好主库与备库 IP 后直接执行，无需任何参数：
  PRIMARY_HOST="10.0.0.11"
  PRIMARY_PORT="5432"
  STANDBY_HOSTS="10.0.0.12 10.0.0.13"      # 空格/换行/逗号分隔，可为 host 或 host:port
  PGUSER="monitor"   PGDATABASE="postgres"
然后:  $(basename "$0")

【单节点模式】只给一个地址时，仅巡检该节点：
  $(basename "$0") -h 10.0.0.11 -U monitor -d postgres

连接与节点选项:
  -h, --host HOST        单节点巡检地址；集群模式下作为主库地址的临时覆盖
  -p, --port PORT        端口
  -U, --user USER        用户名（所有节点共用，建议配合 ~/.pgpass 使用不同密码）
  -d, --dbname DB        库名
      --primary HOST[:PORT]    集群模式主库地址（等价配置 PRIMARY_HOST）
      --standbys "H1,H2:H2P"   集群模式备库清单（等价配置 STANDBY_HOSTS）
  -r, --role ROLE        auto|primary|standby（单节点=期望角色；集群=主库期望角色）
      --conf FILE        指定配置文件
      --no-conf          不读任何配置文件
      --set VAR=VALUE    覆盖任意配置项（可重复，优先级最高）
      --cpu-sample N     CPU 采样秒数，0 表示不采样（默认 1）
      --no-color         关闭彩色输出
  -V, --version          打印版本
      --help             显示本帮助

常用配置项(可用 --set/环境变量/配置文件设置):
  节点   PRIMARY_HOST PRIMARY_PORT STANDBY_HOSTS PGUSER PGDATABASE PGPASSWORD
  磁盘   DISK_WARN DISK_CRIT INODE_WARN INODE_CRIT EXTRA_DISK_PATHS
  CPU    CPU_WARN CPU_CRIT LOAD_WARN_PER_CORE LOAD_CRIT_PER_CORE CPU_SAMPLE
  内存   MEM_WARN MEM_CRIT SWAP_WARN SWAP_CRIT
  连接数 CONN_WARN CONN_CRIT IDLE_IN_XACT_WARN
  主备   REPL_SECS_WARN REPL_SECS_CRIT REPL_BYTES_WARN REPL_BYTES_CRIT
         REPL_MIN_STANDBYS REPL_NO_STANDBY_LEVEL
         REPL_EXPECT_CONFIGURED REPL_MISSING_STANDBY_LEVEL

示例:
  # 一键巡检整组主从（读 ~/.pg_health_check.conf）
  ./pg_health_check.sh
  # 临时指定一组节点并放宽磁盘阈值
  ./pg_health_check.sh --primary 10.0.0.11:5432 --standbys "10.0.0.12,10.0.0.13" \\
                       --set DISK_WARN=70 --set DISK_CRIT=85

退出码: 0=OK 1=WARN 2=CRIT 3=UNKNOWN
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--host)     PGHOST="${2:-}"; shift 2 ;;
            -p|--port)     PGPORT="${2:-}"; shift 2 ;;
            -U|--user)     PGUSER="${2:-}"; shift 2 ;;
            -d|--dbname|--database) PGDATABASE="${2:-}"; shift 2 ;;
            --primary)     PRIMARY_HOST="${2:-}"; shift 2 ;;
            --primary=*)   PRIMARY_HOST="${1#--primary=}"; shift ;;
            --standbys|--standby) STANDBY_HOSTS="${2:-}"; shift 2 ;;
            --standbys=*)  STANDBY_HOSTS="${1#--standbys=}"; shift ;;
            -r|--role)     PGHC_ROLE="${2:-}"; shift 2 ;;
            --conf)        shift 2 ;;
            --no-conf)     shift ;;
            --set)         apply_set "${2:-}"; shift 2 ;;
            --pgdata)      PGDATA="${2:-}"; shift 2 ;;
            --cpu-sample)  CPU_SAMPLE="${2:-}"; shift 2 ;;
            --no-color)    COLOR="0"; shift ;;
            -V|--version)  printf 'pg_health_check.sh %s\n' "$SCRIPT_VERSION"; exit 0 ;;
            --help|-?)     usage; exit 0 ;;
            *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 3 ;;
        esac
    done
    case "$PGHC_ROLE" in
        auto|primary|standby) ;;
        *) printf '角色参数非法: %s (应为 auto|primary|standby)\n' "$PGHC_ROLE" >&2; exit 3 ;;
    esac
}

# ============================================================ 二、节点清单 ==
add_node() {
    NODE_LABELS+=("$1"); NODE_HOSTS+=("$2"); NODE_PORTS+=("$3"); NODE_ROLES+=("$4")
}

add_late() {  # 头部打印后再输出的配置告警/错误
    LATE_LEVELS+=("$1"); LATE_NAMES+=("$2"); LATE_MSGS+=("$3")
}

# 解析单个节点描述：host | host:port | [v6]:port | 别名=host:port
parse_node_spec() {
    local spec="$1" defport="$2" label="" hp host="" port=""
    hp="$spec"
    case "$hp" in
        *=*) label="${hp%%=*}"; hp="${hp#*=}" ;;
    esac
    case "$hp" in
        \[*\]:*)  host="${hp%%]*}"; host="${host#\[}"; port="${hp##*:}" ;;
        \[*\])    host="${hp#\[}"; host="${host%\]}" ;;
        *:*:*)    host="$hp" ;;                      # 纯 IPv6，无端口
        *:[0-9]*) host="${hp%:*}"; port="${hp##*:}" ;;
        *)        host="$hp" ;;
    esac
    PARSED_LABEL="$label"; PARSED_HOST="$host"; PARSED_PORT="${port:-$defport}"
}

build_node_list() {
    NODE_LABELS=(); NODE_HOSTS=(); NODE_PORTS=(); NODE_ROLES=()
    CONFIGURED_STANDBY_HOSTS=""
    CONFIGURED_STANDBY_COUNT=0

    # 备库清单：配置文件 + 命令行，去注释、逗号/分号转空格
    local raw="$STANDBY_HOSTS"
    [ -n "${PGHC_STANDBYS:-}" ] && raw="$raw $PGHC_STANDBYS"
    STANDBY_LIST=$(printf '%s\n' "$raw" | sed 's/#.*//' | tr ',;' '  ')

    local cluster_requested=0
    [ -n "${PRIMARY_HOST:-}" ] && cluster_requested=1
    [ -n "${STANDBY_LIST// /}" ] && cluster_requested=1

    if [ "$cluster_requested" = "0" ]; then
        # 单节点模式：只巡检 -h/PGHOST 指定的一个节点
        MODE="single"
        add_node "single" "${PGHOST:-}" "${PGPORT:-}" "$PGHC_ROLE"
        return 0
    fi

    MODE="cluster"

    # 主库：命令行 -h 可临时覆盖配置文件里的 PRIMARY_HOST
    local primary="${PGHOST:-${PRIMARY_HOST:-}}"
    local primary_port=""
    if [ -n "${PGHOST:-}" ]; then
        primary_port="${PGPORT:-${PRIMARY_PORT:-}}"
    else
        primary_port="${PRIMARY_PORT:-${PGPORT:-}}"
    fi

    local prole="primary"
    [ "$PGHC_ROLE" != "auto" ] && prole="$PGHC_ROLE"
    if [ -n "$primary" ]; then
        add_node "primary" "$primary" "${primary_port:-$GLOBAL_PGPORT}" "$prole"
    else
        add_late UNKNOWN "节点配置" "未配置主库地址 PRIMARY_HOST，本次仅巡检备库"
    fi

    # 备库未显式写端口时，依次继承 PGPORT、主库端口
    local standby_default_port="${GLOBAL_PGPORT:-$primary_port}"

    local spec
    for spec in $STANDBY_LIST; do
        [ -n "$spec" ] || continue
        parse_node_spec "$spec" "$standby_default_port"
        if [ -z "$PARSED_HOST" ]; then
            add_late UNKNOWN "节点配置" "备库配置项无法解析: $spec"
            continue
        fi
        add_node "${PARSED_LABEL:-standby}" "$PARSED_HOST" "$PARSED_PORT" "standby"
        CONFIGURED_STANDBY_HOSTS="$CONFIGURED_STANDBY_HOSTS $PARSED_HOST"
        CONFIGURED_STANDBY_COUNT=$((CONFIGURED_STANDBY_COUNT + 1))
    done

    if [ "${#NODE_HOSTS[@]}" -eq 0 ]; then
        add_late UNKNOWN "节点配置" "节点清单为空，请检查 PRIMARY_HOST / STANDBY_HOSTS 配置"
    fi
}

# ========================================================== 三、通用工具函数 ==
C_RESET=''; C_OK=''; C_WARN=''; C_CRIT=''; C_UNK=''
init_color() {
    if [ "$COLOR" = "1" ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
        C_CRIT=$'\033[31m'; C_UNK=$'\033[36m'
    fi
}

init_tmp() {
    TMP_DIR=$(mktemp -d 2>/dev/null) || TMP_DIR=""
    if [ -z "$TMP_DIR" ]; then
        TMP_DIR="$(pwd)/.pg_health_check_tmp.$$"
        mkdir -p "$TMP_DIR" 2>/dev/null || TMP_DIR=""
    fi
    if [ -z "$TMP_DIR" ]; then
        printf '无法创建临时目录，退出\n' >&2
        exit 3
    fi
    PG_ERR_FILE="$TMP_DIR/psql.err"
    trap 'rm -rf "$TMP_DIR"' EXIT
}

norm_level() {
    case "${1:-}" in
        OK|WARN|CRIT|UNKNOWN) printf '%s' "$1" ;;
        *) printf 'CRIT' ;;
    esac
}

rank_level() {
    case "$1" in
        OK) echo 0 ;;
        CRIT) echo 2 ;;
        *) echo 1 ;;   # WARN / UNKNOWN
    esac
}

worse() {
    local a="$1" b="$2"
    if [ "$(rank_level "$a")" -ge "$(rank_level "$b")" ]; then echo "$a"; else echo "$b"; fi
}

record() {
    local lvl name msg color=""
    lvl=$(norm_level "$1"); name="$2"; msg="$3"
    case "$lvl" in
        OK)      N_OK=$((N_OK + 1)); P_OK=$((P_OK + 1)); color="$C_OK" ;;
        WARN)    N_WARN=$((N_WARN + 1)); P_WARN=$((P_WARN + 1))
                 [ "$P_WORST" -lt 1 ] && P_WORST=1
                 [ "$WORST" -lt 1 ] && WORST=1; color="$C_WARN" ;;
        CRIT)    N_CRIT=$((N_CRIT + 1)); P_CRIT=$((P_CRIT + 1)); P_WORST=2; WORST=2; color="$C_CRIT" ;;
        UNKNOWN) N_UNKNOWN=$((N_UNKNOWN + 1)); P_UNK=$((P_UNK + 1)); color="$C_UNK" ;;
    esac
    printf '%s[%-7s]%s %-12s %s\n' "$color" "$lvl" "$C_RESET" "$name" "$msg"
}

node_level() {
    if [ "$P_CRIT" -gt 0 ]; then echo "CRIT"
    elif [ "$P_WARN" -gt 0 ]; then echo "WARN"
    elif [ "$P_UNK" -gt 0 ]; then echo "UNKNOWN"
    else echo "OK"
    fi
}

# 数值/百分比工具（全部走 awk，避免引入 bc/依赖）
is_num() { case "${1:-}" in ''|*[!0-9.\-]*) return 1 ;; *) return 0 ;; esac; }

# 是否为非负数值（用于识别 -1 这类"取不到"的哨兵值）
is_ge0() { awk -v v="${1:-}" 'BEGIN{ exit !(v+0 >= 0) }'; }

pct() {  # $1 已用 $2 总量 -> 百分比
    awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0 <= 0) { print "0.0"; exit } printf "%.1f", (a/b)*100 }'
}

grade_high() {  # $1 值 $2 warn $3 crit（越大越差）
    awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN{
        if (v+0 >= c+0) print "CRIT"; else if (v+0 >= w+0) print "WARN"; else print "OK"
    }'
}

human_kb() {  # 输入 KB
    awk -v k="$1" 'BEGIN{ split("KB MB GB TB PB",u," "); i=1; v=k+0;
        while (v >= 1024 && i < 5) { v /= 1024; i++ } printf "%.1f%s", v, u[i] }'
}

human_bytes() {
    awk -v b="$1" 'BEGIN{ split("B KB MB GB TB PB",u," "); i=1; v=b+0;
        while (v >= 1024 && i < 6) { v /= 1024; i++ } printf "%.1f%s", v, u[i] }'
}

first_line() { head -n 1 "$1" 2>/dev/null | tr -d '\r'; }

# ============================================================ 四、数据库访问 ==
export_credentials() {
    export PGUSER PGDATABASE PGPASSWORD PGCONNECT_TIMEOUT
    return 0
}

resolve_psql() {
    if [ -n "$PSQL_BIN" ]; then
        [ -x "$PSQL_BIN" ] || { PSQL_BIN=""; }
    else
        PSQL_BIN=$(command -v psql 2>/dev/null || true)
    fi
    TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)
}

run_psql() {
    local sql="$1"
    local -a cmd=()
    [ -n "$TIMEOUT_BIN" ] && [ -n "$PGHC_TIMEOUT" ] && cmd+=("$TIMEOUT_BIN" "$PGHC_TIMEOUT")
    cmd+=("$PSQL_BIN" -X -q -A -t -F '|' -v ON_ERROR_STOP=1)
    [ -n "${PGHOST:-}" ] && cmd+=(-h "$PGHOST")
    [ -n "${PGPORT:-}" ] && cmd+=(-p "$PGPORT")
    [ -n "${PGUSER:-}" ] && cmd+=(-U "$PGUSER")
    [ -n "${PGDATABASE:-}" ] && cmd+=(-d "$PGDATABASE")
    cmd+=(-c "$sql")
    "${cmd[@]}"
}

# 硬查询：失败由调用方处理（错误信息在 $PG_ERR_FILE）
pg_query() { run_psql "$1" 2>"$PG_ERR_FILE"; }
# 软查询：失败返回空（用于可选信息，如权限不足的统计视图）
pg_query_soft() { run_psql "$1" 2>/dev/null || true; }

probe_db() {
    local out
    if [ -z "$PSQL_BIN" ]; then
        DB_ERR="未找到 psql 客户端（请把 psql 加入 PATH 或用 --set PSQL_BIN=/path/to/psql）"
        return 1
    fi
    out=$(run_psql "SELECT 1" 2>"$PG_ERR_FILE")
    if [ $? -ne 0 ] || [ "$(printf '%s' "$out" | tr -d '[:space:]')" != "1" ]; then
        DB_ERR=$(first_line "$PG_ERR_FILE")
        [ -n "$DB_ERR" ] || DB_ERR="无法连接数据库或查询无返回"
        return 1
    fi
    DB_OK=1
    return 0
}

get_version_num() {
    local v rc
    v=$(run_psql "SHOW server_version_num" 2>"$PG_ERR_FILE"); rc=$?
    if [ $rc -ne 0 ]; then
        # 老版本/受限场景回退到 SHOW server_version 解析
        v=$(run_psql "SHOW server_version" 2>/dev/null || true)
        case "$v" in
            "") echo 999999 ;;
            *)  awk -v s="$v" 'BEGIN{
                    split(s, a, "."); maj=a[1]+0; min=(a[2]==""?0:a[2]+0);
                    if (maj >= 10) printf "%d", maj*10000; else printf "%d", maj*10000+min*100
                }' ;;
        esac
        return 0
    fi
    case "$v" in
        ''|*[!0-9]*) echo 999999 ;;
        *) echo "$v" ;;
    esac
}

# ============================================================== 五、各项检查 ==
collect_disk_targets() {
    DISK_LABELS=(); DISK_PATHS=(); DISK_MISSING=()

    local data_dir=""
    if [ "$DB_OK" = "1" ]; then
        data_dir=$(pg_query_soft "SHOW data_directory")
    fi
    [ -n "$data_dir" ] || data_dir="${PGDATA:-}"
    if [ -z "$data_dir" ]; then
        local p
        for p in /var/lib/pgsql/data /var/lib/postgresql/data /var/lib/postgresql/*/main \
                 /usr/local/pgsql/data /opt/pgsql/data /opt/postgresql/data; do
            if [ -d "$p" ]; then data_dir="$p"; break; fi
        done
    fi

    add_disk_target "PGDATA" "$data_dir"

    if [ "$DB_OK" = "1" ]; then
        local ts
        ts=$(pg_query_soft "SELECT spcname || '|' || pg_tablespace_location(oid) FROM pg_tablespace WHERE pg_tablespace_location(oid) <> ''")
        if [ -n "$ts" ]; then
            local line name loc
            while IFS='|' read -r name loc; do
                [ -n "${loc:-}" ] || continue
                add_disk_target "表空间:${name:-?}" "$loc"
            done <<< "$ts"
        fi
    fi

    local extra
    for extra in ${EXTRA_DISK_PATHS:-}; do
        add_disk_target "自定义" "$extra"
    done
}

add_disk_target() {
    local label="$1" path="$2" i=0 n="${#DISK_PATHS[@]}"
    [ -n "$path" ] || return 0
    if [ ! -d "$path" ]; then
        DISK_MISSING+=("${label}=${path}")
        return 0
    fi
    while [ "$i" -lt "$n" ]; do
        [ "${DISK_PATHS[$i]}" = "$path" ] && return 0
        i=$((i + 1))
    done
    DISK_LABELS+=("$label")
    DISK_PATHS+=("$path")
}

check_disk() {
    local i
    if [ "${#DISK_PATHS[@]}" -eq 0 ]; then
        record UNKNOWN "磁盘空间" "未找到可检查的 PGDATA/表空间路径（数据库不可用且未自动探测到数据目录）"
    fi
    i=0
    while [ "$i" -lt "${#DISK_MISSING[@]}" ]; do
        record UNKNOWN "磁盘空间" "路径不存在，已跳过: ${DISK_MISSING[$i]}"
        i=$((i + 1))
    done

    i=0
    while [ "$i" -lt "${#DISK_PATHS[@]}" ]; do
        local label="${DISK_LABELS[$i]}" path="${DISK_PATHS[$i]}"
        local out line total used avail mount used_pct lvl
        if ! out=$(df -P -k "$path" 2>/dev/null); then
            record UNKNOWN "磁盘空间" "$label $path 无法读取 df 信息"
            i=$((i + 1)); continue
        fi
        line=$(printf '%s\n' "$out" | awk 'NR==2')
        total=$(printf '%s' "$line" | awk '{print $(NF-4)}')
        used=$(printf '%s' "$line" | awk '{print $(NF-3)}')
        avail=$(printf '%s' "$line" | awk '{print $(NF-2)}')
        mount=$(printf '%s' "$line" | awk '{print $NF}')
        case "$total" in ''|*[!0-9]*) record UNKNOWN "磁盘空间" "$label $path df 输出无法解析"; i=$((i + 1)); continue ;; esac

        used_pct=$(pct "$used" "$total")
        lvl=$(grade_high "$used_pct" "$DISK_WARN" "$DISK_CRIT")
        record "$lvl" "磁盘空间" \
            "$label $path 挂载:$mount 已用 ${used_pct}% (warn>${DISK_WARN}% crit>${DISK_CRIT}%) 总量 $(human_kb "$total") 可用 $(human_kb "$avail")"
        i=$((i + 1))
    done
}

check_inode() {
    local i=0
    while [ "$i" -lt "${#DISK_PATHS[@]}" ]; do
        local label="${DISK_LABELS[$i]}" path="${DISK_PATHS[$i]}"
        local out line itotal iused ifree mount used_pct lvl
        if ! out=$(df -P -i "$path" 2>/dev/null); then
            record UNKNOWN "磁盘INODE" "$label $path 无法读取 df -i 信息"
            i=$((i + 1)); continue
        fi
        line=$(printf '%s\n' "$out" | awk 'NR==2')
        itotal=$(printf '%s' "$line" | awk '{print $(NF-4)}')
        iused=$(printf '%s' "$line" | awk '{print $(NF-3)}')
        ifree=$(printf '%s' "$line" | awk '{print $(NF-2)}')
        mount=$(printf '%s' "$line" | awk '{print $NF}')
        case "$itotal" in ''|*[!0-9]*) record UNKNOWN "磁盘INODE" "$label $path df -i 输出无法解析"; i=$((i + 1)); continue ;; esac

        used_pct=$(pct "$iused" "$itotal")
        lvl=$(grade_high "$used_pct" "$INODE_WARN" "$INODE_CRIT")
        record "$lvl" "磁盘INODE" \
            "$label $path 挂载:$mount 已用 ${used_pct}% (warn>${INODE_WARN}% crit>${INODE_CRIT}%) inode 总数 $itotal 可用 $ifree"
        i=$((i + 1))
    done
}

sample_cpu_busy() {  # $1 采样秒数 -> 忙时百分比
    local secs="$1" a b
    [ -r /proc/stat ] || { echo "-1"; return 0; }
    a=$(awk '/^cpu /{print; exit}' /proc/stat)
    sleep "$secs"
    b=$(awk '/^cpu /{print; exit}' /proc/stat)
    awk -v a="$a" -v b="$b" 'BEGIN{
        n=split(a,x," "); split(b,y," ");
        ta=0; tb=0;
        for (i=2; i<=n; i++) { ta+=x[i]+0; tb+=y[i]+0 }
        ia=(x[5]+0)+(x[6]+0); ib=(y[5]+0)+(y[6]+0);
        dt=tb-ta; di=ib-ia;
        if (dt <= 0) { print "-1"; exit }
        printf "%.1f", (dt-di)*100/dt
    }'
}

check_cpu() {
    local nproc load1 per_core busy lvl_load lvl_busy lvl msg
    load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "")
    nproc=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    is_num "$nproc" || nproc=1
    [ "$nproc" -lt 1 ] 2>/dev/null && nproc=1

    if is_num "$load1"; then
        per_core=$(awk -v l="$load1" -v n="$nproc" 'BEGIN{ if (n<1) n=1; printf "%.2f", l/n }')
        lvl_load=$(grade_high "$per_core" "$LOAD_WARN_PER_CORE" "$LOAD_CRIT_PER_CORE")
    else
        per_core="-1"; load1="N/A"; lvl_load="UNKNOWN"
    fi

    if is_num "$CPU_SAMPLE" && [ "$CPU_SAMPLE" -gt 0 ] 2>/dev/null; then
        busy=$(sample_cpu_busy "$CPU_SAMPLE")
        if is_num "$busy" && [ "$busy" != "-1" ]; then
            lvl_busy=$(grade_high "$busy" "$CPU_WARN" "$CPU_CRIT")
        else
            busy="-1"; lvl_busy="UNKNOWN"
        fi
    else
        busy="-1"; lvl_busy="OK"
    fi

    lvl=$(worse "$lvl_load" "$lvl_busy")
    msg="核心数 $nproc 1分钟负载 $load1 (${per_core}/核, warn>${LOAD_WARN_PER_CORE} crit>${LOAD_CRIT_PER_CORE})"
    if [ "$busy" != "-1" ]; then
        msg="$msg 采样${CPU_SAMPLE}s 忙时 ${busy}% (warn>${CPU_WARN}% crit>${CPU_CRIT}%)"
    else
        msg="$msg 未采样 CPU 使用率"
    fi
    record "$lvl" "CPU" "$msg"
}

check_mem() {
    local mt ma mf mu used_pct lvl st sf swu lvl_swap msg extra
    mt=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    ma=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    mf=$(awk '/^MemFree:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    if [ -z "$mt" ] || ! is_num "$mt" || [ "$mt" -le 0 ] 2>/dev/null; then
        record UNKNOWN "内存" "无法从 /proc/meminfo 读取内存信息"
        return 0
    fi

    if [ -n "$ma" ] && is_num "$ma"; then
        mu="$ma"; extra=""
    else
        mu="${mf:-0}"; extra=" (内核无 MemAvailable，按 MemFree 估算)"
    fi
    used_pct=$(pct "$((mt - mu))" "$mt")
    lvl=$(grade_high "$used_pct" "$MEM_WARN" "$MEM_CRIT")
    msg="已用 ${used_pct}% (warn>${MEM_WARN}% crit>${MEM_CRIT}%) 总量 $(human_kb "$mt") 可用 $(human_kb "$mu")${extra}"

    st=$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    sf=$(awk '/^SwapFree:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    if [ -n "$st" ] && is_num "$st" && [ "$st" -gt 0 ] 2>/dev/null; then
        swu=$(pct "$((st - ${sf:-0}))" "$st")
        lvl_swap=$(grade_high "$swu" "$SWAP_WARN" "$SWAP_CRIT")
        msg="$msg swap 已用 ${swu}% (warn>${SWAP_WARN}% crit>${SWAP_CRIT}%)"
        lvl=$(worse "$lvl" "$lvl_swap")
    else
        msg="$msg 未启用 swap"
    fi
    record "$lvl" "内存" "$msg"
}

check_connections() {
    if [ "$DB_OK" != "1" ]; then
        record UNKNOWN "连接数" "数据库不可用: $DB_ERR"
        return 0
    fi

    local q out rc used maxc reserved active idle idlex waiting
    q="SELECT count(*)::text,"
    q="$q current_setting('max_connections')::int::text,"
    q="$q current_setting('superuser_reserved_connections')::int::text,"
    q="$q sum(CASE WHEN state='active' THEN 1 ELSE 0 END)::text,"
    q="$q sum(CASE WHEN state='idle' THEN 1 ELSE 0 END)::text,"
    q="$q sum(CASE WHEN state='idle in transaction' THEN 1 ELSE 0 END)::text"
    if [ "$DB_VER_NUM" -ge 90600 ] 2>/dev/null; then
        q="$q, sum(CASE WHEN wait_event IS NOT NULL THEN 1 ELSE 0 END)::text"
    fi
    q="$q FROM pg_stat_activity"

    out=$(pg_query "$q"); rc=$?
    if [ $rc -ne 0 ] || [ -z "$out" ]; then
        record UNKNOWN "连接数" "查询 pg_stat_activity 失败: $(first_line "$PG_ERR_FILE")"
        return 0
    fi

    IFS='|' read -r used maxc reserved active idle idlex waiting <<< "$(printf '%s' "$out" | head -n 1)"
    : "${used:=0}" "${maxc:=0}" "${reserved:=0}" "${active:=0}" "${idle:=0}" "${idlex:=0}" "${waiting:=0}"
    is_num "$maxc" || maxc=0
    is_num "$reserved" || reserved=0

    local eff="$maxc"
    [ "$maxc" -gt "$reserved" ] 2>/dev/null && eff=$((maxc - reserved))
    [ "$eff" -gt 0 ] 2>/dev/null || eff="$maxc"
    if [ "$eff" -le 0 ] 2>/dev/null; then
        record UNKNOWN "连接数" "无法确定 max_connections (查询结果: $out)"
        return 0
    fi

    local usage lvl msg
    usage=$(pct "$used" "$eff")
    lvl=$(grade_high "$usage" "$CONN_WARN" "$CONN_CRIT")
    msg="已用 $used / 有效上限 $eff (max_connections=$maxc 预留 $reserved) 使用率 ${usage}% (warn>${CONN_WARN}% crit>${CONN_CRIT}%)"
    msg="$msg [active=$active idle=$idle idle_in_txn=$idlex waiting=$waiting]"
    if is_num "$idlex" && [ "$idlex" -ge "$IDLE_IN_XACT_WARN" ] 2>/dev/null; then
        lvl=$(worse "$lvl" "WARN")
        msg="$msg ⚠ idle in transaction 偏多(>=$IDLE_IN_XACT_WARN)"
    fi
    record "$lvl" "连接数" "$msg"
}

check_node_role() {
    local in_rec
    in_rec=$(pg_query "SELECT pg_is_in_recovery()::text")
    case "$in_rec" in
        t|true)  ACTUAL_ROLE="standby" ;;
        f|false) ACTUAL_ROLE="primary" ;;
        *)
            ACTUAL_ROLE="unknown"
            record UNKNOWN "节点角色" "无法判断是否处于恢复状态: $in_rec $(first_line "$PG_ERR_FILE")"
            return 1 ;;
    esac

    if [ "$NODE_EXPECT_ROLE" != "auto" ] && [ "$NODE_EXPECT_ROLE" != "$ACTUAL_ROLE" ]; then
        record CRIT "节点角色" "期望 $NODE_EXPECT_ROLE，实际 $ACTUAL_ROLE（配置的 IP 角色可能写反，或发生了主备切换）"
    else
        local extra=""
        [ "$NODE_EXPECT_ROLE" = "auto" ] && extra=" (自动探测，未做角色约束)"
        record OK "节点角色" "实际角色 $ACTUAL_ROLE，期望 $NODE_EXPECT_ROLE$extra"
    fi
    return 0
}

check_replication() {
    if [ "$DB_OK" != "1" ]; then
        record UNKNOWN "主备延迟" "数据库不可用: $DB_ERR"
        return 0
    fi

    check_node_role || return 0

    if [ "$ACTUAL_ROLE" = "primary" ]; then
        check_replication_primary
    else
        check_replication_standby
    fi
}

check_replication_primary() {
    local current_fn diff_fn replay_col lag_expr q out
    if [ "$DB_VER_NUM" -ge 100000 ] 2>/dev/null; then
        current_fn="pg_current_wal_lsn"
        diff_fn="pg_wal_lsn_diff"
        replay_col="replay_lsn"
        lag_expr="COALESCE(EXTRACT(EPOCH FROM replay_lag), -1)"
    else
        current_fn="pg_current_xlog_location"
        diff_fn="pg_xlog_location_diff"
        replay_col="replay_location"
        lag_expr="-1"
    fi

    q="SELECT application_name, COALESCE(client_addr::text,'local'), state, sync_state,"
    q="$q COALESCE($diff_fn($current_fn(), $replay_col),0)::bigint::text,"
    q="$q ($lag_expr)::numeric(12,1)::text"
    q="$q FROM pg_stat_replication ORDER BY 5 DESC"

    if ! out=$(pg_query "$q"); then
        record UNKNOWN "主备延迟" "查询 pg_stat_replication 失败: $(first_line "$PG_ERR_FILE")"
        return 0
    fi

    local rows=0 max_bytes=0 max_secs=-1 bytes_lvl="OK" secs_lvl="OK"
    local app addr state sync bytes secs list=""
    ADDR_LIST=""
    while IFS='|' read -r app addr state sync bytes secs; do
        [ -n "${app:-}" ] || continue
        rows=$((rows + 1))
        is_num "${bytes:-}" || bytes=0
        is_num "${secs:-}" || secs=-1
        [ "$(awk -v a="$bytes" -v b="$max_bytes" 'BEGIN{print (a>b)?1:0}')" = "1" ] && max_bytes="$bytes"
        [ "$(awk -v a="$secs" -v b="$max_secs" 'BEGIN{print (a>b)?1:0}')" = "1" ] && max_secs="$secs"
        [ -n "$addr" ] && ADDR_LIST="$ADDR_LIST $addr"
        list="$list ${app}(${addr}/${state}/${sync})"
    done <<< "$out"

    if [ "$rows" -eq 0 ]; then
        if [ "${REPL_MIN_STANDBYS:-0}" -gt 0 ] 2>/dev/null; then
            record "$(norm_level "$REPL_NO_STANDBY_LEVEL")" "主备延迟" \
                "主库 pg_stat_replication 无任何备库连接（要求最少 $REPL_MIN_STANDBYS 个）"
        else
            record OK "主备延迟" "主库当前无备库连接（REPL_MIN_STANDBYS=0，按配置放行）"
        fi
        return 0
    fi

    bytes_lvl=$(grade_high "$max_bytes" "$REPL_BYTES_WARN" "$REPL_BYTES_CRIT")
    if is_num "$max_secs" && is_ge0 "$max_secs"; then
        secs_lvl=$(grade_high "$max_secs" "$REPL_SECS_WARN" "$REPL_SECS_CRIT")
    else
        secs_lvl="OK"
    fi

    local lvl msg
    lvl=$(worse "$bytes_lvl" "$secs_lvl")
    msg="主库 备库数 $rows 最大字节延迟 $(human_bytes "$max_bytes") (warn>$(human_bytes "$REPL_BYTES_WARN") crit>$(human_bytes "$REPL_BYTES_CRIT"))"
    if is_num "$max_secs" && is_ge0 "$max_secs"; then
        msg="$msg 最大时间延迟 ${max_secs}s (warn>${REPL_SECS_WARN}s crit>${REPL_SECS_CRIT}s)"
    else
        msg="$msg 时间延迟不可得(旧版本无 replay_lag)"
    fi
    msg="$msg 节点:$list"
    record "$lvl" "主备延迟" "$msg"

    # 集群级交叉核对：配置文件里声明的备库是否都已连上主库
    if [ "${REPL_EXPECT_CONFIGURED:-1}" = "1" ] && [ -n "${CONFIGURED_STANDBY_HOSTS// /}" ]; then
        local missing="" sip
        for sip in $CONFIGURED_STANDBY_HOSTS; do
            case " $ADDR_LIST " in
                *" $sip "*) ;;
                *) missing="$missing $sip" ;;
            esac
        done
        if [ -n "$missing" ]; then
            record "$(norm_level "$REPL_MISSING_STANDBY_LEVEL")" "备库连通" \
                "配置的备库未出现在主库 pg_stat_replication:$missing（未连接/网络不通，或 NAT 后地址不一致；可用 REPL_EXPECT_CONFIGURED=0 关闭该校验）"
        else
            record OK "备库连通" "配置的 $CONFIGURED_STANDBY_COUNT 个备库地址均已连上主库"
        fi
    fi
}

check_replication_standby() {
    local recv_fn replay_fn diff_fn q out rc
    if [ "$DB_VER_NUM" -ge 100000 ] 2>/dev/null; then
        recv_fn="pg_last_wal_receive_lsn"; replay_fn="pg_last_wal_replay_lsn"; diff_fn="pg_wal_lsn_diff"
    else
        recv_fn="pg_last_xlog_receive_location"; replay_fn="pg_last_xlog_replay_location"; diff_fn="pg_xlog_location_diff"
    fi

    q="SELECT COALESCE($diff_fn($recv_fn(), $replay_fn()), -1)::bigint::text,"
    q="$q COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())), -1)::numeric(12,1)::text,"
    q="$q COALESCE($recv_fn()::text,'none'),"
    q="$q COALESCE($replay_fn()::text,'none')"

    out=$(pg_query "$q"); rc=$?
    if [ $rc -ne 0 ] || [ -z "$out" ]; then
        record UNKNOWN "主备延迟" "查询备库回放状态失败: $(first_line "$PG_ERR_FILE")"
        return 0
    fi

    local bytes secs recv replay
    IFS='|' read -r bytes secs recv replay <<< "$(printf '%s' "$out" | head -n 1)"
    : "${bytes:=-1}" "${secs:=-1}" "${recv:=none}" "${replay:=none}"

    local msg="备库 接收位点 $recv 回放位点 $replay"
    local lvl="OK"

    if [ "$recv" = "none" ] && [ "$replay" = "none" ]; then
        record "$(norm_level "$REPL_NO_STANDBY_LEVEL")" "主备延迟" \
            "备库尚未收到/回放任何 WAL（接收位点与回放位点均为空），请检查 primary_conninfo 与网络"
        return 0
    fi

    if ! is_num "$bytes" || [ "$bytes" -lt 0 ] 2>/dev/null; then
        record UNKNOWN "主备延迟" "$msg 无法计算接收/回放位点差"
        return 0
    fi

    msg="$msg 字节延迟 $(human_bytes "$bytes") (warn>$(human_bytes "$REPL_BYTES_WARN") crit>$(human_bytes "$REPL_BYTES_CRIT"))"
    lvl=$(grade_high "$bytes" "$REPL_BYTES_WARN" "$REPL_BYTES_CRIT")

    if is_num "$secs" && is_ge0 "$secs"; then
        msg="$msg 最近回放距今 ${secs}s (warn>${REPL_SECS_WARN}s crit>${REPL_SECS_CRIT}s)"
        lvl=$(worse "$lvl" "$(grade_high "$secs" "$REPL_SECS_WARN" "$REPL_SECS_CRIT")")
    elif [ "$bytes" -gt 0 ] 2>/dev/null; then
        msg="$msg ⚠ 存在回放积压但取不到时间延迟(旧版本无 replay 时间戳)"
        lvl=$(worse "$lvl" "WARN")
    else
        msg="$msg 备库已追平(无近期事务则时间戳为空)"
    fi

    if [ "$DB_VER_NUM" -ge 100000 ] 2>/dev/null; then
        local st
        st=$(pg_query_soft "SELECT status FROM pg_stat_wal_receiver LIMIT 1")
        if [ -n "$st" ]; then
            msg="$msg wal_receiver=$st"
            [ "$st" != "streaming" ] && lvl=$(worse "$lvl" "WARN")
        else
            msg="$msg wal_receiver=不可读(权限不足或非流复制)"
        fi
    fi
    record "$lvl" "主备延迟" "$msg"
}

# ========================================================== 六、节点编排/报告 ==
check_one_node() {
    local label="$1" host="$2" port="$3" role="$4"
    local host_disp="${host:-<libpq默认>}"
    [ -n "$port" ] && host_disp="$host_disp:$port"

    # 节点级状态复位
    P_OK=0; P_WARN=0; P_CRIT=0; P_UNK=0; P_WORST=0
    DB_OK=0; DB_ERR=""; DB_VER_NUM=999999; ACTUAL_ROLE="unknown"
    NODE_EXPECT_ROLE="$role"
    PGHOST="$host"; PGPORT="$port"
    export PGHOST PGPORT

    if probe_db; then
        DB_VER_NUM=$(get_version_num)
        record OK "数据库连通" "psql 可用, server_version_num=$DB_VER_NUM"
    else
        record UNKNOWN "数据库连通" "$DB_ERR"
    fi

    collect_disk_targets
    check_disk
    check_inode
    check_cpu
    check_mem
    check_connections
    check_replication
}

print_header() {
    printf '%s\n' '================================================================================'
    printf ' PostgreSQL 主从巡检报告\n'
    printf ' 时间: %s   主机: %s   脚本: v%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$(uname -n 2>/dev/null || echo unknown)" "$SCRIPT_VERSION"
    if [ "$MODE" = "cluster" ]; then
        local i=0 n="${#NODE_HOSTS[@]}" nodes=""
        while [ "$i" -lt "$n" ]; do
            nodes="$nodes ${NODE_LABELS[$i]}=${NODE_HOSTS[$i]}"
            [ -n "${NODE_PORTS[$i]}" ] && nodes="$nodes:${NODE_PORTS[$i]}"
            i=$((i + 1))
        done
        printf ' 模式: 集群巡检（1 主 + %s 备）   节点:%s\n' \
            "$((n > 0 ? n - 1 : 0))" "$nodes"
    else
        printf ' 模式: 单节点巡检（未配置 PRIMARY_HOST/STANDBY_HOSTS）\n'
    fi
    printf ' 连接: %s/%s   阈值覆盖: %s\n' \
        "${PGUSER:-<默认>}" "${PGDATABASE:-<默认>}" "${CONF_FILE:-<无>}"
    printf ' 阈值: 磁盘 %s%%/%s%%  inode %s%%/%s%%  内存 %s%%/%s%%  连接数 %s%%/%s%%  延迟 %ss/%ss\n' \
        "$DISK_WARN" "$DISK_CRIT" "$INODE_WARN" "$INODE_CRIT" "$MEM_WARN" "$MEM_CRIT" \
        "$CONN_WARN" "$CONN_CRIT" "$REPL_SECS_WARN" "$REPL_SECS_CRIT"
    printf '%s\n' '================================================================================'
}

flush_late() {
    local i=0 n="${#LATE_MSGS[@]}"
    while [ "$i" -lt "$n" ]; do
        record "${LATE_LEVELS[$i]}" "${LATE_NAMES[$i]}" "${LATE_MSGS[$i]}"
        i=$((i + 1))
    done
}

run_all_nodes() {
    local i=0 n="${#NODE_HOSTS[@]}"
    while [ "$i" -lt "$n" ]; do
        local label="${NODE_LABELS[$i]}" host="${NODE_HOSTS[$i]}"
        local port="${NODE_PORTS[$i]}" role="${NODE_ROLES[$i]}"
        local disp="${host:-<libpq默认>}"
        [ -n "$port" ] && disp="$disp:$port"

        printf '\n%s\n' '--------------------------------------------------------------------------------'
        printf ' 节点 %s/%s: %s %s (期望角色 %s)\n' "$((i + 1))" "$n" "$label" "$disp" "$role"
        printf '%s\n' '--------------------------------------------------------------------------------'

        check_one_node "$label" "$host" "$port" "$role"

        local lvl
        lvl=$(node_level)
        printf ' >> 节点小结 [%s %s]: OK=%d WARN=%d CRIT=%d UNKNOWN=%d  => %s\n' \
            "$label" "$disp" "$P_OK" "$P_WARN" "$P_CRIT" "$P_UNK" "$lvl"
        NODE_RESULTS+=("$label ${disp} : $lvl  (OK=$P_OK WARN=$P_WARN CRIT=$P_CRIT UNKNOWN=$P_UNK)")
        i=$((i + 1))
    done
}

print_cluster_summary() {
    local rc="$1" name i=0 n="${#NODE_RESULTS[@]}"
    case "$rc" in
        0) name="OK" ;;
        1) name="WARN" ;;
        2) name="CRIT" ;;
        *) name="UNKNOWN" ;;
    esac
    printf '\n%s\n' '================================================================================'
    printf ' 集群汇总（共 %s 个节点）:\n' "$n"
    while [ "$i" -lt "$n" ]; do
        printf '   %s\n' "${NODE_RESULTS[$i]}"
        i=$((i + 1))
    done
    printf ' 合计: OK=%d WARN=%d CRIT=%d UNKNOWN=%d  =>  退出码 %d (%s)\n' \
        "$N_OK" "$N_WARN" "$N_CRIT" "$N_UNKNOWN" "$rc" "$name"
    printf '%s\n' '================================================================================'
}

calc_exit_code() {
    if [ "$N_CRIT" -gt 0 ]; then echo 2
    elif [ "$N_WARN" -gt 0 ]; then echo 1
    elif [ "$N_UNKNOWN" -gt 0 ]; then echo 3
    else echo 0
    fi
}

# ================================================================== 七、主流程 ==
main() {
    local -a argv=("$@")

    pre_parse_conf "${argv[@]}"
    snapshot_env
    assign_defaults
    load_conf_file
    apply_env_overrides
    parse_args "${argv[@]}"

    init_color
    init_tmp
    resolve_psql
    export_credentials

    GLOBAL_PGHOST="${PGHOST:-}"
    GLOBAL_PGPORT="${PGPORT:-}"
    build_node_list

    print_header
    flush_late
    run_all_nodes

    local rc
    rc=$(calc_exit_code)
    print_cluster_summary "$rc"
    exit "$rc"
}

main "$@"
