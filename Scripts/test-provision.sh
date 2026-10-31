#!/usr/bin/env bash
# Offline tests for MCNetworkManager/Resources/provision.sh.
# Sources the script's functions and stubs out the network. Needs bash and jq.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/MCNetworkManager/Resources/provision.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { # check DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

bash -n "$SCRIPT" && ok "bash -n syntax check" || bad "bash -n syntax check"

run_in_subshell() { # run a snippet with the script's functions loaded
  ( export MCNM_SOURCE_ONLY=1; set +e; source "$SCRIPT"; set +e +u; eval "$1" )
}

# --- validators ---------------------------------------------------------
check "valid_name accepts survival" 0 "$(run_in_subshell 'valid_name survival; echo $?')"
check "valid_name rejects spaces"   1 "$(run_in_subshell 'valid_name "a b"; echo $?')"
check "valid_name rejects injection" 1 "$(run_in_subshell 'valid_name "a;rm -rf /"; echo $?')"
check "valid_slug accepts fabric-api" 0 "$(run_in_subshell 'valid_slug fabric-api; echo $?')"
check "valid_slug rejects quote"     1 "$(run_in_subshell "valid_slug \"x'y\"; echo \$?")"
check "valid_mcver accepts 1.21.4"   0 "$(run_in_subshell 'valid_mcver 1.21.4; echo $?')"
check "valid_mcver accepts 26.2"     0 "$(run_in_subshell 'valid_mcver 26.2; echo $?')"
check "valid_mcver rejects junk"     1 "$(run_in_subshell 'valid_mcver "1.21; id"; echo $?')"

# --- env parsing --------------------------------------------------------
GOOD_ENV='ACCEPT_EULA=1 FORWARD_SECRET=abcdefghijklmnop1234567890ABCDEF ROLE_PROXY=1'
out="$(env $GOOD_ENV SERVERS='lobby|30066|adventure|1024|;survival|30067|survival|4096|invview,bluemap' \
  BACKENDS='lobby|127.0.0.1|30066;survival|127.0.0.1|30067' MCNM_SOURCE_ONLY=1 \
  bash -c "source '$SCRIPT'; set +e; parse_env && echo \${#SERVER_LIST[@]}")"
check "parse_env accepts a valid plan (2 servers)" 2 "$out"

out="$(env ROLE_PROXY=0 MCNM_SOURCE_ONLY=1 bash -c "source '$SCRIPT'; set +e; (parse_env) 2>&1 | grep -c EULA")"
check "parse_env refuses without EULA acceptance" 1 "$out"

out="$(env $GOOD_ENV SERVERS='bad name|1|survival|1024|' MCNM_SOURCE_ONLY=1 \
  bash -c "source '$SCRIPT'; set +e; (parse_env) 2>&1 | grep -c 'bad server name'")"
check "parse_env rejects a bad server name" 1 "$out"

out="$(env $GOOD_ENV SERVERS='a|25566|survival|1024|x;y' MCNM_SOURCE_ONLY=1 \
  bash -c "source '$SCRIPT'; set +e; (parse_env) 2>&1 | grep -c 'bad mod slug'")"
check "parse_env rejects a bad mod slug" 1 "$out"

out="$(env ACCEPT_EULA=1 ROLE_PROXY=1 FORWARD_SECRET=short MCNM_SOURCE_ONLY=1 \
  bash -c "source '$SCRIPT'; set +e; (parse_env) 2>&1 | grep -c FORWARD_SECRET")"
check "parse_env rejects a weak forwarding secret" 1 "$out"

# --- Modrinth selection with a stubbed API ------------------------------
read -r -d '' MOD_JSON <<'JSON' || true
[
 {"version_type":"beta","files":[{"primary":true,"url":"https://cdn.modrinth.com/data/x/versions/b/beta.jar","hashes":{"sha512":"bbb"}}]},
 {"version_type":"release","files":[
   {"primary":false,"url":"https://cdn.modrinth.com/data/x/versions/r/sources.jar","hashes":{"sha512":"sss"}},
   {"primary":true,"url":"https://cdn.modrinth.com/data/x/versions/r/mod-1.0.jar","hashes":{"sha512":"rrr"}}]}
]
JSON
out="$(run_in_subshell "fetch() { cat <<'J'
$MOD_JSON
J
}; modrinth_pick x 1.21.4")"
check "modrinth_pick prefers the primary file of the newest release" \
  $'https://cdn.modrinth.com/data/x/versions/r/mod-1.0.jar\trrr' "$out"

out="$(run_in_subshell "fetch() { echo '[]'; }; modrinth_pick x 1.21.4")"
check "modrinth_pick prints nothing when no version matches" "" "$out"

out="$(run_in_subshell "fetch() { echo '[{\"version_type\":\"beta\",\"files\":[{\"url\":\"https://e/x.jar\",\"hashes\":{}}]}]'; }; modrinth_pick x 1.21.4")"
check "modrinth_pick falls back to a beta when no release exists" $'https://e/x.jar\t' "$out"

# --- Velocity JSON parsing ----------------------------------------------
VEL_BUILDS='[{"id":9,"channel":"BETA","downloads":{"server:default":{"url":"https://u/beta.jar","checksums":{"sha256":"b"}}}},{"id":8,"channel":"STABLE","downloads":{"server:default":{"url":"https://u/stable.jar","checksums":{"sha256":"s"}}}}]'
url="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads."server:default".url) // first(.[] | .downloads."server:default".url) // empty' <<<"$VEL_BUILDS")"
check "velocity: picks the STABLE build" "https://u/stable.jar" "$url"
VEL_PROJECT='{"versions":{"3.4":["3.4.0-SNAPSHOT","3.3.0-SNAPSHOT"],"3.3":["3.2.0"]}}'
ver="$(jq -r '.versions | to_entries[0] | .value[0]' <<<"$VEL_PROJECT")"
check "velocity: picks the newest version" "3.4.0-SNAPSHOT" "$ver"

# --- Fabric loader selection --------------------------------------------
out="$(run_in_subshell "MC_VERSION=1.21.4; fetch() { case \"\$*\" in
  *versions/loader) echo '[{\"version\":\"0.17.0-beta\",\"stable\":false},{\"version\":\"0.16.9\",\"stable\":true}]';;
  *versions/installer) echo '[{\"version\":\"1.0.1\",\"stable\":true}]';; esac; }; fabric_launcher_url")"
check "fabric_launcher_url uses newest stable loader/installer" \
  "https://meta.fabricmc.net/v2/versions/loader/1.21.4/0.16.9/1.0.1/server/jar" "$out"

# --- set_prop -----------------------------------------------------------
tmp="$(mktemp)"
printf 'server-port=25565\nmotd=old\n' > "$tmp"
run_in_subshell "set_prop '$tmp' server-port 30066; set_prop '$tmp' motd 'My & Net | one'; set_prop '$tmp' gamemode creative"
check "set_prop updates an existing key"  "server-port=30066" "$(grep '^server-port=' "$tmp")"
check "set_prop escapes sed specials"      "motd=My & Net | one" "$(grep '^motd=' "$tmp")"
check "set_prop appends a missing key"     "gamemode=creative" "$(grep '^gamemode=' "$tmp")"
run_in_subshell "set_prop '$tmp' gamemode survival"
check "set_prop is idempotent (no duplicates)" 1 "$(grep -c '^gamemode=' "$tmp")"

# --- generated configs --------------------------------------------------
work="$(mktemp -d)"
out="$(run_in_subshell "BASE='$work'; mkdir -p \$BASE/proxy; chown() { :; }
  FORWARD_SECRET=abcdefghijklmnop1234567890ABCDEF PUBLIC_PORT=25565 NETWORK_NAME='Test Net'
  BACKENDS='lobby|127.0.0.1|30066;survival|10.0.0.5|30067'
  write_velocity_config; cat \$BASE/proxy/velocity.toml")"
case "$out" in *'lobby = "127.0.0.1:30066"'*) ok "velocity.toml lists the lobby backend";; *) bad "velocity.toml lists the lobby backend";; esac
case "$out" in *'survival = "10.0.0.5:30067"'*) ok "velocity.toml lists a remote backend";; *) bad "velocity.toml lists a remote backend";; esac
case "$out" in *'try = ["lobby"]'*) ok "velocity.toml tries the first server (lobby) first";; *) bad "velocity.toml try order";; esac
case "$out" in *'player-info-forwarding-mode = "modern"'*) ok "velocity.toml uses modern forwarding";; *) bad "modern forwarding";; esac
check "forwarding.secret has the exact secret, no newline" "abcdefghijklmnop1234567890ABCDEF" "$(cat "$work/proxy/forwarding.secret")"
check "forwarding.secret is mode 600" 600 "$(stat -c %a "$work/proxy/forwarding.secret")"
check "toml section headers are well formed" 4 "$(grep -c '^\[' "$work/proxy/velocity.toml")"

run_in_subshell "FORWARD_SECRET=abcdefghijklmnop1234567890ABCDEF; write_fabric_proxy_config '$work/srv'"
check "FabricProxy-Lite secret matches" 'secret = "abcdefghijklmnop1234567890ABCDEF"' "$(grep '^secret' "$work/srv/config/FabricProxy-Lite.toml")"

# --- SERVERS parsing round trip ----------------------------------------
out="$(env ACCEPT_EULA=1 FORWARD_SECRET=abcdefghijklmnop1234567890ABCDEF SERVERS='lobby|30066|adventure|1024|;survival|30067|survival|4096|invview,bluemap' MCNM_SOURCE_ONLY=1 \
  bash -c "source '$SCRIPT'; set +e; parse_env; IFS='|' read -r n p g m mods <<<\"\${SERVER_LIST[1]}\"; echo \"\$n \$p \$g \$m \$mods\"")"
check "second server entry parses with its mods" "survival 30067 survival 4096 invview,bluemap" "$out"

rm -rf "$tmp" "$work"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
