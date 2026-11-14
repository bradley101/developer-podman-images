#!/usr/bin/env bash
# Installs tools that are distributed as GitHub release binaries, always at
# their latest release (or a pinned one via the *_VERSION variables):
#   neovim, cmake, lua-language-server, stylua, tree-sitter CLI
#
# The latest version is resolved with `git ls-remote --tags`, which (unlike the
# GitHub REST API) is not rate limited for anonymous use.
set -euo pipefail

NVIM_VERSION="${NVIM_VERSION:-latest}"
CMAKE_VERSION="${CMAKE_VERSION:-latest}"
LUALS_VERSION="${LUALS_VERSION:-latest}"
STYLUA_VERSION="${STYLUA_VERSION:-latest}"
TREESITTER_VERSION="${TREESITTER_VERSION:-latest}"

log() { echo "[github-tools] $*"; }

case "$(uname -m)" in
  x86_64)  A_NVIM=x86_64  A_CMAKE=x86_64  A_LUALS=x64   A_STYLUA=x86_64  A_TS=x64   ;;
  aarch64) A_NVIM=arm64   A_CMAKE=aarch64 A_LUALS=arm64 A_STYLUA=aarch64 A_TS=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# latest_tag <owner/repo> <regex for stable tags>
latest_tag() {
  git ls-remote --tags --refs "https://github.com/$1" \
    | awk '{print $2}' | sed 's#^refs/tags/##' \
    | grep -E "$2" | sort -V | tail -n1
}

# resolve <requested> <owner/repo> <regex> -> tag
resolve() {
  if [[ "$1" == "latest" ]]; then latest_tag "$2" "$3"; else echo "$1"; fi
}

fetch() { # url dest
  log "downloading $1"
  curl -fsSL --retry 5 --retry-delay 2 -o "$2" "$1"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# -------------------------------------------------------------------- neovim
tag="$(resolve "$NVIM_VERSION" neovim/neovim '^v[0-9]+\.[0-9]+\.[0-9]+$')"
log "neovim $tag"
fetch "https://github.com/neovim/neovim/releases/download/${tag}/nvim-linux-${A_NVIM}.tar.gz" "$TMP/nvim.tgz"
rm -rf /opt/nvim && mkdir -p /opt/nvim
tar -xzf "$TMP/nvim.tgz" -C /opt/nvim --strip-components=1
ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim

# --------------------------------------------------------------------- cmake
tag="$(resolve "$CMAKE_VERSION" Kitware/CMake '^v[0-9]+\.[0-9]+\.[0-9]+$')"
ver="${tag#v}"
log "cmake $ver"
fetch "https://github.com/Kitware/CMake/releases/download/${tag}/cmake-${ver}-linux-${A_CMAKE}.tar.gz" "$TMP/cmake.tgz"
rm -rf /opt/cmake && mkdir -p /opt/cmake
tar -xzf "$TMP/cmake.tgz" -C /opt/cmake --strip-components=1
for b in /opt/cmake/bin/*; do ln -sf "$b" "/usr/local/bin/$(basename "$b")"; done

# ------------------------------------------------------- lua-language-server
# (NvChad enables lua_ls by default)
tag="$(resolve "$LUALS_VERSION" LuaLS/lua-language-server '^[0-9]+\.[0-9]+\.[0-9]+$')"
log "lua-language-server $tag"
fetch "https://github.com/LuaLS/lua-language-server/releases/download/${tag}/lua-language-server-${tag}-linux-${A_LUALS}.tar.gz" "$TMP/luals.tgz"
rm -rf /opt/lua-language-server && mkdir -p /opt/lua-language-server
tar -xzf "$TMP/luals.tgz" -C /opt/lua-language-server
cat > /usr/local/bin/lua-language-server <<'EOF'
#!/bin/sh
exec /opt/lua-language-server/bin/lua-language-server "$@"
EOF
chmod 0755 /usr/local/bin/lua-language-server

# -------------------------------------------------------------------- stylua
# (formatter configured in ConfigChad's conform.lua)
tag="$(resolve "$STYLUA_VERSION" JohnnyMorganz/StyLua '^v[0-9]+\.[0-9]+\.[0-9]+$')"
log "stylua $tag"
fetch "https://github.com/JohnnyMorganz/StyLua/releases/download/${tag}/stylua-linux-${A_STYLUA}.zip" "$TMP/stylua.zip"
unzip -o -q "$TMP/stylua.zip" -d "$TMP/stylua"
install -m 0755 "$TMP/stylua/stylua" /usr/local/bin/stylua

# --------------------------------------------------------------- tree-sitter
# (nvim-treesitter compiles parsers with the tree-sitter CLI + a C compiler)
tag="$(resolve "$TREESITTER_VERSION" tree-sitter/tree-sitter '^v[0-9]+\.[0-9]+\.[0-9]+$')"
log "tree-sitter $tag"
fetch "https://github.com/tree-sitter/tree-sitter/releases/download/${tag}/tree-sitter-linux-${A_TS}.gz" "$TMP/ts.gz"
gunzip -c "$TMP/ts.gz" > /usr/local/bin/tree-sitter
chmod 0755 /usr/local/bin/tree-sitter

log "nvim:        $(nvim --version | head -n1)"
log "cmake:       $(cmake --version | head -n1)"
log "lua_ls:      $(lua-language-server --version 2>/dev/null | head -n1)"
log "stylua:      $(stylua --version)"
log "tree-sitter: $(tree-sitter --version)"
