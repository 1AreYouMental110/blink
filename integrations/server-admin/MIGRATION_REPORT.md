# Server Admin Blink V2 Migration Report

This report was generated from the live Server Admin place through Studio Bridge scans. It is the source-of-truth handoff for replacing old Roblox remotes with this fork's v2-only Blink transport.

## Inventory

- Legacy ReplicatedStorage remotes mapped: 133.
- RemoteEvents: 74.
- RemoteFunctions: 59.
- Client-origin legacy surfaces quarantined by the firewall: 81.
- Server-facing or observed-only surfaces kept annotated/observable: 52.
- Caller scan rows: 766 (135 high confidence, 251 medium, 380 low/broad-name matches).

Risk split:
- Admin: 16
- Cosmetic: 22
- Inventory: 26
- Marketplace: 12
- Moderation: 15
- ServerState: 40
- Teleport: 2

## Generated schema

- `ServerAdminLegacy.blink` keeps the existing v2 envelope API and adds per-remote legacy entries with explicit `WireId`.
- Bidirectional old RemoteEvents are split into `LegacyC2S_*` and `LegacyS2C_*` v2 entries. The C2S side uses the legacy base `WireId`; the S2C side uses `WireId + 1` when both directions exist.
- RemoteFunctions become `LegacyFn_*` functions with policy, risk, rate limit, idempotency where sensitive, and max packet bounds.
- The installed runtime adapters currently route through the envelope entries so migrated scripts can be rewritten incrementally without resurrecting v1 or raw legacy remotes.
- The full schema compiles and has a lockfile, but its generated server/client modules exceed Studio's single `Source` assignment limit. `schemas/*` contains the Studio-safe split schemas that were generated, validated, and installed.

## Runtime modules

- `LegacyManifest.luau`: exact old path, class, wire id, risk, policy, max packet bytes, direction, and migration mode.
- `LegacyClient.luau`: client proxy for `FireServer`, `InvokeServer`, `OnClientEvent.Connect`, nested tree access, `WaitForChild`, and `FindFirstChild`.
- `LegacyServer.luau`: server proxy for `OnServerEvent.Connect`, `OnServerInvoke`, server-to-client sends, nested tree access, and no-handler deny/audit.
- `LegacyRemoteFirewall.server.luau`: moves client-origin old remotes into `ServerStorage.BlinkV2LegacyQuarantine`, creates deny/log honeypot stubs at the old paths, annotates observed remotes, and starts the v2 adapter dispatcher.
- `split-schemas.json` plus `schemas/*/generated`: 15 generated Blink v2 API chunks installed under `BlinkV2.Generated` so direct rewrites can use explicit per-remote APIs without hitting Studio source-size limits.

## Live install evidence

- `BlinkV2LegacyInstall` installed the manifest, adapters, and firewall modules.
- `BlinkV2LegacyFirewall` activated with 81 quarantined old remotes and 52 observed remotes.
- `BlinkV2SplitInstall` prepared 15 generated chunks.
- `BlinkV2SplitVerify` confirmed 15 of 15 generated chunks, maximum source length 176369, `LegacyClient` length 5160, and `LegacyServer` length 6424.

## Live honeypot hits seen

- ReplicatedStorage.EXE6_STORAGE.events.quick_actions.SaveActions: 7 hit(s), legacy-remote-honeypot, player 0pealz.
- ReplicatedStorage.EXE6_STORAGE.events.auth.Auth: 3 hit(s), legacy-function-honeypot, player 0pealz.
- ReplicatedStorage.RemoteEvents.AFKUpdate: 2 hit(s), legacy-remote-honeypot, player 0pealz.
- ReplicatedStorage.EXE6_STORAGE.events.GetDeletedThemes: 1 hit(s), legacy-function-honeypot, player 0pealz.
- ReplicatedStorage.EXE6_STORAGE.events.quick_actions.GetActions: 1 hit(s), legacy-function-honeypot, player 0pealz.
- ReplicatedStorage.EXE6_STORAGE.events.ui.GetGameDesignTable: 1 hit(s), legacy-function-honeypot, player 0pealz.
- ReplicatedStorage.RemoteFunctions.GetCommands: 1 hit(s), legacy-function-honeypot, player 0pealz.
- ReplicatedStorage.RemoteFunctions.PaintCustomColors: 1 hit(s), legacy-function-honeypot, player 0pealz.
- ReplicatedStorage.RemoteFunctions.RequestTutorialStatus: 1 hit(s), legacy-function-honeypot, player 0pealz.
- ReplicatedStorage.RemoteEvents.JoinServer: 1 hit(s), legacy-remote-honeypot, player 0pealz.
- ReplicatedStorage.RemoteEvents.SaveTutorialDone: 1 hit(s), legacy-remote-honeypot, player 0pealz.

## Rewrite rule

Old client code should not call `RemoteEvent:FireServer` or `RemoteFunction:InvokeServer` directly. Replace remote roots with:

```lua
local LegacyClient = require(game:GetService("ReplicatedStorage"):WaitForChild("BlinkV2"):WaitForChild("LegacyClient"))
local events = LegacyClient.Tree("ReplicatedStorage.EXE6_STORAGE.events")
local remoteEvents = LegacyClient.Tree("ReplicatedStorage.RemoteEvents")
local remoteFunctions = LegacyClient.Tree("ReplicatedStorage.RemoteFunctions")
```

Old server handler code should replace raw remote roots with:

```lua
local LegacyServer = require(game:GetService("ServerScriptService"):WaitForChild("BlinkV2"):WaitForChild("LegacyServer"))
local events = LegacyServer.Tree("ReplicatedStorage.EXE6_STORAGE.events")
local remoteEvents = LegacyServer.Tree("ReplicatedStorage.RemoteEvents")
local remoteFunctions = LegacyServer.Tree("ReplicatedStorage.RemoteFunctions")
```

For new work, prefer the generated specific `LegacyC2S_*`, `LegacyS2C_*`, and `LegacyFn_*` APIs in `ServerAdminLegacy.blink`; the tree proxy exists to migrate the large existing Server Admin codebase without re-enabling raw old remotes.

## Compatibility risk

- The old client-origin remotes are intentionally denied/logged. Any remaining old LocalScript call will show as a honeypot hit until that script is rewritten to `LegacyClient` or generated Blink entries.
- Broad caller rows for generic names such as `Color` can be false positives; high-confidence rows in `legacy-callers.csv` should be prioritized first.
- This integration does not claim remote spying can be prevented. The server must keep authority, issue handles/capabilities, validate policies, reject replay, avoid secrets in remotes, and score abuse.
