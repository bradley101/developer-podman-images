#!/usr/bin/env bash
# Installs the newest available GCC and LLVM/Clang toolchains (g++, clang++,
# clangd, lldb, lld, clang-format, clang-tidy, libc++) and makes them the
# defaults (symlinks in /usr/local/bin, which comes first in PATH).
#
#   GCC_VERSION / LLVM_VERSION   "latest" (default) or a major version, e.g. 15
#   USE_TOOLCHAIN_PPA=1          also look in ppa:ubuntu-toolchain-r/test
#   USE_LLVM_APT_REPO=1          also look in apt.llvm.org (newest stable LLVM)
#   GCC_ALLOW_SNAPSHOT=0         set to 1 to allow GCC pre-release snapshots
#
# Extra repositories are best effort: if one is unreachable or does not (yet)
# support this Ubuntu release, the newest version from the Ubuntu archive is
# used instead.
set -euo pipefail

GCC_VERSION="${GCC_VERSION:-latest}"
LLVM_VERSION="${LLVM_VERSION:-latest}"
USE_TOOLCHAIN_PPA="${USE_TOOLCHAIN_PPA:-1}"
USE_LLVM_APT_REPO="${USE_LLVM_APT_REPO:-1}"
GCC_ALLOW_SNAPSHOT="${GCC_ALLOW_SNAPSHOT:-0}"

. /etc/os-release
CODENAME="${VERSION_CODENAME}"

log() { echo "[toolchains] $*"; }

# Keep a newly added repo only if `apt-get update` works with it. By default
# apt only *warns* about unreachable repos, hence --error-on=any.
keep_repo_or_drop() { # files...
  if apt-get update --error-on=any; then return 0; fi
  log "WARN: repository not usable for ${CODENAME}, dropping: $*"
  rm -f "$@"
  apt-get update
}

# Writes the apt.llvm.org source list. Returns non-zero on any failure.
# (No reliance on `set -e`: it is ignored inside `if` conditions.)
add_llvm_repo() { # list-file
  local tmp ver
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 https://apt.llvm.org/llvm.sh -o "$tmp/llvm.sh" || { rm -rf "$tmp"; return 1; }
  if [[ "$LLVM_VERSION" == "latest" ]]; then
    ver="$(sed -n 's/^CURRENT_LLVM_STABLE=\([0-9]*\).*/\1/p' "$tmp/llvm.sh")"
  else
    ver="$LLVM_VERSION"
  fi
  rm -rf "$tmp"
  [[ -n "$ver" ]] || return 1
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 https://apt.llvm.org/llvm-snapshot.gpg.key -o /etc/apt/keyrings/apt.llvm.org.asc || return 1
  grep -q "BEGIN PGP PUBLIC KEY BLOCK" /etc/apt/keyrings/apt.llvm.org.asc || return 1
  echo "deb [signed-by=/etc/apt/keyrings/apt.llvm.org.asc] http://apt.llvm.org/${CODENAME}/ llvm-toolchain-${CODENAME}-${ver} main" > "$1"
  log "apt.llvm.org: LLVM ${ver} for ${CODENAME}"
}

# ------------------------------------------------------------ extra apt repos
if [[ "$USE_TOOLCHAIN_PPA" == "1" ]]; then
  log "adding ppa:ubuntu-toolchain-r/test"
  if add-apt-repository -y -n ppa:ubuntu-toolchain-r/test; then
    keep_repo_or_drop /etc/apt/sources.list.d/ubuntu-toolchain-r-*
  else
    log "WARN: could not add the toolchain PPA, using the Ubuntu archive"
    rm -f /etc/apt/sources.list.d/ubuntu-toolchain-r-*
  fi
fi

if [[ "$USE_LLVM_APT_REPO" == "1" ]]; then
  log "adding apt.llvm.org"
  llvm_list=/etc/apt/sources.list.d/apt.llvm.org.list
  if add_llvm_repo "$llvm_list"; then
    keep_repo_or_drop "$llvm_list" /etc/apt/keyrings/apt.llvm.org.asc
  else
    log "WARN: could not add apt.llvm.org, using the Ubuntu archive"
    rm -f "$llvm_list" /etc/apt/keyrings/apt.llvm.org.asc
  fi
fi

apt-get update

# Highest N for which package "<prefix>N" exists, e.g. newest g++-N.
newest() {
  apt-cache pkgnames "$1" | grep -E "^$(sed 's/[+]/\\+/g' <<<"$1")[0-9]+$" \
    | sed "s/^.*-//" | sort -n | tail -n1
}

# Newest g++-N that is a real release. Ubuntu sometimes ships a pre-release
# snapshot of the next GCC (package version "16-20260322-1ubuntu1", compiler
# reports "experimental"); releases look like "15.2.0-...".
newest_stable_gcc() {
  local n cand
  for n in $(apt-cache pkgnames g++- | grep -E '^g\+\+-[0-9]+$' | sed 's/^g++-//' | sort -rn); do
    cand="$(apt-cache policy "g++-$n" | awk '/Candidate:/{print $2}')"
    if [[ "$GCC_ALLOW_SNAPSHOT" == "1" || "$cand" =~ ^([0-9]+:)?[0-9]+\.[0-9]+ ]]; then
      echo "$n"; return 0
    fi
    log "skipping g++-$n ($cand is a pre-release snapshot; GCC_ALLOW_SNAPSHOT=1 to use it)" >&2
  done
  return 1
}

# ------------------------------------------------------------------------ GCC
[[ "$GCC_VERSION" == "latest" ]] && GCC_VERSION="$(newest_stable_gcc)"
G="$GCC_VERSION"
log "installing GCC $G"
apt-get install -y --no-install-recommends "gcc-$G" "g++-$G" "cpp-$G"

# ----------------------------------------------------------------------- LLVM
[[ "$LLVM_VERSION" == "latest" ]] && LLVM_VERSION="$(newest clang-)"
V="$LLVM_VERSION"
log "installing LLVM $V"
apt-get install -y --no-install-recommends \
  "clang-$V" "clangd-$V" "clang-format-$V" "clang-tidy-$V" "clang-tools-$V" \
  "lldb-$V" "lld-$V" "llvm-$V" "llvm-$V-dev" \
  "libc++-$V-dev" "libc++abi-$V-dev" "libclang-rt-$V-dev"

# ------------------------------------------------------ make them the default
link() { [[ -x "$1" ]] && ln -sf "$1" "/usr/local/bin/$2"; return 0; }

for t in gcc g++ cpp gcc-ar gcc-nm gcc-ranlib gcov gcov-dump gcov-tool; do
  link "/usr/bin/$t-$G" "$t"
done
link "/usr/bin/gcc-$G" cc
link "/usr/bin/g++-$G" c++

for t in /usr/lib/llvm-"$V"/bin/*; do
  name="$(basename "$t")"
  # only link tools that Ubuntu also exposes as <tool>-<ver> in /usr/bin
  [[ -e "/usr/bin/$name-$V" ]] && link "/usr/bin/$name-$V" "$name"
done

cat > /etc/profile.d/toolchains.sh <<EOF
# Installed by install-toolchains.sh
export DEVBOX_GCC_VERSION=$G
export DEVBOX_LLVM_VERSION=$V
EOF

log "g++:     $(/usr/local/bin/g++ --version | head -n1)"
log "clang++: $(/usr/local/bin/clang++ --version | head -n1)"
log "clangd:  $(/usr/local/bin/clangd --version | head -n1)"
log "lldb:    $(/usr/local/bin/lldb --version | head -n1)"
