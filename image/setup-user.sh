#!/usr/bin/env bash
# Per-user setup, run as the developer user:
#   nvm + Node.js, uv + Python, Python LSPs, rustup + rust-analyzer,
#   Neovim config (ConfigChad) with all plugins and treesitter parsers.
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-lts/*}"
PYTHON_VERSION="${PYTHON_VERSION:-}"           # empty = latest stable
UV_VERSION="${UV_VERSION:-latest}"
NVM_VERSION="${NVM_VERSION:-latest}"
INSTALL_RUST="${INSTALL_RUST:-1}"
NVIM_CONFIG_REPO="${NVIM_CONFIG_REPO:-https://github.com/bradley101/ConfigChad}"
NVIM_CONFIG_REF="${NVIM_CONFIG_REF:-main}"
NVIM_STRICT="${NVIM_STRICT:-1}"   # fail the build if a plugin/parser is missing
# Compiler for treesitter parsers. clang needs far less memory than GCC for
# the big generated parser.c files: the gitcommit parser gets OOM-killed with
# GCC 15 even with 4 GB of RAM, but builds with clang in < 1 GB.
TS_CC="${TS_CC:-clang}"
# Parallel parser compiles (memory use grows with this); default: min(nproc, 4)
TS_JOBS="${TS_JOBS:-$(( $(nproc) < 4 ? $(nproc) : 4 ))}"
TS_PARSERS="${TS_PARSERS:-c cpp cmake make python lua luadoc vim vimdoc rust bash json yaml toml markdown markdown_inline printf query regex diff gitcommit}"

log() { echo "[setup-user] $*"; }
latest_tag() {
  git ls-remote --tags --refs "https://github.com/$1" \
    | awk '{print $2}' | sed 's#^refs/tags/##' | grep -E "$2" | sort -V | tail -n1
}

cd "$HOME"
mkdir -p "$HOME/.local/bin" "$HOME/workspace"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# ------------------------------------------------------------------------ nvm
[[ "$NVM_VERSION" == "latest" ]] && NVM_VERSION="$(latest_tag nvm-sh/nvm '^v[0-9]+\.[0-9]+\.[0-9]+$')"
log "nvm $NVM_VERSION"
curl -fsSL --retry 5 "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" \
  | PROFILE=/dev/null bash   # shell init is written below

export NVM_DIR="$HOME/.nvm"
set +u; . "$NVM_DIR/nvm.sh"
log "node $NODE_VERSION"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
nvm use default
# pyright: Python LSP (used by most Neovim setups)
npm install -g pyright neovim
set -u

# ------------------------------------------------------------------------- uv
case "$(uname -m)" in
  x86_64) UV_TARGET=x86_64-unknown-linux-gnu ;;
  aarch64) UV_TARGET=aarch64-unknown-linux-gnu ;;
esac
[[ "$UV_VERSION" == "latest" ]] && UV_VERSION="$(latest_tag astral-sh/uv '^[0-9]+\.[0-9]+\.[0-9]+$')"
log "uv $UV_VERSION"
tmp="$(mktemp -d)"
curl -fsSL --retry 5 -o "$tmp/uv.tgz" \
  "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_TARGET}.tar.gz"
tar -xzf "$tmp/uv.tgz" -C "$tmp"
install -m 0755 "$tmp/uv-${UV_TARGET}/uv" "$tmp/uv-${UV_TARGET}/uvx" "$HOME/.local/bin/"
rm -rf "$tmp"

log "python ${PYTHON_VERSION:-latest} via uv"
# shellcheck disable=SC2086
uv python install ${PYTHON_VERSION}
# Python LSP + linters/formatter + debug adapter as isolated uv tools
uv tool install 'python-lsp-server[all]'
uv tool install ruff

# ----------------------------------------------------------------------- rust
# ConfigChad enables rust-analyzer
if [[ "$INSTALL_RUST" == "1" ]]; then
  log "rustup + stable toolchain + rust-analyzer"
  tmp="$(mktemp -d)"
  curl -fsSL --retry 5 -o "$tmp/rustup-init" \
    "https://static.rust-lang.org/rustup/dist/$(uname -m)-unknown-linux-gnu/rustup-init"
  chmod +x "$tmp/rustup-init"
  "$tmp/rustup-init" -y --no-modify-path --profile minimal \
    --component rust-analyzer,rust-src,rustfmt,clippy
  rm -rf "$tmp"
fi

# --------------------------------------------------------------- shell setup
# The PATH block goes at the *top* of ~/.bashrc: Ubuntu's .bashrc returns early
# for non-interactive shells, and `ssh devbox <cmd>` (or an IDE remote server)
# runs a non-interactive bash that only reads ~/.bashrc.
{
  cat <<'TOP'
# ---- devbox: tool paths (also for non-interactive ssh commands) ----
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export EDITOR=nvim VISUAL=nvim
# ---------------------------------------------------------------------

TOP
  cat "$HOME/.bashrc"
  cat <<'BOTTOM'

# ---- devbox: interactive extras ----
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
command -v uv >/dev/null && eval "$(uv generate-shell-completion bash)"
command -v rustup >/dev/null && eval "$(rustup completions bash 2>/dev/null)"
alias vim=nvim vi=nvim
BOTTOM
} > "$HOME/.bashrc.new"
mv "$HOME/.bashrc.new" "$HOME/.bashrc"

# --------------------------------------------------------------- neovim conf
log "neovim config from $NVIM_CONFIG_REPO ($NVIM_CONFIG_REF)"
rm -rf "$HOME/.config/nvim"
git clone --branch "$NVIM_CONFIG_REF" "$NVIM_CONFIG_REPO" "$HOME/.config/nvim"

export TS_PARSERS
LUA_DIR="$(mktemp -d)"

cat > "$LUA_DIR/ts-install.lua" <<'EOF'
local parsers = vim.split(os.getenv("TS_PARSERS") or "", "%s+", { trimempty = true })
local jobs = tonumber(os.getenv("TS_JOBS") or "") or 2
local WAIT = 30 * 60 * 1000
require("lazy").load({ plugins = { "nvim-treesitter" } })

local function missing()
  local m = {}
  for _, lang in ipairs(parsers) do
    if #vim.api.nvim_get_runtime_file("parser/" .. lang .. ".so", false) == 0 then
      table.insert(m, lang)
    end
  end
  return m
end

local ok, ts = pcall(require, "nvim-treesitter")
if ok and type(ts.install) == "function" then
  -- nvim-treesitter `main` branch
  ts.install(parsers, { summary = true, max_jobs = jobs }):wait(WAIT)
  -- retry failures one at a time (least memory pressure)
  for _, lang in ipairs(missing()) do
    print("retrying parser " .. lang .. " on its own")
    ts.install({ lang }, { force = true, summary = true, max_jobs = 1 }):wait(WAIT)
  end
else
  -- nvim-treesitter `master` branch
  vim.cmd("TSInstallSync! " .. table.concat(parsers, " "))
end
EOF

# Exits non-zero (and lists them) if any plugin or parser is missing.
cat > "$LUA_DIR/verify.lua" <<'EOF'
local missing = {}
for _, p in ipairs(require("lazy").plugins()) do
  if not (p._ and p._.installed) then table.insert(missing, "plugin:" .. p.name) end
end
for _, lang in ipairs(vim.split(os.getenv("TS_PARSERS") or "", "%s+", { trimempty = true })) do
  if #vim.api.nvim_get_runtime_file("parser/" .. lang .. ".so", false) == 0 then
    table.insert(missing, "parser:" .. lang)
  end
end
if #missing > 0 then
  io.stderr:write("MISSING: " .. table.concat(missing, " ") .. "\n")
  vim.cmd("cquit 1")
end
io.stdout:write("all plugins and parsers installed\n")
vim.cmd("qall!")
EOF

nvim_setup() {
  log "installing neovim plugins (lazy.nvim)"
  CC="$TS_CC" nvim --headless "+Lazy! sync" +qa
  # once more so every lazy `build` hook (e.g. base46 theme cache) settles
  # before the parsers are installed
  CC="$TS_CC" nvim --headless "+Lazy! sync" +qa
  log "installing treesitter parsers with CC=$TS_CC, $TS_JOBS at a time: $TS_PARSERS"
  CC="$TS_CC" TS_JOBS="$TS_JOBS" nvim --headless "+luafile $LUA_DIR/ts-install.lua" +qa
  nvim --headless "+luafile $LUA_DIR/verify.lua"
}

if ! nvim_setup; then
  log "some neovim plugins/parsers are missing, retrying once"
  sleep 5
  if ! nvim_setup; then
    if [[ "$NVIM_STRICT" == "1" ]]; then
      log "ERROR: neovim setup incomplete (see MISSING above)"; exit 1
    fi
    log "WARN: neovim setup incomplete (see MISSING above); run :Lazy sync and :TSInstall <lang> in nvim later"
  fi
fi
rm -rf "$LUA_DIR"

log "done"
