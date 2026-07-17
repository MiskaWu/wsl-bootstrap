#!/usr/bin/env bash
# =============================================================================
# Phase 2 (root): container runtime + baseline 套件
# BS_RUNTIME=podman|docker  BS_COMPOSE_SHIM=true|false  BS_USER=<name>
# =============================================================================
set -euo pipefail

: "${BS_USER:?BS_USER not set}"
: "${BS_RUNTIME:?BS_RUNTIME not set}"
BS_COMPOSE_SHIM="${BS_COMPOSE_SHIM:-true}"

log() { printf '\033[1;35m[phase2]\033[0m %s\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive

log "baseline 套件 (git, tmux, ripgrep, jq, curl ...)"
apt-get update -y
apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  git tmux ripgrep jq unzip build-essential

case "${BS_RUNTIME}" in
  podman)
    log "安裝 Podman (rootless)"
    # iptables 不是 podman 的相依套件，但沒有它 netavark 無法走 iptables driver，
    # 而在 WSL2 上非走不可——理由見下面的 containers.conf。
    apt-get install -y podman buildah skopeo uidmap slirp4netns fuse-overlayfs iptables

    # netavark 預設用自己的 nftables driver，在 WSL2 kernel 上會失敗：
    #   netavark: nftables error: "nft" did not return successfully while applying ruleset
    #   internal:0:0-0: Error: Could not process rule: No such file or directory
    # 症狀很誤導：`podman run` 完全正常（rootless 預設網路走 pasta，不碰防火牆規則），
    # 只有「自建 bridge network」才炸——也就是 docker-compose 每次都會炸，因為它一定
    # 會建 <project>_default 網路。容器會卡在 Created 永遠起不來。
    # 換成 iptables driver 就正常（它經 xtables 相容層產生的 ruleset，WSL2 kernel 吃得下）。
    log "寫入 /etc/containers/containers.conf（netavark 改用 iptables driver）"
    install -d -m 0755 /etc/containers
    cat > /etc/containers/containers.conf <<'EOF'
[network]
firewall_driver = "iptables"
EOF

    # Ubuntu 完全不出貨 /etc/containers/registries.conf，而內建的 shortnames
    # 別名表沒有 postgres / redis / nats。不寫這個檔，`podman pull postgres`
    # 會直接失敗（fail fast，不會卡在 TTY 提示，所以不破壞無人值守——但依賴
    # 服務一個都拉不下來）。只給一個 registry 就不存在歧義，不可能觸發提示。
    log "寫入 /etc/containers/registries.conf"
    install -d -m 0755 /etc/containers
    cat > /etc/containers/registries.conf <<'EOF'
unqualified-search-registries = ["docker.io"]
short-name-mode = "disabled"
EOF

    # 讓該 user 開機不用登入也能跑 rootless service（systemd user lingering）
    loginctl enable-linger "${BS_USER}" || true

    if [ "${BS_COMPOSE_SHIM}" = "true" ]; then
      log "安裝 docker-compose 二進位當 compose shim"
      ARCH="$(uname -m)"
      curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${ARCH}" \
        -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
    fi
    ;;

  docker)
    log "安裝 Docker Engine"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    usermod -aG docker "${BS_USER}"
    systemctl enable --now docker
    ;;

  *)
    echo "未知 runtime: ${BS_RUNTIME}" >&2
    exit 1
    ;;
esac

log "phase2 完成"
