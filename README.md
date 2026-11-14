# devbox: an Ubuntu developer environment for Podman

You build this image once, start it, and SSH into it. It runs all the time:
Podman restarts it when it exits, and as a Quadlet systemd service it also
starts at boot.

| Area | What's inside |
|---|---|
| Base | `ubuntu:26.04` (LTS). The apt repos are refreshed and the system is `full-upgrade`d at build time. The image is unminimized, so man pages are included. |
| C / C++ | Newest **GCC** (`g++`) and **LLVM** (`clang++`, **`clangd`**, `lldb`, `lld`, `clang-format`, `clang-tidy`, `libc++`). `gcc`, `g++`, `cc`, `c++`, `clang++`, `clangd`, … point at the newest versions. |
| Build | `cmake` (latest release from Kitware), `make`, `build-essential`, `ninja`, `meson`, `autotools`, `pkg-config`, `ccache`, `bear` (creates `compile_commands.json` for clangd), common `-dev` libraries |
| Node | **nvm** (latest), with the Node.js LTS release installed as the default |
| Python | **uv** (latest), with the latest CPython installed by uv. Python LSPs: **pyright** and **python-lsp-server** (`pylsp`), plus `ruff`. |
| Rust | rustup stable + **rust-analyzer** (ConfigChad enables it) |
| Neovim | **Latest stable Neovim** and the [ConfigChad](https://github.com/bradley101/ConfigChad) config in `~/.config/nvim`. All plugins and treesitter parsers are installed at build time. |
| nvim deps | `lua-language-server`, `stylua`, `tree-sitter` CLI, `ripgrep`, `fd`, `fzf`, a C compiler, `git`, `curl`, `unzip`, `npm`, `python3-venv` (for Mason) |
| Git | `git`, `git-lfs`, `gh`, `lazygit` |
| Networking | `ip`, `ping`, `tracepath`, `traceroute`, `mtr`, `dig`/`nslookup`, `netstat`/`ifconfig`, `nc`, `socat`, `nmap`, `tcpdump`, `tshark`, `iperf3`, `ethtool`, `arping`, `telnet`, `whois`, `httpie`, `iftop`, `nethogs`, `bmon` |
| Debugging | `gdb`, `gdbserver`, `lldb`, `valgrind`, `strace`, `ltrace`, `lsof`, `heaptrack`, `rr`, `binutils`, `elfutils` |
| Performance | `top`, `htop`, `btop`, `atop`, `nmon`, `glances`, `iostat`/`mpstat`/`sar` (sysstat), `iotop`, `perf`, `numactl`, `stress-ng`, `hyperfine`, `ncdu`, `duf` |
| Shell | `tmux`, `screen`, `bash-completion`, `bat`, `jq`, `yq`, `tree`, `rsync`, `less`, `nano` |
| SSH | `openssh-server` runs in the foreground as the container's main process, with `tini` as PID 1. Login is by public key; a password is optional. |

The user is `dev` and has passwordless `sudo`. Put your projects in
`~/workspace`, which is a persistent volume.

## Quick start

These steps need Podman 4.4 or newer (Quadlet needs 4.4+, and
`HealthOnFailure` needs 4.6+).

```bash
git clone https://github.com/bradley101/developer-podman-images.git
cd developer-podman-images

./devbox.sh build             # build localhost/devbox:latest (takes a while)
./devbox.sh install-service   # run as a systemd service: always running, starts at boot
# or: ./devbox.sh run         # plain `podman run --restart=always`

ssh -p 2222 dev@localhost     # or ./devbox.sh ssh
```

`devbox.sh` collects your `~/.ssh/*.pub` keys into
`~/.config/devbox/authorized_keys` and mounts that directory read-only into the
container. To use a different key, set `DEVBOX_PUBKEY=/path/to/key.pub` before
you run it. You can also add keys to that file later. A running container sees
the change right away, with no restart needed.

You can add a host entry to `~/.ssh/config`:

```sshconfig
Host devbox
    HostName localhost        # or the machine's IP / hostname
    Port 2222
    User dev
    ForwardAgent yes          # use your local keys for git push inside the box
```

Then connect with `ssh devbox`. The entry also works for VS Code Remote-SSH,
JetBrains Gateway, and `nvim` over SSH.

### `devbox.sh` commands and settings

```
./devbox.sh build [podman build args]   e.g. ./devbox.sh build --build-arg GCC_VERSION=15
./devbox.sh run | install-service | ssh | shell | logs | status | stop | rm
```

| Variable | Default | |
|---|---|---|
| `DEVBOX_IMAGE` | `localhost/devbox:latest` | image tag |
| `DEVBOX_NAME` | `devbox` | container, volume and service name |
| `DEVBOX_PORT` | `2222` | SSH port on the host |
| `DEVBOX_BIND` | `0.0.0.0` | Set `127.0.0.1` to allow local connections only. |
| `DEVBOX_PUBKEY` | `~/.ssh/*.pub` | key file(s) to authorize, separated by `:` |
| `DEVBOX_PASSWORD` | unset | Sets a password for `dev` and turns on SSH password login. `install-service` stores it as a Podman secret. |
| `DEVBOX_WORKSPACE` | unset | A host directory to use as `~/workspace` in place of the `devbox-workspace` volume |
| `DEVBOX_MOUNTS` | unset | Extra host directories, comma separated: `host:container[:options]` |

`./devbox.sh run` passes any extra arguments through to `podman run`, for
example `./devbox.sh run -e FOO=bar`.

## Mounting your own directories

Set these variables when you run `./devbox.sh run` or `./devbox.sh install-service`:

```bash
# your local ~/code becomes ~/workspace inside the box
DEVBOX_WORKSPACE=~/code ./devbox.sh install-service
```

```bash
# extra mounts; a relative container path is relative to /home/dev
DEVBOX_WORKSPACE=~/code DEVBOX_MOUNTS="~/notes:notes,~/datasets:/data:ro" ./devbox.sh run
```

- Each `DEVBOX_MOUNTS` entry is `host:container[:options]`. The options are
  passed to `podman --volume`, e.g. `ro`. Paths can't contain `,` or `:`.
- `~` and relative host paths are resolved. A host directory that doesn't exist
  is reported as an error.
- With `install-service`, the mounts are written into the systemd unit. To
  change them, run `install-service` again with new values. With `run`, use
  `./devbox.sh rm` and run it again.
- **SELinux** (Fedora, RHEL): a mount with no options gets `:z`, so the
  container can access it. Your home directory itself is never relabeled. If
  you give options yourself, include `z` when you need it.

**File ownership.** With **rootless** Podman (`./devbox.sh` run as your normal
user), the helper adds `--userns=keep-id:uid=1000,gid=1000`. This maps *your*
host user to `dev` inside the container. Files you edit in the box stay owned
by you on the host, whatever your host UID is. The first start after this
setting changes takes a little longer, because Podman prepares an ID-mapped
copy of the image.

With **rootful** Podman (`sudo`), UIDs are not remapped, so `dev` (UID 1000)
can only write to host files owned by UID 1000. The script warns you if that
isn't the case. Use rootless Podman, or build with
`--build-arg USER_UID=<uid> --build-arg USER_GID=<gid>`.

## "Always running"

- **`./devbox.sh install-service`** (recommended) installs the
  [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
  unit [`quadlet/devbox.container`](quadlet/devbox.container). For a rootless
  setup it goes in `~/.config/containers/systemd/`; for a rootful setup, in
  `/etc/containers/systemd/`. The unit has `Restart=always`, a health check
  that kills an unhealthy sshd so systemd restarts it, and `WantedBy=default.target`.
  For rootless use, the script also runs `loginctl enable-linger`, so the service
  starts at boot without anyone logged in.
  Manage it with `systemctl --user status|restart|stop devbox`.
- **`./devbox.sh run`** uses `podman run --restart=always`. Podman restarts the
  container if it exits. To start it at boot with rootless Podman, enable
  `systemctl --user enable --now podman-restart.service`.

The container's main process is `sshd -D`, so the container keeps running as
long as sshd is up.

## Using it without the helper script

```bash
podman build --format docker -t localhost/devbox:latest .
```

```bash
podman run -d --name devbox --hostname devbox --restart always \
  -p 2222:22 \
  -v devbox-workspace:/home/dev/workspace \
  -v devbox-hostkeys:/etc/ssh/hostkeys \
  -e SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  --cap-add SYS_PTRACE --cap-add PERFMON --security-opt seccomp=unconfined \
  localhost/devbox:latest
```

The build uses `--format docker` because the default OCI format drops the
`HEALTHCHECK`.

Environment variables the container understands:

- `SSH_AUTHORIZED_KEYS`: public keys, one per line, added to `~dev/.ssh/authorized_keys`.
- A key file at `/etc/devbox/authorized_keys` also works. Mount a directory that contains it at `/etc/devbox`.
- `DEV_PASSWORD`: turns on password authentication with this password.
- `TZ`: time zone, e.g. `Europe/Berlin`.

The SSH host keys are stored in the `devbox-hostkeys` volume. Rebuilding the
image or re-creating the container keeps the same host fingerprint, so you
won't get `REMOTE HOST IDENTIFICATION HAS CHANGED` warnings.

`--cap-add SYS_PTRACE --security-opt seccomp=unconfined` lets `gdb`, `lldb`,
`strace`, `rr` and `valgrind` work fully. Without these options, `gdb` cannot
turn off ASLR. `perf` also depends on the host's `kernel.perf_event_paranoid`
setting. Lower it with `sudo sysctl kernel.perf_event_paranoid=1`, or run the
container `--privileged` if you need system-wide profiling.

## Build arguments

Pass these with `./devbox.sh build --build-arg NAME=value` or
`podman build --build-arg NAME=value`.

| Argument | Default | |
|---|---|---|
| `BASE_IMAGE` | `docker.io/library/ubuntu:26.04` | `ubuntu:24.04` also works |
| `USERNAME` / `USER_UID` / `USER_GID` | `dev` / `1000` / `1000` | If you change `USERNAME`, also set `DEVBOX_USER` when running, and update `USER_IN_BOX` in `devbox.sh`. |
| `GCC_VERSION` | `latest` | the newest *released* `g++-N` available, or a major version such as `15` |
| `GCC_ALLOW_SNAPSHOT` | `0` | Set `1` to let `latest` pick a GCC pre-release snapshot. Ubuntu 26.04 ships one as `gcc-16`, and it reports itself as "experimental". |
| `LLVM_VERSION` | `latest` | the newest `clang-N` available, or a major version such as `21` |
| `USE_TOOLCHAIN_PPA` | `1` | Also search `ppa:ubuntu-toolchain-r/test` for a newer GCC. |
| `USE_LLVM_APT_REPO` | `1` | Also search [apt.llvm.org](https://apt.llvm.org) for the current stable LLVM. |
| `NVIM_VERSION` | `latest` | e.g. `v0.12.6` |
| `CMAKE_VERSION` | `latest` | e.g. `v4.2.3` |
| `NODE_VERSION` | `lts/*` | any version `nvm install` accepts |
| `PYTHON_VERSION` | (latest) | any version `uv python install` accepts, e.g. `3.13` |
| `INSTALL_RUST` | `1` | Set `0` to skip rustup and rust-analyzer. |
| `NVIM_CONFIG_REPO` / `NVIM_CONFIG_REF` | ConfigChad / `main` | the Neovim config to clone |
| `NVIM_STRICT` | `1` | The build fails if any Neovim plugin or treesitter parser fails to install. Set `0` to only warn, for example behind a proxy that blocks codeberg.org. lazy.nvim then retries on first start. |
| `UNMINIMIZE` | `1` | Set `0` to skip restoring man pages and docs, which saves build time and space. |

The PPA and apt.llvm.org are used only if they are reachable and support this
Ubuntu release. Otherwise the build falls back to the newest GCC and LLVM in
the Ubuntu archive. The build log shows which version was picked
(`[toolchains] g++: …`).

The latest versions of Neovim, CMake, lua-language-server, StyLua,
tree-sitter, nvm and uv are looked up with `git ls-remote --tags`. Release
files are downloaded from GitHub. This avoids the GitHub API, which limits
unauthenticated requests.

To update everything, rebuild with `./devbox.sh build --no-cache`, then restart
with `systemctl --user restart devbox`, or with `./devbox.sh rm && ./devbox.sh run`.
Your `~/workspace` volume and SSH host keys are kept.

## Neovim / ConfigChad notes

- `~/.config/nvim` is a git clone of ConfigChad, so you can `git pull` it
  inside the container.
- The plugins (NvChad, lazy.nvim, aerial, navic, auto-session, …) and
  treesitter parsers are already installed. The parsers cover C, C++, CMake,
  Python, Lua, Rust, Bash, JSON, YAML, TOML and Markdown. Add more with
  `:TSInstall <lang>`.
- ConfigChad enables `clangd`, `rust-analyzer` and NvChad's default `lua_ls`,
  and all three are installed system-wide. For C++ projects, create
  `compile_commands.json` with `cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON` or
  `bear -- make`.
- The Python LSPs `pyright` and `pylsp` are installed, but ConfigChad doesn't
  enable a Python server yet. To enable one, add `"pyright"` (or `"pylsp"`) to
  the `servers` list in `lua/configs/lspconfig.lua`.
- NvChad uses Nerd Font icons. Install a [Nerd Font](https://www.nerdfonts.com/)
  in the terminal you SSH from. The font lives on the client side, not in the
  container.

## Repository layout

```
Containerfile                   image definition
devbox.sh                       host helper: build / run / install-service / ssh …
quadlet/devbox.container        systemd (Quadlet) unit template
image/install-packages.sh       apt update/upgrade + dev, net, debug, perf tools
image/install-toolchains.sh     newest GCC + LLVM/clang/clangd, set as default
image/install-github-tools.sh   latest neovim, cmake, lua-language-server, stylua, tree-sitter
image/setup-user.sh             nvm/node, uv/python + LSPs, rust-analyzer, ConfigChad + plugins
image/entrypoint.sh             host keys, authorized keys, optional password, exec sshd -D
image/sshd_config               sshd drop-in configuration
```
