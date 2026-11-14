# Developer environment image (Podman / Buildah, also builds with Docker)
#
#   podman build -t localhost/devbox:latest .
#
# See README.md for all build arguments and how to run it.

ARG BASE_IMAGE=docker.io/library/ubuntu:26.04
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="devbox" \
      org.opencontainers.image.description="Ubuntu developer environment: gcc/clang/clangd, nvim (ConfigChad), nvm, uv, rust, debug/net/perf tools, sshd"

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG UNMINIMIZE=1

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    DEVBOX_USER=${USERNAME}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 1) apt update + upgrade, developer / networking / debugging / perf tools
COPY image/install-packages.sh /tmp/devbox/
RUN UNMINIMIZE=${UNMINIMIZE} bash /tmp/devbox/install-packages.sh

# 2) latest GCC (g++) and LLVM (clang++, clangd, lldb, ...)
ARG GCC_VERSION=latest
ARG LLVM_VERSION=latest
ARG USE_TOOLCHAIN_PPA=1
ARG USE_LLVM_APT_REPO=1
ARG GCC_ALLOW_SNAPSHOT=0
COPY image/install-toolchains.sh /tmp/devbox/
RUN GCC_VERSION=${GCC_VERSION} LLVM_VERSION=${LLVM_VERSION} \
    USE_TOOLCHAIN_PPA=${USE_TOOLCHAIN_PPA} USE_LLVM_APT_REPO=${USE_LLVM_APT_REPO} \
    GCC_ALLOW_SNAPSHOT=${GCC_ALLOW_SNAPSHOT} \
    bash /tmp/devbox/install-toolchains.sh

# 3) latest neovim, cmake, lua-language-server, stylua, tree-sitter CLI
ARG NVIM_VERSION=latest
ARG CMAKE_VERSION=latest
COPY image/install-github-tools.sh /tmp/devbox/
RUN NVIM_VERSION=${NVIM_VERSION} CMAKE_VERSION=${CMAKE_VERSION} \
    bash /tmp/devbox/install-github-tools.sh

# 4) developer user with passwordless sudo
#    (Ubuntu >= 23.04 images ship an "ubuntu" user that owns UID 1000)
RUN if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu || true; fi \
 && if ! getent group "${USER_GID}" >/dev/null; then groupadd -g "${USER_GID}" "${USERNAME}"; fi \
 && useradd -m -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" -G sudo "${USERNAME}" \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" \
 && chmod 0440 "/etc/sudoers.d/${USERNAME}" \
 && usermod -p '*' "${USERNAME}"   # no password: SSH keys only (see DEV_PASSWORD)

# 5) per-user tooling: nvm + node, uv + python + LSPs, rust-analyzer,
#    ConfigChad neovim config with plugins and treesitter parsers
ARG NODE_VERSION=lts/*
ARG PYTHON_VERSION=
ARG INSTALL_RUST=1
ARG NVIM_CONFIG_REPO=https://github.com/bradley101/ConfigChad
ARG NVIM_CONFIG_REF=main
ARG NVIM_STRICT=1
COPY --chmod=0755 image/setup-user.sh /tmp/devbox/
USER ${USERNAME}
WORKDIR /home/${USERNAME}
RUN NODE_VERSION="${NODE_VERSION}" PYTHON_VERSION="${PYTHON_VERSION}" \
    INSTALL_RUST="${INSTALL_RUST}" \
    NVIM_CONFIG_REPO="${NVIM_CONFIG_REPO}" NVIM_CONFIG_REF="${NVIM_CONFIG_REF}" \
    NVIM_STRICT="${NVIM_STRICT}" \
    bash /tmp/devbox/setup-user.sh

# 6) SSH server + entrypoint
USER root
COPY image/sshd_config /etc/ssh/sshd_config.d/10-devbox.conf
COPY --chmod=0755 image/entrypoint.sh /usr/local/bin/devbox-entrypoint
RUN install -d -m 0755 /etc/devbox /etc/ssh/hostkeys /run/sshd \
 && rm -f /etc/ssh/ssh_host_* \
 && rm -rf /tmp/devbox \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

EXPOSE 22
VOLUME ["/etc/ssh/hostkeys", "/home/${USERNAME}/workspace"]
WORKDIR /home/${USERNAME}/workspace

HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
  CMD bash -c '</dev/tcp/127.0.0.1/22' || exit 1

# tini reaps zombies (gdb, language servers, ...); sshd -D keeps the
# container running.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/devbox-entrypoint"]
CMD []
