#!/usr/bin/env bash
# ==============================================================================
# ERPNext v16 开发环境一键安装（WSL Ubuntu 24.04）
#   - 用 uv 安装 Python 3.14，并由 uv 创建 bench 的虚拟环境
#   - MariaDB 11.8 / Node 24 / Redis / wkhtmltopdf(patched qt)
#   - bench + erpnext 装在 $HOME/frappe-bench
#
# 用法：在 WSL 里执行（不要用 root）
#   bash /mnt/f/AgentHarness-demo/ERPNext/scripts/install-bench-wsl.sh
#
# 可选环境变量：
#   SITE_NAME         默认 erp.local
#   ADMIN_PASSWORD    默认随机生成
#   DB_ROOT_PASSWORD  默认随机生成
#   BENCH_DIR         默认 $HOME/frappe-bench
# ==============================================================================
set -uo pipefail

BENCH_DIR="${BENCH_DIR:-$HOME/frappe-bench}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-16}"
ERPNEXT_BRANCH="${ERPNEXT_BRANCH:-version-16}"
SITE_NAME="${SITE_NAME:-erp.local}"
LOG="$HOME/bench-install-$(date +%Y%m%d-%H%M%S).log"

ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)}"

exec > >(tee -a "$LOG") 2>&1

step() { printf '\n\033[1;36m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m✗ 失败：%s\033[0m\n日志：%s\n' "$*" "$LOG"; exit 1; }

# ---------------------------------------------------------------- 0. 预检
step "0/9 环境预检"

[ "$(id -u)" -eq 0 ] && die "不要用 root 运行，请用 administrator 用户"
[ -f /etc/os-release ] || die "找不到 /etc/os-release"
. /etc/os-release
[ "${VERSION_ID:-}" = "24.04" ] || warn "当前系统 ${PRETTY_NAME:-未知}，脚本按 24.04 编写"

AVAIL_GB=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
[ "$AVAIL_GB" -lt 20 ] && die "家目录剩余空间 ${AVAIL_GB}GB，至少需要 20GB"
ok "用户 $(id -un) (uid=$(id -u))，家目录剩余 ${AVAIL_GB}GB"

if ! sudo -n true 2>/dev/null; then
  echo "  需要 sudo 权限，请输入 $(id -un) 的密码："
  sudo -v || die "sudo 授权失败"
fi
( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null' EXIT
ok "sudo 已授权"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- 1. 系统依赖
step "1/9 安装系统基础依赖"
sudo apt-get update || die "apt update 失败"
sudo apt-get install -y \
  git curl wget build-essential pkg-config \
  libmariadb-dev libjpeg-turbo8 libxrender1 libxext6 libfontconfig1 \
  xfonts-75dpi xfonts-base xvfb cron ca-certificates gnupg 2>&1 | tail -8 \
  || die "基础依赖安装失败（上面有具体包名）"
command -v curl >/dev/null 2>&1 || die "curl 未装上"
command -v git  >/dev/null 2>&1 || die "git 未装上"
ok "基础依赖就绪"

# ---------------------------------------------------------------- 2. MariaDB 11.8
step "2/9 MariaDB 11.8"
MDB_OK=0
if command -v mariadbd >/dev/null 2>&1; then
  mariadbd --version | grep -q '11\.8' && MDB_OK=1
fi

if [ "$MDB_OK" -eq 0 ]; then
  if command -v mariadbd >/dev/null 2>&1; then
    warn "已存在旧版 $(mariadbd --version | head -1)，升级到 11.8"
  fi
  curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup -o /tmp/mariadb_repo_setup.sh \
    || die "下载 MariaDB 源脚本失败"
  sudo bash /tmp/mariadb_repo_setup.sh --mariadb-server-version="mariadb-11.8" 2>&1 | tail -6 \
    || die "MariaDB 源配置失败"
  sudo apt-get update -qq
  sudo apt-get install -y -qq mariadb-server mariadb-client 2>&1 | tail -5 \
    || die "MariaDB 安装失败"
fi
ok "$(mariadbd --version | head -1)"

sudo tee /etc/mysql/mariadb.conf.d/99-frappe.cnf >/dev/null <<'CNF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_file_per_table = 1
[mysql]
default-character-set = utf8mb4
CNF

sudo systemctl enable mariadb >/dev/null 2>&1
sudo systemctl restart mariadb 2>/dev/null || sudo service mariadb restart
sleep 3
sudo systemctl is-active --quiet mariadb || die "MariaDB 未能启动"

if sudo mariadb -e "SELECT 1" >/dev/null 2>&1; then
  sudo mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" \
    || die "设置 MariaDB root 密码失败"
  ok "已设置 root 密码（原 socket 免密登录失效，改用 mysql -u root -p）"
elif mariadb -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1; then
  ok "root 密码已存在且可用"
else
  die "无法连接 MariaDB，请手动检查（sudo systemctl status mariadb）"
fi
mariadb -h 127.0.0.1 -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT VERSION()" >/dev/null 2>&1 \
  || die "MariaDB TCP 连接失败"

# ---------------------------------------------------------------- 3. Node 24
step "3/9 Node.js 24 + Yarn"
NODE_MAJOR=0
command -v node >/dev/null 2>&1 && NODE_MAJOR=$(node -v | sed 's/^v\([0-9]*\).*/\1/')
if [ "${NODE_MAJOR:-0}" -lt 24 ]; then
  sudo apt-get remove -y -qq npm nodejs 2>/dev/null | tail -2
  curl -fsSL https://deb.nodesource.com/setup_24.x -o /tmp/nodesource_setup.sh || die "下载 NodeSource 脚本失败"
  sudo -E bash /tmp/nodesource_setup.sh 2>&1 | tail -6 || die "NodeSource 源配置失败"
  sudo apt-get install -y -qq nodejs 2>&1 | tail -5 || die "Node.js 安装失败"
fi
NODE_MAJOR=$(node -v | sed 's/^v\([0-9]*\).*/\1/')
[ "$NODE_MAJOR" -ge 24 ] || die "Node 版本仍为 $(node -v)，需 >=24"
command -v yarn >/dev/null 2>&1 || sudo npm install -g yarn 2>&1 | tail -3
ok "node $(node -v) / npm $(npm -v) / yarn $(yarn -v 2>/dev/null || echo 未装)"

# ---------------------------------------------------------------- 4. wkhtmltopdf
step "4/9 wkhtmltopdf 0.12.6 (patched qt)"
if wkhtmltopdf --version 2>/dev/null | grep -q patched; then
  ok "已安装：$(wkhtmltopdf --version | head -1)"
else
  WK_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb"
  curl -fsSL -o /tmp/wkhtmltox.deb "$WK_URL" || die "下载 wkhtmltopdf 失败"
  sudo apt-get install -y -qq /tmp/wkhtmltox.deb 2>&1 | tail -5 || {
    sudo apt-get -f install -y -qq
    sudo dpkg -i /tmp/wkhtmltox.deb || die "wkhtmltopdf 安装失败"
  }
  wkhtmltopdf --version | grep -q patched || warn "wkhtmltopdf 可能不是 patched qt 版本"
  ok "$(wkhtmltopdf --version | head -1)"
fi

# ---------------------------------------------------------------- 5. uv + Python 3.14
step "5/9 uv + Python 3.14"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh 2>&1 | tail -4 || die "uv 安装失败"
fi
export PATH="$HOME/.local/bin:$PATH"
grep -qs 'HOME/.local/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
uv --version || die "uv 不可用"

uv python install 3.14 2>&1 | tail -3 || die "Python 3.14 安装失败"
PY314="$(uv python find 3.14)" || die "找不到 uv 安装的 Python 3.14"
"$PY314" --version | grep -q '3\.14' || die "Python 版本不符：$("$PY314" --version)"
ok "uv $(uv --version | awk '{print $2}') / $("$PY314" --version 2>&1)"

step "5.1/9 frappe-bench CLI（uv tool 隔离环境）"
if uv tool list 2>/dev/null | grep -q frappe-bench; then
  uv tool upgrade frappe-bench 2>&1 | tail -3
else
  uv tool install frappe-bench 2>&1 | tail -5 || die "frappe-bench 安装失败"
fi
command -v bench >/dev/null 2>&1 || die "bench 不在 PATH，请检查 ~/.local/bin"
ok "bench $(bench --version 2>/dev/null | head -1)"

# ---------------------------------------------------------------- 6. bench init
step "6/9 初始化 bench（uv 创建虚拟环境）→ $BENCH_DIR"
if [ -d "$BENCH_DIR" ]; then
  warn "目录已存在，跳过 bench init"
else
  bench init --frappe-branch "$FRAPPE_BRANCH" --python "$PY314" --dev "$BENCH_DIR" 2>&1 | tail -25 \
    || die "bench init 失败（详见日志）"
fi
[ -x "$BENCH_DIR/env/bin/python" ] || die "虚拟环境未生成：$BENCH_DIR/env"
ok "虚拟环境 $("$BENCH_DIR/env/bin/python" --version)，frappe $(cd "$BENCH_DIR/apps/frappe" && git describe --tags --always 2>/dev/null | head -1)"

# ---------------------------------------------------------------- 7. erpnext
step "7/9 拉取 ERPNext ($ERPNEXT_BRANCH)"
cd "$BENCH_DIR" || die "无法进入 $BENCH_DIR"
if [ -d apps/erpnext ]; then
  warn "erpnext 已存在，跳过 get-app"
else
  bench get-app --branch "$ERPNEXT_BRANCH" https://github.com/frappe/erpnext 2>&1 | tail -20 \
    || die "bench get-app erpnext 失败"
fi
ok "erpnext $(cd apps/erpnext && git describe --tags --always 2>/dev/null | head -1)"

# ---------------------------------------------------------------- 8. 站点
step "8/9 创建站点 $SITE_NAME"
if [ -d "sites/$SITE_NAME" ]; then
  warn "站点已存在，跳过创建"
else
  HELP="$(bench new-site --help 2>&1)"
  NS_ARGS=(--admin-password "$ADMIN_PASSWORD")
  if echo "$HELP" | grep -q -- '--mariadb-root-password'; then
    NS_ARGS+=(--mariadb-root-username root --mariadb-root-password "$DB_ROOT_PASSWORD")
  elif echo "$HELP" | grep -q -- '--db-root-password'; then
    NS_ARGS+=(--db-root-password "$DB_ROOT_PASSWORD")
  else
    warn "未识别到 root 密码参数，安装过程可能要求手动输入"
  fi
  bench new-site "$SITE_NAME" "${NS_ARGS[@]}" </dev/null 2>&1 | tail -15 \
    || die "bench new-site 失败"
fi

if bench --site "$SITE_NAME" list-apps 2>/dev/null | grep -qx erpnext; then
  warn "erpnext 已安装到站点"
else
  bench --site "$SITE_NAME" install-app erpnext 2>&1 | tail -15 || die "install-app erpnext 失败"
fi

bench --site "$SITE_NAME" set-config developer_mode 1 >/dev/null 2>&1
bench --site "$SITE_NAME" enable-scheduler >/dev/null 2>&1
bench --site "$SITE_NAME" clear-cache >/dev/null 2>&1
bench use "$SITE_NAME" >/dev/null 2>&1
ok "站点 $SITE_NAME 就绪，已开启 developer_mode"

# ---------------------------------------------------------------- 9. 汇总
step "9/9 完成"
cat <<EOF

  项目目录   : $BENCH_DIR
  虚拟环境   : $BENCH_DIR/env  (Python 3.14, 由 uv 管理)
  站点        : $SITE_NAME
  管理员账号 : Administrator
  管理员密码 : $ADMIN_PASSWORD
  数据库 root : $DB_ROOT_PASSWORD

  启动开发服务器：
    cd $BENCH_DIR && bench start
  然后浏览器访问：
    http://localhost:8000
  账号 Administrator / $ADMIN_PASSWORD

  常用命令：
    cd $BENCH_DIR
    bench --site $SITE_NAME console        # 交互式 shell
    bench build --app erpnext              # 改前端后重新构建
    bench --site $SITE_NAME migrate        # 拉代码后迁移
    bench restart                          # 重启进程

  日志：$LOG

EOF
