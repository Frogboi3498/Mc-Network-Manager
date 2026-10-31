import Foundation

/// Builds the bash script that is run on each Linux host (Debian/Ubuntu with apt + systemd).
/// A generated header sets variables; the static body below does the work.
enum ProvisionScript {

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Minecraft names are 3-16 chars of letters, digits, underscore.
    static func operatorNames(_ raw: String) -> [String] {
        raw.split(whereSeparator: { ", \n\t".contains($0) })
            .map(String.init)
            .filter { $0.range(of: "^[A-Za-z0-9_]{3,16}$", options: .regularExpression) != nil }
    }

    static func make(for host: Host, profile: Profile, secret: String, tailscaleAuthKey: String) -> String {
        let q = shellQuote
        let isProxyHost = profile.proxyHostID == host.id
        let home = host.username == "root" ? "/root" : "/home/\(host.username)"
        let proxyHost = profile.hosts.first { $0.id == profile.proxyHostID } ?? host

        var h: [String] = ["#!/usr/bin/env bash"]
        h.append("MC_USER=\(q(host.username))")
        h.append("BASE=\(q(home + "/mc-network"))")
        h.append("EULA=true")
        h.append("PROXY=\(isProxyHost ? 1 : 0)")
        h.append("PROXY_PORT=\(profile.proxyPort)")
        h.append("FORWARD_SECRET=\(q(secret))")
        h.append("LOBBY_WORLD_URL=\(q(profile.lobbyWorldURL))")
        h.append("NET_TAILSCALE=\(profile.installTailscale ? 1 : 0)")
        h.append("TS_AUTHKEY=\(q(tailscaleAuthKey))")
        h.append("NET_UPNP=\(profile.autoPortForward && isProxyHost ? 1 : 0)")

        let mine = profile.servers.filter { $0.hostID == host.id }
        let bothHere = ServerRole.allCases.filter { r in
            r == .survival || r == .creative
        }.allSatisfy { r in mine.contains { $0.role == r } }
        h.append("SYNC_SURVIVAL_CREATIVE=\(profile.syncSurvivalToCreative && bothHere ? 1 : 0)")

        h.append("SERVERS=(")
        for s in mine { h.append("  \(q("\(s.name)|\(s.port)|\(s.memoryGB)|\(s.role.rawValue)"))") }
        h.append(")")

        h.append("BACKENDS=(")
        for s in profile.servers {
            let target = profile.hosts.first { $0.id == s.hostID } ?? proxyHost
            let address = target.id == proxyHost.id ? "127.0.0.1" : target.effectiveBackend
            h.append("  \(q("\(s.name)|\(address):\(s.port)"))")
        }
        h.append(")")

        h.append("MODS=(")
        for m in profile.mods where m.enabled || m.required {
            let roles = m.roles.map(\.rawValue).sorted().joined(separator: ",")
            if m.isCustom {
                guard m.customURL.lowercased().hasPrefix("http") else { continue }
                h.append("  \(q("url:\(m.customURL)|\(roles)"))")
            } else {
                h.append("  \(q("\(m.id)|\(roles)"))")
            }
        }
        h.append(")")

        let ops = operatorNames(profile.operators).joined(separator: " ")
        h.append("OPERATORS=\(q(ops))")
        h.append("OP_ROLES=\(q(profile.opRoles.map(\.rawValue).sorted().joined(separator: ",")))")

        return h.joined(separator: "\n") + "\n" + body
    }

    /// Command that runs `script` on the remote host (through sudo unless the user is root).
    static func remoteCommand(script: String, user: String, password: String) -> String {
        let scriptB64 = Data(script.utf8).base64EncodedString()
        let runner: String
        if user == "root" {
            runner = "bash /tmp/mcnm-provision.sh"
        } else {
            let pwB64 = Data(password.utf8).base64EncodedString()
            runner = "echo \(pwB64) | base64 -d | sudo -S -p '' bash /tmp/mcnm-provision.sh"
        }
        return "echo \(scriptB64) | base64 -d > /tmp/mcnm-provision.sh; \(runner); rc=$?; rm -f /tmp/mcnm-provision.sh; exit $rc"
    }

    // MARK: Static body

    static let body = #"""
set -Eeuo pipefail
trap 'echo "!! Failed near line $LINENO (exit $?)"' ERR
log() { printf '\n==> %s\n' "$*"; }
UA="MCNetworkManager/1.0 (+https://github.com)"

[ "$(id -u)" -eq 0 ] || { echo "!! Must run as root."; exit 1; }
command -v apt-get >/dev/null || { echo "!! Only Debian/Ubuntu hosts (apt) are supported."; exit 1; }
id "$MC_USER" >/dev/null 2>&1 || { echo "!! User '$MC_USER' does not exist on this host."; exit 1; }

export DEBIAN_FRONTEND=noninteractive
log "Installing base packages"
apt-get update -y
apt-get install -y curl jq rsync ca-certificates unzip

install -d -o "$MC_USER" -g "$MC_USER" "$BASE" "$BASE/servers"

# ---------- Versions ----------
log "Resolving latest Minecraft + Fabric versions"
MC_VERSION=$(curl -fsSL -A "$UA" https://meta.fabricmc.net/v2/versions/game | jq -r '[.[]|select(.stable)][0].version')
LOADER=$(curl -fsSL -A "$UA" https://meta.fabricmc.net/v2/versions/loader | jq -r '[.[]|select(.stable)][0].version')
INSTALLER=$(curl -fsSL -A "$UA" https://meta.fabricmc.net/v2/versions/installer | jq -r '[.[]|select(.stable)][0].version')
echo "Minecraft $MC_VERSION, Fabric loader $LOADER"
FABRIC_URL="https://meta.fabricmc.net/v2/versions/loader/${MC_VERSION}/${LOADER}/${INSTALLER}/server/jar"

MANIFEST_URL=$(curl -fsSL -A "$UA" https://piston-meta.mojang.com/mc/game/version_manifest_v2.json \
  | jq -r --arg v "$MC_VERSION" '.versions[]|select(.id==$v)|.url')
JAVA_MAJOR=$(curl -fsSL -A "$UA" "$MANIFEST_URL" | jq -r '.javaVersion.majorVersion')
log "Installing Java $JAVA_MAJOR"
apt-get install -y "openjdk-${JAVA_MAJOR}-jre-headless" || {
  echo "!! Could not install openjdk-${JAVA_MAJOR}-jre-headless from apt."
  echo "!! Install Java ${JAVA_MAJOR} manually (for example from Adoptium) and run again."
  exit 1
}
JAVA_BIN=$(update-alternatives --list java | grep "java-${JAVA_MAJOR}-" | head -n1)
echo "Using $JAVA_BIN"

# ---------- Helpers ----------
setprop() { # file key value
  local f="$1" k="$2" v="$3"
  touch "$f"
  if grep -q "^${k}=" "$f"; then sed -i "s|^${k}=.*|${k}=${v}|" "$f"; else echo "${k}=${v}" >> "$f"; fi
}

roles_include() { # "a,b,c" role
  case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}

modrinth_install() { # slug dir
  local slug="$1" dir="$2" url
  url=$(curl -fsSL -A "$UA" -G "https://api.modrinth.com/v2/project/${slug}/version" \
        --data-urlencode 'loaders=["fabric"]' \
        --data-urlencode "game_versions=[\"${MC_VERSION}\"]" \
      | jq -r 'first(.[]|select(.version_type=="release")) // .[0] // empty | .files | (map(select(.primary))[0] // .[0]) | .url') || url=""
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "!! No Fabric build of '${slug}' for Minecraft ${MC_VERSION} yet. Skipped (re-run later)."
    return 0
  fi
  local file="$dir/mods/$(basename "${url%%\?*}")"
  curl -fsSL -A "$UA" -o "$file" "$url"
  chown "$MC_USER:$MC_USER" "$file"
  echo "   + ${slug}"
}

url_install() { # url dir
  local url="$1" dir="$2" file
  file="$dir/mods/$(basename "${url%%\?*}")"
  curl -fsSL -A "$UA" -o "$file" "$url"
  chown "$MC_USER:$MC_USER" "$file"
  echo "   + $(basename "$file")"
}

write_ops() { # dir
  local dir="$1" json="[]" n id
  for n in $OPERATORS; do
    id=$(curl -fsSL -A "$UA" "https://api.mojang.com/users/profiles/minecraft/${n}" | jq -r '.id // empty') || id=""
    if [ -z "$id" ]; then echo "!! Could not look up Minecraft user ${n}; skipped."; continue; fi
    id=$(echo "$id" | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
    json=$(jq -c --arg u "$id" --arg n "$n" '. + [{"uuid":$u,"name":$n,"level":4,"bypassesPlayerLimit":false}]' <<<"$json")
  done
  echo "$json" > "$dir/ops.json"
  chown "$MC_USER:$MC_USER" "$dir/ops.json"
}

# ---------- Game servers ----------
for entry in "${SERVERS[@]}"; do
  IFS='|' read -r name port mem role <<<"$entry"
  dir="$BASE/servers/$name"
  log "Setting up server '$name' (port $port, ${mem}G, role $role)"
  install -d -o "$MC_USER" -g "$MC_USER" "$dir" "$dir/mods" "$dir/config"

  curl -fsSL -A "$UA" -o "$dir/fabric-server.jar" "$FABRIC_URL"
  echo "eula=${EULA}" > "$dir/eula.txt"

  props="$dir/server.properties"
  setprop "$props" server-port "$port"
  setprop "$props" online-mode false
  setprop "$props" motd "${name^} server"
  setprop "$props" enable-query false
  case "$role" in
    lobby)    setprop "$props" gamemode adventure; setprop "$props" force-gamemode true; setprop "$props" allow-flight true ;;
    creative) setprop "$props" gamemode creative; setprop "$props" force-gamemode true; setprop "$props" allow-flight true ;;
    survival) setprop "$props" gamemode survival ;;
  esac

  if [ "$role" = lobby ] && [ -n "$LOBBY_WORLD_URL" ] && [ ! -d "$dir/world" ]; then
    log "Downloading lobby world"
    tmp=$(mktemp -d)
    curl -fsSL -A "$UA" -o "$tmp/world.zip" "$LOBBY_WORLD_URL"
    unzip -q "$tmp/world.zip" -d "$tmp/x"
    src=$(find "$tmp/x" -name level.dat -printf '%h\n' | head -n1)
    if [ -n "$src" ]; then mkdir -p "$dir/world"; cp -a "$src/." "$dir/world/"; else echo "!! No level.dat in the lobby world zip."; fi
    rm -rf "$tmp"
  fi

  echo "Mods:"
  has_bluemap=0
  for m in "${MODS[@]}"; do
    IFS='|' read -r ref roles <<<"$m"
    roles_include "$roles" "$role" || continue
    case "$ref" in
      url:*) url_install "${ref#url:}" "$dir" ;;
      *)     modrinth_install "$ref" "$dir" ;;
    esac
    if [ "$ref" = bluemap ]; then has_bluemap=1; fi
  done

  # Velocity modern forwarding (FabricProxy-Lite reads this file)
  cat > "$dir/config/FabricProxy-Lite.toml" <<EOF
hackOnlineMode = false
hackEarlySend = false
hackMessageChain = false
disconnectMessage = "Please join through the network address."
secret = "${FORWARD_SECRET}"
EOF

  if [ "$has_bluemap" = 1 ]; then
    install -d -o "$MC_USER" -g "$MC_USER" "$dir/config/bluemap"
    [ -f "$dir/config/bluemap/core.conf" ] || echo 'accept-download: true' > "$dir/config/bluemap/core.conf"
  fi

  if roles_include "$OP_ROLES" "$role" && [ -n "$OPERATORS" ]; then write_ops "$dir"; fi

  chown -R "$MC_USER:$MC_USER" "$dir"

  cat > "/etc/systemd/system/minecraft-${name}.service" <<EOF
[Unit]
Description=Minecraft (${name})
After=network-online.target
Wants=network-online.target

[Service]
User=${MC_USER}
WorkingDirectory=${dir}
ExecStart=${JAVA_BIN} -Xms${mem}G -Xmx${mem}G -jar fabric-server.jar nogui
Restart=on-failure
RestartSec=10
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF
done

# ---------- Velocity proxy ----------
if [ "$PROXY" = 1 ]; then
  pdir="$BASE/proxy"
  log "Setting up Velocity proxy (port $PROXY_PORT)"
  install -d -o "$MC_USER" -g "$MC_USER" "$pdir"
  VEL_URL="${VELOCITY_URL:-}"
  if [ -z "$VEL_URL" ]; then
    VEL_VERSION=$(curl -fsSL -A "$UA" https://fill.papermc.io/v3/projects/velocity | jq -r '[.versions[][]][0]')
    VEL_URL=$(curl -fsSL -A "$UA" "https://fill.papermc.io/v3/projects/velocity/versions/${VEL_VERSION}/builds/latest" | jq -r '.downloads["server:default"].url')
  fi
  case "$VEL_URL" in http*) ;; *) echo "!! Could not resolve the Velocity download. Set VELOCITY_URL (see README)."; exit 1 ;; esac
  curl -fsSL -A "$UA" -o "$pdir/velocity.jar" "$VEL_URL"
  printf '%s' "$FORWARD_SECRET" > "$pdir/forwarding.secret"
  [ -f "$pdir/velocity.toml" ] && cp "$pdir/velocity.toml" "$pdir/velocity.toml.bak"

  {
    echo 'config-version = "2.7"'
    echo "bind = \"0.0.0.0:${PROXY_PORT}\""
    echo 'motd = "<#09add3>A Minecraft Network"'
    echo 'show-max-players = 100'
    echo 'online-mode = true'
    echo 'force-key-authentication = true'
    echo 'player-info-forwarding-mode = "modern"'
    echo 'forwarding-secret-file = "forwarding.secret"'
    echo 'ping-passthrough = "DISABLED"'
    echo
    echo '[servers]'
    for b in "${BACKENDS[@]}"; do
      IFS='|' read -r bname baddr <<<"$b"
      echo "${bname} = \"${baddr}\""
    done
    echo 'try = ["lobby"]'
    echo
    echo '[forced-hosts]'
  } > "$pdir/velocity.toml"
  chown -R "$MC_USER:$MC_USER" "$pdir"

  cat > /etc/systemd/system/minecraft-proxy.service <<EOF
[Unit]
Description=Velocity proxy
After=network-online.target
Wants=network-online.target

[Service]
User=${MC_USER}
WorkingDirectory=${pdir}
ExecStart=${JAVA_BIN} -Xms512M -Xmx512M -jar velocity.jar
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
fi

# ---------- Survival -> Creative sync (one way) ----------
if [ "$SYNC_SURVIVAL_CREATIVE" = 1 ]; then
  log "Installing nightly Survival -> Creative world sync"
  cat > /usr/local/bin/mc-sync-survival-to-creative <<EOF
#!/usr/bin/env bash
set -euo pipefail
systemctl stop minecraft-creative
rsync -a --delete --exclude session.lock "${BASE}/servers/survival/world/" "${BASE}/servers/creative/world/"
chown -R ${MC_USER}:${MC_USER} "${BASE}/servers/creative/world"
systemctl start minecraft-creative
EOF
  chmod +x /usr/local/bin/mc-sync-survival-to-creative
  cat > /etc/systemd/system/mc-sync.service <<EOF
[Unit]
Description=Copy Survival world into Creative (one way)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mc-sync-survival-to-creative
EOF
  cat > /etc/systemd/system/mc-sync.timer <<EOF
[Unit]
Description=Nightly Survival -> Creative sync

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
fi

# ---------- Networking ----------
if [ "$NET_TAILSCALE" = 1 ]; then
  log "Tailscale"
  command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
  if tailscale status >/dev/null 2>&1; then
    echo "Tailscale already connected."
  elif [ -n "$TS_AUTHKEY" ]; then
    tailscale up --authkey="$TS_AUTHKEY"
  else
    echo "Open the link below to sign this host in to Tailscale (waiting up to 3 minutes):"
    timeout 180 tailscale up 2>&1 || echo "!! Tailscale sign-in was not completed. Run 'sudo tailscale up' on the host later."
  fi
  TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  [ -n "$TS_IP" ] && echo "TAILSCALE_ADDRESS=${TS_IP}"
fi

if [ "$NET_UPNP" = 1 ]; then
  log "Automatic port forwarding (UPnP)"
  apt-get install -y miniupnpc
  LAN_IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if upnpc -e "Minecraft" -a "$LAN_IP" "$PROXY_PORT" "$PROXY_PORT" TCP; then
    echo "Router mapped port ${PROXY_PORT}."
  else
    echo "!! UPnP mapping failed. Enable UPnP on your router or forward port ${PROXY_PORT} manually."
  fi
  EXT=$(upnpc -s 2>/dev/null | awk -F'= ' '/ExternalIPAddress/{print $2}' || true)
  PUB=$(curl -fsS https://api.ipify.org 2>/dev/null || true)
  echo "PUBLIC_ADDRESS=${PUB}"
  if [ -n "$EXT" ] && [ -n "$PUB" ] && [ "$EXT" != "$PUB" ]; then
    echo "!! Your router reports ${EXT} but the internet sees ${PUB}: your provider uses CGNAT, so port forwarding cannot work. Use Tailscale instead."
  fi
  cat > /etc/systemd/system/mc-upnp.service <<EOF
[Unit]
Description=Renew Minecraft UPnP mapping

[Service]
Type=oneshot
ExecStart=/usr/bin/upnpc -e Minecraft -a ${LAN_IP} ${PROXY_PORT} ${PROXY_PORT} TCP
EOF
  cat > /etc/systemd/system/mc-upnp.timer <<EOF
[Unit]
Description=Renew Minecraft UPnP mapping daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  log "Opening firewall (ufw)"
  [ "$PROXY" = 1 ] && ufw allow "${PROXY_PORT}/tcp"
  ip link show tailscale0 >/dev/null 2>&1 && ufw allow in on tailscale0
  for entry in "${SERVERS[@]}"; do
    IFS='|' read -r _n p _m _r <<<"$entry"
    ufw allow from 10.0.0.0/8 to any port "$p" proto tcp || true
    ufw allow from 192.168.0.0/16 to any port "$p" proto tcp || true
    ufw allow from 172.16.0.0/12 to any port "$p" proto tcp || true
  done
fi

# ---------- Start everything ----------
log "Starting services"
systemctl daemon-reload
for entry in "${SERVERS[@]}"; do
  IFS='|' read -r name _p _m _r <<<"$entry"
  systemctl enable minecraft-"$name"
  systemctl restart minecraft-"$name"
done
if [ "$PROXY" = 1 ]; then systemctl enable minecraft-proxy; systemctl restart minecraft-proxy; fi
if [ "$SYNC_SURVIVAL_CREATIVE" = 1 ]; then systemctl enable --now mc-sync.timer; fi
if [ "$NET_UPNP" = 1 ]; then systemctl enable --now mc-upnp.timer; fi

log "Done"
echo "PROVISION_OK"
"""#
}
