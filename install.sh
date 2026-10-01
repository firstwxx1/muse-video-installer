#!/usr/bin/env bash
# ============================================================================
#  Muse 视频工作台 —— 一键安装脚本
#
#  装好之后你能：
#    · 在浏览器里打开一个网页，输入一句话就生成视频
#    · 让别的软件（Cherry Studio、NextChat 等）连上它调用接口
#
#  用法（下面统一写作 install.sh，实际就是你下载时的文件名）：
#    交互安装：   sudo bash install.sh
#    全自动安装： sudo bash install.sh --yes
#    看会做什么： sudo bash install.sh --dry-run
#    其他：       sudo bash install.sh --status | --uninstall | --help
#
#  支持 Debian/Ubuntu（apt）、CentOS/RHEL（yum/dnf）、Alpine（apk）
# ============================================================================

set -uo pipefail

# 脚本自身的名字 —— 提示里一律用它，这样不管用户下载后叫 install.sh、
# setup.sh 还是别的，复制粘贴出来的命令都是对的。
#
# ⚠️ 但**管道运行**时必须特判（实测踩过）：
#    `curl ... | bash` / `cat install.sh | bash` 时 $0 是解释器名（bash / sh），
#    basename 得到 "bash" —— 于是收尾里会印出
#        sudo bash bash --status
#    这种 nonsense，小白照抄必报错。这正是「一条命令安装」最常见的用法。
#    判定：$0 是常见 shell 名 → 认为是从管道/标准输入来的，改用固定名 install.sh。
SELF="$(basename "${0:-}")"
# 记住「脚本文件在哪」。管道运行时这里为空 —— 后面安装流程会**把脚本自己
# 抄一份进安装目录**，让 --status/--upgrade 这些生命周期命令永远有个可执行的副本，
# 不再依赖「用户当初把脚本下到哪了」。这一步是小白最需要的兜底：
# 他很可能装完就把脚本删了 / 换成手机看，回头想升级时两手空空。
SELF_PATH=""
# 判定很简单：$0 指向一个**真实存在的文件**，就认为「知道自己在哪」。
# ⚠️ 早先写成匹配 /*、./*、../* 白名单，漏掉了最常见的一种调用：
#    `cd /tmp/dir && bash install.sh`（相对名、不带 ./）—— 那是小白
#    解压完之后的典型动作，结果自存功能直接失效。改成「存在即认」。
if [ -f "${0:-}" ]; then
  SELF_PATH="$0"
fi
case "$SELF" in
  bash|sh|dash|ash|zsh|ksh|"") SELF="install.sh"; SELF_PATH="" ;;
esac

# ── 自我定位「我是从哪个安装目录跑起来的」──────────────────────────────
#
# 我们把脚本副本存进安装目录（见 save_state），就是为了让用户随时能
# `bash /opt/xxx/install.sh --status`。但副本里的 DEFAULT_DIR 还是 /opt/mvw ——
# 装到别的目录时副本会认不出自己是谁（实测：跑副本报「还没装过 /opt/mvw」）。
# 解法：脚本启动时看看自己躺在哪里 —— 如果**旁边就有 install.conf**，
# 说明「我就在某个安装目录里」，那就把那个目录当作默认安装目录。
INSTALL_DIR_SELF=""
if [ -n "$SELF_PATH" ] && [ -f "$SELF_PATH" ]; then
  _self_dir="$(cd "$(dirname "$SELF_PATH")" 2>/dev/null && pwd)"
  if [ -n "$_self_dir" ] && [ -f "$_self_dir/install.conf" ]; then
    INSTALL_DIR_SELF="$_self_dir"
  fi
fi

SCRIPT_VERSION="1.5.0"
# 前缀统一用 mvw-（Muse Video Workbench），避免和用户已有的 muse-video / muse2api
# 等同名服务撞车 —— 曾因默认名与既有服务的 unit 重名，把别人的服务覆盖掉。
APP_NAME="mvw"
APP_LABEL="Muse 视频工作台"
DEFAULT_DIR="/opt/mvw"
DEFAULT_API_PORT=18610
DEFAULT_WEB_PORT=8090
# v1.3.0：一键导号 sidecar（网页里登录 muse.ai，cookie 自动入库）的端口
DEFAULT_IMPORT_PORT=18620
# 装哪一份 muse2api？
#   指向自己的 fork —— 它基于上游 v1.5.2，并叠加了 11 项缺陷修复
#   （FIFO 队列调度 / CDP 单读循环 / 参数校验 / 405 鉴权绕过等）。
#   ⚠️ 上游原仓库 czg86389-hub/muse2api 当前**不含**这些修复，
#   因此这里不能用上游地址，否则装出来的版本会缺修复。
#   待上游合并 PR（czg86389-hub/muse2api#5）后，可考虑切回上游。
MUSE2API_REPO="yys9253462-gif/muse2api"
# 装仓库里的哪个分支/标签。
# ⚠️ 必须显式写死，不能让 git 用「默认分支」——这是个踩过的坑：
#   `git clone --depth 1 <url>` 不加 -b 时**只拉默认分支**。曾经修复代码放在
#   其它分支、默认分支还是旧版，脚本却提示「安装成功」，用户装完才发现功能是坏的，
#   排查了很久。显式 -b 让「装哪一版」变成脚本里看得见的一行，而不是仓库设置里的隐藏状态。
#   同时下游还有 verify_installed_fixes() 自检兜底，双保险。
MUSE2API_REF="main"
# 本脚本自己所在的仓库 —— 导号小工具托管在这里，别指向上游
# （上游的 tools/get_muse_cookie.py 是原版，不能多账号、也没有连通自检）。
SELF_REPO="yys9253462-gif/muse-video-installer"

# ── 颜色（注意：变量名不与业务变量冲突） ──────────────────────────────
C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_BLD=''; C_DIM=''; C_OFF=''
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_CYN=$'\033[0;36m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
fi

# ── 输出函数 ─────────────────────────────────────────────────────────
# ⚠️ 铁律：**所有**面向人的输出一律走 stderr（>&2），
#    stdout 只留给「函数返回值」（如 pick_port / used_ports / gen_key）。
#    曾经因为 warn() 写 stdout，导致 $(pick_port) 的命令替换结果里
#    混进了「端口 18610 已被占用，换一个」这句告警文本，把 compose
#    写成语法错误的垃圾 —— 这个坑踩过一次，绝不能再犯。
say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '  %s×%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
step() { printf '\n%s▸ %s%s\n' "$C_BLD" "$*" "$C_OFF" >&2; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; }

# 菜单/提示一律走 stderr，stdout 只留给返回值
info() { printf '%s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ── 参数与状态 ────────────────────────────────────────────────────────
ASSUME_YES=0
DRY_RUN=0
NO_DEPS=0
DO_STATUS=0
DO_UNINSTALL=0
DO_UPGRADE=0
DO_ADD_ACCOUNT=0
DO_ACCOUNTS=0
DO_LINK=0
DO_HELP=0
# --accounts 的附属动作（列表是默认行为）
ACCT_REMOVE=""
ACCT_TEST=0
INSTALL_DIR="${INSTALL_DIR_SELF:-$DEFAULT_DIR}"
API_PORT=""
WEB_PORT=""
IMPORT_PORT=""
DOMAIN=""
NO_DOMAIN=0
ADV_GIVEN=0
# 用户要了域名、但 DNS 没生效导致这次没配上的话，记在这里，验收清单里再提一次
DOMAIN_SKIPPED=""

RUN_LOG=""

usage() {
  cat <<EOF
${APP_LABEL} 一键安装脚本 v${SCRIPT_VERSION}

用法：sudo bash ${SELF} [选项]

最常用（就这么用）：
  sudo bash ${SELF}              装好后直接敲 muse 进控制面板
  muse                           终端面板：加账号 / 看状态 / 管账号池 / 拿直达链接
  --add-account        导号：生成登录链接，浏览器打开登录即导入（可连续导多个）
  --link               打印工作台直达链接（带 Key，点开即用）
  --accounts           账号池管理（列出 / 删除 / 测活）

其他：
  --status             看当前运行状态（也能找回地址和 API Key）
  --upgrade            升级到最新版
  --uninstall          卸载
  --help, -h           显示本帮助

自动化：
  --yes, -y            全自动安装，所有问题用默认值（适合脚本/CI）
  --dry-run            只显示会做什么，不实际改动系统

进阶：
  --dir <路径>         安装到哪个目录（默认 ${DEFAULT_DIR}）
  --api-port <端口>    接口服务端口（默认自动挑，常用 ${DEFAULT_API_PORT}）
  --web-port <端口>    网页端口（默认自动挑，常用 ${DEFAULT_WEB_PORT}）
  --import-port <端口> 一键导号端口（默认自动挑，常用 ${DEFAULT_IMPORT_PORT}）
  --domain <域名>      给网页绑个域名并自动配 HTTPS（需要域名已解析到本机）
  --no-domain          不要域名（默认就是不要）
  --no-deps            不自动安装依赖，缺什么只告诉你
  --accounts --remove <编号|ID>   删掉账号池里的某个账号
  --accounts --test               逐个验证账号会话是否还有效（会真开浏览器，慢）

示例：
  sudo bash ${SELF}
  sudo bash ${SELF} --yes --web-port 8090
  sudo bash ${SELF} --domain video.example.com
  sudo bash ${SELF} --add-account
  sudo bash ${SELF} --accounts
EOF
}

# ── 「你是不是想打……」：给打错的参数一个最接近的建议 ────────────────
#
# ⚠️ 为什么值得单写一个函数（真人实测）：
#    小白打错 --uninstall 的概率极高，而最常见的错法是**少一个字母**
#    （--unstall / --uninstal）—— 光看两行字他根本发现不了差在哪。
#    更常见的是**不带你以为的横杠**：直接敲 `uninstall` / `status`。
#    这时只回一句「不认识的参数，用 --help 看用法」，等于把人晾在原地。
#    下面用最朴素的「编辑距离」找最近的合法选项，明确告诉他打哪个。
_levdist() {
  # 极简 Levenshtein 距离（纯 bash，字符串都很短，性能无所谓）
  local a="$1" b="$2" i j
  local la=${#a} lb=${#b}
  local prev cur
  local -a row
  for ((j = 0; j <= lb; j++)); do row[j]=$j; done
  for ((i = 1; i <= la; i++)); do
    prev=${row[0]}; row[0]=$i
    for ((j = 1; j <= lb; j++)); do
      cur=${row[j]}
      if [ "${a:i-1:1}" = "${b:j-1:1}" ]; then
        row[j]=$prev
      else
        local m=$prev
        [ "${row[j]}" -lt "$m" ] && m=${row[j]}
        [ "${row[j-1]}" -lt "$m" ] && m=${row[j-1]}
        row[j]=$((m + 1))
      fi
      prev=$cur
    done
  done
  printf '%s' "${row[lb]}"
}

suggest_arg() {
  local bad="$1"
  # 归一化：去掉前导横杠，转小写 —— 这样 `uninstall`/`-Uninstall` 都能对上
  local key="${bad#--}"; key="${key#-}"
  local had_dash=0
  case "$bad" in -*) had_dash=1 ;; esac
  key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  local best="" bestd=99 cand d
  for cand in yes dry-run no-deps status uninstall upgrade help dir api-port web-port domain no-domain; do
    d="$(_levdist "$key" "$cand")"
    if [ "$d" -lt "$bestd" ]; then bestd=$d; best=$cand; fi
  done
  # 冒号后面这段是「完全对上、但没写横杠」的情况 —— **小白最常犯的错**：
  # 直接把 `uninstall` / `status` 当子命令敲。这时距离是 0，必须也给出建议，
  # 否则最该帮的那一类人反而得不到提示。
  if [ "$bestd" = 0 ] && [ "$had_dash" = 0 ] && [ -n "$best" ]; then
    printf '%s' "--$best"; return 0
  fi
  # 距离阈值：宁可多猜一次，也别让小白卡住 —— 这个提示只是**建议**，
  # 猜错了顶多浪费一眼；猜对了就省掉他反复试错。实测常见错法：
  #   unstall→uninstall(2) / stauts→status(2,字母调位) / updat→upgrade(4,缩写)
  # 但也不能太松，否则乱敲个 `xyz` 都会被"建议"成 --yes。规则：
  #   · 太短（<=4 字符）→ 只容忍 2，够抓 stauts/updat 这类，
  #     又不至于把 `xyz`(→yes,3) 硬凑上；
  #   · 中等（5-7）→ 容忍 4；
  #   · 长词（>=8）→ 容忍 5。
  local lim=4
  if [ "${#key}" -le 4 ]; then lim=2
  elif [ "${#key}" -ge 8 ]; then lim=5
  fi
  if [ -n "$best" ] && [ "$bestd" -le "$lim" ] && [ "$bestd" -gt 0 ]; then
    printf '%s' "--$best"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)        ASSUME_YES=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    --no-deps)       NO_DEPS=1 ;;
    --status)        DO_STATUS=1 ;;
    --add-account)   DO_ADD_ACCOUNT=1 ;;
    --accounts)      DO_ACCOUNTS=1 ;;
    --link|--open)   DO_LINK=1 ;;
    --remove)        ACCT_REMOVE="${2:-}"; shift; [ -n "${ACCT_REMOVE:-}" ] || die "--remove 后面要跟账号编号或 ID（先跑 --accounts 看列表）" ;;
    --remove=*)      ACCT_REMOVE="${1#*=}"; [ -n "$ACCT_REMOVE" ] || die "--remove= 后面要跟账号编号或 ID" ;;
    --test)          ACCT_TEST=1 ;;
    --uninstall)     DO_UNINSTALL=1 ;;
    --upgrade)       DO_UPGRADE=1 ;;
    --help|-h)       DO_HELP=1 ;;
    --dir)           INSTALL_DIR="${2:-}"; shift; [ -n "${INSTALL_DIR:-}" ] || die "--dir 后面要跟一个路径" ;;
    --dir=*)         INSTALL_DIR="${1#*=}"; [ -n "$INSTALL_DIR" ] || die "--dir= 后面要跟一个路径" ;;
    --api-port)      API_PORT="${2:-}"; shift; [ -n "${API_PORT:-}" ] || die "--api-port 后面要跟一个端口号（比如 --api-port 18610）"; ADV_GIVEN=1 ;;
    --api-port=*)    API_PORT="${1#*=}"; [ -n "$API_PORT" ] || die "--api-port= 后面要跟一个端口号"; ADV_GIVEN=1 ;;
    --web-port)      WEB_PORT="${2:-}"; shift; [ -n "${WEB_PORT:-}" ] || die "--web-port 后面要跟一个端口号（比如 --web-port 8090）"; ADV_GIVEN=1 ;;
    --web-port=*)    WEB_PORT="${1#*=}"; [ -n "$WEB_PORT" ] || die "--web-port= 后面要跟一个端口号"; ADV_GIVEN=1 ;;
    --import-port)      IMPORT_PORT="${2:-}"; shift; [ -n "${IMPORT_PORT:-}" ] || die "--import-port 后面要跟一个端口号（比如 --import-port 18620）"; ADV_GIVEN=1 ;;
    --import-port=*)    IMPORT_PORT="${1#*=}"; [ -n "$IMPORT_PORT" ] || die "--import-port= 后面要跟一个端口号"; ADV_GIVEN=1 ;;
    --domain)        DOMAIN="${2:-}"; shift; [ -n "${DOMAIN:-}" ] || die "--domain 后面要跟一个域名（比如 --domain video.example.com）"; ADV_GIVEN=1 ;;
    --domain=*)      DOMAIN="${1#*=}"; [ -n "$DOMAIN" ] || die "--domain= 后面要跟一个域名"; ADV_GIVEN=1 ;;
    --no-domain)     NO_DOMAIN=1; ADV_GIVEN=1 ;;
    *)
      # 打错的参数：先猜一个最像的，明确告诉他该敲哪个；猜不到再退回看帮助。
      _sug="$(suggest_arg "$1")"
      if [ -n "$_sug" ]; then
        die "不认识的参数：$1
       你是不是想打：$_sug ？
       全部用法：bash ${SELF} --help"
      fi
      die "不认识的参数：$1（用 --help 看用法）" ;;
  esac
  shift
done

if [ "$DO_HELP" = 1 ]; then usage; exit 0; fi

# 端口合法性
validate_port() {
  local p="$1" what="$2"
  [ -n "$p" ] || return 0
  case "$p" in *[!0-9]*) die "$what 必须是数字，你给的是「$p」" ;; esac
  if [ "$p" -lt 1024 ] || [ "$p" -gt 65535 ]; then
    die "$what 要在 1024–65535 之间，你给的是 $p"
  fi
}
validate_port "$API_PORT" "接口端口"
validate_port "$WEB_PORT" "网页端口"
validate_port "$IMPORT_PORT" "导号端口"

# 端口别撞车
if [ -n "$API_PORT" ] && [ -n "$WEB_PORT" ] && [ "$API_PORT" = "$WEB_PORT" ]; then
  die "接口端口和网页端口不能是同一个（都是 $API_PORT）。给它们各分一个。"
fi
for _pair in "$API_PORT $IMPORT_PORT 接口 导号" "$WEB_PORT $IMPORT_PORT 网页 导号"; do
  set -- $_pair
  if [ -n "$1" ] && [ -n "$2" ] && [ "$1" = "$2" ]; then
    die "$3端口和$4端口不能是同一个（都是 $1）。给它们各分一个。"
  fi
done
unset _pair

# 子命令互斥检查：--status / --uninstall / --upgrade / --add-account /
#                  --accounts / --link 只能给一个
# --remove / --test 是 --accounts 的附属动作，给了它们就等于要管账号池
if [ -n "$ACCT_REMOVE" ] || [ "$ACCT_TEST" = 1 ]; then DO_ACCOUNTS=1; fi
_SUB_CNT=0
_SUB_LIST=""
# ⚠️ 循环里用下划线写法（add_account），因为 eval 拼变量名时连字符是非法字符；
#    展示给用户时再转回连字符。
for _v in status uninstall upgrade add_account accounts link; do
  eval "_cur=\$DO_$(printf '%s' "$_v" | tr 'a-z' 'A-Z')"
  if [ "$_cur" = 1 ]; then
    _SUB_CNT=$((_SUB_CNT + 1))
    _SUB_LIST="${_SUB_LIST:+$_SUB_LIST 和 }--$(printf '%s' "$_v" | tr '_' '-')"
  fi
done
if [ "$_SUB_CNT" -gt 1 ]; then
  die "这几个参数一次只能给一个：$_SUB_LIST。
       你想干什么就留哪个，比如只看状态：sudo bash ${SELF} --status"
fi
unset _SUB_CNT _SUB_LIST _cur _v

# 域名清洗：用户常粘 https:// 和结尾斜杠
if [ -n "$DOMAIN" ]; then
  DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN%%/*}"; DOMAIN="${DOMAIN%%:*}"
fi

# ── 运行包装器（dry-run 只打印） ──────────────────────────────────────
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s[dry-run]%s %s\n' "$C_CYN" "$C_OFF" "$*"
    return 0
  fi
  printf '    %s$%s %s\n' "$C_DIM" "$C_OFF" "$*"
  "$@"
}

runsh() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s[dry-run]%s %s\n' "$C_CYN" "$C_OFF" "$*"
    return 0
  fi
  printf '    %s$%s %s\n' "$C_DIM" "$C_OFF" "$*"
  bash -c "$*"
}

# ── 交互函数（非终端 / --yes 时用默认值） ─────────────────────────────
ask() {
  local prompt="$1" def="$2" ans=""
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$def"; return 0; fi
  printf '  %s [%s]: ' "$prompt" "$def" >&2
  if ! read -r ans; then printf '%s' "$def"; return 0; fi   # EOF → 默认值
  printf '%s' "${ans:-$def}"
}

ask_yn() {
  local prompt="$1" def="$2" ans=""        # def: y 或 n
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
    [ "$def" = y ] && return 0 || return 1
  fi
  while :; do
    printf '  %s [%s/%s]: ' "$prompt" \
      "$( [ "$def" = y ] && echo 'Y' || echo 'y')" \
      "$( [ "$def" = y ] && echo 'n' || echo 'N')" >&2
    if ! read -r ans; then          # EOF：确认类一律按「否」，不能默认放行
      [ "$def" = y ] && return 0 || return 1
    fi
    ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
    [ -z "$ans" ] && { [ "$def" = y ] && return 0 || return 1; }
    case "$ans" in
      y|Y|yes|YES|Yes|true|1|是|是的|好|好的|对|要|嗯|可以|行|确定|確認) return 0 ;;
      n|N|no|NO|No|false|0|否|不|不要|不用|不是|取消|取消吧) return 1 ;;
      *) printf '  %s没看懂「%s」—— 请回答 y（是）或 n（否），直接回车用默认值%s\n' \
           "$C_YEL" "$ans" "$C_OFF" >&2 ;;
    esac
  done
}

# ── 环境探测 ──────────────────────────────────────────────────────────
OS_ID=""; OS_VER=""; PKG=""
detect_os() {
  if [ -f /etc/os-release ]; then
    # 在子 shell 里读，避免 os-release 里的 ID/VERSION/NAME 等通用变量名
    # 污染本脚本的同名变量（实测 VERSION 被覆盖成 "12 (bookworm)"）
    OS_ID="$( (. /etc/os-release 2>/dev/null; printf '%s' "${ID:-unknown}") )"
    OS_VER="$( (. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}") )"
  fi
  if   command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
  elif command -v yum     >/dev/null 2>&1; then PKG=yum
  elif command -v apk     >/dev/null 2>&1; then PKG=apk
  else PKG=""
  fi
}

IS_ROOT=0
check_root() {
  [ "$(id -u)" = 0 ] && IS_ROOT=1
  if [ "$IS_ROOT" != 1 ]; then
    if command -v sudo >/dev/null 2>&1; then
      die "这个脚本要用管理员权限跑。请这样运行：
       sudo bash ${SELF} $*"
    fi
    die "这个脚本要用管理员权限跑，但这台机器上没有 sudo。
       请先切换到 root 再运行（执行：su -  然后重新跑本脚本）"
  fi
}

# ── 端口检测（v1.2.0 重写）──────────────────────────────────────────
# 「一个端口能不能用」分三层判定：
#   第 1 层  ss 列表：宿主 TCP 监听 —— 快，覆盖绝大多数情况
#   第 2 层  docker -a：**所有**容器（含已停止的）的发布端口 —— 停止容器的端口
#            此刻没在宿主上监听，但它下次启动就会和我们抢；提前避开更稳
#   第 3 层  真实 bind 测试：往 0.0.0.0 真绑一次马上释放 —— 消除「ss 快照之后、
#            服务起来之前」被别人抢先的时间窗（TOCTOU），也能兜住 ss 看不到的情况
#
# ⚠️ bind 测试为什么用**裸 bind（不开 SO_REUSEADDR）**：
#    对端口挑选器而言，两个方向的错误代价不对称 ——
#      漏判（说空闲、实际被占）→ 服务起不来，安装翻车；
#      误判（说占用、实际空闲，如 TIME_WAIT 残留）→ 不过是跳过这个端口，
#      后面有的是候选。所以宁严勿松，用最严格的原生语义。
#    另外 SO_REUSEADDR 在 Windows 上允许重复绑定（端口劫持），在 Linux 上
#    只跳 TIME_WAIT —— 依赖它的平台差异就是埋雷。裸 bind 两边行为一致。
#    依赖 python3（装不上就只靠第 1、2 层，do_install 会在挑端口前主动装 python3）。
USED_PORTS_CACHE=""
used_ports() {
  if [ -z "$USED_PORTS_CACHE" ]; then
    USED_PORTS_CACHE="$(
      { ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://'
        docker ps -a --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
          | sed -n 's/.*:\([0-9][0-9]*\)->.*/\1/p'
      } | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' '
    )"
  fi
  printf '%s' "$USED_PORTS_CACHE"
}

port_bindable() {
  local p="$1"
  command -v python3 >/dev/null 2>&1 || return 0   # 没 python3 就放弃这层
  python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
' "$p" 2>/dev/null
}

port_free() {
  local p="$1"
  case " $(used_ports) " in *" $p "*) return 1 ;; esac
  port_bindable "$p" || return 1
  return 0
}

# 这个端口是不是「我们自己上次安装的」占着的？
# 重跑安装/改配置时，端口被自己的旧容器/旧网页服务占着是**正常且预期**的，
# 不该像被外人占用那样直接报错退出（否则幂等重跑会撞墙）。
#
# 有两种「自己人」：
#   1) 接口端口 —— Docker 容器 $CONTAINER_NAME 发布的端口
#   2) 网页端口 —— systemd 服务 $WEB_UNIT 跑的静态服务器
# 两类都要认，否则重跑时会卡在网页端口上（实测踩过）。
port_owned_by_us() {
  local p="$1"

  # ① Docker 容器发布的端口
  if command -v docker >/dev/null 2>&1; then
    local ports
    ports="$(docker inspect "$CONTAINER_NAME" \
               --format '{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} {{end}}' \
               2>/dev/null)"
    case " $ports " in *":${p}/tcp "*) return 0 ;; esac
    ports="$(docker port "$CONTAINER_NAME" 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
    case " $ports " in *"0.0.0.0:${p} "*) return 0 ;; esac
  fi

  # ② 我们自己的网页 systemd 服务占的端口
  #    判据：该单元 active，且它的命令行里出现了这个端口
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "$WEB_UNIT" 2>/dev/null; then
      local cmdline
      cmdline="$(systemctl show "$WEB_UNIT" -p ExecStart --value 2>/dev/null)"
      case "$cmdline" in
        *":${p} "|*":${p}\""|*" ${p} "|*" ${p}\""|*":${p}'"'"'*) return 0 ;;
        *) case "$cmdline" in *"${p}"*) return 0 ;; esac ;;
      esac
    fi
  fi

  return 1
}

# 自动挑端口（v1.2.0 增强）：
#   1) 从起始端口往上走 —— 端口号挨得近，好记好说明
#   2) 连续 50 个都被占 → 说明这段被人密集占了，换高位段（20000-61000）
#      随机探测，不再一个一个傻扫
#   3) exclude：本轮已经定下来的其他端口（空格分隔列表）—— 三个端口
#      绝不能挑成同一个（默认端口被顶开之后是可能凑到一起的，别赌运气）
pick_port() {
  local start="$1" exclude="${2:-}"
  local p="$start" tries=0 moved=0
  while :; do
    # 起点可能来自上一端口的 +1（如 65535 被占后来到 65536），先夹回合法段
    if [ "$p" -gt 65535 ]; then p=$(( (RANDOM % 41000) + 20000 )); fi
    case " $exclude " in *" $p "*) ;; *)
      if port_free "$p"; then
        printf '%s' "$p"
        return 0
      fi
      # 是自家旧容器/旧服务占的 → 不换端口，直接沿用（它会原地重建）
      if port_owned_by_us "$p"; then
        printf '%s' "$p"
        return 0
      fi ;;
    esac
    # ⚠️ 文案分两种：
    #    真实安装时说「已被占用，换一个」是对的（脚本真的会自动往上找）；
    #    但在 dry-run 里这么说会让小白**误以为必须自己手动换端口** ——
    #    实测时 dry-run 打出「端口 18610 已被占用，换一个」，
    #    而 18610 只是这台机器上别的服务占的，脚本本来就会自动避开。
    #    dry-run 要说清楚"这是自动的，不用管"。
    if [ "$DRY_RUN" = 1 ]; then
      if [ "$moved" = 0 ]; then
        say "    [dry-run] 端口 $start 被占了，脚本会自动往上找空闲端口（不用管）"
      fi
    else
      warn "端口 $p 已被占用，自动换一个"
    fi
    moved=1
    tries=$((tries + 1))
    if [ "$tries" -ge 500 ]; then
      die "试了 $tries 个端口都被占用，请用 --api-port / --web-port 手动指定"
    fi
    if [ "$tries" -ge 50 ]; then
      # 起始端口附近被密集占用 → 跳到高位段随机找
      p=$(( (RANDOM % 41000) + 20000 ))
    else
      p=$((p + 1))
    fi
  done
}

# 用户**显式指定**端口的最终裁定（v1.2.0：不再直接死）：
#   · 空闲 → 原样用
#   · 被自家旧服务占着 → 原样用（重跑场景，会原地重建）
#   · 被外人占着 → warn + 从这个端口往后自动挑一个空闲的，最终端口在
#     收尾信息里写得明明白白。旧版在这里直接 die 让用户重跑一遍 ——
#     无人值守/CI 里这就是卡死点；现在自愈，不再挡路。
resolve_port() {
  local p="$1" what="$2" exclude="${3:-}"
  case " $exclude " in *" $p "*) ;; *)
    if port_free "$p"; then printf '%s' "$p"; return 0; fi
    if port_owned_by_us "$p"; then printf '%s' "$p"; return 0; fi ;;
  esac
  warn "你指定的${what}端口 $p 已被别的程序占用，自动换一个空闲的"
  say "    （查是谁占的：sudo ss -lntp | grep :$p）"
  pick_port "$((p + 1))" "$exclude"
}

# 安装目录能否创建/写入？提前拦，避免下载完几百 MB 才失败。
check_install_dir_writable() {
  # 已有目录：校验写权限
  if [ -d "$INSTALL_DIR" ]; then
    if [ ! -w "$INSTALL_DIR" ]; then
      die "目录 $INSTALL_DIR 已存在但没有写权限。换个 --dir，或 sudo chown 一下。"
    fi
    if [ "$DRY_RUN" = 1 ]; then
      say "    [dry-run] 安装目录已存在且可写：$INSTALL_DIR"
    else
      ok "安装目录可用（已存在）：$INSTALL_DIR"
    fi
    return 0
  fi
  # 目录不存在：往上一层找已存在且可写的祖先
  local probe="$INSTALL_DIR"
  while [ ! -d "$probe" ]; do
    local parent; parent="$(dirname "$probe")"
    [ "$parent" = "$probe" ] && break
    probe="$parent"
  done
  if [ -w "$probe" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      say "    [dry-run] 安装目录将创建：$INSTALL_DIR（上级 $probe 可写）"
    else
      ok "安装目录将创建：$INSTALL_DIR"
    fi
    return 0
  fi
  die "创建不了目录 $INSTALL_DIR —— 它的上级 $probe 没有写权限。
       换个位置：sudo bash ${SELF} --dir /你的/可写/路径"
}

# 冲突保护：目标 systemd 单元 / 容器名如果已被「别人的服务」占着，就停下别动。
# 背景：本脚本按安装目录派生 unit 名（如 /opt/mvw → mvw-web.service）。
# 万一派生出的名字和机器上既有服务重名，直接写会把人家的服务覆盖掉
# （开发期就真发生过：默认名与既有 muse-video-web.service 撞名，把正式服务删了）。
assert_no_unit_conflict() {
  [ "$DRY_RUN" = 1 ] && return 0
  local unit="/etc/systemd/system/${WEB_UNIT}"
  [ -f "$unit" ] || return 0
  # 是我们的（内容里带我们的安装目录，或带我们的 Description）→ 放行，会原地重建
  if grep -q -- "$INSTALL_DIR" "$unit" 2>/dev/null; then return 0; fi
  if grep -q -- "$APP_LABEL (static site)" "$unit" 2>/dev/null; then return 0; fi
  die "服务名冲突：$unit 已经存在，而且不是本脚本装的（指向别的目录）。
       为避免覆盖别人的服务，已停止。
       换个安装目录即可自动换个服务名：sudo bash ${SELF} --dir /opt/别的名字"
}

assert_no_container_conflict() {
  [ "$DRY_RUN" = 1 ] && return 0
  command -v docker >/dev/null 2>&1 || return 0
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || return 0

  # 认领判定（任一命中即认为是我们的，放行原地重建）：
  #   ① docker compose 打的工程标签（最可靠）
  #   ② 镜像 tag 是 <容器名> 开头（本脚本 build 时就这么打）
  #   ③ 挂载点指向我们的安装目录
  #   ④ 容器是我们 compose 文件里定义的服务名
  local proj img mounts
  proj="$(docker inspect "$CONTAINER_NAME" \
            --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)"
  [ -n "$proj" ] && [ "$proj" != "<no value>" ] && return 0

  img="$(docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}}' 2>/dev/null)"
  case "$img" in "${CONTAINER_NAME}"|"${CONTAINER_NAME}:"*|*"/${CONTAINER_NAME}:"*) return 0 ;; esac

  mounts="$(docker inspect "$CONTAINER_NAME" \
              --format '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null)"
  case " $mounts " in *" $INSTALL_DIR "*) return 0 ;; esac
  case "$mounts" in *"$INSTALL_DIR"*) return 0 ;; esac

  # 只有「容器在跑，且上面四个信号一个都对不上」才认为是别人的
  die "容器名冲突：已有一个叫 $CONTAINER_NAME 的容器，而且不是本脚本装的。
       为避免误删别人的容器，已停止。
       换个安装目录即可自动换个容器名：sudo bash ${SELF} --dir /opt/别的名字"
}

# ── 依赖自动安装 ──────────────────────────────────────────────────────
pkg_install() {
  local pkgs="$1"
  [ "$NO_DEPS" = 1 ] && return 1
  case "$PKG" in
    apt) run apt-get update -qq && run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs ;;
    dnf) run dnf install -y -q $pkgs ;;
    yum) run yum install -y -q $pkgs ;;
    apk) run apk add --no-cache $pkgs ;;
    *)   return 1 ;;
  esac
}

docker_ok() { command -v docker >/dev/null 2>&1; }

compose_ok() { docker compose version >/dev/null 2>&1; }

# 统一的 compose 调用入口。
#
# ⚠️ 为什么必须显式带 -p（项目名）：
#    docker compose 默认拿**目录名**当项目名。目录名如果全是中文（国内太常见了，
#    比如 /opt/视频工作台），推导出来的项目名字符全被过滤掉，只剩空串，
#    compose 直接报 `project name must not be empty`，安装当场失败 ——
#    而报错信息里完全看不出是"目录名是中文"引起的，小白绝对查不出来。
#    显式给一个 ASCII 的项目名（和容器名一致）就彻底绕开这个坑，
#    顺带保证「不同目录 → 不同项目」，多份安装互不干扰。
compose() {
  docker compose -p "$CONTAINER_NAME" "$@"
}

ensure_docker() {
  if docker_ok; then
    ok "docker 已就绪（$(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//')）"
  else
    if [ "$NO_DEPS" = 1 ]; then
      die "这台机器上还没装 docker，而你用了 --no-deps。
       想让它自动装就去掉 --no-deps，或自己执行：
       curl -fsSL https://get.docker.com | sh"
    fi
    step "这台机器上还没有 docker，正在自动安装"
    dim "  （会从官方源下载，网慢就久一点，别急）"
    local installed=0
    # 方式 1：官方一键脚本
    if [ "$DRY_RUN" = 1 ]; then
      runsh "curl -fsSL https://get.docker.com | sh"
      installed=1
    else
      local tmp; tmp="$(mktemp)"
      if curl -fsSL --max-time 120 https://get.docker.com -o "$tmp" 2>/dev/null; then
        sh "$tmp" >/tmp/muse-docker-install.log 2>&1 || true
        docker_ok && installed=1     # 关键：不信退出码，验命令真的可用
      fi
      rm -f "$tmp"
      # 方式 2：发行版仓库
      if [ "$installed" != 1 ]; then
        warn "官方脚本没能装上，改用系统自带仓库"
        pkg_install "docker.io" || true
        docker_ok && installed=1
      fi
      # 方式 3：重装（包在、二进制没了的情况）
      if [ "$installed" != 1 ] && [ "$PKG" = apt ]; then
        warn "再试一次：重新安装 docker 包"
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall docker.io || true
        docker_ok && installed=1
      fi
    fi
    [ "$installed" = 1 ] || die "docker 自动安装失败。
       可以看一眼日志：/tmp/muse-docker-install.log
       或手动装：curl -fsSL https://get.docker.com | sh"
    run systemctl enable --now docker 2>/dev/null || true
    ok "docker 装好了"
  fi

  # compose 插件
  if compose_ok; then
    ok "docker compose 可用"
    return 0
  fi
  step "缺 docker compose，正在自动安装"
  if [ "$DRY_RUN" = 1 ]; then
    runsh "install compose plugin"
    return 0
  fi
  pkg_install "docker-compose-plugin" || true
  if ! compose_ok; then
    # 兜底：直接下插件二进制
    local ver; ver="$(curl -fsSL --max-time 20 \
      https://api.github.com/repos/docker/compose/releases/latest 2>/dev/null \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$ver" ] || ver="v2.29.7"
    run mkdir -p /usr/local/lib/docker/cli-plugins
    local url="https://github.com/docker/compose/releases/download/${ver}/docker-compose-linux-x86_64"
    run curl -fsSL --max-time 300 "$url" -o /usr/local/lib/docker/cli-plugins/docker-compose
    run chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  compose_ok && ok "docker compose 装好了" || warn "docker compose 仍不可用，后续可能出错"
}

ensure_git() {
  if command -v git >/dev/null 2>&1; then ok "git 已就绪"; return 0; fi
  step "缺 git，正在自动安装"
  pkg_install "git" || true
  command -v git >/dev/null 2>&1 && ok "git 装好了" || warn "git 装不上，将改用下载压缩包的方式"
}

# 公网 IP（云主机上 ip route 拿到的是内网 IP，必须走外部服务）
public_ip() {
  local ip=""
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    ip="$(curl -s --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]')"
    case "$ip" in *[!0-9.]*|"") ip="" ;; *) break ;; esac
  done
  printf '%s' "$ip"
}

# ── 状态文件（不 source！自己解析 + 键白名单） ────────────────────────
STATE_FILE=""
load_state() {
  STATE_FILE="$INSTALL_DIR/install.conf"
  [ -f "$STATE_FILE" ] || return 1
  local got=0
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    local k="${line%%=*}" v="${line#*=}"
    case "$k" in
      API_PORT) [ -z "$API_PORT" ] && API_PORT="$v"; got=1 ;;
      WEB_PORT) [ -z "$WEB_PORT" ] && WEB_PORT="$v"; got=1 ;;
      IMPORT_PORT) [ -z "$IMPORT_PORT" ] && IMPORT_PORT="$v"; got=1 ;;
      DOMAIN)   [ "$NO_DOMAIN" != 1 ] && [ -z "$DOMAIN" ] && DOMAIN="$v"; got=1 ;;
      # 把上次的 Key 读回来，重跑时复用它 —— 否则会生成新 Key，
      # 导致所有已配置的客户端和导号脚本全部失效（实测踩过）。
      API_KEY)  [ -z "$API_KEY" ] && API_KEY="$v"; got=1 ;;
      INSTALL_DIR) got=1 ;;
    esac
  done < "$STATE_FILE"
  [ "$got" = 1 ] && return 0
  # 有内容但一个可用键都没有 → 文件可能被改坏
  if [ -s "$STATE_FILE" ]; then
    warn "状态文件看起来被改坏了（$STATE_FILE），将使用默认值"
  fi
  return 1
}

save_state() {
  [ "$DRY_RUN" = 1 ] && return 0
  STATE_FILE="$INSTALL_DIR/install.conf"
  mkdir -p "$INSTALL_DIR"
  umask 077
  # ⚠️ API_KEY 一定要记进来：否则小白关掉安装窗口后就再也找不回 Key，
  #    而客户端接入、导号脚本都要用它。--status 也从这里读出来展示。
  cat > "$STATE_FILE" <<EOF
# $APP_LABEL 安装记录 —— 重跑脚本时会读这里的值
# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')
INSTALL_DIR=$INSTALL_DIR
API_PORT=$API_PORT
WEB_PORT=$WEB_PORT
IMPORT_PORT=$IMPORT_PORT
DOMAIN=$DOMAIN
API_KEY=$API_KEY
INSTALLED_AT=$(date +%s)
SCRIPT_VERSION=$SCRIPT_VERSION
EOF
  chmod 600 "$STATE_FILE" 2>/dev/null || true

  # 顺手把**脚本自己**存一份进安装目录（覆盖式，永远是最新版）。
  # 为什么必须做（实测）：小白多半是用「一条命令」装的（curl | bash），
  # 机器上根本没有脚本文件；装完想升级/卸载时他就懵了 —— 因为他手上
  # 既没有 install.sh，也不知道该从哪再弄一个。存一份在这儿之后，
  # 收尾提示就能给他一条**永远可用**的命令：
  #     sudo bash /opt/mvw/install.sh --status
  if [ -n "$SELF_PATH" ] && [ -f "$SELF_PATH" ]; then
    cp -f "$SELF_PATH" "$INSTALL_DIR/install.sh" 2>/dev/null && \
      chmod 755 "$INSTALL_DIR/install.sh" 2>/dev/null || true
  fi
}

# 生命周期命令（--status/--upgrade/--uninstall）该用哪条命令来提示？
# 优先用「安装目录里那份脚本副本」—— 哪怕用户当初是管道装的、或者把
# 下载的脚本删了，这条路也一定通。目录里还没有副本（首次安装中途）时，
# 退回脚本自身的名字。
self_hint() {
  if [ -n "${INSTALL_DIR:-}" ] && [ -f "$INSTALL_DIR/install.sh" ]; then
    printf 'bash %s/install.sh' "$INSTALL_DIR"
  else
    printf 'bash %s' "$SELF"
  fi
}

# 从已有安装里读出 API Key —— 优先状态文件，其次 compose 文件（兼容旧版本安装）。
#
# ⚠️ 两个坑（都实测踩过）：
#  1) 上游仓库自带 docker-compose.yml，里面有个**占位符** MUSE2API_KEY=m2a_change_me_to_your_secure_key。
#     首次安装时 fetch 完代码这个文件就存在了，若不加甄别就会把占位符当成"上次的 Key"。
#  2) 用 [A-Za-z0-9]* 匹配会在下划线处截断，把 m2a_change_me_to... 截成 m2a_change。
# 所以：正则要含下划线，且必须排除已知占位符。
read_existing_key() {
  local k="" raw=""
  if [ -f "$INSTALL_DIR/install.conf" ]; then
    k="$(sed -n 's/^API_KEY=//p' "$INSTALL_DIR/install.conf" 2>/dev/null | head -1)"
  fi
  if [ -z "$k" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    raw="$(sed -n 's/.*MUSE2API_KEY=\(m2a_[A-Za-z0-9_]*\).*/\1/p' \
          "$INSTALL_DIR/docker-compose.yml" 2>/dev/null | head -1)"
    k="$raw"
  fi
  # 排除上游占位符 / 明显无效值
  case "$k" in
    ''|m2a_change|m2a_change_me_to_your_secure_key|m2a_your_secret_admin_key_here)
      k="" ;;
  esac
  # 太短的一定不是我们生成的真钥匙（我们生成的是 m2a_ + 32 位 hex）
  if [ -n "$k" ] && [ "${#k}" -lt 20 ]; then k=""; fi
  printf '%s' "$k"
}

need_state() {
  if [ ! -d "$INSTALL_DIR" ]; then
    die "这台机器上还没有装过 $APP_LABEL（找不到目录 $INSTALL_DIR）。
       想安装的话跑：sudo bash ${SELF}"
  fi
  if [ ! -f "$STATE_FILE" ]; then
    # ⚠️ 目录在、记录读不到，有两种可能，别混为一谈：
    #    a) 文件真的不存在（上次装到一半中断）→ 让他重跑安装
    #    b) 文件存在但**当前用户没权限读**（目录是 root 0700）→ 别叫他"重装"，
    #       而是要他用 sudo。实测：普通用户跑 --status 会走到这里，
    #       若只按 a 处理，会对着一个装好的服务说"还没装过"，纯耽误事。
    if [ ! -e "$STATE_FILE" ] && [ ! -r "$INSTALL_DIR" ]; then
      die "看不到安装记录（目录 $INSTALL_DIR 需要管理员权限才能读）。
       加上 sudo 再试：sudo bash ${SELF} --status"
    fi
    die "目录 $INSTALL_DIR 在，但没有安装记录 —— 多半是上次装到一半中断了。
       直接重跑一次安装就能接上：sudo bash ${SELF}"
  fi
}

# ── 资源体检：内存 / 磁盘 ─────────────────────────────────────────────
#
# 这套栈的容器里跑 Chromium（shm 2G），最现实的失败是 **OOM**：
# 1G 内存的小鸡在「点生成」那一刻容器被内核杀掉，docker logs 只有一句
# "Killed"，小白完全看不出原因，只会觉得「这软件坏了」。
# 所以装之前先量一下内存，太小就**明说**（给数字、给出路），
# 但不硬拦 —— 2G 也能跑，只是偶尔卡；决定权留给用户。
check_resources() {
  # 内存（kB）→ 换算 GB 时用整数近似，够用了
  local mem_kb=0 mem_gb=0
  if [ -r /proc/meminfo ]; then
    mem_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  fi
  case "$mem_kb" in ''|*[!0-9]*) mem_kb=0 ;; esac
  if [ "$mem_kb" -gt 0 ]; then
    mem_gb=$(( mem_kb / 1024 / 1024 ))
    if [ "$mem_gb" -ge 4 ]; then
      ok "内存：约 ${mem_gb} GB（够用）"
    elif [ "$mem_gb" -ge 2 ]; then
      ok "内存：约 ${mem_gb} GB（够用；同时跑别的服务时可能有点紧）"
    elif [ "$mem_gb" -ge 1 ]; then
      warn "内存只有约 ${mem_gb} GB —— 这套工具要跑无头浏览器，1G 容易在生成视频时被系统杀掉。"
      warn "   现象是「点了生成，然后任务莫名失败」，日志里只有 Killed。"
      warn "   建议升级到 2 核 4G，或先加一块 swap（临时顶一下）："
      warn "     sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
      warn "   继续装也可以，只是别指望它稳定出片。"
    else
      warn "读不到内存大小（/proc/meminfo 不可读），跳过内存检查。"
    fi
  fi

  # 磁盘：本体 + 浏览器镜像加起来大约 2GB，留 3GB 才舒服
  local avail_kb=0
  avail_kb="$(df -Pk "${INSTALL_DIR%/*}" 2>/dev/null | awk 'NR==2{print $4}')"
  case "$avail_kb" in ''|*[!0-9]*) avail_kb=0 ;; esac
  if [ "$avail_kb" -gt 0 ]; then
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [ "$avail_gb" -lt 3 ]; then
      warn "磁盘剩余约 ${avail_gb} GB —— 这套工具连镜像加数据要 2GB 出头，可能会装到一半写满。"
      warn "   清一清旧文件，或者换个盘：df -h"
    else
      ok "磁盘剩余：约 ${avail_gb} GB"
    fi
  fi
}

# ── 装机主流程 ────────────────────────────────────────────────────────
API_KEY=""

# 容器名与服务名从安装目录派生 —— 这样同一台机器可以并存多份，
# 分别放到不同目录（--dir）用不同端口，互不干扰。
derive_names() {
  local base
  base="$(basename "$INSTALL_DIR")"
  # 只保留字母数字和连字符，避免 docker 容器名非法
  base="$(printf '%s' "$base" | tr -c 'a-zA-Z0-9_.-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
  # ⚠️ 目录名如果全是中文/emoji（国内很常见，比如 /opt/视频工作台），
  #    上面那步会把整串都换成 '-'，清洗完**什么都不剩**。
  #    早期版本这时直接退回默认名 "$APP_NAME"，后果是：你在两个不同中文目录
  #    各装一份，两份的容器名/服务名**一模一样**，第二份会覆盖第一份 ——
  #    而且报错信息是别的（project name must not be empty），小白根本联想不到。
  #    这里改成：清不干净时挂一个目录路径的短哈希，保证「不同目录 → 不同名字」。
  if [ -z "$base" ]; then
    local h
    h="$(printf '%s' "$INSTALL_DIR" | cksum | awk '{print $1}')"
    base="${APP_NAME}-$(printf '%x' "$h" | cut -c1-6)"
  fi
  CONTAINER_NAME="$base"
  WEB_UNIT="${base}-web.service"
  CADDY_NAME="${base}-caddy"
}
CONTAINER_NAME="$APP_NAME"
WEB_UNIT="${APP_NAME}-web.service"
CADDY_NAME="${APP_NAME}-caddy"

gen_key() {
  local k=""
  if command -v openssl >/dev/null 2>&1; then
    k="$(openssl rand -hex 16 2>/dev/null)"
  fi
  if [ -z "$k" ]; then
    k="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  printf 'm2a_%s' "$k"
}


# v1.3.0：把导号 sidecar 写进安装目录（compose 以只读卷挂载进容器）。
# ⚠️ 内嵌全文、不依赖网络 —— 单文件安装（curl 一个 install.sh 就跑完）是本
#    脚本的立身之本，不能为这一个文件破例。仓库里也单独存了一份
#    import_sidecar.py 供审阅，两边内容必须一致。
write_importer() {
  local dir="$1"
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s[dry-run]%s 写入 %s/import_sidecar.py\n' "$C_CYN" "$C_OFF" "$dir"
    return 0
  fi
  umask 022
  cat > "$dir/import_sidecar.py" <<'MUSEIMPORT'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Muse 视频工作台 · 网页一键导号 sidecar（v1.5.0）

干什么用：
    原版导号要在用户自己的电脑上装 Python、跑脚本、手填服务器地址和 Key。
    这个 sidecar 把「登录 muse.ai」整个搬进网页 —— 它在本容器里起一个无头
    Chromium，把页面画面实时投屏到用户的浏览器（CDP screencast），用户的
    鼠标键盘操作转发回去。用户在里面登录 muse.ai，session cookie 一出现就
    自动抓下来、自动注册进 muse2api 账号池。用户全程只需要一个浏览器。

两条进入路径：
    · ?key=<MUSE2API_KEY>    手动粘贴 Key（老方式，长期有效）
    · ?token=<导号令牌>       install.sh --add-account 在终端生成，15 分钟有效；
                             页面拿到 token 跳过填 Key 直接开窗，终端同时轮询
                             /api/token_status?since=N 显示每一个导入结果

多账号（v1.5.0）：
    · 一条令牌 = 一个 15 分钟的「导号窗口」，期间可以连着导多个账号 ——
      网页里导完一个点「再导一个」即可，终端会依次报出每个账号。
    · 每次成功导入自动把这个窗口续期 15 分钟，连续导号不会中途失效。
    · 同一个 muse.ai 账号重复导入不再堆重复条目：按邮箱匹配，命中就更新
      那一份的 cookie（走 /admin/accounts/{id}/cookies），池子里一个账号只占一行。

安全模型：
    · 网页本身不含任何密钥（连 HTML 都是公开无害的）
    · WebSocket 连接必须带有效 key 或有效令牌；同一令牌同时只允许一个窗口
    · 令牌文件在宿主机 ./runtime 卷上，两边都「读-改-原子替换」
    · cookie 只经本机回环进账号池，不落地、不外发

依赖：复用 muse2api 镜像（chromium + python + fastapi/uvicorn 都在），
    零额外下载。本文件由 install.sh 的 write_importer() 写入安装目录，
    compose 以只读卷挂载进来。
"""

from __future__ import annotations

import asyncio
import base64
import hmac
import json
import os
import queue
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import urllib.request
import urllib.error

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
import uvicorn

# ── 配置（compose 注入）──────────────────────────────────────────────
API_KEY = os.environ.get("MUSE2API_KEY", "")
API_BASE = os.environ.get(
    "MUSE2API_INTERNAL_BASE",
    # ⚠️ 默认 bridge 网络上容器间没有名字 DNS，但宿主的网关 IP 永远可达，
    #    而 API 发布在 0.0.0.0 上 —— 走网关 IP 即回到本机 API 端口。
    f"http://172.17.0.1:{os.environ.get('MUSE2API_PORT', '18610')}",
)
IMPORT_PORT = int(os.environ.get("IMPORT_PORT", "18620"))
TOKENS_FILE = os.environ.get("TOKENS_FILE", "/runtime/import_tokens.json")
CHROMIUM = os.environ.get("CHROMIUM_BIN", "/usr/bin/chromium")
CDP_PORT = 19999  # 容器内回环端口，不发布
LOGIN_URL = "https://muse.ai/login"
DOMAIN_HINT = "muse.ai"
SESSION_COOKIE = "hatch_sess"     # 登录成功后必然出现的会话 cookie
VIEW_W, VIEW_H = 1280, 800
IDLE_TIMEOUT = 600                # 无操作 10 分钟自动回收浏览器
TOKEN_TTL = 900                   # 导号令牌窗口时长（每次成功导入自动续期）

# ── 极简 WebSocket 客户端（RFC6455 文本帧，stdlib，供 CDP 用）────────
#    与上游 tools/get_muse_cookie.py 里的 WS 同族：容器里没有 websocket-client，
#    自己实现一个够用品。
#
#    ⚠️ 读写分离（v1.4.1 修复的核心）：
#    早期版本让多个线程各自 recv 同一条 socket —— 收帧线程阻塞等画面帧时，
#    输入指令（Input.dispatch*）的响应包会被它当帧吃掉，指令线程永远等不到
#    响应、超时、异常被静默吞掉。表现为：画面活着，点击/键盘全部无效。
#    现在：一个后台 pump 线程独占 recv，带 id 的响应按 id 路由给等待中的
#    call()，无 id 的事件交给注册的 handler。发送端加锁即可多线程并发 call。


class WS:
    def __init__(self, url: str, timeout: float = 15.0):
        assert url.startswith("ws://"), url
        rest = url[5:]
        hostport, _, path = rest.partition("/")
        path = "/" + path
        host, _, port = hostport.partition(":")
        self.sock = socket.create_connection((host, int(port or 80)), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("WebSocket 握手失败")
            buf += chunk
        if b" 101 " not in buf.split(b"\r\n")[0]:
            raise ConnectionError("WebSocket 握手被拒绝")
        self._id = 0
        self._send_lock = threading.Lock()
        self._pending: dict[int, "queue.Queue"] = {}
        self._handlers = []
        self._closed = False
        # pump 独占 recv；握手完成后转阻塞模式（靠 close() 唤醒），
        # 不能用超时读 —— 超时会在半帧中间炸掉，字节流错位后整个连接就废了。
        self.sock.settimeout(None)
        self._pump = threading.Thread(target=self._pump_loop, daemon=True)
        self._pump.start()

    def on_event(self, handler):
        """注册 CDP 事件回调（在 pump 线程里跑，别在里面做阻塞调用）。"""
        self._handlers.append(handler)

    def _pump_loop(self):
        while not self._closed:
            try:
                msg = self.recv_msg()
            except Exception:
                break
            mid = msg.get("id")
            q = self._pending.pop(mid, None) if mid is not None else None
            if q is not None:
                q.put(msg)
            else:
                for h in list(self._handlers):
                    try:
                        h(msg)
                    except Exception:
                        pass
        # 连接死了：唤醒所有还在等响应的调用者，别让它们傻等到超时
        for q in list(self._pending.values()):
            q.put(None)
        self._pending.clear()

    def _frame(self, payload: bytes):
        head = bytearray([0x81])
        n = len(payload)
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head.append(0x80 | 126)
            head += struct.pack(">H", n)
        else:
            head.append(0x80 | 127)
            head += struct.pack(">Q", n)
        mask = os.urandom(4)
        head += mask
        self.sock.sendall(bytes(head) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _read(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("WebSocket 断开")
            buf += chunk
        return buf

    def recv_msg(self) -> dict:
        payload = b""
        while True:
            b1, b2 = self._read(2)
            fin = b1 & 0x80
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            if b2 & 0x80:  # 服务端→客户端不掩码，防御性处理
                mask = self._read(4)
                data = bytes(x ^ mask[i % 4] for i, x in enumerate(self._read(n)))
            else:
                data = self._read(n)
            payload += data
            if fin:
                return json.loads(payload.decode("utf-8", "replace"))

    def call(self, method: str, params: dict | None = None, timeout: float = 15.0) -> dict:
        with self._send_lock:
            self._id += 1
            mid = self._id
            q: "queue.Queue" = queue.Queue()
            self._pending[mid] = q
            self._frame(json.dumps({"id": mid, "method": method,
                                    "params": params or {}}).encode())
        try:
            msg = q.get(timeout=timeout)
        except queue.Empty:
            self._pending.pop(mid, None)
            raise TimeoutError(f"CDP {method} 超时")
        if msg is None:
            raise ConnectionError("WebSocket 断开")
        if "error" in msg:
            raise RuntimeError(f"CDP {method}: {msg['error']}")
        return msg.get("result", {})

    def close(self):
        self._closed = True
        try:
            self.sock.close()
        except Exception:
            pass


# ── 无头浏览器会话 ────────────────────────────────────────────────────


class BrowserSession:
    """一个无头 Chromium 实例 + 两条 CDP 通道（页面级/浏览器级）。"""

    def __init__(self, profile_dir: str):
        self.profile_dir = profile_dir
        # 画面帧队列：page_ws 的 pump 线程投进来，ws_endpoint 的 frames_out 消费
        self.frame_q: "queue.Queue" = queue.Queue()
        self.proc = subprocess.Popen([
            CHROMIUM, "--headless=new", "--no-sandbox", "--disable-gpu",
            "--disable-dev-shm-usage", f"--remote-debugging-port={CDP_PORT}",
            "--remote-debugging-address=127.0.0.1",
            f"--user-data-dir={profile_dir}",
            f"--window-size={VIEW_W},{VIEW_H}",
            "--lang=zh-CN", LOGIN_URL,
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.page_ws: WS | None = None
        self.browser_ws: WS | None = None
        self._connect()

    def _wait_cdp(self, timeout: float = 30.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(
                        f"http://127.0.0.1:{CDP_PORT}/json/version", timeout=2) as r:
                    if r.status == 200:
                        return
            except Exception:
                time.sleep(0.4)
        raise RuntimeError("Chromium CDP 没起来")

    def _connect(self):
        self._wait_cdp()
        with urllib.request.urlopen(
                f"http://127.0.0.1:{CDP_PORT}/json/version", timeout=5) as r:
            ver = json.loads(r.read().decode())
        self.browser_ws = WS(ver["webSocketDebuggerUrl"])
        with urllib.request.urlopen(
                f"http://127.0.0.1:{CDP_PORT}/json", timeout=5) as r:
            targets = json.loads(r.read().decode())
        page = next(t for t in targets if t.get("type") == "page"
                    and DOMAIN_HINT in (t.get("url") or ""))
        self.page_ws = WS(page["webSocketDebuggerUrl"])
        self.page_ws.on_event(self._on_page_event)
        self.page_ws.call("Page.enable")
        self.page_ws.call("Emulation.setDeviceMetricsOverride", {
            "width": VIEW_W, "height": VIEW_H, "deviceScaleFactor": 1, "mobile": False})

    def _on_page_event(self, msg: dict):
        """pump 线程里跑：只投队列，绝不阻塞（ack 由消费线程补）。"""
        if msg.get("method") == "Page.screencastFrame":
            self.frame_q.put(msg.get("params", {}))

    def start_screencast(self):
        self.page_ws.call("Page.startScreencast", {
            "format": "jpeg", "quality": 60,
            "maxWidth": VIEW_W, "maxHeight": VIEW_H, "everyNthFrame": 1})

    def stop_screencast(self):
        try:
            self.page_ws.call("Page.stopScreencast")
        except Exception:
            pass

    def ack(self, session_id: int):
        try:
            self.page_ws.call("Page.screencastFrameAck", {"sessionId": session_id})
        except Exception:
            pass

    def cookies(self) -> dict[str, dict]:
        res = self.browser_ws.call("Storage.getCookies", {}, timeout=10)
        out = {}
        for c in res.get("cookies", []):
            if DOMAIN_HINT not in (c.get("domain") or ""):
                continue
            name = c.get("name")
            if not name:
                continue
            try:
                exp = int(float(c.get("expires", -1)))
            except (TypeError, ValueError):
                exp = -1
            out[name] = {"value": c.get("value", ""), "expires": exp}
        return out

    def login_email(self) -> str:
        try:
            r = self.page_ws.call("Runtime.evaluate", {
                "expression": (
                    "(function(){try{"
                    "var m=document.querySelector('meta[name=user-email]');"
                    "if(m&&m.content)return m.content;"
                    "var t=document.body?document.body.innerText:'';"
                    "var x=t.match(/[\\w.+-]+@[\\w-]+\\.[\\w.]+/);"
                    "return x?x[0]:'';}catch(e){return '';}})()"
                ), "returnByValue": True}, timeout=8)
            return str((r.get("result") or {}).get("value") or "").strip()
        except Exception:
            return ""

    def dispatch_mouse(self, ev: dict):
        p = {"x": ev["x"], "y": ev["y"]}
        kind = ev["kind"]
        if kind == "move":
            p["type"] = "mouseMoved"
        elif kind == "down":
            # buttons=1 标明左键正按着 —— 缺了这个，一些前端框架不认这次点击
            p.update(type="mousePressed", button="left", clickCount=1, buttons=1)
        elif kind == "up":
            p.update(type="mouseReleased", button="left", clickCount=1, buttons=0)
        elif kind == "wheel":
            p.update(type="mouseWheel", deltaX=ev.get("dx", 0), deltaY=ev.get("dy", 0))
        else:
            return
        self.page_ws.call("Input.dispatchMouseEvent", p, timeout=5)

    _KEYMAP = {"Enter": 13, "Backspace": 8, "Tab": 9, "Escape": 27,
               "Delete": 46, "Home": 36, "End": 35, "PageUp": 33, "PageDown": 34,
               "ArrowLeft": 37, "ArrowUp": 38, "ArrowRight": 39, "ArrowDown": 40}

    def dispatch_key(self, ev: dict):
        key = ev.get("key", "")
        if len(key) == 1:  # 可打印字符：insertText 最稳（含非 ASCII）
            self.page_ws.call("Input.insertText", {"text": key}, timeout=5)
            return
        code = self._KEYMAP.get(key)
        if code is None:
            return
        for t in ("rawKeyDown", "keyUp"):
            self.page_ws.call("Input.dispatchKeyEvent", {
                "type": t, "key": key, "code": key,
                "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code}, timeout=5)

    def kill(self):
        self.stop_screencast()
        for ws in (self.page_ws, self.browser_ws):
            if ws:
                ws.close()
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


# ── 账号池 API ────────────────────────────────────────────────────────


def _api(path: str, method: str = "GET", payload: dict | None = None) -> dict:
    url = API_BASE.rstrip("/") + path
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Authorization": f"Bearer {API_KEY}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read().decode("utf-8", "replace")
        return json.loads(body) if body.strip() else {}


def list_accounts() -> list[dict]:
    """账号池里的账号列表（按 label 判重用）。拿不到就返回空表。"""
    try:
        r = _api("/admin/accounts")
    except Exception:
        return []
    if isinstance(r, list):
        return r
    for k in ("accounts", "items", "data", "list"):
        v = r.get(k)
        if isinstance(v, list):
            return v
    return []


def pool_count() -> int:
    try:
        r = _api("/admin/accounts")
        if isinstance(r, list):
            return len(r)
        for k in ("accounts", "items", "data", "list"):
            v = r.get(k)
            if isinstance(v, list):
                return len(v)
    except Exception:
        pass
    return -1


def import_account(label: str, cookies: dict[str, dict]) -> dict:
    """把一次登录抓到的 cookie 写进账号池。

    v1.5.0：先按邮箱找同款账号 —— 命中就更新它那份 cookie（走
    /admin/accounts/{id}/cookies，该端点会重置有效期锚点），不新增条目。
    只有真正的新账号才追加。返回结果带 updated 标志。
    """
    payload_cookies = {k: v["value"] for k, v in cookies.items()}
    payload_expires = {k: v["expires"] for k, v in cookies.items() if v["expires"] > 0}

    key = (label or "").strip().lower()
    existing = None
    if key:
        for a in list_accounts():
            if (a.get("label") or "").strip().lower() == key:
                existing = a
                break

    if existing:
        r = _api(f"/admin/accounts/{existing['id']}/cookies", "POST", {
            "cookies": payload_cookies, "expires": payload_expires})
        r = dict(r) if isinstance(r, dict) else {}
        r["updated"] = True
        r["id"] = existing["id"]
        return r

    r = _api("/admin/accounts", "POST", {
        "label": label,
        "cookies": payload_cookies,
        "expires": payload_expires,
    })
    r = dict(r) if isinstance(r, dict) else {}
    r["updated"] = False
    return r


# ── 导号令牌（install.sh --add-account 在宿主机生成）──────────────────
#    文件经 ./runtime 卷共享。宿主机只「加新令牌+清理过期」，本进程只
#    「回写导入计数」——两边都是读-改-原子替换，竞争窗口的最坏结果只是
#    丢一次计数（终端少报一次），不会丢令牌本身。
_active_tokens: set[str] = set()      # 正被某条 ws 占用的令牌


def _load_tokens() -> dict:
    try:
        with open(TOKENS_FILE, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {}


def _save_tokens(tokens: dict) -> None:
    directory = os.path.dirname(TOKENS_FILE) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tokens-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(tokens, f)
        os.replace(tmp, TOKENS_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass


def token_valid(token: str) -> bool:
    """令牌只在它的时间窗口内有效（不因用过一次而废）。"""
    if not token:
        return False
    m = _load_tokens().get(token)
    if not isinstance(m, dict):
        return False
    try:
        return float(m.get("expires", 0)) > time.time()
    except (TypeError, ValueError):
        return False


def record_import(token: str, email: str) -> None:
    """记一次成功导入：计数 +1、记住邮箱，并把窗口再续 15 分钟。

    v1.5.0 起令牌不再「用一次就废」—— 一个窗口里可以连着导多个账号
    （网页上点「再导一个」），连续导入也不会中途过期。
    """
    tokens = _load_tokens()
    m = tokens.get(token)
    if not isinstance(m, dict):
        return
    try:
        m["imports"] = int(m.get("imports", 0) or 0) + 1
    except (TypeError, ValueError):
        m["imports"] = 1
    m["email"] = email
    m["expires"] = time.time() + TOKEN_TTL
    tokens[token] = m
    _save_tokens(tokens)


# ── 网页（无任何密钥，key 由用户输入后仅存 sessionStorage）────────────

PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>导入 muse.ai 账号</title>
<style>
  body{margin:0;font-family:system-ui,sans-serif;background:#1c1c1e;color:#eee;
       display:flex;flex-direction:column;align-items:center;min-height:100vh}
  .bar{width:100%;max-width:__W__px;padding:10px 14px;box-sizing:border-box}
  h1{font-size:16px;margin:8px 0}
  .hint{font-size:13px;color:#9a9aa0;line-height:1.7}
  #keyrow{display:flex;gap:8px;margin:10px 0}
  input{flex:1;padding:9px 12px;border-radius:8px;border:1px solid #3a3a3e;
        background:#2c2c2e;color:#eee;font-size:14px;outline:none}
  button{padding:9px 16px;border-radius:8px;border:0;background:#0a84ff;
         color:#fff;font-size:14px;cursor:pointer}
  button:disabled{background:#3a3a3e;cursor:default}
  #stage{display:none;position:relative;border-radius:10px;overflow:hidden;
         box-shadow:0 8px 40px rgba(0,0,0,.5)}
  #view{display:block;cursor:pointer;background:#000}
  #status{padding:10px 14px;font-size:14px;min-height:20px}
  .ok{color:#30d158}.err{color:#ff453a}
</style></head><body>
<div class="bar">
  <h1>导入 muse.ai 账号 → 视频工作台</h1>
  <div class="hint" id="hints">
    ① 粘贴 API Key（--status 能看到）→ ② 点「打开登录窗口」→
    ③ 在下面的窗口里登录 muse.ai → ④ 看到「导入成功」就好了。
    想加第二个账号，登录成功后点「再导一个」。
  </div>
  <div id="keyrow">
    <input id="key" type="password" placeholder="API Key（形如 m2a_xxxx…）">
    <button id="start" onclick="start()">打开登录窗口</button>
  </div>
  <div id="stage">
    <img id="view" width="__W__" height="__H__" alt="登录窗口加载中…">
  </div>
  <div id="status"></div>
</div>
<script>
const stage=document.getElementById('stage'),view=document.getElementById('view'),
      statusEl=document.getElementById('status'),keyEl=document.getElementById('key');
// v1.4.0：终端 --add-account 生成的链接带 ?token=，跳过填 Key 直接开窗
// v1.5.0：令牌有效期内可以连着导多个账号（导完点「再导一个」）
const urlTok=new URLSearchParams(location.search).get('token')||'';
if(urlTok){
  document.getElementById('keyrow').style.display='none';
  document.getElementById('hints').innerHTML='这是终端生成的导号窗口（15 分钟内有效，可以连着导多个账号）。'+
    '<br>登录窗口正在打开 —— 在里面登录 muse.ai，看到「导入成功」就好了。'+
    '<br>想导下一个账号，点「再导一个账号」，再登录另一个 muse.ai 账号。';
}
keyEl.value=sessionStorage.getItem('mvw_key')||'';
let ws=null,again=false;
function say(t,cls){statusEl.textContent=t;statusEl.className=cls||'';}
function start(){
  const key=keyEl.value.trim();
  if(!urlTok&&!key){say('先填 API Key','err');return;}
  if(!urlTok)sessionStorage.setItem('mvw_key',key);
  document.getElementById('start').disabled=true;
  say('正在启动登录窗口…');
  const q=urlTok?'token='+encodeURIComponent(urlTok):'key='+encodeURIComponent(key);
  ws=new WebSocket((location.protocol==='https:'?'wss':'ws')+'://'+location.host+'/ws?'+q);
  ws.onmessage=e=>{
    const m=JSON.parse(e.data);
    if(m.type==='frame'){stage.style.display='block';view.src='data:image/jpeg;base64,'+m.data;}
    else if(m.type==='info'){say(m.text);}
    else if(m.type==='done'){
      say((m.updated?'✓ 这个账号之前导过，已刷新它的会话：':'✓ 导入成功：')+m.label+
          (m.count>=0?'（账号池现有 '+m.count+' 个）':''),'ok');
      const b=document.createElement('button');b.textContent='再导一个账号';
      b.style.marginLeft='10px';
      b.onclick=()=>{b.remove();say('正在重置窗口，换个 muse.ai 账号登录…');
        ws.send(JSON.stringify({kind:'again'}));};
      statusEl.appendChild(b);
    }
    else if(m.type==='error'){say('× '+m.text,'err');document.getElementById('start').disabled=false;}
  };
  ws.onclose=()=>{if(statusEl.className!=='ok'){say('连接断开了，刷新页面重试','err');
    document.getElementById('start').disabled=false;}};
  ws.onerror=()=>say(urlTok?'× 连接失败（链接过期了？回终端重新跑 --add-account 生成一条新的）':'× 连接失败（Key 不对？服务没起来？）','err');
}
if(urlTok)start();
function pos(e){const r=view.getBoundingClientRect();
  return{x:Math.round((e.clientX-r.left)*__W__/r.width),
         y:Math.round((e.clientY-r.top)*__H__/r.height)};}
view.addEventListener('mousemove',e=>{if(ws&&ws.readyState===1){const p=pos(e);
  ws.send(JSON.stringify({kind:'move',...p}));}});
view.addEventListener('mousedown',e=>{const p=pos(e);
  ws.send(JSON.stringify({kind:'down',...p}));});
view.addEventListener('mouseup',e=>{const p=pos(e);
  ws.send(JSON.stringify({kind:'up',...p}));});
view.addEventListener('wheel',e=>{e.preventDefault();const p=pos(e);
  ws.send(JSON.stringify({kind:'wheel',...p,dx:e.deltaX,dy:e.deltaY}));},{passive:false});
document.addEventListener('keydown',e=>{
  if(!ws||ws.readyState!==1||document.activeElement===keyEl)return;
  if(e.key.length===1||['Enter','Backspace','Tab','Escape','Delete','Home','End',
     'PageUp','PageDown','ArrowLeft','ArrowUp','ArrowRight','ArrowDown'].includes(e.key)){
    e.preventDefault();ws.send(JSON.stringify({kind:'key',key:e.key}));}});
</script></body></html>""".replace("__W__", str(VIEW_W)).replace("__H__", str(VIEW_H))


# ── FastAPI 服务 ──────────────────────────────────────────────────────

app = FastAPI()
_busy = asyncio.Lock()


@app.get("/", response_class=HTMLResponse)
async def index():
    return PAGE


@app.get("/healthz")
async def healthz():
    return {"ok": True, "service": "mvw-importer"}


@app.get("/api/token_status")
async def token_status(token: str = "", since: int = 0):
    """终端 install.sh --add-account 的轮询端点（只经回环调用）。

    since = 终端已经报过的导入次数（第一次问传 0）。
    返回的 state：
      pending   链接已生成，还没人打开
      active    浏览器窗口正开着，用户正在里面操作
      done      本次窗口又导进来了一个（imports > since），带 email / imports / count
      expired   窗口超时（15 分钟无人操作）
      unknown   令牌不存在
    """
    if not token:
        return {"state": "unknown"}
    m = _load_tokens().get(token)
    if not isinstance(m, dict):
        return {"state": "unknown"}
    try:
        expires = float(m.get("expires", 0))
    except (TypeError, ValueError):
        return {"state": "unknown"}
    try:
        imports = int(m.get("imports", 0) or 0)
    except (TypeError, ValueError):
        imports = 0
    if imports > since:
        return {"state": "done", "email": m.get("email", ""),
                "imports": imports, "count": pool_count()}
    if expires <= time.time():
        return {"state": "expired"}
    if token in _active_tokens:
        return {"state": "active"}
    return {"state": "pending"}


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    key = ws.query_params.get("key", "")
    token = ws.query_params.get("token", "")
    via_token = False
    if key and API_KEY and hmac.compare_digest(key, API_KEY):
        pass  # 主 Key 通道（网页手填 Key 的老方式，长期有效）
    elif token and token_valid(token):
        # ⚠️ 令牌在导入成功前允许刷新重连（不因断开而作废），但同一时刻
        #    只允许一个窗口占用 —— 防止链接被转发后多人同时开。
        if token in _active_tokens:
            await ws.accept()
            await ws.send_json({"type": "error", "text": "这条链接已经在另一个窗口打开了"})
            await ws.close()
            return
        via_token = True
    else:
        await ws.close(code=4401)
        return
    if _busy.locked():
        await ws.accept()
        await ws.send_json({"type": "error",
                            "text": "正有人在用导入窗口，稍等一会再刷新"})
        await ws.close()
        return
    if via_token:
        _active_tokens.add(token)
    await ws.accept()
    async with _busy:
        session: BrowserSession | None = None
        loop = asyncio.get_running_loop()
        try:
            profile = tempfile.mkdtemp(prefix="muse-login-")
            try:
                session = await loop.run_in_executor(None, BrowserSession, profile)
            except Exception as e:
                await ws.send_json({"type": "error", "text": f"浏览器启动失败：{e}"})
                return
            await ws.send_json({"type": "info", "text": "登录窗口就绪，在里面登录 muse.ai"})
            await loop.run_in_executor(None, session.start_screencast)

            stop = asyncio.Event()
            last_active = time.time()
            # 本窗口已经导过的邮箱 —— cookie_watch 每 2 秒轮一次，没有这个集合
            # 就会对着同一个已登录账号反复导入（v1.5.0 修）。点「再导一个」
            # 会换干净 profile 并清空它。
            imported_labels: set[str] = set()

            async def frames_out():
                """画面帧 → 浏览器。帧由 page_ws 的 pump 线程投进 frame_q，
                这里只消费（ack + 转发），不再直接碰 socket —— 多线程抢读
                同一条 socket 就是「画面能动、点击全死」的病根。"""
                while not stop.is_set():
                    try:
                        p = await loop.run_in_executor(
                            None, lambda: session.frame_q.get(True, 1.0))
                    except queue.Empty:
                        p = None
                    except Exception:
                        stop.set()
                        return
                    if p is not None:
                        await loop.run_in_executor(
                            None, session.ack, p.get("sessionId", 0))
                        try:
                            await ws.send_json({"type": "frame", "data": p.get("data", "")})
                        except Exception:
                            stop.set()
                            return
                    if time.time() - last_active > IDLE_TIMEOUT:
                        await ws.send_json({"type": "error", "text": "闲置太久，窗口已回收，刷新重来"})
                        stop.set()
                        return

            async def input_in():
                """浏览器输入事件 → CDP。"""
                nonlocal last_active
                while not stop.is_set():
                    try:
                        raw = await asyncio.wait_for(ws.receive_text(), timeout=1.0)
                    except asyncio.TimeoutError:
                        continue
                    except WebSocketDisconnect:
                        stop.set()
                        return
                    last_active = time.time()
                    try:
                        ev = json.loads(raw)
                    except Exception:
                        continue
                    kind = ev.get("kind")
                    try:
                        if kind == "again":
                            # 重置：换干净 profile 重启，继续同一条 ws
                            await loop.run_in_executor(None, _reset_browser, session)
                            imported_labels.clear()
                        elif kind == "key":
                            await loop.run_in_executor(None, session.dispatch_key, ev)
                        else:
                            await loop.run_in_executor(None, session.dispatch_mouse, ev)
                    except Exception:
                        pass

            async def cookie_watch():
                """盯 session cookie：出现 → 自动抓全量 → 自动注册账号池。"""
                while not stop.is_set():
                    await asyncio.sleep(2.0)
                    try:
                        cookies = await loop.run_in_executor(None, session.cookies)
                        if SESSION_COOKIE not in cookies:
                            continue
                        email = await loop.run_in_executor(None, session.login_email)
                        if not email:
                            continue  # 登录中转态，等页面稳定
                        label = email
                        if label.strip().lower() in imported_labels:
                            continue  # 这个账号本窗口已经导过了
                        res = await loop.run_in_executor(
                            None, import_account, label, cookies)
                        imported_labels.add(label.strip().lower())
                        if via_token:
                            # 一次成功导入 = 一次进度；终端的
                            # /api/token_status?since=N 轮询会依次拿到每个结果
                            await loop.run_in_executor(None, record_import, token, label)
                        await ws.send_json({
                            "type": "done", "label": label, "count": pool_count(),
                            "updated": bool(isinstance(res, dict) and res.get("updated"))})
                    except WebSocketDisconnect:
                        stop.set()
                        return
                    except Exception:
                        pass

            def _reset_browser(sess: BrowserSession):
                sess.kill()
                new_profile = tempfile.mkdtemp(prefix="muse-login-")
                ns = BrowserSession(new_profile)
                sess.__dict__.update(ns.__dict__)
                sess.start_screencast()

            tasks = [asyncio.create_task(t()) for t in
                     (frames_out, input_in, cookie_watch)]
            await stop.wait()
            for t in tasks:
                t.cancel()
        finally:
            if session:
                await asyncio.get_running_loop().run_in_executor(None, session.kill)
            if via_token:
                _active_tokens.discard(token)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=IMPORT_PORT, log_level="warning")
MUSEIMPORT
}

write_compose() {
  local dir="$1"
  local compose_file="$dir/docker-compose.yml"
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s[dry-run]%s 写入 %s（含真实密钥，权限 600）\n' "$C_CYN" "$C_OFF" "$compose_file"
    return 0
  fi
  umask 077
  cat > "$compose_file" <<EOF
services:
  muse2api:
    build: .
    image: ${CONTAINER_NAME}:latest
    container_name: ${CONTAINER_NAME}
    restart: always
    # ⚠️ 用默认 bridge 网络，**不要**让 compose 新建项目网络。
    #
    #    为什么：docker 默认的地址池只有 172.17~172.31 这一小段 /16。
    #    compose 默认会为**每个项目**新建一个网络，各占一个网段。
    #    一台机器上反复安装/卸载、或者本来就有不少容器时，池子很快被分光，
    #    之后所有新容器都起不来，报的还是天书：
    #        all predefined address pools have been fully subnetted
    #    实测就撞上了这个（28 个网络把池子耗干）。小白看到这行完全无法自救。
    #
    #    这个应用只有**一个**容器、只靠端口对外服务，根本不需要项目内网，
    #    共享 bridge 网络完全够用，而且再也不消耗地址池（多装几份也无所谓）。
    network_mode: bridge
    ports:
      - "${API_PORT}:${API_PORT}"
    # 上游 Dockerfile 把 --port 18610 写死了，这里必须显式覆盖，
    # 否则自定义端口会出现「宿主映射通了、应用还在听 18610」的半死状态。
    command: ["sh", "-c", "python -m uvicorn app:app --host 0.0.0.0 --port ${API_PORT}"]
    environment:
      # 管理与 API 鉴权密钥（脚本自动生成）
      - MUSE2API_KEY=${API_KEY}
      - MUSE2API_HOST=0.0.0.0
      - MUSE2API_PORT=${API_PORT}
      - MUSE2API_PUBLIC_BASE=
      - MUSE2API_CHROMIUM=/usr/bin/chromium
      - MUSE2API_CDP_PORT=19210
      - MUSE2API_IMAGE_TIMEOUT=240
      - MUSE2API_VIDEO_TIMEOUT=600
      - MUSE2API_CHAT_TIMEOUT=300
    volumes:
      - ./data:/app/data
    shm_size: '2gb'

  # v1.3.0 一键导号 sidecar —— 网页里登录 muse.ai，cookie 自动进账号池
  # ⚠️ 复用同一个镜像（build 同一份代码，第二次构建全部命中缓存，零额外下载）：
  #    镜像里本来就有 chromium + python + uvicorn，sidecar 只是换个启动命令。
  importer:
    build: .
    image: ${CONTAINER_NAME}:latest
    container_name: ${CONTAINER_NAME}-import
    restart: always
    network_mode: bridge
    depends_on:
      - muse2api
    ports:
      - "${IMPORT_PORT}:${IMPORT_PORT}"
    command: ["sh", "-c", "cd /app && python -m uvicorn import_sidecar:app --host 0.0.0.0 --port ${IMPORT_PORT}"]
    environment:
      # ⚠️ Key 只进容器环境变量，绝不写进网页 —— 网页端靠用户手动粘贴 Key 鉴权
      - MUSE2API_KEY=${API_KEY}
      - MUSE2API_PORT=${API_PORT}
      - IMPORT_PORT=${IMPORT_PORT}
      - CHROMIUM_BIN=/usr/bin/chromium
      # v1.4.0 一次性导号令牌（--add-account 生成，网页 ?token= 免 Key 进入）
      - TOKENS_FILE=/runtime/import_tokens.json
    volumes:
      # 由 write_importer() 写入安装目录，只读挂载进容器
      - ./import_sidecar.py:/app/import_sidecar.py:ro
      # 令牌文件的双向通道：宿主机 install.sh 写新令牌，sidecar 回写 used 标记
      - ./runtime:/runtime
    shm_size: '2gb'
EOF
  chmod 600 "$compose_file"
}

fetch_muse2api() {
  local dir="$1"
  if [ -d "$dir/.git" ]; then
    ok "代码已存在，拉取最新版本"
    runsh "cd '$dir' && git pull --ff-only 2>&1 | tail -3" || warn "git pull 失败，沿用现有代码"
    return 0
  fi
  step "下载程序本体"
  if command -v git >/dev/null 2>&1; then
    # -b "$MUSE2API_REF" 不能省：不加时 git 只拉默认分支，若修复不在默认分支上就会
    # 静默装到没有修复的旧代码（曾经的线上事故根因）。
    if runsh "git clone --depth 1 -b '$MUSE2API_REF' https://github.com/${MUSE2API_REPO}.git '$dir' 2>&1 | tail -3"; then
      ok "下载完成"
      return 0
    fi
    warn "git 下载失败，改试压缩包"
  fi
  # 兜底：下载 zip
  local url="https://codeload.github.com/${MUSE2API_REPO}/zip/refs/heads/${MUSE2API_REF}"
  run mkdir -p "$dir"
  # ⚠️ zip 的临时文件不能写死 /tmp/muse2api.zip：
  #    两台安装同时跑、或上一次失败留了残file，都会互相踩（比如复用了别人下坏的半截包）。
  #    用 mktemp 生成唯一名，并在结束时一定清掉。
  local ztmp
  ztmp="$(mktemp /tmp/muse2api-XXXXXX.zip 2>/dev/null || echo "/tmp/muse2api-$$.zip")"
  if runsh "curl -fsSL --max-time 300 '$url' -o '$ztmp'"; then
    # 解包 → 把顶层目录里的内容（含隐藏文件）挪到 $dir，再删掉那个空壳目录。
    # 早期写法 `mv muse2api-main/* .` 有两个毛病：
    #   1) 漏掉隐藏文件（.env.example / .gitignore），装完缺文件；
    #   2) 不删 muse2api-main 空目录，$dir 里留个垃圾壳。
    # ⚠️ 顶层目录名不是写死的 "muse2api-main"：GitHub 打包规则是 <repo>-<ref>，
    #    ref 换成别的时候（如 master / v1.5.2）名字就变了，写死会 mv 不到而留下空目录。
    #    所以这里先探出真实目录名再挪 —— 兼容任意分支/标签。
    runsh "cd '$dir' && (command -v unzip >/dev/null 2>&1 && unzip -q -o '$ztmp' || python3 -c \"import zipfile;zipfile.ZipFile('$ztmp').extractall('.')\")"
    local top
    top="$(cd "$dir" && find . -maxdepth 1 -mindepth 1 -type d -name '*-*' | head -1 | sed 's|^\./||')"
    if [ -z "$top" ]; then
      rm -f "$ztmp"
      die "压缩包解出来找不到顶层目录，可能下载不完整。请重跑本脚本。"
    fi
    runsh "cd '$dir' && (shopt -s dotglob nullglob 2>/dev/null; mv '$top'/* . 2>/dev/null; rm -rf '$top') && rm -f '$ztmp'"
    ok "下载完成（压缩包方式）"
  else
    rm -f "$ztmp"
    die "下载程序本体失败。请检查这台机器的网络能否访问 github.com。
       国内机器可以先配好代理，或手动把代码放到 $dir 再重跑本脚本。"
  fi
}

write_webpage() {
  local dir="$1"
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s[dry-run]%s 写入 %s/index.html\n' "$C_CYN" "$C_OFF" "$dir"
    return 0
  fi
  umask 022
  cat > "$dir/index.html" <<'MUSEHTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Muse 视频工作台</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg:#f7f7f5; --panel:#fff; --panel-2:#fafafa; --border:#e4e3de;
    --border-strong:#d0cfc9; --text:#23231f; --text-2:#6b6a64; --text-3:#9a9992;
    --accent:#c0392b; --accent-soft:#fdf2f0; --accent-hover:#a5301f;
    --ok:#1e8e5a; --warn:#b7791f; --err:#c0392b; --radius:10px; --radius-lg:14px;
  }
  body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;
    background:var(--bg); color:var(--text); font-size:14px; line-height:1.6; -webkit-font-smoothing:antialiased; }
  .wrap { max-width:1180px; margin:0 auto; padding:28px 24px 60px; }
  header { display:flex; align-items:center; justify-content:space-between; gap:16px; flex-wrap:wrap; margin-bottom:24px; }
  .brand { display:flex; align-items:center; gap:12px; }
  .logo { width:38px; height:38px; border-radius:9px; background:var(--accent); color:#fff;
    display:flex; align-items:center; justify-content:center; font-size:17px; font-weight:500; flex-shrink:0; }
  .brand h1 { font-size:17px; font-weight:500; letter-spacing:-0.01em; }
  .brand p { font-size:12px; color:var(--text-3); }
  .status { display:flex; align-items:center; gap:7px; font-size:12px; color:var(--text-2);
    background:var(--panel); border:1px solid var(--border); padding:6px 12px; border-radius:999px; }
  .dot { width:7px; height:7px; border-radius:50%; background:var(--text-3); flex-shrink:0; }
  .dot.on { background:var(--ok); } .dot.off { background:var(--err); }
  .grid { display:grid; grid-template-columns:400px 1fr; gap:20px; align-items:start; }
  @media (max-width:900px) { .grid { grid-template-columns:1fr; } }
  .card { background:var(--panel); border:1px solid var(--border); border-radius:var(--radius-lg); padding:20px; }
  .card + .card { margin-top:16px; }
  .card-title { font-size:13px; font-weight:500; display:flex; align-items:center;
    justify-content:space-between; margin-bottom:16px; }
  .card-title .hint { font-size:11px; color:var(--text-3); font-weight:400; }
  label.field { display:block; margin-bottom:16px; }
  label.field:last-of-type { margin-bottom:0; }
  .lbl { display:flex; align-items:center; justify-content:space-between; font-size:12px;
    color:var(--text-2); margin-bottom:7px; }
  .lbl .count { font-size:11px; color:var(--text-3); font-variant-numeric:tabular-nums; }
  textarea,input[type=text],input[type=password],select { width:100%; font-family:inherit; font-size:13px;
    color:var(--text); background:var(--panel-2); border:1px solid var(--border); border-radius:var(--radius);
    padding:10px 12px; outline:none; transition:border-color .15s, background .15s; }
  textarea { resize:vertical; min-height:108px; line-height:1.7; }
  textarea:focus,input:focus,select:focus { border-color:var(--accent); background:#fff; }
  textarea::placeholder,input::placeholder { color:var(--text-3); }
  select { cursor:pointer; appearance:none;
    background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' stroke='%236b6a64' stroke-width='1.4' fill='none' stroke-linecap='round'/%3E%3C/svg%3E");
    background-repeat:no-repeat; background-position:right 12px center; padding-right:32px; }
  .sizes { display:grid; grid-template-columns:repeat(2,1fr); gap:8px; }
  .size-opt { border:1px solid var(--border); background:var(--panel-2); border-radius:var(--radius);
    padding:10px 8px; cursor:pointer; display:flex; flex-direction:column; align-items:center;
    gap:5px; transition:all .15s; text-align:center; }
  .size-opt:hover { border-color:var(--border-strong); }
  .size-opt.sel { border-color:var(--accent); background:var(--accent-soft); }
  .size-opt .box { border:1.5px solid var(--text-3); border-radius:3px; transition:border-color .15s; }
  .size-opt.sel .box { border-color:var(--accent); }
  .size-opt .name { font-size:11px; color:var(--text-2); }
  .size-opt.sel .name { color:var(--accent); font-weight:500; }
  .box-16-9 { width:36px; height:20px; } .box-9-16 { width:20px; height:36px; }
  .box-1-1 { width:28px; height:28px; } .box-4-3 { width:32px; height:24px; }
  .drop { border:1.5px dashed var(--border-strong); border-radius:var(--radius); padding:18px;
    text-align:center; cursor:pointer; transition:all .15s; background:var(--panel-2); position:relative; }
  .drop:hover,.drop.over { border-color:var(--accent); background:var(--accent-soft); }
  .drop .ico { font-size:20px; color:var(--text-3); margin-bottom:5px; }
  .drop .t1 { font-size:12px; color:var(--text-2); }
  .drop .t2 { font-size:11px; color:var(--text-3); margin-top:2px; }
  .drop img { max-width:100%; max-height:130px; border-radius:7px; display:block; margin:0 auto; }
  .drop.has-img { padding:8px; border-style:solid; border-color:var(--border); }
  .clear-img { position:absolute; top:6px; right:6px; width:22px; height:22px; border-radius:50%;
    border:none; background:rgba(35,35,31,.72); color:#fff; font-size:13px; cursor:pointer;
    line-height:1; display:flex; align-items:center; justify-content:center; }
  .clear-img:hover { background:rgba(35,35,31,.9); }
  .btn { width:100%; border:none; border-radius:var(--radius); font-family:inherit; font-size:14px;
    font-weight:500; padding:12px; cursor:pointer; transition:all .15s;
    display:flex; align-items:center; justify-content:center; gap:8px; }
  .btn-primary { background:var(--accent); color:#fff; margin-top:20px; }
  .btn-primary:hover:not(:disabled) { background:var(--accent-hover); }
  .btn-primary:disabled { background:var(--border-strong); color:#fff; cursor:not-allowed; }
  .btn-ghost { background:var(--panel-2); color:var(--text-2); border:1px solid var(--border);
    font-size:12px; padding:8px 12px; width:auto; }
  .btn-ghost:hover { border-color:var(--border-strong); color:var(--text); }
  .spinner { width:14px; height:14px; border-radius:50%; border:2px solid rgba(255,255,255,.35);
    border-top-color:#fff; animation:spin .7s linear infinite; }
  @keyframes spin { to { transform:rotate(360deg); } }
  .task-empty { text-align:center; padding:56px 20px; color:var(--text-3); }
  .task-empty .ico { font-size:30px; margin-bottom:10px; opacity:.5; }
  .task-empty .t { font-size:13px; }
  .prog-head { display:flex; justify-content:space-between; align-items:baseline; margin-bottom:10px; }
  .prog-status { font-size:13px; font-weight:500; }
  .prog-pct { font-size:13px; color:var(--text-2); font-variant-numeric:tabular-nums; }
  .bar { height:5px; background:var(--border); border-radius:999px; overflow:hidden; }
  .bar > i { display:block; height:100%; background:var(--accent); border-radius:999px; transition:width .5s ease; }
  .prog-note { font-size:12px; color:var(--text-3); margin-top:10px; }
  .prog-note.err { color:var(--err); }
  video { width:100%; border-radius:var(--radius); background:#000; display:block; }
  .result-meta { display:flex; align-items:center; justify-content:space-between; gap:12px;
    flex-wrap:wrap; margin-top:14px; }
  .meta-txt { font-size:12px; color:var(--text-3); }
  .result-actions { display:flex; gap:8px; }
  .result-actions a { text-decoration:none; }
  .result-actions .btn-ghost { display:inline-flex; }
  .hist-list { display:flex; flex-direction:column; gap:8px; max-height:340px; overflow-y:auto; }
  .hist-item { display:flex; gap:11px; align-items:center; padding:9px; border-radius:var(--radius);
    cursor:pointer; border:1px solid transparent; transition:all .15s; }
  .hist-item:hover { background:var(--panel-2); border-color:var(--border); }
  .hist-thumb { width:56px; height:34px; border-radius:6px; flex-shrink:0; background:var(--panel-2);
    border:1px solid var(--border); display:flex; align-items:center; justify-content:center;
    font-size:14px; color:var(--text-3); overflow:hidden; }
  .hist-body { min-width:0; flex:1; }
  .hist-prompt { font-size:12px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .hist-sub { font-size:11px; color:var(--text-3); margin-top:2px; }
  .hist-badge { font-size:10px; padding:2px 7px; border-radius:999px; background:var(--panel-2);
    border:1px solid var(--border); color:var(--text-2); flex-shrink:0; }
  .hist-badge.ok { color:var(--ok); border-color:#b8e0c8; background:#f0f9f4; }
  .hist-badge.fail { color:var(--err); border-color:#f0c8c4; background:var(--accent-soft); }
  .hist-badge.run { color:var(--warn); border-color:#eed9ac; background:#fdf8ec; }
  .toast { position:fixed; bottom:24px; left:50%; transform:translateX(-50%) translateY(80px);
    background:var(--text); color:#fff; font-size:13px; padding:11px 20px; border-radius:var(--radius);
    opacity:0; transition:all .25s; pointer-events:none; z-index:99; max-width:90vw; }
  .toast.show { opacity:1; transform:translateX(-50%) translateY(0); }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="brand">
      <div class="logo">M</div>
      <div><h1>Muse 视频工作台</h1><p>文生视频 · 首帧图生视频</p></div>
    </div>
    <div class="status"><span class="dot" id="statusDot"></span><span id="statusText">未连接</span></div>
  </header>

  <div class="grid">
    <div>
      <div class="card">
        <div class="card-title">创作</div>
        <label class="field">
          <div class="lbl"><span>视频描述</span><span class="count" id="promptCount">0 / 1000</span></div>
          <textarea id="prompt" maxlength="1000" placeholder="描述你想要的画面，越具体越好。例如：&#10;金色的枫叶在微风中缓缓飘落，阳光穿过树梢，镜头缓慢推进，电影级景深"></textarea>
        </label>
        <label class="field">
          <div class="lbl"><span>时长</span></div>
          <select id="duration">
            <option value="5" selected>5 秒</option>
            <option value="6">6 秒</option>
            <option value="10">10 秒</option>
          </select>
        </label>
        <label class="field">
          <div class="lbl"><span>画幅</span></div>
          <div class="sizes" id="sizes">
            <div class="size-opt sel" data-size="16:9"><div class="box box-16-9"></div><div class="name">16:9 横屏</div></div>
            <div class="size-opt" data-size="9:16"><div class="box box-9-16"></div><div class="name">9:16 竖屏</div></div>
            <div class="size-opt" data-size="1:1"><div class="box box-1-1"></div><div class="name">1:1 方形</div></div>
            <div class="size-opt" data-size="4:3"><div class="box box-4-3"></div><div class="name">4:3</div></div>
          </div>
        </label>
        <label class="field">
          <div class="lbl"><span>首帧图（可选）</span><span class="count">不填＝文生视频</span></div>
          <div class="drop" id="drop">
            <input type="file" id="file" accept="image/*" hidden>
            <div id="dropInner">
              <div class="ico">＋</div>
              <div class="t1">点击或拖拽图片到这里</div>
              <div class="t2">作为视频首帧 · 支持 JPG / PNG / WebP</div>
            </div>
          </div>
        </label>
        <button class="btn btn-primary" id="genBtn"><span id="genBtnText">生成视频</span></button>
      </div>

      <div class="card">
        <div class="card-title">连接设置</div>
        <label class="field">
          <div class="lbl"><span>接口地址</span></div>
          <input type="text" id="baseUrl" placeholder="http://127.0.0.1:18610">
        </label>
        <label class="field">
          <div class="lbl"><span>API Key</span></div>
          <input type="password" id="apiKey" placeholder="m2a_...">
        </label>
        <button class="btn btn-ghost" id="saveCfg">保存并测试连接</button>
      </div>
    </div>

    <div>
      <div class="card">
        <div class="card-title"><span>当前任务</span><span class="hint" id="taskHint"></span></div>
        <div id="taskArea">
          <div class="task-empty"><div class="ico">▷</div>
            <div class="t">在左侧填写描述，点击「生成视频」开始创作</div></div>
        </div>
      </div>
      <div class="card">
        <div class="card-title"><span>历史记录</span>
          <button class="btn btn-ghost" id="clearHist">清空</button></div>
        <div id="histArea">
          <div class="task-empty" style="padding:28px 10px"><div class="t">暂无记录</div></div>
        </div>
      </div>
    </div>
  </div>
</div>
<div class="toast" id="toast"></div>

<script>
(function () {
  'use strict';
  var LS_CFG = 'muse_video_cfg', LS_HIST = 'muse_video_hist', POLL_MS = 4000;
  var $ = function (id) { return document.getElementById(id); };
  var state = { base:'', key:'', size:'16:9', firstFrame:null, busy:false,
                timer:null, taskId:null, tasks:[] };
  var curDur = 5;

  function toast(m){ var t=$('toast'); t.textContent=m; t.classList.add('show');
    clearTimeout(t._h); t._h=setTimeout(function(){t.classList.remove('show');},2600); }
  function normBase(u){ u=(u||'').trim().replace(/\/+$/,''); if(!u) return '';
    if(!/^https?:\/\//i.test(u)) u='http://'+u;
    if(/\/v1$/i.test(u)) u=u.slice(0,-3); return u; }
  function api(p){ return state.base+p; }
  function headers(){ return {'Authorization':'Bearer '+state.key,'Content-Type':'application/json'}; }
  function fmtBytes(n){ if(!n) return ''; return n<1048576?(n/1024).toFixed(0)+' KB':(n/1048576).toFixed(1)+' MB'; }
  function fmtTime(ts){ if(!ts) return ''; var d=new Date(ts*1000);
    return (d.getMonth()+1)+'/'+d.getDate()+' '+String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0'); }
  function setStatus(c,t){ $('statusDot').className='dot '+c; $('statusText').textContent=t; }
  function esc(s){ return String(s==null?'':s).replace(/[&<>"']/g,function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }

  function loadCfg(){
    var c={}; try{ c=JSON.parse(localStorage.getItem(LS_CFG)||'{}'); }catch(e){}
    // 终端打印的直达链接会带 ?key=&api= —— 点开就自动填好，不用手抄 Key。
    // 填好之后立刻从地址栏抹掉，免得 Key 留在浏览器历史和转发的链接里。
    var q=null; try{ q=new URLSearchParams(location.search||''); }catch(e){}
    var qk=(q&&q.get('key'))||'', qa=(q&&q.get('api'))||'';
    var linked=!!(qk||qa);
    state.base=normBase(qa||c.base||location.origin.replace(/:\d+$/, ':18610'));
    state.key=(qk||c.key||'').trim();
    $('baseUrl').value=state.base; $('apiKey').value=state.key;
    if(linked){
      try{ localStorage.setItem(LS_CFG, JSON.stringify({base:state.base,key:state.key})); }catch(e){}
      try{ history.replaceState(null,'',location.pathname); }catch(e){}
      toast('已自动填好接口地址和 API Key');
    }
    if(state.key) testConn(true);
  }
  function saveCfg(){
    state.base=normBase($('baseUrl').value); state.key=$('apiKey').value.trim();
    $('baseUrl').value=state.base;
    localStorage.setItem(LS_CFG, JSON.stringify({base:state.base,key:state.key}));
  }
  function testConn(silent){
    if(!state.base||!state.key){ setStatus('off','未配置'); return; }
    fetch(api('/v1/models'),{headers:headers()}).then(function(r){
      if(r.ok){ setStatus('on','已连接'); if(!silent) toast('连接成功'); }
      else if(r.status===401){ setStatus('off','Key 无效'); if(!silent) toast('API Key 无效（401）'); }
      else { setStatus('off','HTTP '+r.status); if(!silent) toast('连接失败：HTTP '+r.status); }
    }).catch(function(){ setStatus('off','连接失败');
      if(!silent) toast('连不上 '+state.base+'，请检查地址与网络'); });
  }

  function loadHist(){ try{ state.tasks=JSON.parse(localStorage.getItem(LS_HIST)||'[]'); }catch(e){ state.tasks=[]; } renderHist(); }
  function saveHist(){
    var slim=state.tasks.slice(0,30).map(function(t){ return {id:t.id,prompt:t.prompt,status:t.status,
      size:t.size,duration:t.duration,created:t.created,url:t.url||'',bytes:t.bytes||0,err:t.err||''}; });
    try{ localStorage.setItem(LS_HIST,JSON.stringify(slim)); }catch(e){}
  }
  function addTask(t){ state.tasks.unshift(t); if(state.tasks.length>30) state.tasks.length=30; renderHist(); saveHist(); }
  function updTask(id,patch){ for(var i=0;i<state.tasks.length;i++){ if(state.tasks[i].id===id){
    for(var k in patch) state.tasks[i][k]=patch[k]; break; } } renderHist(); saveHist(); }

  function renderHist(){
    var a=$('histArea');
    if(!state.tasks.length){ a.innerHTML='<div class="task-empty" style="padding:28px 10px"><div class="t">暂无记录</div></div>'; return; }
    var h='<div class="hist-list">';
    state.tasks.forEach(function(t,i){
      var b,c;
      if(t.status==='completed'){ b='已完成'; c='ok'; }
      else if(t.status==='failed'){ b='失败'; c='fail'; }
      else { b='生成中'; c='run'; }
      h+='<div class="hist-item" data-i="'+i+'"><div class="hist-thumb">'+(t.url?'▷':'…')+'</div>'+
        '<div class="hist-body"><div class="hist-prompt">'+esc(t.prompt||'(无描述)')+'</div>'+
        '<div class="hist-sub">'+esc(t.size||'')+' · '+(t.duration||5)+'s · '+fmtTime(t.created)+
        (t.bytes?' · '+fmtBytes(t.bytes):'')+'</div></div>'+
        '<span class="hist-badge '+c+'">'+b+'</span></div>';
    });
    h+='</div>'; a.innerHTML=h;
    a.querySelectorAll('.hist-item').forEach(function(el){
      el.onclick=function(){ showTask(state.tasks[+el.dataset.i]); };
    });
  }

  function showTask(t){
    var area=$('taskArea'); $('taskHint').textContent=t.id||'';
    if(t.status==='completed'&&t.url){
      var abs=/^https?:\/\//i.test(t.url)?t.url:state.base+t.url;
      area.innerHTML='<video src="'+abs+'" controls playsinline preload="metadata"></video>'+
        '<div class="result-meta"><div class="meta-txt">'+esc(t.size||'')+' · '+(t.duration||5)+'s'+
        (t.bytes?' · '+fmtBytes(t.bytes):'')+'</div><div class="result-actions">'+
        '<a href="'+abs+'" download target="_blank" rel="noopener"><button class="btn btn-ghost">下载视频</button></a>'+
        '<a href="'+abs+'" target="_blank" rel="noopener"><button class="btn btn-ghost">新窗口打开</button></a>'+
        '</div></div><div class="prog-note" style="margin-top:14px;padding-top:14px;border-top:1px solid var(--border)">'+
        esc(t.prompt||'')+'</div>';
      return;
    }
    if(t.status==='failed'){
      area.innerHTML='<div class="prog-head"><span class="prog-status" style="color:var(--err)">生成失败</span></div>'+
        '<div class="prog-note err">'+esc(t.err||'未知错误')+'</div>'+
        '<div class="prog-note" style="margin-top:12px">'+esc(t.prompt||'')+'</div>';
      return;
    }
    var pct=t.progress||0;
    area.innerHTML='<div class="prog-head"><span class="prog-status">'+(pct>=100?'正在保存':'生成中')+
      '</span><span class="prog-pct">'+pct+'%</span></div>'+
      '<div class="bar"><i style="width:'+Math.max(pct,4)+'%"></i></div>'+
      '<div class="prog-note">视频生成通常需要 1～2 分钟，请保持页面打开</div>'+
      '<div class="prog-note" style="margin-top:12px">'+esc(t.prompt||'')+'</div>';
  }

  function stopPolling(){ if(state.timer){ clearInterval(state.timer); state.timer=null; } }
  function startPolling(id){ stopPolling(); state.timer=setInterval(function(){ poll(id); }, POLL_MS); }

  function currentPrompt(id){ for(var i=0;i<state.tasks.length;i++){ if(state.tasks[i].id===id) return state.tasks[i].prompt; } return ''; }

  function poll(id){
    fetch(api('/v1/videos/'+id),{headers:headers()}).then(function(r){ return r.json(); }).then(function(j){
      var status=j.status, pct=(typeof j.progress==='number')?j.progress:0;
      var patch={status:status,progress:pct};
      if(status==='completed'||status==='succeeded'){
        var res=j.result||{};
        patch.status='completed'; patch.url=res.url||''; patch.bytes=res.bytes||0;
        stopPolling(); setBusy(false); updTask(id,patch);
        showTask(Object.assign({id:id},patch,{prompt:currentPrompt(id),size:state.size,duration:curDur}));
        toast('视频生成完成'); return;
      }
      if(status==='failed'||status==='error'){
        patch.status='failed'; patch.err=j.error||'生成失败';
        stopPolling(); setBusy(false); updTask(id,patch);
        showTask(Object.assign({id:id},patch,{prompt:currentPrompt(id),size:state.size,duration:curDur}));
        return;
      }
      updTask(id,patch);
      showTask(Object.assign({id:id,progress:pct,status:status},{prompt:currentPrompt(id),size:state.size,duration:curDur}));
    }).catch(function(){});
  }

  function setBusy(b){
    state.busy=b; var btn=$('genBtn'); btn.disabled=b;
    $('genBtnText').textContent=b?'生成中…':'生成视频';
    if(b&&!btn.querySelector('.spinner')){
      var sp=document.createElement('span'); sp.className='spinner'; btn.insertBefore(sp,$('genBtnText'));
    } else if(!b){ var ex=btn.querySelector('.spinner'); if(ex) ex.remove(); }
  }

  function generate(){
    if(state.busy) return;
    if(!state.base||!state.key){ toast('请先在下方填写接口地址与 API Key'); return; }
    var prompt=$('prompt').value.trim();
    if(!prompt){ toast('请填写视频描述'); return; }
    var payload={prompt:prompt,duration:parseInt($('duration').value,10)||5,size:state.size};
    if(state.firstFrame) payload.image=state.firstFrame;
    curDur=payload.duration; setBusy(true);
    fetch(api('/v1/videos'),{method:'POST',headers:headers(),body:JSON.stringify(payload)})
      .then(function(r){ return r.json().then(function(j){ return {ok:r.ok,status:r.status,body:j}; }); })
      .then(function(res){
        if(!res.ok){
          var msg=(res.body&&(res.body.error&&(res.body.error.message||res.body.error)||res.body.detail))||('HTTP '+res.status);
          throw new Error(typeof msg==='string'?msg:JSON.stringify(msg));
        }
        var id=res.body.id||res.body.task_id;
        if(!id) throw new Error('服务端未返回任务 ID');
        state.taskId=id;
        addTask({id:id,prompt:prompt,status:'queued',progress:10,size:state.size,
          duration:payload.duration,created:Math.floor(Date.now()/1000),url:'',bytes:0,err:''});
        showTask({id:id,prompt:prompt,status:'queued',progress:10,size:state.size,duration:payload.duration});
        toast('任务已提交，正在生成…'); startPolling(id);
      })
      .catch(function(e){ setBusy(false); toast('提交失败：'+e.message); });
  }

  function bindDrop(){
    var drop=$('drop'), file=$('file');
    drop.onclick=function(e){ if(e.target.classList.contains('clear-img')) return; file.click(); };
    file.onchange=function(){ if(file.files[0]) readFile(file.files[0]); };
    ['dragenter','dragover'].forEach(function(ev){ drop.addEventListener(ev,function(e){ e.preventDefault(); drop.classList.add('over'); }); });
    ['dragleave','drop'].forEach(function(ev){ drop.addEventListener(ev,function(e){ e.preventDefault(); drop.classList.remove('over'); }); });
    drop.addEventListener('drop',function(e){
      var f=e.dataTransfer.files[0];
      if(f&&/^image\//.test(f.type)) readFile(f); else if(f) toast('请拖入图片文件');
    });
    function readFile(f){
      if(f.size>8*1024*1024){ toast('图片不要超过 8MB'); return; }
      var fr=new FileReader();
      fr.onload=function(){
        state.firstFrame=fr.result; drop.classList.add('has-img');
        $('dropInner').innerHTML='<img src="'+fr.result+'"><button class="clear-img" type="button">×</button>';
        drop.querySelector('.clear-img').onclick=function(e){
          e.stopPropagation(); state.firstFrame=null; drop.classList.remove('has-img');
          $('dropInner').innerHTML='<div class="ico">＋</div><div class="t1">点击或拖拽图片到这里</div>'+
            '<div class="t2">作为视频首帧 · 支持 JPG / PNG / WebP</div>';
          file.value='';
        };
      };
      fr.readAsDataURL(f);
    }
  }

  function bind(){
    $('prompt').oninput=function(){ $('promptCount').textContent=$('prompt').value.length+' / 1000'; };
    $('sizes').onclick=function(e){
      var el=e.target.closest?e.target.closest('.size-opt'):null; if(!el) return;
      this.querySelectorAll('.size-opt').forEach(function(o){ o.classList.remove('sel'); });
      el.classList.add('sel'); state.size=el.dataset.size;
    };
    $('genBtn').onclick=generate;
    $('saveCfg').onclick=function(){ saveCfg(); testConn(false); };
    $('clearHist').onclick=function(){ if(!state.tasks.length) return; state.tasks=[]; renderHist(); saveHist(); toast('历史已清空'); };
    $('prompt').addEventListener('keydown',function(e){
      if((e.ctrlKey||e.metaKey)&&e.key==='Enter'){ e.preventDefault(); generate(); }
    });
  }

  bind(); bindDrop(); loadCfg(); loadHist();
})();
</script>
</body>
</html>
MUSEHTML
}

write_service() {
  local f="/etc/systemd/system/${WEB_UNIT}"
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s[dry-run]%s 写入并启用 %s\n' "$C_CYN" "$C_OFF" "$f"
    return 0
  fi
  cat > "$f" <<EOF
[Unit]
Description=$APP_LABEL (static site)
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$(command -v python3 || echo /usr/bin/python3) -m http.server ${WEB_PORT} --bind 0.0.0.0 --directory $INSTALL_DIR
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now "${WEB_UNIT}"
}

# 等容器内部端口真的活起来（docker-proxy 会让宿主端口「假通」）
# 判据：能拿到任意 HTTP 状态码即算活 —— 401 恰恰说明服务在跑（缺 Key 而已）。
# 注意不能用 curl -f：它遇 4xx 直接返回错误码，会把正常的 401 误判成「服务没起来」。
api_alive() {
  local code
  code="$(docker exec "$CONTAINER_NAME" curl -s -o /dev/null -w '%{http_code}' \
    --max-time 5 "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null)"
  case "$code" in ''|000) return 1 ;; *) return 0 ;; esac
}

# 解析「真正在跑的那个容器名」。
# 为什么不能直接用 $CONTAINER_NAME：容器名是**安装时**写进 compose 的，
# 而手工改过 compose、或用更早的脚本装过、或有人 docker rename 过，都会让它对不上。
# 这时如果死认 $CONTAINER_NAME，--status 会报「× 没找到容器」——明明服务好好地跑着，
# 用户看到只会恐慌（曾经我自己就被这个误导过：容器叫 muse2api，脚本找 mvw）。
# 策略：先用 $CONTAINER_NAME；找不到就退而按「镜像名 / 服务标签」反查一个 muse 容器。
resolve_container_name() {
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    printf '%s' "$CONTAINER_NAME"; return 0
  fi
  # 反查：优先本项目的 compose 标签，其次镜像名以 muse2api/mvw 开头
  local c
  c="$(docker ps -a \
        --filter "label=com.docker.compose.service=muse2api" \
        --format '{{.Names}}' 2>/dev/null | head -1)"
  if [ -z "$c" ]; then
    c="$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
          | awk -F'\t' '$2 ~ /^(muse2api|mvw|muse-video)/ {print $1; exit}')"
  fi
  printf '%s' "$c"
}

# 装完自检代码级修复是否真的在。
# ⚠️ 为什么需要这个：脚本装的是「仓库的某个 ref」，但 ref 里到底有没有修复，
#    光看「容器起来了 / 接口有响应」是看不出来的 —— 旧版代码同样能起来、同样有响应。
#    曾经的事故就是：默认分支还是旧版，脚本报「安装成功」，用户用了几轮才发现
#    并发一上来就卡死（旧版用裸锁，第二个请求会永久自锁）。
#    所以这里做三项硬校验，任一不过就**明确报警**（而不是假装成功）：
#      ① scheduler.py 存在       → FIFO 队列调度在
#      ② app.py 有鉴权守卫函数    → 405 绕过修复在
#      ③ app.py 有时长校验函数    → 参数校验修复在
#    在容器里查（而不是宿主目录），保证查的就是真正跑起来的那份代码。
verify_installed_fixes() {
  local c
  c="$(resolve_container_name)"
  if [ -z "$c" ]; then
    err "自检跳过：找不到对应的容器（服务没起来？用 docker ps -a 看一眼）"
    return 1
  fi

  local missing=""

  if ! docker exec "$c" test -f /app/scheduler.py 2>/dev/null; then
    missing="${missing} scheduler.py"
  fi
  if ! docker exec "$c" sh -c \
      'grep -q "_guard_method_not_allowed" /app/app.py' 2>/dev/null; then
    missing="${missing} 鉴权守卫"
  fi
  if ! docker exec "$c" sh -c \
      'grep -q "validate_video_duration" /app/app.py' 2>/dev/null; then
    missing="${missing} 时长校验"
  fi

  if [ -n "$missing" ]; then
    err "自检没过：装到的代码缺少关键修复 ——${missing}"
    say "     这说明下载到的版本不对（多半是分支选错了或仓库被改动）。"
    say "     请删除 ${INSTALL_DIR} 后重跑本脚本；若仍失败，把它反馈给维护者。"
    return 1
  fi
  ok "代码自检：关键修复都在（队列调度 / 鉴权守卫 / 时长校验）"
  return 0
}

wait_api_ready() {
  local tries=0
  while [ "$tries" -lt 40 ]; do
    api_alive && return 0
    tries=$((tries + 1)); sleep 3
  done
  return 1
}

print_next_steps() {
  local IP="$1"
  printf '\n%s════════════════════════════════════════════════════════%s\n' "$C_GRN" "$C_OFF"
  printf '%s  装好了！下一步只要做一件事：导入你的 muse.ai 账号%s\n' "$C_BLD" "$C_OFF"
  printf '%s════════════════════════════════════════════════════════%s\n\n' "$C_GRN" "$C_OFF"
  say "  ${C_BLD}① 先打开网页看看${C_OFF}"
  if [ -n "$DOMAIN" ]; then
    say "     https://${DOMAIN}/"
  else
    say "     http://${IP}:${WEB_PORT}/"
  fi
  say ""
  say "  ${C_BLD}② 导入 muse.ai 账号（必须先做这步，否则生成不了）${C_OFF}"
  say "     在终端里敲这一条："
  say "        ${C_BLD}sudo $(self_hint) --add-account${C_OFF}"
  say "     它会给你一条链接 —— 在你自己电脑的浏览器里打开，"
  say "     网页里出现登录窗口，登录 muse.ai 就导入完成了。"
  say "     ${C_BLD}不用装 Python、不用下载工具、不用填 Key${C_OFF}。"
  say "     一条链接能连着导多个账号（导完一个，在网页上点「再导一个」）。"
  say ""
  say "     ${C_DIM}（也可以直接开 http://${IP}:${IMPORT_PORT}/ 手动粘贴 Key 导入；"
  say "     老方法 tools/get_muse_cookie.py 同样仍然可用）${C_OFF}"
  say ""
  say "  ${C_BLD}③ 回到网页，输入一句话测试${C_OFF}"
  say "     用这条直达链接打开，接口地址和 Key 会自动填好："
  say "        ${C_BLD}$(direct_link "$API_KEY" "$IP")${C_OFF}"
  say "     然后直接写描述、点生成就行。"
  say ""
  say "  ${C_DIM}以后要加账号、看账号池、再拿这条链接，直接在终端敲：${C_OFF}${C_BLD} muse${C_OFF}"
  say ""
  printf '%s  ────────── 以下是详细信息，以后需要再查 ──────────%s\n\n' "$C_DIM" "$C_OFF"
  say "  网页地址：      http://${IP}:${WEB_PORT}/"
  say "  接口地址：      http://${IP}:${API_PORT}/v1"
  say "  一键导号：      http://${IP}:${IMPORT_PORT}/"
  say "  API Key：       ${API_KEY}"
  say "  安装目录：      ${INSTALL_DIR}"
  say "  账号池面板：    http://${IP}:${API_PORT}/admin?key=${API_KEY}"
  # ⚠️ 用户要了域名但这次没配上（DNS 没生效），必须在这里再明确说一次：
  #    否则上面那些 "✓ 服务已启动" 会让他以为域名能用了，打开却打不开。
  if [ -n "${DOMAIN_SKIPPED:-}" ]; then
    say ""
    warn "你给的域名 ${DOMAIN_SKIPPED} 这次没生效 —— 现在请先用上面的 IP 地址访问。"
    warn "等 DNS 解析到这台机器后，重跑一遍安装即可自动配上 HTTPS："
    warn "    sudo bash ${SELF} --domain ${DOMAIN_SKIPPED}"
  fi
  say ""
  say "  常用命令："
  # 用 self_hint：脚本自己已经存了一份到安装目录，这里给出**一定可用**的命令。
  # （管道安装时用户手上没有脚本文件，写 ${SELF} 他会找不到。）
  say "    ${C_BLD}muse${C_OFF}                            终端控制面板（加账号 / 管账号池 / 拿链接）"
  say "    sudo $(self_hint) --add-account 导号：生成登录链接（可连着导多个账号）"
  say "    sudo $(self_hint) --link        工作台直达链接（带 Key，点开即用）"
  say "    sudo $(self_hint) --accounts    账号池管理（列出 / 删除 / 测活）"
  say "    sudo $(self_hint) --status      看运行状态（也能把上面的地址和 Key 再打印一遍）"
  say "    sudo $(self_hint) --upgrade     升级到最新版"
  say "    sudo $(self_hint) --uninstall   卸载"
  if [ -n "$SELF_PATH" ] && [ "$SELF_PATH" != "$INSTALL_DIR/install.sh" ]; then
    say "    ${C_DIM}（脚本已另存一份到 $INSTALL_DIR/install.sh，你原来的那份可以删）${C_OFF}"
  fi
  say ""
  say "  ${C_DIM}记不住 API Key？随时跑 --status 就能看回来；或者敲 muse 进面板拿直达链接。${C_OFF}"
  say ""
  warn "如果网页打不开，多半是云服务商的安全组没放行 ${WEB_PORT}、${API_PORT}、${IMPORT_PORT} 端口，去控制台加一下。"
  say ""
  dim "  验收清单："
  dim "    □ 网页 http://${IP}:${WEB_PORT}/ 能打开（左侧能看到「生成视频」按钮）"
  dim "    □ 右上角状态灯是绿的（说明 Key 对、接口通）"
  dim "    □ 账号池里有 1 个账号（终端敲 sudo $(self_hint) --accounts 看）"
  dim "      ↑ 现在还是 0 个，做完上面第 ② 步（导号）才会变成 1"
  dim "    □ 填一句描述点生成，1-2 分钟内出片"
  say ""
}

do_install() {
  say ""
  printf '%s╭──────────────────────────────────────────────────────╮%s\n' "$C_BLD" "$C_OFF"
  printf '%s│  %s 一键安装%s  %-34s│\n' "$C_BLD" "$APP_LABEL" "$C_OFF" ""
  printf '%s╰──────────────────────────────────────────────────────╯%s\n\n' "$C_BLD" "$C_OFF"
  say "  我在帮你装一个「输入文字就能生成视频」的网页工具。"
  say "  装好之后你可以："
  say "    · 用浏览器打开一个网址，写一句话就出视频"
  say "    · 让别的软件连上它来调用接口"
  say ""
  say "  大概要 2-5 分钟 —— 第一次得下载程序本体和浏览器（几百 MB），"
  say "  网慢就久一点，别急。"
  say ""
  if [ "$ASSUME_YES" = 1 ]; then
    say "  ${C_DIM}（全自动模式：所有问题都用默认值）${C_OFF}"
  elif [ ! -t 0 ]; then
    say "  ${C_YEL}注意：当前不是交互终端，所有问题会自动采用默认值。${C_OFF}"
    say "  ${C_DIM}想自己选，请直接在自己电脑的终端里运行本脚本。${C_OFF}"
  else
    say "  只会问你 1-2 个问题。拿不准的直接按回车，用默认值就行。"
  fi
  say ""

  # 端口
  # 说明：如果端口是「本安装目录自己的旧容器」占着的，视为可用（会原地重建），
  # 这样重复安装 / 改配置重跑才不会撞墙。
  #
  # ⚠️ dry-run 下**不要**去真正探测端口：
  #    探测结果会被下面重置回默认值，于是"端口被占，会自动往上找"这句提示
  #    和最后显示的端口自相矛盾（实测：先说 18610 被占，最后又显示 18610），
  #    小白看了完全懵。dry-run 只演示默认值，跳过探测最省事也最不容易误导。
  if [ "$DRY_RUN" = 1 ]; then
    [ -n "$API_PORT" ] || API_PORT="$DEFAULT_API_PORT"
    [ -n "$WEB_PORT" ] || WEB_PORT="$DEFAULT_WEB_PORT"
    [ -n "$IMPORT_PORT" ] || IMPORT_PORT="$DEFAULT_IMPORT_PORT"
  else
    # ⚠️ python3 要在挑端口**之前**就位：端口检测的第 3 层（真实 bind 测试，
    #    见 port_bindable）依赖它。放在这里装，后面的安装流程就都能用上。
    if ! command -v python3 >/dev/null 2>&1; then
      step "缺 python3，正在自动安装"
      pkg_install "python3" || true
    fi
    if [ -z "$API_PORT" ]; then
      API_PORT="$(pick_port "$DEFAULT_API_PORT")"
    else
      # 显式指定的端口被占 → 自动换（v1.2.0 起不再 die，见 resolve_port）
      API_PORT="$(resolve_port "$API_PORT" "接口")"
    fi
    if [ -z "$WEB_PORT" ]; then
      WEB_PORT="$(pick_port "$DEFAULT_WEB_PORT" "$API_PORT")"
    else
      WEB_PORT="$(resolve_port "$WEB_PORT" "网页" "$API_PORT")"
    fi
    # v1.3.0 第三个端口：一键导号 sidecar
    if [ -z "$IMPORT_PORT" ]; then
      IMPORT_PORT="$(pick_port "$DEFAULT_IMPORT_PORT" "$API_PORT $WEB_PORT")"
    else
      IMPORT_PORT="$(resolve_port "$IMPORT_PORT" "导号" "$API_PORT $WEB_PORT")"
    fi
  fi

  step "开始检查环境"
  detect_os
  [ -n "$PKG" ] && ok "系统：$OS_ID $OS_VER（用 $PKG 装东西）" || warn "认不出这个系统的包管理器，可能需要手工装依赖"
  # 资源体检：内存太小是这套栈最**隐蔽**的失败源。
  # 容器里跑着 Chromium（shm 2G），1G 内存的小鸡会在出片那一刻被 OOM 杀掉，
  # 日志里只留一句 Killed —— 小白根本看不出是内存不够。
  # 提前说清楚，比事后让他对着 "Killed" 发懵强得多。
  check_resources

  # 安装目录能否创建/写入 —— 提前拦住，别等下载完几百 MB 才失败
  check_install_dir_writable
  # 命名冲突保护：宁可停下，也不覆盖别人的服务/容器
  assert_no_unit_conflict
  assert_no_container_conflict

  if [ "$DRY_RUN" != 1 ]; then
    ensure_git
    ensure_docker
  else
    say "    [dry-run] 跳过：检查并自动安装 git / docker / docker compose"
  fi

  # （python3 的安装已提前到「挑端口」之前 —— 端口检测的 bind 测试要用它）

  step "准备程序文件"
  if [ "$DRY_RUN" != 1 ]; then
    # ⚠️ 创建目录之后必须**立刻验证真的写进去了**，不能只 mkdir 完就往下走。
    #    实测事故：把 --dir 指到 /proc/nope/mvw（父级不存在且不可写）时，
    #    mkdir 失败了却被忽略，脚本一路打印「✓ 配置完成」，直到最后
    #    `cd $INSTALL_DIR` 才炸，报一句没头没尾的 "No such file or directory"，
    #    还让小白去 `cd /proc/nope/mvw` 看日志（一个根本不存在的目录）。
    #    早失败在「准备程序文件」这一步，比晚失败在「启动服务」好得多。
    if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
      die "建不了安装目录 $INSTALL_DIR（上级目录不存在或没有写权限）。
    换个目录试试，比如：
      bash $SELF --dir /opt/mvw --api-port $API_PORT --web-port $WEB_PORT
    （/opt 或你的家目录一般都行）"
    fi
    if ! touch "$INSTALL_DIR/.write-test" 2>/dev/null; then
      die "安装目录 $INSTALL_DIR 建出来了，但写不进去（磁盘满？只读挂载？权限不够？）。
    检查一下：df -h $INSTALL_DIR  和  ls -ld $INSTALL_DIR"
    fi
    rm -f "$INSTALL_DIR/.write-test"
    if [ -f "$INSTALL_DIR/.env" ]; then rm -f "$INSTALL_DIR/.env"; fi  # 统一用 compose 环境变量
  fi
  fetch_muse2api "$INSTALL_DIR"

  step "配置密钥"
  if [ "$DRY_RUN" = 1 ]; then
    API_KEY="m2a_<自动生成的随机密钥>"
  else
    # 已有安装 → 复用原来的 Key。
    # 重新生成会让所有已配置的客户端、以及导号命令里的 --key 全部失效。
    local _oldkey; _oldkey="$(read_existing_key)"
    if [ -n "$_oldkey" ]; then
      API_KEY="$_oldkey"
      ok "沿用上次的密钥（客户端不用重配）"
    else
      API_KEY="$(gen_key)"
      ok "已生成一把随机密钥（只显示在最后，请留意）"
    fi
  fi

  step "写入配置"
  write_compose "$INSTALL_DIR"
  write_importer "$INSTALL_DIR"
  write_webpage "$INSTALL_DIR"
  # 一次性导号令牌的存放目录（importer 容器以卷挂载共享）
  run mkdir -p "$INSTALL_DIR/runtime"
  # 一次输出一整句，别拆成两条 —— 拆开会和 pick_port 的告警交错成乱码
  ok "配置完成：接口端口 $API_PORT，网页端口 $WEB_PORT"

  # 终端面板快捷命令：/usr/local/bin/muse（之后敲 muse 就能回到控制面板）
  install_cli

  # ── 域名（默认不要） ──
  if [ -z "$DOMAIN" ] && [ "$NO_DOMAIN" != 1 ] && [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
    if ask_yn "要不要给网页绑个域名（会自动配 HTTPS）？" n; then
      DOMAIN="$(ask "你的域名（要已经解析到这台机器）" "")"
      DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN%%/*}"
    fi
  fi

  if [ -n "$DOMAIN" ]; then
    step "绑定域名 $DOMAIN"
    IP_NOW="$(public_ip)"
    RESOLVED="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)"
    if [ -z "$RESOLVED" ]; then
      # ⚠️ 这里只 warn 是不够的：早期版本 warn 完就继续，最后照样打印
      #    「✓ 网页服务已启动」，小白以为域名能用了，打开却打不开。
      #    必须把"域名这次没生效、现在只能用 IP 访问"记下来，
      #    在最后的验收清单里再明确说一次。
      warn "域名 $DOMAIN 解析不出来（DNS 还没生效？）"
      warn "这次先不配 HTTPS —— 域名暂时用不了。"
      DOMAIN_SKIPPED="$DOMAIN"
      DOMAIN=""
    elif [ -n "$IP_NOW" ] && [ "$RESOLVED" != "$IP_NOW" ]; then
      warn "域名 $DOMAIN 解析到 $RESOLVED，但本机公网 IP 是 $IP_NOW"
      warn "这次先不配 HTTPS（DNS 没指对，证书签不下来）。"
      DOMAIN_SKIPPED="$DOMAIN"
      DOMAIN=""
    else
      setup_domain_caddy || { warn "HTTPS 配置失败，网页仍可用 IP:${WEB_PORT} 访问"; DOMAIN_SKIPPED="$DOMAIN"; DOMAIN=""; }
    fi
  fi

  step "启动服务"
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s[dry-run]%s cd %s && docker compose -p %s up -d --build\n' "$C_CYN" "$C_OFF" "$INSTALL_DIR" "$CONTAINER_NAME"
    # ⚠️ 这里必须用 "$WEB_UNIT"（含派生名），**不能**写死 "$APP_NAME-web.service"。
    #    unit 名是按安装目录派生的（见 derive_names），写死的话 dry-run 会显示一个
    #    根本不存在的服务名 —— 比如装到 /opt/mvtest 时实际是 mvtest-web.service，
    #    却打印 mvw-web.service。小白拿这个去 systemctl 查会扑空。
    printf '    %s[dry-run]%s systemctl enable --now %s\n' "$C_CYN" "$C_OFF" "$WEB_UNIT"
  else
    local out rc
    out="$(cd "$INSTALL_DIR" && compose up -d --build 2>&1)"; rc=$?
    if [ "$rc" != 0 ]; then
      printf '%s\n' "$out" | tail -8 | sed 's/^/    /'
      case "$out" in
        *"is already in use"*)  die "容器名被占用了 —— 可能这台机器上已经装过一次。
       先看看：docker ps -a | grep '${CONTAINER_NAME}'
       或者卸载重装：sudo bash ${SELF} --uninstall" ;;
        *"address already in use"*|*"port is already allocated"*)
          die "端口被占用了，换个端口重跑：sudo bash ${SELF} --api-port <另一个端口>" ;;
        # docker 地址池被分光时的天书报错，翻译成人话 + 给出可操作步骤。
        # （write_compose 已经用 network_mode: bridge 避免消耗池子，
        #   但机器上如果本来就有别的 compose 项目把池子占满，仍可能撞上。）
        *"address pools have been fully subnetted"*|*"could not find an available, non-overlapping IPv4 address pool"*)
          die "Docker 的网段用完了 —— 这台机器上的网络太多了，开不出新网段。
    清理一下没人用的旧网络就能继续（不会动到正在跑的服务）：
      docker network prune -f
    然后重跑本命令即可。" ;;
        *) die "启动失败（上面是原始输出）。看日志：cd $INSTALL_DIR && docker compose -p $CONTAINER_NAME logs --tail=40" ;;
      esac
    fi
    ok "容器已启动"

    step "等待服务就绪（初次启动要装浏览器，可能 1-2 分钟）"
    if wait_api_ready; then
      ok "接口服务正常"
      # 接口有响应 ≠ 代码是带修复的版本 —— 再查一遍代码级修复。
      verify_installed_fixes || true
    else
      warn "接口服务等了好久还没就绪，看看日志："
      docker logs "$CONTAINER_NAME" 2>&1 | tail -10 | sed 's/^/    /'
    fi

    write_service
    ok "网页服务已启动"

    save_state
  fi

  save_state
  print_next_steps "$(public_ip)"
}

# ── 域名：复用/自建 Caddy ────────────────────────────────────────────
# v1.4.2：站点块把 /v1/* 也反代到接口端口 —— 网页走域名时，页面里的
# 「接口地址」可以直接填同源 https://域名，没有跨域、没有混合内容。
# （实测坑：域名页 localStorage 是空的，自动推导出的接口地址是域名本身，
#   之前没这条反代时 /v1/models 全 404，状态灯永远「未连接」。）
caddy_site_block() {
  cat <<EOF
$DOMAIN {
	encode zstd gzip
	handle /v1/* {
		reverse_proxy 127.0.0.1:${API_PORT}
	}
	handle {
		reverse_proxy 127.0.0.1:${WEB_PORT}
	}
}
EOF
}

setup_domain_caddy() {
  local block_file
  # 情况 A：宿主上有 caddy 二进制
  if command -v caddy >/dev/null 2>&1 && [ -f /etc/caddy/Caddyfile ]; then
    local cfg=/etc/caddy/Caddyfile
    local bak="${cfg}.bak-$(date +%Y%m%d-%H%M%S)-preMuse"
    run cp "$cfg" "$bak"
    strip_managed_block "$cfg"
    if [ "$DRY_RUN" != 1 ]; then
      {
        printf '\n# >>> muse-video managed block —— 由 install-muse-video.sh 维护，请勿手改 >>>\n'
        caddy_site_block
        printf '# <<< muse-video managed block <<<\n'
      } >> "$cfg"
    fi
    if run caddy validate --config "$cfg" >/dev/null 2>&1; then
      if run systemctl reload caddy 2>/dev/null || run caddy reload --config "$cfg" 2>/dev/null; then
        ok "已挂到现有网页服务器上（原有网站不受影响）"
        return 0
      fi
    fi
    run cp "$bak" "$cfg"
    return 1
  fi

  # 情况 B'：80/443 被占 —— 但占用者是我们自己上次起的 caddy 容器。
  #    早期版本不认识自家 caddy，一律报「被别的程序占着」然后放弃，
  #    导致重跑安装永远更新不了 Caddyfile（比如 v1.4.2 要补 /v1/ 反代）。
  if [ "$(docker inspect -f '{{.State.Status}}' "$CADDY_NAME" 2>/dev/null)" = "running" ] \
     && [ -f "$INSTALL_DIR/Caddyfile" ]; then
    if [ "$DRY_RUN" != 1 ]; then
      {
        printf '{\n\temail admin@%s\n}\n\n' "$DOMAIN"
        caddy_site_block
      } > "$INSTALL_DIR/Caddyfile"
    fi
    if run docker exec "$CADDY_NAME" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
      ok "域名仍由上次装的 caddy 服务，配置已热更新"
      return 0
    fi
    warn "caddy 热重载失败，改重启容器"
    run docker restart "$CADDY_NAME" >/dev/null 2>&1 && { ok "caddy 已重启，域名配置已更新"; return 0; }
    return 1
  fi

  # 情况 B：80/443 被占用但不是 caddy
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ':(80|443)$'; then
    warn "这台机器的 80/443 已经被别的程序占着了，不方便自动接管。"
    say "    想用域名的话，在占着 80/443 的那个软件里加一条反代，指向 127.0.0.1:${WEB_PORT} 即可。"
    return 1
  fi

  # 情况 C：80/443 空着 → 自己起一个 caddy 容器
  run docker volume create muse_caddy_data >/dev/null 2>&1 || true
  if [ "$DRY_RUN" != 1 ]; then
    # 必须先落盘再 up，否则 docker 会把不存在的文件创建成目录
    {
      printf '{\n\temail admin@%s\n}\n\n' "$DOMAIN"
      caddy_site_block
    } > "$INSTALL_DIR/Caddyfile"
  fi
  run docker run -d --name "$CADDY_NAME" --restart always \
    --network host \
    -v "$INSTALL_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v muse_caddy_data:/data \
    caddy:2-alpine >/dev/null 2>&1 || return 1
  ok "已自动配好 HTTPS"
  return 0
}

strip_managed_block() {
  local f="$1"
  [ -f "$f" ] || return 0
  [ "$DRY_RUN" = 1 ] && return 0
  local tmp; tmp="$(mktemp)"
  awk '
    /# >>> muse-video managed block/ { skip=1; next }
    /# <<< muse-video managed block/ { skip=0; next }
    !skip { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# ── --status ─────────────────────────────────────────────────────────
do_status() {
  # ⚠️ --status 是**只读**操作，不需要管理员权限。
  #    早期版本在 main 里对 --status 也调了 check_root，结果普通用户
  #    （或 docker 组用户）想看「服务在跑吗？我的网址和 Key 是什么？」
  #    会被一句「请用管理员权限运行」挡回去 —— 对小白来说是纯粹的惊吓，
  #    他并没有要改任何东西。现在放行，只在**真的**读不到时给温和提示。
  load_state || need_state
  say ""
  printf '%s%s 运行状态%s\n\n' "$C_BLD" "$APP_LABEL" "$C_OFF"
  if ! command -v docker >/dev/null 2>&1; then
    err "这台机器上没有 docker"; return 1
  fi
  local st
  # 先解析出真正在跑的容器名（手工改过 compose / 老脚本装过时，$CONTAINER_NAME 会对不上）
  local real_c
  real_c="$(resolve_container_name)"
  if [ -n "$real_c" ]; then
    CONTAINER_NAME="$real_c"
  fi
  # 容器不存在时 docker 会把错误写进 stderr，必须整段丢弃，
  # 否则报错文字会混进 st，让下面 case 匹配不上（表现为多余的换行+missing）
  st="$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null | head -1)"
  [ -n "$st" ] || st="missing"
  case "$st" in
    running)
      if [ "$CONTAINER_NAME" != "$APP_NAME" ]; then
        ok "接口服务：运行中（容器 ${CONTAINER_NAME}，端口 ${API_PORT}）"
      else
        ok "接口服务：运行中（端口 ${API_PORT}）"
      fi
      if api_alive; then
        ok "接口自检：正常"
        # 顺便复查代码级修复还在不在（用户随时可以跑 --status 确认版本没装错）
        verify_installed_fixes || true
      else
        warn "接口自检：没响应（看日志：docker logs "$CONTAINER_NAME" --tail 40）"
      fi ;;
    missing)
      # docker 权限不足时 inspect 也返回空，会落到这里 —— 和「真没容器」长得一样。
      # 区分一下：不是 root、也没有 docker 组权限 → 明确说是权限问题，别误导。
      if [ "$(id -u)" != 0 ] && ! docker ps >/dev/null 2>&1; then
        warn "看不到容器状态（当前用户没有 docker 权限）"
        say "    换个身份再看：sudo bash ${SELF} --status"
      else
        err "接口服务：没找到容器"
        say "    如果你确定服务在跑，可能是容器名和预期不一致。看全部容器："
        say "        docker ps -a"
      fi ;;
    *)       err "接口服务：$st" ;;
  esac
  if systemctl is-active "${WEB_UNIT}" >/dev/null 2>&1; then
    ok "网页服务：运行中（端口 ${WEB_PORT}）"
  else
    err "网页服务：没运行"
  fi

  # v1.3.0 一键导号 sidecar
  local imp_st
  imp_st="$(docker inspect "${CONTAINER_NAME}-import" --format '{{.State.Status}}' 2>/dev/null | head -1)"
  if [ "$imp_st" = "running" ]; then
    ok "一键导号：运行中（端口 ${IMPORT_PORT}）"
  elif [ -z "$imp_st" ]; then
    warn "一键导号：没装（v1.3.0 新增 —— 重跑一次安装即可加上）"
  else
    err "一键导号：$imp_st（看日志：docker logs ${CONTAINER_NAME}-import --tail 40）"
  fi

  # 关键信息：小白关掉安装窗口后，要能从这里把地址和 Key 找回来
  local k ip
  k="$(read_existing_key)"
  ip="$(public_ip 2>/dev/null)"
  [ -n "$ip" ] || ip="<本机公网IP>"
  say ""
  say "  ${C_BLD}连接信息${C_OFF}（配客户端、导号都用这些）"
  say "    网页地址：   http://${ip}:${WEB_PORT}/"
  say "    接口地址：   http://${ip}:${API_PORT}/v1"
  say "    一键导号：   http://${ip}:${IMPORT_PORT}/"
  if [ -n "$k" ]; then
    say "    API Key：    ${k}"
    say "    账号池面板： http://${ip}:${API_PORT}/admin?key=${k}"
  else
    warn "读不到 API Key（可能装的是旧版本）。可从 $INSTALL_DIR/docker-compose.yml 里找 MUSE2API_KEY"
  fi

  # 账号数：直接数 /admin/accounts 里的数组长度
  # （⚠️ 早期版本在这里 grep '"total"'，而接口返回里根本没有这个字段 ——
  #   于是 --status 从来不显示账号数，空池指引也从来不触发。v1.5.0 修。）
  local acct
  acct="$(pool_summary "$k")"
  [ -n "$acct" ] && say "    账号池：     ${acct} 个账号"
  if [ -n "$k" ]; then
    say ""
    say "  ${C_BLD}工作台直达链接${C_OFF}（点开即用 —— 接口地址和 Key 都会自动填好）"
    say "    $(direct_link "$k" "$ip")"
  fi
  if [ "${acct:-}" = "0" ]; then
    say ""
    warn "账号池是空的 —— 还没导入 muse.ai 账号，现在生成不了视频。"
    say ""
    say "    ${C_BLD}加账号只要一条命令：${C_OFF}"
    say "      sudo $(self_hint) --add-account"
    say "      它会生成一条链接 —— 在你自己电脑的浏览器里打开、"
    say "      登录 muse.ai 就导入完成了（不用装 Python、不用填 Key）。"
    say ""
    say "     ${C_DIM}一条链接就能连着导多个账号（导完一个在网页点「再导一个」）。"
    say "     管理账号池：sudo $(self_hint) --accounts${C_OFF}"
  fi
  say ""
  say "  最近的日志："
  docker logs "$CONTAINER_NAME" --tail 5 2>&1 | sed 's/^/    /'
  say ""
}

# ── --add-account ────────────────────────────────────────────────────
# v1.4.0：终端里一条命令完成导号 —— 生成一次性令牌 → 打印免 Key 链接 →
# 用户在浏览器打开链接登录 muse.ai → sidecar 抓到 session cookie 自动入池 →
# 终端轮询 /api/token_status 拿到结果。全程不碰 API Key、不装 Python。
# ── 直达链接 / 账号池读数（面板、--link、--add-account 共用）──────────
#
# 为什么要有「直达链接」：网页的接口地址和 Key 存在浏览器的 localStorage 里，
# 按域名分开存 —— 换个入口打开（IP → 域名）就是一张白纸，用户得手抄一遍 Key，
# 抄错了还只看到「Key 无效」。终端生成带 ?key=&api= 的链接，点开即自动配置，
# 从根上消掉这一类问题。
active_domain() {
  local d="$DOMAIN"
  if [ -z "$d" ] && [ -f "$INSTALL_DIR/Caddyfile" ]; then
    # Caddyfile 形如：全局块 { ... } 然后 "域名 {"。取第一个站点块的名字。
    d="$(awk '
      /^[ \t]*\{[ \t]*$/ { blk=1; next }
      blk && /^[ \t]*\}/ { blk=0; next }
      blk { next }
      /^[^ \t#]/ && /[ \t]*\{[ \t]*$/ { print $1; exit }
    ' "$INSTALL_DIR/Caddyfile" 2>/dev/null)"
  fi
  printf '%s' "$d"
}

direct_link() {
  local k="$1" dom
  dom="$(active_domain)"
  if [ -n "$dom" ]; then
    printf 'https://%s/?key=%s&api=https://%s' "$dom" "$k" "$dom"
  else
    printf 'http://%s:%s/?key=%s&api=http://%s:%s' \
      "$2" "$WEB_PORT" "$k" "$2" "$API_PORT"
  fi
}

pool_summary() {
  local k="$1" n
  [ -n "$k" ] || return 0
  n="$(curl -fsS --max-time 5 -H "Authorization: Bearer $k" \
        "http://127.0.0.1:${API_PORT}/admin/accounts" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    acc = d.get("accounts") if isinstance(d, dict) else d
    print(len(acc) if isinstance(acc, list) else "")
except Exception:
    print("")' 2>/dev/null)"
  printf '%s' "$n"
}

# 生成一枚导号令牌：15 分钟窗口、imports 计数从 0 起。
# 顺手清理过期令牌和旧版本留下的 used 标记条目。
_new_import_token() {
  local path="$1"
  python3 - "$path" <<'PYTOK'
import json, os, secrets, sys, tempfile, time
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        tokens = json.load(f)
    if not isinstance(tokens, dict):
        tokens = {}
except Exception:
    tokens = {}
now = time.time()
tokens = {t: m for t, m in tokens.items()
          if isinstance(m, dict) and float(m.get("expires", 0) or 0) > now
          and not m.get("used")}   # used 是 v1.4.x 的旧字段，留着没用
tok = secrets.token_hex(16)
tokens[tok] = {"created": now, "expires": now + 900, "imports": 0}
directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tokens-")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(tokens, f)
os.replace(tmp, path)
print(tok)
PYTOK
}

do_add_account() {
  load_state || need_state
  command -v docker >/dev/null 2>&1 || die "这台机器上没有 docker"
  say ""
  printf '%s%s 添加 muse.ai 账号%s\n\n' "$C_BLD" "$APP_LABEL" "$C_OFF"

  # 容器名可能被手工改过 / 老脚本装过，先解析出真实名字
  local real_c
  real_c="$(resolve_container_name)"
  [ -n "$real_c" ] && CONTAINER_NAME="$real_c"

  local imp_st
  imp_st="$(docker inspect "${CONTAINER_NAME}-import" --format '{{.State.Status}}' 2>/dev/null | head -1)"
  if [ "$imp_st" != "running" ]; then
    if [ -z "$imp_st" ]; then
      die "一键导号服务还没装（v1.3.0 加入的新组件）。
       先升级装上它：sudo $(self_hint) --upgrade"
    fi
    die "一键导号服务没在跑（状态：$imp_st）。
       看日志：docker logs ${CONTAINER_NAME}-import --tail 40"
  fi
  command -v python3 >/dev/null 2>&1 || die "需要 python3（装的时候应该装过了，手动补一下：apt install -y python3）"

  step "生成导号链接"
  run mkdir -p "$INSTALL_DIR/runtime"
  local token
  # tr 兜底：即使 python 的 stdout 带了 CR（某些环境），令牌也不会被污染
  token="$(_new_import_token "$INSTALL_DIR/runtime/import_tokens.json" | tr -d '\r\n')" \
    || die "令牌生成失败（python3 执行异常）"
  [ -n "$token" ] || die "令牌生成失败（输出为空）"
  chmod 600 "$INSTALL_DIR/runtime/import_tokens.json" 2>/dev/null || true

  local ip dom
  ip="$(public_ip 2>/dev/null)"
  [ -n "$ip" ] || ip="<本机公网IP>"
  dom="$(active_domain)"

  say ""
  say "  ${C_BLD}在你自己电脑的浏览器里打开这个链接：${C_OFF}"
  say ""
  if [ -n "$dom" ]; then
    say "      https://${dom}/import/?token=${token}"
    say "      ${C_DIM}（走域名的前提是域名反代里配过 /import/ → 127.0.0.1:${IMPORT_PORT}；"
    say "       没配过就直接用下面这个直连地址）${C_OFF}"
  fi
  say "      http://${ip}:${IMPORT_PORT}/?token=${token}"
  say ""
  say "  ${C_DIM}· 打开后网页里会出现登录窗口，在里面登录 muse.ai 就行，导入全自动"
  say "  · 一个链接 = 一个 15 分钟的导号窗口，可以连着导多个账号："
  say "    导完一个在网页上点「再导一个」，换个 muse.ai 账号继续登录即可"
  say "  · 这里会一直等并依次报出每个导入的账号；结束按 Ctrl-C，不影响已导入的${C_OFF}"
  say ""

  # 轮询 sidecar（回环，不经过公网）。since = 已经报过的导入次数，
  # 每报一个 +1，于是同一个窗口里连导多个账号也能逐个拿到结果。
  local url="http://127.0.0.1:${IMPORT_PORT}/api/token_status?token=${token}"
  local since=0 imported=0 waited=0 grace=0 legacy=0
  local resp="" line="" state="" imp="" email="" cnt="" hasimp=""
  while [ "$waited" -lt 1800 ]; do
    resp="$(curl -fsS --max-time 5 "${url}&since=${since}" 2>/dev/null)" || resp=""
    if [ -n "$resp" ]; then
      line="$(printf '%s' "$resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
# 最后一个字段：服务端认不认识 imports（v1.5.0+ 才有）
print(d.get("state", ""), d.get("imports", -1), d.get("email", ""),
      d.get("count", -1), 1 if "imports" in d else 0)' 2>/dev/null | tr -d '\r')"
      state="$(printf '%s' "$line" | cut -d' ' -f1)"
      imp="$(printf '%s' "$line" | cut -d' ' -f2)"
      email="$(printf '%s' "$line" | cut -d' ' -f3)"
      cnt="$(printf '%s' "$line" | cut -d' ' -f4)"
      hasimp="$(printf '%s' "$line" | cut -d' ' -f5)"
      case "$state" in
        done)
          printf '\r%-72s\r' " " >&2
          imported=$((imported + 1))
          if [ "$hasimp" = "1" ] && [ "${imp:--1}" -ge 0 ] 2>/dev/null; then
            since="$imp"
          else
            legacy=1
          fi
          if [ "${cnt:--1}" -ge 0 ] 2>/dev/null; then
            ok "导入成功：${email:-账号已进池}（账号池现有 ${cnt} 个）"
          else
            ok "导入成功：${email:-账号已进池}"
          fi
          if [ "$legacy" = 1 ]; then
            # 容器还是 v1.4.x 的导号服务：令牌用一次就废，连不了第二个。
            warn "导号服务是旧版本（v1.4.x）—— 一条链接只能导一个账号。"
            say "    想连着导多个：重跑一次安装升级即可"
            say "      sudo $(self_hint) --upgrade"
            break
          fi
          if [ "$imported" = 1 ]; then
            say "    ${C_DIM}想再加一个？在刚才那个网页点「再导一个」，换个 muse.ai 账号登录 ——"
            say "    这里会自动接着报；再等 90 秒没有新的就结束。${C_OFF}"
          fi
          grace=$((waited + 90))
          ;;
        expired)
          printf '\r%-72s\r' " " >&2
          if [ "$imported" = 0 ]; then
            err "链接过期了（15 分钟没人用）。重新生成一条："
            say "      sudo $(self_hint) --add-account"
            return 1
          fi
          break ;;
        unknown)
          printf '\r%-72s\r' " " >&2
          err "导号服务不认这条链接（容器可能刚重启过）。重新生成一条："
          say "      sudo $(self_hint) --add-account"
          return 1 ;;
      esac
    fi
    if [ "$grace" -gt 0 ] && [ "$waited" -ge "$grace" ]; then
      printf '\r%-72s\r' " " >&2
      break
    fi
    if [ "$imported" = 0 ]; then
      printf '\r    等待浏览器里完成登录… %02d:%02d（Ctrl-C 退出等待）' \
        "$((waited / 60))" "$((waited % 60))" >&2
    else
      printf '\r    本次已导入 %d 个账号 · 还可以继续导，结束按 Ctrl-C' "$imported" >&2
    fi
    sleep 3
    waited=$((waited + 3))
  done
  printf '\r%-72s\r' " " >&2

  if [ "$imported" -gt 0 ]; then
    say ""
    say "  ${C_BLD}工作台直达链接${C_OFF}（接口地址和 Key 都已经带在里面，点开即用）："
    say ""
    say "      $(direct_link "$API_KEY" "$ip")"
    say ""
    say "  ${C_DIM}再管账号就敲：${C_OFF}sudo $(self_hint) --accounts"
    say ""
    return 0
  fi

  warn "等了 30 分钟还没完成，链接应该早就过期了。重新生成：sudo $(self_hint) --add-account"
  return 1
}


# ── 网页入口地址 ──────────────────────────────────────────────────────
web_entry_url() {
  local ip="$1" d
  d="$(active_domain)"
  if [ -n "$d" ]; then printf 'https://%s/' "$d"; else printf 'http://%s:%s/' "$ip" "$WEB_PORT"; fi
}

# ── 账号池管理 ────────────────────────────────────────────────────────
_accounts_json() {
  curl -fsS --max-time 10 -H "Authorization: Bearer $1" \
    "http://127.0.0.1:${API_PORT}/admin/accounts" 2>/dev/null
}

# 账号列表渲染：编号 / 邮箱 / 状态 / 已用次数 / 有效期 / ID，重复邮箱单独标出
_accounts_render() {
  python3 -c '
import sys, json, time, collections, datetime
HINT = sys.argv[1] if len(sys.argv) > 1 else "bash install.sh"
try:
    d = json.load(sys.stdin)
except Exception:
    print("  （解析不了账号池返回的数据）"); sys.exit(0)
acc = d.get("accounts") if isinstance(d, dict) else d
if not isinstance(acc, list) or not acc:
    print("  账号池是空的 —— 还没导入 muse.ai 账号。")
    print("")
    print("  加账号：sudo %s --add-account" % HINT)
    sys.exit(0)

def when(ts):
    try:
        ts = float(ts)
    except Exception:
        return "-"
    if ts <= 0:
        return "-"
    return datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d")

def dw(s):
    """显示宽度：中日韩字符按 2 格算，中文列才不会歪。"""
    return sum(2 if ord(c) > 0x2E80 else 1 for c in str(s))

def pad(s, width):
    s = str(s)
    return s + " " * max(0, width - dw(s))

dup = collections.Counter()
for a in acc:
    dup[(a.get("label") or "").strip().lower()] += 1

w = max([dw(a.get("label") or "") for a in acc] + [dw("邮箱 / 标签")])
print("  账号池：%d 个账号" % len(acc))
print("")
print("   #   " + pad("邮箱 / 标签", w) + "  " + pad("状态", 6) + " "
      + pad("已用", 4) + " " + pad("有效期至", 10) + "  ID")
for i, a in enumerate(acc, 1):
    label = a.get("label") or a.get("id") or ""
    ok = a.get("ok")
    st = "正常" if ok is True else ("异常" if ok is False else "未测")
    if not a.get("enabled", True):
        st = "已停用"
    used = a.get("use_count")
    used = "-" if used is None else str(used)
    mark = "   <- 重复" if dup[(label or "").strip().lower()] > 1 else ""
    print("   " + pad(i, 3) + " " + pad(label, w) + "  " + pad(st, 6) + " "
          + pad(used, 4) + " " + pad(when(a.get("expires_at")), 10) + "  "
          + str(a.get("id", "")) + mark)
dups = [k for k, v in dup.items() if v > 1]
if dups:
    print("")
    print("  ! 有 %d 个邮箱重复导入（同一个 muse.ai 账号进了多条）——" % len(dups))
    print("    重复条目不会让额度变多，反而分不清哪条还能用。删掉多余的：")
    print("      sudo %s --accounts --remove <上面的编号>" % HINT)
print("")
print("  删账号：  sudo %s --accounts --remove <编号>" % HINT)
print("  测会话：  sudo %s --accounts --test   （真开浏览器，每个 10-30 秒）" % HINT)
' "$1"
}

_accounts_list() {
  local k="$1" json
  json="$(_accounts_json "$k")"
  if [ -z "$json" ]; then
    die "拿不到账号池（接口没响应？先跑 sudo $(self_hint) --status 看看服务在不在）"
  fi
  say ""
  printf '%s' "$json" | _accounts_render "$(self_hint)"
}

_accounts_remove() {
  local k="$1" sel="$2" json aid
  json="$(_accounts_json "$k")"
  [ -n "$json" ] || die "拿不到账号池（接口没响应）"
  aid="$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    acc = json.load(sys.stdin).get("accounts") or []
except Exception:
    acc = []
sel = (sys.argv[1] or "").strip()
if sel.isdigit():
    i = int(sel)
    if 1 <= i <= len(acc):
        print(acc[i - 1].get("id", ""))
else:
    for a in acc:
        if a.get("id") == sel:
            print(sel); break
' "$sel" 2>/dev/null)"
  [ -n "$aid" ] || die "找不到编号/ID 是「$sel」的账号（先跑 sudo $(self_hint) --accounts 看列表）"

  local label
  label="$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    acc = json.load(sys.stdin).get("accounts") or []
except Exception:
    acc = []
for a in acc:
    if a.get("id") == sys.argv[1]:
        print(a.get("label", "")); break
' "$aid" 2>/dev/null)"

  curl -fsS --max-time 10 -X DELETE -H "Authorization: Bearer $k" \
    "http://127.0.0.1:${API_PORT}/admin/accounts/${aid}" >/dev/null 2>&1 \
    || die "删除失败（接口报错，账号可能已经不在了）"
  ok "已删除账号：${label:-$aid}"
  say ""
  _accounts_list "$k"
}

_accounts_test() {
  local k="$1" json ids
  json="$(_accounts_json "$k")"
  [ -n "$json" ] || die "拿不到账号池（接口没响应）"
  ids="$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    acc = json.load(sys.stdin).get("accounts") or []
except Exception:
    acc = []
for a in acc:
    print(a.get("id", "") + "\t" + (a.get("label") or ""))' 2>/dev/null)"
  [ -n "$ids" ] || { warn "账号池是空的，没有可测的账号"; return 0; }

  say ""
  say "  逐个打开 muse.ai 验证会话（每个 10-30 秒，别急）..."
  say ""
  local id label res msg n=0 bad=0
  while IFS="$(printf '\t')" read -r id label; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    printf '   [%d] %s … ' "$n" "$label" >&2
    res="$(curl -fsS --max-time 180 -X POST -H "Authorization: Bearer $k" \
      "http://127.0.0.1:${API_PORT}/admin/accounts/${id}/test" 2>/dev/null)"
    msg="$(printf '%s' "$res" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print("ok" if d.get("ok") else "bad", d.get("message", ""))
except Exception:
    print("bad", "没拿到结果")' 2>/dev/null)"
    if [ "${msg%% *}" = "ok" ]; then
      printf '%s✓ 会话有效%s\n' "$C_GRN" "$C_OFF" >&2
    else
      bad=$((bad + 1))
      printf '%s× %s%s\n' "$C_RED" "${msg#* }" "$C_OFF" >&2
    fi
  done <<EOF
$ids
EOF
  say ""
  if [ "$bad" -eq 0 ]; then
    ok "全部 $n 个账号会话有效"
  else
    warn "$n 个账号里有 $bad 个有问题 —— 重新导一遍那个账号即可（--add-account）"
  fi
  say ""
}

do_accounts() {
  load_state || need_state
  local k="$API_KEY"
  [ -n "$k" ] || die "读不到 API Key（安装记录里没有）。先跑 sudo $(self_hint) --status 看看"

  if [ -n "$ACCT_REMOVE" ]; then _accounts_remove "$k" "$ACCT_REMOVE"; return $?; fi
  if [ "$ACCT_TEST" = 1 ]; then   _accounts_test "$k";             return $?; fi
  _accounts_list "$k"
}

# ── 直达链接 ──────────────────────────────────────────────────────────
do_link() {
  load_state || need_state
  local ip
  ip="$(public_ip 2>/dev/null)"
  [ -n "$ip" ] || ip="<本机公网IP>"
  say ""
  say "  ${C_BLD}工作台直达链接${C_OFF}（接口地址和 Key 都带在里面，点开即用）"
  say ""
  say "      $(direct_link "$API_KEY" "$ip")"
  say ""
  say "  ${C_DIM}· 页面打开时自动填好接口地址和 API Key，不用手工配"
  say "  · 手机 / 另一台电脑也能用，把链接发过去就行"
  say "  · 当前 API Key：${API_KEY}${C_OFF}"
  say ""
}

# ── 终端面板快捷命令：/usr/local/bin/muse ─────────────────────────────
install_cli() {
  local cli="/usr/local/bin/muse"
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s[dry-run]%s 写入 %s（之后敲 muse 就能进控制面板）\n' \
      "$C_CYN" "$C_OFF" "$cli"
    return 0
  fi
  cat > "$cli" <<EOF
#!/usr/bin/env bash
# $APP_LABEL 控制面板入口 —— 由 install.sh 生成，删掉它不影响程序运行。
exec bash "$INSTALL_DIR/install.sh" "\$@"
EOF
  chmod 755 "$cli" 2>/dev/null || true
}

remove_cli() {
  rm -f "/usr/local/bin/muse" 2>/dev/null || true
}

# ── 终端控制面板 ──────────────────────────────────────────────────────
_menu_ask() {
  local __v=""
  if [ -r /dev/tty ]; then
    IFS= read -r __v < /dev/tty || __v=""
  else
    IFS= read -r __v || __v=""
  fi
  printf '%s' "$__v"
}

interactive_menu() {
  load_state || true
  local ip n c
  ip="$(public_ip 2>/dev/null)"
  [ -n "$ip" ] || ip="<本机IP>"
  while :; do
    n="$(pool_summary "$API_KEY")"
    say ""
    say "  ${C_BLD}══════════════════════════════════════════════${C_OFF}"
    say "   ${C_BLD}$APP_LABEL${C_OFF}  ·  控制面板"
    say "  ${C_BLD}══════════════════════════════════════════════${C_OFF}"
    say "    网页：   $(web_entry_url "$ip")"
    say "    账号池： ${n:-?} 个 muse.ai 账号"
    say ""
    say "    1) 添加 muse.ai 账号（浏览器登录，可连着导多个）"
    say "    2) 工作台直达链接（带 Key，点开即用）"
    say "    3) 账号池管理（列出 / 删除 / 测活）"
    say "    4) 运行状态"
    say "    5) 升级到最新版"
    say "    6) 重新配置并安装（沿用数据）"
    say "    7) 卸载"
    say "    0) 退出"
    say ""
    printf '  请选择 [0-7，回车=0]: ' >&2
    c="$(_menu_ask)"
    c="${c:-0}"
    case "$c" in
      1) do_add_account ;;
      2) do_link ;;
      3) do_accounts ;;
      4) do_status ;;
      5) do_upgrade ;;
      6) do_install ;;
      7) do_uninstall; return $? ;;
      0|q|exit) say ""; say "  收工。下次敲 muse 就能回来。"; say ""; return 0 ;;
      *) say "  ${C_YEL}没看懂「$c」—— 请输入 0 到 7 之间的数字${C_OFF}" ;;
    esac
  done
}

# ── --uninstall ──────────────────────────────────────────────────────
do_uninstall() {
  load_state || need_state
  say ""
  warn "准备卸载 $APP_LABEL（目录：$INSTALL_DIR）"
  # ⚠️ 卸载是**破坏性**操作，非交互环境下**绝不能默默继续**。
  #
  #    早期版本写的是 `[ "$ASSUME_YES" != 1 ] && [ -t 0 ]` 才问确认 ——
  #    也就是说在非交互环境（管道、`< /dev/null`、CI、从网页复制的命令串）里
  #    会**跳过确认直接卸载**。实测复现：`bash install.sh --uninstall < /dev/null`
  #    一行就把容器删了，小白如果误粘贴这么一条，服务当场就没了。
  #
  #    正确做法：非交互时要求用户**显式**给 --yes 才动手，否则拒绝并告诉他怎么做。
  if [ "$ASSUME_YES" != 1 ]; then
    if [ ! -t 0 ]; then
      die "当前不是交互终端，出于安全我没有直接卸载。
       确认要卸载的话，请显式加上 --yes：
           sudo bash ${SELF} --uninstall --yes
       （不加 --yes 时，请在自己电脑的终端里跑，脚本会问你「确定吗」）"
    fi
    if ! ask_yn "确定要卸载吗？" n; then say "  已取消。"; return 0; fi
  fi
  step "停止并删除容器"
  if [ "$DRY_RUN" != 1 ]; then
    (cd "$INSTALL_DIR" 2>/dev/null && compose down --remove-orphans 2>&1 | tail -2) || true
    docker rm -f "$CADDY_NAME" >/dev/null 2>&1 || true
  fi
  step "摘除域名配置"
  if [ -f /etc/caddy/Caddyfile ]; then
    local bak="/etc/caddy/Caddyfile.bak-$(date +%Y%m%d-%H%M%S)-preUninstall"
    run cp /etc/caddy/Caddyfile "$bak"
    strip_managed_block /etc/caddy/Caddyfile
    run systemctl reload caddy 2>/dev/null || true
  fi
  step "移除网页服务"
  run systemctl disable --now "${WEB_UNIT}" 2>/dev/null || true
  run rm -f "/etc/systemd/system/${WEB_UNIT}"
  run systemctl daemon-reload

  # 顺手把终端面板快捷命令摘掉（否则 muse 会指向一个不存在的脚本）
  remove_cli

  local del_dir=n
  # 非交互时**默认保留**数据（del_dir=n），只删服务不删账号 —— 这是保守的安全默认。
  # 要连数据一起删，只有交互确认（或手动 rm -rf）这一条路。
  # 注：这里不再额外打印说明 —— 下面分支的「数据保留在 …」已经把结果讲清楚了，
  #     多说一句反而啰嗦、还会和它重复。
  if [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
    say ""
    say "  账号和生成过的视频都放在 $INSTALL_DIR 里。"
    if ask_yn "连这些数据一起删掉吗？（删了就不能恢复）" n; then del_dir=y; fi
  fi
  if [ "$del_dir" = y ]; then
    run rm -rf "$INSTALL_DIR"
    ok "目录已删除"
  else
    ok "数据保留在 $INSTALL_DIR（下次重装会自动接着用）"
  fi
  say ""
  ok "卸载完成"
  say ""
}

# ── --upgrade ────────────────────────────────────────────────────────
do_upgrade() {
  load_state || need_state
  say ""
  step "升级 $APP_LABEL"
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s[dry-run]%s git pull && docker compose -p %s up -d --build\n' "$C_CYN" "$C_OFF" "$CONTAINER_NAME"
    return 0
  fi
  # 回滚用的「旧镜像」必须先**打固定 tag 保住**，不能只记 ID。
  #
  #   ⚠️ 为什么：`docker inspect X --format {{.Image}}` 拿到的是容器创建时的镜像 ID
  #   （形如 sha256:ec3c...）。而下面 `compose up --build` 会用**同一个 tag**
  #   （X:latest）重建，旧镜像被顶掉、变成 dangling 层，接着就可能被回收。
  #   实测：拿那个 sha256 去 `docker run` 直接报 "No such image" ——
  #   也就是**原来的回滚根本没生效**（错误还被 `|| true` 吞了，只打印「已尝试回滚」骗人）。
  #   正解：先把当前镜像另存一个固定 tag，回滚时用这个 tag，就一定还在。
  local old_tag=""
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    old_tag="${CONTAINER_NAME}:rollback"
    if docker tag "$CONTAINER_NAME:latest" "$old_tag" >/dev/null 2>&1; then
      : # 保住了
    else
      # 容器在但 :latest 不在（少见），退而用它的镜像 ID
      old_tag="$(docker inspect "$CONTAINER_NAME" --format '{{.Image}}' 2>/dev/null || echo '')"
    fi
  fi
  if [ -d "$INSTALL_DIR/.git" ]; then
    (cd "$INSTALL_DIR" && git pull --ff-only 2>&1 | tail -3) || warn "git pull 没成功，仍尝试用现有代码重建"
  else
    warn "安装目录不是 git 仓库，跳过拉取最新代码"
  fi
  if (cd "$INSTALL_DIR" && compose up -d --build 2>&1 | tail -4); then
    if wait_api_ready; then
      ok "升级完成，服务正常"
      # 升级后同样校验一次：新版代码该带的修复不能丢。
      verify_installed_fixes || true
    else
      err "新版本启动异常，正在回滚"
      # ⚠️ 回滚**必须补齐和正常 compose 一样的关键参数**，不能只映射端口。
      #
      #    早期版本这里是：
      #        docker run -d --name X --restart always -p PORT:PORT "$old_id"
      #    后果：回滚出来的容器等于一个「半残」实例 ——
      #      · 没有 -v data 挂载 → 账号/任务数据全看不见（像被清空）
      #      · 没有 MUSE2API_KEY   → 鉴权密钥变了，所有客户端连同导号工具一并失联
      #      · 没有 --shm-size     → 无头浏览器渲染多标签页时可能崩
      #      · 没有 command 覆盖   → 自定义端口时应用还在听 18610
      #    也就是说：升级失败后「回滚」反而把服务搞得更坏，小白会以为数据丢了。
      #    下面每一项都照 write_compose 对齐。
      if [ -n "$old_tag" ]; then
        local rkey; rkey="$(read_existing_key)"
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        # 校验回滚镜像确实存在；不存在就别假装成功
        if ! docker image inspect "$old_tag" >/dev/null 2>&1; then
          err "回滚镜像 $old_tag 已不存在，无法自动回滚。"
          warn "服务当前是停的。重跑一次安装即可恢复到可用状态：sudo bash ${SELF}"
          return 1
        fi
        if docker run -d --name "$CONTAINER_NAME" --restart always \
          -p "${API_PORT}:${API_PORT}" \
          -v "$INSTALL_DIR/data:/app/data" \
          --shm-size 2g \
          -e "MUSE2API_KEY=${rkey}" \
          -e "MUSE2API_HOST=0.0.0.0" \
          -e "MUSE2API_PORT=${API_PORT}" \
          -e "MUSE2API_PUBLIC_BASE=" \
          -e "MUSE2API_CHROMIUM=/usr/bin/chromium" \
          -e "MUSE2API_CDP_PORT=19210" \
          -e "MUSE2API_IMAGE_TIMEOUT=240" \
          -e "MUSE2API_VIDEO_TIMEOUT=600" \
          -e "MUSE2API_CHAT_TIMEOUT=300" \
          "$old_tag" sh -c "python -m uvicorn app:app --host 0.0.0.0 --port ${API_PORT}" \
          >/dev/null 2>&1; then
          warn "已回滚到升级前的版本（数据卷 / 密钥 / 浏览器参数都已带上），请用 --status 复查"
        else
          err "回滚也没起来。请把下面这条的输出发出来求助："
          say "      docker logs ${CONTAINER_NAME} --tail 50"
        fi
      else
        warn "没有可用的旧镜像，无法自动回滚。服务当前可能不可用，重跑安装可恢复。"
      fi
      return 1
    fi
  else
    err "重建失败，服务可能仍是旧的"
    return 1
  fi
}

# ── 主流程 ───────────────────────────────────────────────────────────
main() {
  detect_os
  derive_names

  if [ "$DO_STATUS" = 1 ]; then     do_status; exit $?; fi
  if [ "$DO_ADD_ACCOUNT" = 1 ]; then check_root "$@"; do_add_account; exit $?; fi
  if [ "$DO_ACCOUNTS" = 1 ]; then   check_root "$@"; do_accounts; exit $?; fi
  if [ "$DO_LINK" = 1 ]; then       do_link; exit $?; fi
  if [ "$DO_UNINSTALL" = 1 ]; then  check_root "$@"; do_uninstall; exit $?; fi
  if [ "$DO_UPGRADE" = 1 ]; then    check_root "$@"; do_upgrade; exit $?; fi

  check_root "$@"

  # 已装过 → 先读回上次的配置作为默认值（命令行显式给的优先）
  if [ -f "$INSTALL_DIR/install.conf" ]; then
    load_state || true
  fi

  # 已装过 + 有终端 → 直接进控制面板（加账号 / 管账号池 / 拿直达链接都在这儿）。
  # --yes 或非交互（脚本、管道）时保持老行为：直接幂等重装一遍。
  if [ -f "$INSTALL_DIR/install.conf" ] && [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
    interactive_menu
    return $?
  fi

  do_install
}

# ⚠️ 小白按 Ctrl+C 中断时（比如嫌下载太慢），脚本默认什么都不说就退出了，
#    他完全不知道自己中断到了哪一步、机器上留了什么、接下来该干什么。
#    这里接住中断，明确告诉他：可以直接重跑，脚本是幂等的、会接着来。
on_interrupt() {
  printf '\n'
  say "  ${C_YEL:-}按了 Ctrl+C，安装中断了。${C_OFF:-}"
  say "  不用担心 —— 这个脚本可以安全地重复运行。刚才下到一半的文件、"
  say "  装好的容器都会保留，重跑一次就会接着来："
  say "      sudo bash ${SELF:-install.sh} --dir ${INSTALL_DIR:-/opt/mvw}"
  say ""
  say "  想看看现在装到哪了："
  say "      sudo bash ${SELF:-install.sh} --status --dir ${INSTALL_DIR:-/opt/mvw}"
  printf '\n'
  exit 130
}
trap on_interrupt INT

main "$@"
