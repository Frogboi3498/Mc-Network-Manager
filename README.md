# MC Network Manager

A Mac app that builds a multi-server Minecraft network on your own Linux machines, then lets you watch and control it. It sets up a Velocity proxy with a lobby plus Survival and Creative Fabric servers, shows live player counts and machine health, and has built-in SSH terminals that sit side by side.

Your nodes and plan sync between devices through an account on a small server you run yourself. Everything is encrypted on your device before it is uploaded.

## Status

| Platform | State |
| --- | --- |
| macOS 15+ | Written. **Not yet compiled by its author** (see [Known gaps](#known-gaps)). CI builds it on GitHub's macOS runners. |
| iPhone / iPad | Not started. The models, sync and install logic are shared code and are written to be reused; the terminal and a few views need UIKit versions. |
| Windows | Not started. SwiftUI does not run on Windows, so this needs a different UI layer that reads the same encrypted vault. |

## Quick start (Mac)

1. Install Xcode 16 or newer.
2. Open `MCNetworkManager.xcodeproj` and press Run. Xcode downloads the Swift packages the first time.
3. Add your machines under **Nodes**, describe your servers under **Network**, then press **Install**.

The target machines need Debian or Ubuntu, systemd, SSH with password login, and a user that can use `sudo` (or the root account).

### What the installer does

On each node, over SSH:

- Installs `curl`, `jq` and `rsync`, plus a Java runtime matching your Minecraft version (Eclipse Temurin).
- Sets up each backend as a Fabric server with Fabric API and FabricProxy-Lite, so the Velocity proxy can forward players.
- Sets up the Velocity proxy with modern forwarding and a generated secret.
- Runs everything as systemd services under an unprivileged `mcnm` user.
- Optional: Tailscale, or automatic port forwarding (UPnP), or neither.
- Optional: a daily one-way copy of the Survival world into Creative.

It is safe to run again. Existing worlds and `server.properties` values are updated in place, never replaced.

### Mods and consent

Only Fabric API and FabricProxy-Lite are installed without asking, and the install screen says so. Every other mod (Inv View and BlueMap are built in; you can add any Modrinth mod by name) is listed on the install screen. You untick what you do not want and tick one agreement box before anything optional is downloaded. You must also accept the [Minecraft EULA](https://aka.ms/MinecraftEULA).

### Reaching the network from outside

- **Tailscale:** installs and signs in Tailscale on the proxy node. Friends join over your tailnet, so no router changes are needed. Tailscale Funnel is not used, because it only carries TLS traffic on ports 443, 8443 and 10000 (Tailscale, n.d.), which does not suit Minecraft.
- **UPnP:** asks your router to open the join port. It fails on routers with UPnP off and on internet connections behind carrier-grade NAT, and the installer says so if it fails.

## Accounts and sync

Run the sync server on any machine with Node 18 or newer:

```
cd SyncServer
node server.js
```

It listens on port 8787 and needs no packages. Settings are environment variables: `PORT`, `HOST`, `DATA_DIR`, `INVITE_CODE` (require a code to register) and `ALLOW_REGISTRATION=false` (close registration once your accounts exist).

In the app, open **Account**, enter the server address, and create an account or sign in. Signing in on a second device pulls your data down. If both devices already have data you choose which copy to keep.

### How the data is protected

- The password is stretched with PBKDF2-HMAC-SHA256 at 600,000 iterations (Moriarty et al., 2017; OWASP Foundation, n.d.) into 64 bytes.
- The first 32 bytes encrypt your vault with AES-256-GCM (Dworkin, 2007) on your device. They never leave it.
- The last 32 bytes are sent to the server as a login proof. The server hashes that again with scrypt before storing it.
- The server stores an encrypted blob and cannot read it. A forgotten password cannot be recovered.
- Concurrent edits from two devices are detected with a revision number and merged by node, newest edit winning.

Use `https://` or Tailscale for the sync server when it is reachable from the internet. The app warns on plain `http://` to public addresses.

## Tests

```
cd SyncServer && npm test               # 10 sync server tests
bash Scripts/test-provision.sh          # 33 installer script tests (needs jq)
node Scripts/check-xcodeproj.js         # project file consistency
```

The installer tests stub the network, so they check the script's logic but not the live Mojang, Fabric, PaperMC, Modrinth or Adoptium services.

## Known gaps

- **Not compiled yet.** The Swift code was written without access to a Swift compiler. Expect to fix a few compile errors on the first build, and please open an issue or a pull request. CI will show them.
- **SwiftTerm and Citadel are pinned to their `main` branches**, because release tags could not be checked when this was written. Pin them to released versions once the build works.
- **SSH host keys are not verified.** Connections accept any host key. Pin keys before exposing this beyond a network you trust.
- **SSH uses passwords only**, and node passwords are stored in the encrypted vault (and in the local, encrypted copy on each device).
- **Live service calls are untested.** The installer's calls to Mojang, Fabric, PaperMC, Modrinth and Adoptium follow their documented formats but have not run against the real services.
- The Minecraft status ping follows the Java Edition server list ping format from memory and has not been checked against a real server.
- The dependency on a fork of `swift-nio-ssh` comes from Citadel's own package manifest.

## Design

The interface follows Apple's Human Interface Guidelines (Apple Inc., n.d.): a sidebar for navigation, SF Symbols for icons, system fonts that scale with the user's settings, standard controls, accessibility labels on icon-only buttons, and light and dark appearance. Touch targets of at least 44 by 44 points matter on iPhone and iPad and will be enforced when those targets are added.

## Project layout

```
MCNetworkManager/
  Models/       Nodes, network plan, vault, mod catalogue
  Services/     Crypto, Keychain, sync client, SSH, installer, monitor
  Views/        SwiftUI screens
  Resources/    provision.sh (the installer script), assets
SyncServer/     Self-hosted account and vault server (Node, no dependencies)
Scripts/        Tests and project tooling
```

## References

Apple Inc. (n.d.). *Human interface guidelines*. https://developer.apple.com/design/human-interface-guidelines/

de Icaza, M. (n.d.). *SwiftTerm* [Computer software]. GitHub. https://github.com/migueldeicaza/SwiftTerm

Dworkin, M. (2007). *Recommendation for block cipher modes of operation: Galois/Counter Mode (GCM) and GMAC* (NIST Special Publication 800-38D). National Institute of Standards and Technology. https://doi.org/10.6028/NIST.SP.800-38D

Modrinth. (n.d.). *Modrinth API* (Version 2) [Computer software interface]. https://api.modrinth.com/v2/

Moriarty, K., Kaliski, B., & Rusch, A. (2017). *PKCS #5: Password-based cryptography specification version 2.1* (RFC 8018). Internet Engineering Task Force. https://doi.org/10.17487/RFC8018

OKTW Network. (n.d.). *FabricProxy-Lite* [Computer software]. GitHub. https://github.com/OKTW-Network/FabricProxy-Lite

orlandos-nl. (n.d.). *Citadel* [Computer software]. GitHub. https://github.com/orlandos-nl/Citadel

OWASP Foundation. (n.d.). *Password storage cheat sheet*. OWASP Cheat Sheet Series. https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html

PaperMC. (n.d.). *Downloads service*. https://docs.papermc.io/misc/downloads-service/

Tailscale. (n.d.). *Tailscale Funnel*. https://tailscale.com/docs/features/tailscale-funnel

## License

MIT. See [LICENSE](LICENSE).
