#!/usr/bin/env bash
# Installs the base system: refreshed apt repos, full upgrade, developer,
# networking, debugging and performance-monitoring tools.
set -euo pipefail

UNMINIMIZE="${UNMINIMIZE:-1}"

apt_install() { apt-get install -y --no-install-recommends "$@"; }

# ---------------------------------------------------------------- apt refresh
apt-get update
apt-get -y full-upgrade

# Ubuntu container images are "minimized" (no man pages / docs). A developer
# box wants them back.
if [[ "$UNMINIMIZE" == "1" ]]; then
  apt_install unminimize
  yes | unminimize || true
fi

# --------------------------------------------------------------- core / shell
core=(
  ca-certificates curl wget gnupg openssl software-properties-common
  sudo tini locales tzdata bash-completion ncurses-term
  man-db manpages manpages-dev less nano vim-tiny tmux screen
  zip unzip xz-utils bzip2 zstd tar gzip file tree jq yq
  ripgrep fd-find fzf bat lazygit rsync xxd
  openssh-server openssh-client
)

# ------------------------------------------------------------------- git / vcs
vcs=( git git-lfs gh )

# ---------------------------------------------------------------- build tools
# (gcc/g++/clang are installed by install-toolchains.sh, cmake by
#  install-github-tools.sh so that we always get the latest versions)
build=(
  build-essential make ninja-build meson pkg-config autoconf automake libtool
  m4 bison flex gettext patch ccache bear
  libssl-dev zlib1g-dev libffi-dev libbz2-dev libreadline-dev libsqlite3-dev
  liblzma-dev libncurses-dev uuid-dev
  python3 python3-dev python3-pip python3-venv
)

# --------------------------------------------------------------- networking
net=(
  iproute2 iputils-ping iputils-tracepath arping net-tools bind9-dnsutils
  traceroute mtr-tiny netcat-openbsd socat nmap tcpdump tshark telnet whois
  iperf3 ethtool ipcalc httpie iftop nethogs bmon
)

# ---------------------------------------------------------------- debugging
debug=(
  gdb gdbserver valgrind strace ltrace lsof binutils elfutils heaptrack rr
)

# --------------------------------------------------- performance monitoring
perf=(
  procps htop btop atop nmon glances sysstat iotop iotop-c psmisc
  numactl stress-ng hyperfine ncdu duf
)
# perf: its own package since Ubuntu 25.10, part of linux-tools before
if apt-cache show linux-perf >/dev/null 2>&1; then perf+=(linux-perf); else perf+=(linux-tools-generic); fi

apt_install "${core[@]}" "${vcs[@]}" "${build[@]}" "${net[@]}" "${debug[@]}" "${perf[@]}"

# ------------------------------------------------------------- small fixups
# Ubuntu ships these under different names.
ln -sf "$(command -v fdfind)" /usr/local/bin/fd
ln -sf "$(command -v batcat)" /usr/local/bin/bat

# With linux-tools-* (Ubuntu <= 25.04) perf is installed per kernel version and
# the /usr/bin/perf wrapper refuses to run when the host kernel differs (it
# always does in a container). Point straight at the binary instead.
if ! perf --version >/dev/null 2>&1; then
  perf_bin="$(ls -1 /usr/lib/linux-tools*/*/perf /usr/lib/linux-tools*/perf 2>/dev/null | sort -V | tail -n1 || true)"
  if [[ -n "$perf_bin" ]]; then ln -sf "$perf_bin" /usr/local/bin/perf; fi
fi

# Locale
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

git lfs install --system
