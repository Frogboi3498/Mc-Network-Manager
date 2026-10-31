#!/usr/bin/env bash
# MC Network Manager - node provisioning script.
#
# Sent to a node over SSH by the app and run as root (directly or via sudo).
# Everything it does is driven by environment variables set by the app. It is
# safe to re-run: existing worlds and server.properties are updated in place,
# never replaced.
#
# Targets Debian/Ubuntu (apt) on x86_64 or aarch64 with systemd.

set -euo pipefail

BASE=/opt/mcnm
SVC_USER=mcnm
UA="MCNetworkManager/1.0 (https://github.com/your-name/MCNetworkManager)"

log()  { printf '[mcnm] %s\n' "$*"; }
warn() { printf '[mcnm] WARN: %s\n' "$*" >&2; }
die()  { printf '[mcnm] ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'MCNM_INFO %s=%s\n' "$1" "$2"; }

# ---------------------------------------------------------------- validation

valid_name() { [[ "$1" =~ ^[a-z0-9_-]{1,24}$ ]]; }
valid_int()  { [[ "$1" =~ ^[0-9]{1,6}$ ]]; }
valid_slug() { [[ "$1" =~ ^[A-Za-z0-9_-]{2,64}$ ]]; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9._:-]{1,255}$ ]]; }
valid_mcver() { [[ "$1" == latest || "$1" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; }

# --------------------------------------------------------------- web helpers

fetch() { curl -fsSL --retry 3 --retry-delay 2 -H "User-Agent: $UA" "$@"; }

# Download a file and verify a checksum: download_verified URL DEST ALGO HASH
download_verified() {
  local url="$1" dest="$2" algo="$3" want="$4" got tmp
  tmp="$(mktemp)"
  fetch -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
  if [ -n "$want" ] && [ "$want" != "null" ]; then
    got="$("${algo}sum" "$tmp" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
      rm -f "$tmp"
      warn "checksum mismatch for $url (expected $want, got $got)"
      return 1
    fi
  fi
  mv "$tmp" "$dest"
}

# Prints "URL<TAB>SHA512" for the newest release of a Modrinth project that
# supports the Fabric loader and the given Minecraft version. Prints nothing
# if there is no compatible version.
modrinth_pick() {
  local slug="$1" mcver="$2"
  fetch -G "https://api.modrinth.com/v2/project/${slug}/version" \
    --data-urlencode 'loaders=["fabric"]' \
    --data-urlencode "game_versions=[\"${mcver}\"]" 2>/dev/null |
    jq -r 'if length == 0 then empty else
             (first(.[] | select(.version_type == "release")) // .[0])
             | .files
             | ((map(select(.primary)) | first) // .[0])
             | [.url, (.hashes.sha512 // "")] | @tsv
           end'
}

# modrinth_install SLUG MCVER DESTDIR -> 0 on success
modrinth_install() {
  local slug="$1" mcver="$2" dest="$3" url sha picked file
  picked="$(modrinth_pick "$slug" "$mcver" || true)"
  if [ -z "$picked" ]; then
    warn "no Fabric build of '$slug' for Minecraft $mcver on Modrinth"
    return 1
  fi
  url="${picked%%$'\t'*}"
  sha="${picked#*$'\t'}"
  file="$dest/$(basename "${url%%\?*}")"
  # Remove the previously installed jar of the same project so updates replace instead of stack.
  if [ -f "$dest/.${slug}.name" ]; then rm -f "$dest/$(cat "$dest/.${slug}.name")"; fi
  download_verified "$url" "$file" sha512 "$sha" || return 1
  basename "$file" > "$dest/.${slug}.name"
  log "installed $slug -> $(basename "$file")"
}

# ------------------------------------------------------------- environment

parse_env() {
  [ "${ACCEPT_EULA:-0}" = 1 ] || die "The Minecraft EULA (https://aka.ms/MinecraftEULA) was not accepted."

  MC_VERSION="${MC_VERSION:-latest}"; valid_mcver "$MC_VERSION" || die "bad MC_VERSION"
  ROLE_PROXY="${ROLE_PROXY:-0}"
  PUBLIC_PORT="${PUBLIC_PORT:-25565}"; valid_int "$PUBLIC_PORT" || die "bad PUBLIC_PORT"
  SERVERS="${SERVERS:-}"
  BACKENDS="${BACKENDS:-}"
  NETWORK_NAME="${NETWORK_NAME:-Minecraft Network}"
  FORWARD_SECRET="${FORWARD_SECRET:-}"
  WHITELIST="${WHITELIST:-0}"
  OP_NAME="${OP_NAME:-}"
  OP_ALL="${OP_ALL:-1}"
  NET_MODE="${NET_MODE:-none}"
  PROXY_HOST="${PROXY_HOST:-}"
  SYNC_SRC="${SYNC_SRC:-}"
  SYNC_DST="${SYNC_DST:-}"
  SYNC_HOUR="${SYNC_HOUR:-4}"
  VELOCITY_URL="${VELOCITY_URL:-}"

  case "$NET_MODE" in none|tailscale|upnp) ;; *) die "bad NET_MODE" ;; esac
  valid_int "$SYNC_HOUR" && [ "$SYNC_HOUR" -le 23 ] || die "bad SYNC_HOUR"
  if [ -n "$OP_NAME" ] && ! [[ "$OP_NAME" =~ ^[A-Za-z0-9_]{3,16}$ ]]; then die "bad OP_NAME"; fi
  if [ "$ROLE_PROXY" = 1 ]; then
    [[ "$FORWARD_SECRET" =~ ^[A-Za-z0-9]{16,64}$ ]] || die "FORWARD_SECRET missing or malformed"
  fi
  if [ -n "$SERVERS" ] && ! [[ "$FORWARD_SECRET" =~ ^[A-Za-z0-9]{16,64}$ ]]; then
    die "FORWARD_SECRET missing or malformed"
  fi

  SERVER_LIST=()
  if [ -n "$SERVERS" ]; then
    local entry name port gm mem mods m
    IFS=';' read -ra SERVER_LIST <<<"$SERVERS"
    for entry in "${SERVER_LIST[@]}"; do
      IFS='|' read -r name port gm mem mods <<<"$entry"
      valid_name "$name" || die "bad server name '$name'"
      valid_int "$port" || die "bad port for $name"
      valid_int "$mem" && [ "$mem" -ge 512 ] || die "bad memory for $name"
      case "$gm" in survival|creative|adventure|spectator) ;; *) die "bad gamemode for $name" ;; esac
      if [ -n "$mods" ]; then
        IFS=',' read -ra _m <<<"$mods"
        for m in "${_m[@]}"; do valid_slug "$m" || die "bad mod slug '$m'"; done
      fi
    done
  fi
  if [ -n "$BACKENDS" ]; then
    local b h p n
    IFS=';' read -ra _b <<<"$BACKENDS"
    for b in "${_b[@]}"; do
      IFS='|' read -r n h p <<<"$b"
      valid_name "$n" && valid_host "$h" && valid_int "$p" || die "bad backend entry '$b'"
    done
  fi
}

# ------------------------------------------------------------------ system

need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

install_packages() {
  command -v apt-get >/dev/null 2>&1 || die "this script needs a Debian/Ubuntu system (apt-get not found)"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
  log "installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl jq rsync ca-certificates tar gzip >/dev/null
}

ensure_user() {
  if ! id "$SVC_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$BASE" --shell /usr/sbin/nologin "$SVC_USER"
  fi
  mkdir -p "$BASE/servers" "$BASE/proxy" "$BASE/java"
  chown -R "$SVC_USER:$SVC_USER" "$BASE"
}

# Prints the latest Minecraft release id.
latest_release() {
  fetch https://piston-meta.mojang.com/mc/game/version_manifest_v2.json | jq -r '.latest.release'
}

# Prints the Java major version Mojang requires for a Minecraft version.
required_java() {
  local ver="$1" url
  url="$(fetch https://piston-meta.mojang.com/mc/game/version_manifest_v2.json |
         jq -r --arg v "$ver" '.versions[] | select(.id == $v) | .url')"
  [ -n "$url" ] || return 1
  fetch "$url" | jq -r '.javaVersion.majorVersion // empty'
}

ensure_java() {
  local major="$1" arch dir
  dir="$BASE/java/$major"
  if [ -x "$dir/bin/java" ]; then JAVA_BIN="$dir/bin/java"; return; fi
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "unsupported CPU architecture $(uname -m)" ;;
  esac
  log "downloading Java $major (Eclipse Temurin JRE)"
  mkdir -p "$dir"
  fetch "https://api.adoptium.net/v3/binary/latest/${major}/ga/linux/${arch}/jre/hotspot/normal/eclipse" |
    tar -xz -C "$dir" --strip-components=1 || die "could not download Java $major"
  [ -x "$dir/bin/java" ] || die "Java $major install failed"
  JAVA_BIN="$dir/bin/java"
}

resolve_minecraft() {
  if [ "$MC_VERSION" = latest ]; then
    MC_VERSION="$(latest_release)"
    [ -n "$MC_VERSION" ] && [ "$MC_VERSION" != null ] || die "could not look up the latest Minecraft version"
  fi
  log "Minecraft version: $MC_VERSION"
  JAVA_MAJOR="$(required_java "$MC_VERSION" || true)"
  if [ -z "$JAVA_MAJOR" ]; then
    warn "could not determine required Java version; assuming 21"
    JAVA_MAJOR=21
  fi
  ensure_java "$JAVA_MAJOR"
  info java "$JAVA_MAJOR"
  info minecraft "$MC_VERSION"
}

# ------------------------------------------------------------ properties

# set_prop FILE KEY VALUE  (idempotent; handles "key=" lines and missing keys)
set_prop() {
  local file="$1" key="$2" val="$3" esc
  touch "$file"
  esc="$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${esc}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# --------------------------------------------------------- fabric servers

fabric_launcher_url() {
  local loader installer
  loader="$(fetch https://meta.fabricmc.net/v2/versions/loader | jq -r 'first(.[] | select(.stable)) | .version')"
  installer="$(fetch https://meta.fabricmc.net/v2/versions/installer | jq -r 'first(.[] | select(.stable)) | .version')"
  [ -n "$loader" ] && [ -n "$installer" ] || return 1
  printf 'https://meta.fabricmc.net/v2/versions/loader/%s/%s/%s/server/jar\n' "$MC_VERSION" "$loader" "$installer"
}

write_fabric_proxy_config() {
  local dir="$1"
  mkdir -p "$dir/config"
  cat > "$dir/config/FabricProxy-Lite.toml" <<EOF
hackOnlineMode = true
hackEarlySend = true
hackMessageChain = true
disconnectMessage = "Please join through the network address."
secret = "$FORWARD_SECRET"
EOF
}

setup_server() {
  local name="$1" port="$2" gm="$3" mem="$4" mods="$5"
  local dir="$BASE/servers/$name" launcher m
  log "setting up server '$name' ($gm, port $port, ${mem}MB)"
  mkdir -p "$dir/mods" "$dir/config"

  launcher="$(fabric_launcher_url)" || die "could not look up Fabric versions"
  if ! download_verified "$launcher" "$dir/fabric-server-launch.jar" sha256 ""; then
    die "Fabric does not offer a server launcher for Minecraft $MC_VERSION yet. Pick an older Minecraft version in the app."
  fi

  printf 'eula=true\n' > "$dir/eula.txt"

  local props="$dir/server.properties"
  set_prop "$props" server-port "$port"
  set_prop "$props" motd "$NETWORK_NAME - $name"
  set_prop "$props" gamemode "$gm"
  set_prop "$props" force-gamemode true
  set_prop "$props" white-list "$([ "$WHITELIST" = 1 ] && echo true || echo false)"
  set_prop "$props" enforce-whitelist "$([ "$WHITELIST" = 1 ] && echo true || echo false)"
  # Backends on the same machine as the proxy only listen on loopback.
  if [ "$ROLE_PROXY" = 1 ] && [ "${BACKEND_LOOPBACK:-1}" = 1 ]; then
    set_prop "$props" server-ip 127.0.0.1
  fi

  # Required components: the Fabric API and the Velocity forwarding mod.
  modrinth_install fabric-api "$MC_VERSION" "$dir/mods" || die "Fabric API is not available for Minecraft $MC_VERSION"
  modrinth_install fabricproxy-lite "$MC_VERSION" "$dir/mods" || die "FabricProxy-Lite is not available for Minecraft $MC_VERSION"
  write_fabric_proxy_config "$dir"

  # Optional mods the user explicitly accepted in the app.
  if [ -n "$mods" ]; then
    IFS=',' read -ra _mods <<<"$mods"
    for m in "${_mods[@]}"; do
      modrinth_install "$m" "$MC_VERSION" "$dir/mods" || warn "skipped optional mod '$m'"
    done
  fi

  printf 'MEM=%s\nJAVA=%s\n' "$mem" "$JAVA_BIN" > "$dir/service.env"
  chown -R "$SVC_USER:$SVC_USER" "$dir"
}

# ------------------------------------------------------------------ proxy

install_velocity() {
  local dir="$BASE/proxy" url sha ver builds
  if [ -n "$VELOCITY_URL" ]; then
    url="$VELOCITY_URL"; sha=""
  else
    ver="$(fetch https://fill.papermc.io/v3/projects/velocity | jq -r '.versions | to_entries[0] | .value[0]')"
    [ -n "$ver" ] && [ "$ver" != null ] || die "could not look up the latest Velocity version"
    builds="$(fetch "https://fill.papermc.io/v3/projects/velocity/versions/${ver}/builds")"
    url="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads."server:default".url) // first(.[] | .downloads."server:default".url) // empty' <<<"$builds")"
    sha="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads."server:default".checksums.sha256) // first(.[] | .downloads."server:default".checksums.sha256) // empty' <<<"$builds")"
    [ -n "$url" ] || die "could not find a Velocity download. Set VELOCITY_URL in the app's advanced settings."
    log "Velocity $ver"
  fi
  download_verified "$url" "$dir/velocity.jar" sha256 "$sha" || die "Velocity download failed"
}

write_velocity_config() {
  local dir="$BASE/proxy" servers_block="" try_name="" b n h p
  IFS=';' read -ra _b <<<"$BACKENDS"
  for b in "${_b[@]}"; do
    IFS='|' read -r n h p <<<"$b"
    servers_block+="$n = \"$h:$p\""$'\n'
    [ -n "$try_name" ] || try_name="$n"
  done
  [ -n "$try_name" ] || die "the proxy needs at least one backend server"

  printf '%s' "$FORWARD_SECRET" > "$dir/forwarding.secret"
  cat > "$dir/velocity.toml" <<EOF
config-version = "2.7"
bind = "0.0.0.0:${PUBLIC_PORT}"
motd = "${NETWORK_NAME}"
show-max-players = 100
online-mode = true
force-key-authentication = true
prevent-client-proxy-connections = false
player-info-forwarding-mode = "modern"
forwarding-secret-file = "forwarding.secret"
announce-forge = false
kick-existing-players = false
ping-passthrough = "DISABLED"
enable-player-address-logging = true

[servers]
${servers_block}try = ["${try_name}"]

[forced-hosts]

[advanced]
compression-threshold = 256
compression-level = -1
login-ratelimit = 3000
connection-timeout = 5000
read-timeout = 30000
haproxy-protocol = false
tcp-fast-open = false
bungee-plugin-message-channel = true
show-ping-requests = false
failover-on-unexpected-server-disconnect = true
announce-proxy-commands = true
log-command-executions = false
log-player-connections = true

[query]
enabled = false
EOF
  chmod 600 "$dir/forwarding.secret"
  chown -R "$SVC_USER:$SVC_USER" "$dir"
}

# ---------------------------------------------------------------- systemd

write_units() {
  cat > /etc/systemd/system/mcnm@.socket <<'EOF'
[Unit]
Description=MC Network Manager console for %i

[Socket]
ListenFIFO=/run/mcnm-%i.stdin
SocketMode=0660
SocketUser=mcnm
SocketGroup=mcnm
RemoveOnStop=true
FileDescriptorName=stdin
Service=mcnm@%i.service
EOF

  cat > /etc/systemd/system/mcnm@.service <<'EOF'
[Unit]
Description=MC Network Manager server %i
After=network-online.target
Wants=network-online.target

[Service]
User=mcnm
Group=mcnm
WorkingDirectory=/opt/mcnm/servers/%i
EnvironmentFile=/opt/mcnm/servers/%i/service.env
ExecStart=/bin/sh -c 'exec "$JAVA" -Xms${MEM}M -Xmx${MEM}M -jar fabric-server-launch.jar nogui'
Sockets=mcnm@%i.socket
StandardInput=socket
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=10
TimeoutStopSec=120
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/mcnm-proxy.service <<EOF
[Unit]
Description=MC Network Manager Velocity proxy
After=network-online.target
Wants=network-online.target

[Service]
User=mcnm
Group=mcnm
WorkingDirectory=$BASE/proxy
ExecStart=$JAVA_BIN -Xms512M -Xmx512M -XX:+UseG1GC -XX:G1HeapRegionSize=4M -jar velocity.jar
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

console_send() { # console_send SERVER "command"
  local fifo="/run/mcnm-$1.stdin" i
  for i in $(seq 1 30); do
    [ -p "$fifo" ] && break
    sleep 1
  done
  [ -p "$fifo" ] || { warn "console for '$1' is not available"; return 1; }
  printf '%s\n' "$2" > "$fifo"
}

wait_active() { # wait_active UNIT SECONDS
  local i
  for i in $(seq 1 "$2"); do
    systemctl is-active --quiet "$1" && return 0
    sleep 1
  done
  return 1
}

start_server() {
  local name="$1" mods="$2"
  systemctl enable "mcnm@${name}.service" >/dev/null 2>&1
  systemctl restart "mcnm@${name}.service"
  wait_active "mcnm@${name}.service" 20 || warn "server '$name' did not start; check: journalctl -u mcnm@${name}"

  # BlueMap needs a one-time acceptance of Mojang's resource download terms.
  if [[ ",$mods," == *",bluemap,"* ]]; then
    local conf="$BASE/servers/$name/config/bluemap/core.conf" i
    for i in $(seq 1 180); do [ -f "$conf" ] && break; sleep 1; done
    if [ -f "$conf" ] && grep -q 'accept-download: *false' "$conf"; then
      sed -i 's/accept-download: *false/accept-download: true/' "$conf"
      systemctl restart "mcnm@${name}.service"
      log "BlueMap resource download accepted (web map on port 8100 of this node)"
    fi
  fi
}

# --------------------------------------------------------------- networking

lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

setup_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  log "ufw is active; adding rules"
  [ "$ROLE_PROXY" = 1 ] && ufw allow "${PUBLIC_PORT}/tcp" >/dev/null
  if [ "$ROLE_PROXY" != 1 ] && [ -n "$PROXY_HOST" ] && [ -n "$SERVERS" ]; then
    local entry name port
    for entry in "${SERVER_LIST[@]}"; do
      IFS='|' read -r name port _ <<<"$entry"
      ufw allow from "$PROXY_HOST" to any port "$port" proto tcp >/dev/null
    done
  fi
  ip link show tailscale0 >/dev/null 2>&1 && ufw allow in on tailscale0 >/dev/null || true
}

setup_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    log "installing Tailscale"
    fetch https://tailscale.com/install.sh | sh >/dev/null || die "Tailscale install failed"
  fi
  systemctl enable --now tailscaled >/dev/null 2>&1 || true
  if tailscale ip -4 >/dev/null 2>&1; then
    log "Tailscale is already connected"
  else
    local args=(up)
    [ -n "${TS_HOSTNAME:-}" ] && args+=(--hostname "$TS_HOSTNAME")
    if [ -n "${TS_AUTHKEY:-}" ]; then
      args+=(--authkey "$TS_AUTHKEY")
      tailscale "${args[@]}" || die "tailscale up failed"
    else
      log "Open the link below to sign this machine in to Tailscale (waiting up to 5 minutes):"
      timeout 300 tailscale "${args[@]}" 2>&1 || die "Tailscale sign-in did not complete"
    fi
  fi
  local ip
  ip="$(tailscale ip -4 | head -n1)"
  info tailscale_ip "$ip"
  info join_address "${ip}:${PUBLIC_PORT}"
}

setup_upnp() {
  log "installing UPnP client"
  apt-get install -y miniupnpc >/dev/null
  local ip
  ip="$(lan_ip)"
  [ -n "$ip" ] || die "could not determine this machine's LAN address"

  cat > /usr/local/bin/mcnm-upnp <<EOF
#!/bin/sh
exec upnpc -a "$ip" "$PUBLIC_PORT" "$PUBLIC_PORT" TCP 86400
EOF
  chmod 755 /usr/local/bin/mcnm-upnp
  cat > /etc/systemd/system/mcnm-upnp.service <<'EOF'
[Unit]
Description=MC Network Manager UPnP port mapping
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mcnm-upnp
EOF
  cat > /etc/systemd/system/mcnm-upnp.timer <<'EOF'
[Unit]
Description=Renew MC Network Manager UPnP port mapping

[Timer]
OnBootSec=1min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now mcnm-upnp.timer >/dev/null 2>&1

  if /usr/local/bin/mcnm-upnp >/tmp/mcnm-upnp.out 2>&1 && ! grep -qi 'failed\|error' /tmp/mcnm-upnp.out; then
    local ext
    ext="$(upnpc -s 2>/dev/null | awk -F= '/ExternalIPAddress/ {print $2}' | tr -d ' ')"
    log "router accepted the port mapping"
    [ -n "$ext" ] && info join_address "${ext}:${PUBLIC_PORT}"
  else
    warn "the router did not accept an automatic port mapping. UPnP may be switched off, or your ISP may use CGNAT. Use Tailscale instead, or forward port ${PUBLIC_PORT} manually."
    cat /tmp/mcnm-upnp.out >&2 || true
  fi
}

# -------------------------------------------------------------- world sync

setup_world_sync() {
  [ -n "$SYNC_SRC" ] && [ -n "$SYNC_DST" ] || return 0
  valid_name "$SYNC_SRC" && valid_name "$SYNC_DST" || die "bad sync server names"
  [ -d "$BASE/servers/$SYNC_SRC" ] && [ -d "$BASE/servers/$SYNC_DST" ] ||
    { warn "world sync skipped: both servers must be on this machine"; return 0; }

  log "scheduling one-way world copy $SYNC_SRC -> $SYNC_DST daily at ${SYNC_HOUR}:00"
  cat > /usr/local/bin/mcnm-world-sync <<EOF
#!/bin/sh
# One-way copy of the world from '$SYNC_SRC' into '$SYNC_DST'. Never the reverse.
set -e
SRC="$BASE/servers/$SYNC_SRC/world/"
DST="$BASE/servers/$SYNC_DST/world/"
[ -d "\$SRC" ] || exit 0
echo save-all > /run/mcnm-$SYNC_SRC.stdin 2>/dev/null || true
sleep 15
systemctl stop mcnm@$SYNC_DST.service
rsync -a --delete --exclude session.lock --exclude 'playerdata/' --exclude 'advancements/' --exclude 'stats/' "\$SRC" "\$DST"
chown -R $SVC_USER:$SVC_USER "\$DST"
systemctl start mcnm@$SYNC_DST.service
EOF
  chmod 755 /usr/local/bin/mcnm-world-sync
  cat > /etc/systemd/system/mcnm-world-sync.service <<'EOF'
[Unit]
Description=MC Network Manager one-way world copy

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mcnm-world-sync
EOF
  cat > /etc/systemd/system/mcnm-world-sync.timer <<EOF
[Unit]
Description=Run the MC Network Manager world copy daily

[Timer]
OnCalendar=*-*-* ${SYNC_HOUR}:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now mcnm-world-sync.timer >/dev/null 2>&1
}

# -------------------------------------------------------------------- main

main() {
  need_root
  parse_env
  install_packages
  ensure_user

  if [ "$NET_MODE" = tailscale ]; then setup_tailscale; fi

  resolve_minecraft

  # Does this node also host the proxy? If so backends bind to loopback.
  BACKEND_LOOPBACK=1
  [ -n "$PROXY_HOST" ] && BACKEND_LOOPBACK=0

  if [ "$ROLE_PROXY" = 1 ]; then
    install_velocity
    write_velocity_config
  fi

  if [ ${#SERVER_LIST[@]} -gt 0 ]; then
    local entry name port gm mem mods
    for entry in "${SERVER_LIST[@]}"; do
      IFS='|' read -r name port gm mem mods <<<"$entry"
      setup_server "$name" "$port" "$gm" "$mem" "$mods"
    done
  fi

  write_units
  setup_firewall

  if [ ${#SERVER_LIST[@]} -gt 0 ]; then
    for entry in "${SERVER_LIST[@]}"; do
      IFS='|' read -r name port gm mem mods <<<"$entry"
      start_server "$name" "$mods"
      if [ "$WHITELIST" = 1 ] && [ -n "$OP_NAME" ]; then
        console_send "$name" "whitelist add $OP_NAME" || true
      fi
      if [ -n "$OP_NAME" ] && { [ "$OP_ALL" = 1 ] || [ "$name" = "${FIRST_SERVER:-$name}" ]; }; then
        console_send "$name" "op $OP_NAME" || true
      fi
      FIRST_SERVER="${FIRST_SERVER:-$name}"
    done
  fi

  if [ "$ROLE_PROXY" = 1 ]; then
    systemctl enable mcnm-proxy.service >/dev/null 2>&1
    systemctl restart mcnm-proxy.service
    wait_active mcnm-proxy.service 20 || warn "the proxy did not start; check: journalctl -u mcnm-proxy"
  fi

  if [ "$NET_MODE" = upnp ] && [ "$ROLE_PROXY" = 1 ]; then setup_upnp; fi
  setup_world_sync

  log "done"
  info status ok
}

# Allow tests to source the functions without running anything.
if [ "${MCNM_SOURCE_ONLY:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
