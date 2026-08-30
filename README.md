# AtollPluginManager

> **Status:** Work in progress. This is a personal project by
> [Tomasz Dabrowski](https://github.com/tomdabro) — all credit and
> contribution for *this* repository goes to the author. Note that
> [Atoll](https://github.com/Ebullioscopic/Atoll) itself, which this
> broker connects to, and [AtollExtensionKit](https://github.com/Ebullioscopic/AtollExtensionKit),
> the SDK this broker depends on for Atoll's descriptor types, are
> separate projects by a different author
> ([Ebullioscopic](https://github.com/Ebullioscopic)/kryoscopic) — all
> credit for Atoll and AtollExtensionKit belongs to them, not to this
> repository.

A broker app that holds the single authorized connection to
[Atoll](https://github.com/Ebullioscopic/Atoll) (a macOS Dynamic Island app)
and relays live activities on behalf of any number of plugins, so each
plugin doesn't need its own Atoll authorization or its own RPC client.

```
cliamp ──┐
other-app├──► local socket ──► AtollPluginManager ──► AtollRPC ──► Atoll
plugin-3 ─┘   (per-plugin)       (registry + relay)   (ws://9020)
```

Atoll's "App Permissions" list shows exactly one entry: AtollPluginManager.
Everything downstream of it is invisible to Atoll.

## Writing a plugin

See [`PROTOCOL.md`](PROTOCOL.md) for the manifest schema and wire protocol.
No SDK required — any language that can listen on a Unix domain socket and
write JSON lines works.
[`tomdabro/cliamp`](https://github.com/tomdabro/cliamp)'s `atollplugin/`
package is a complete, tested reference implementation in Go.

## Building

```sh
swift build            # debug build
swift test              # unit + integration tests
swift run                # run the app
```

Requires the sibling `AtollExtensionKit` checkout at `../AtollExtensionKit`
(declared as a local Swift package dependency in `Package.swift`) — it
supplies the `AtollLiveActivityDescriptor`/`AtollIconDescriptor`/etc. model
types used to build descriptors for Atoll's RPC surface.

## Architecture

| Component                     | Responsibility                                                                                     |
|--------------------------------|-----------------------------------------------------------------------------------------------------|
| `AtollRPCClient`               | WebSocket JSON-RPC 2.0 client for Atoll's `ExtensionRPCServer` (`ws://127.0.0.1:9020`). Connects, authorizes once, reconnects with backoff. |
| `PluginDiscovery`               | Scans and watches `~/Library/Application Support/AtollPluginManager/Plugins/` for `plugin.json` manifests. |
| `PluginManifest`                | The manifest schema plus structural/version validation.                                             |
| `PluginConnection`               | One actor per discovered plugin: connects to its Unix socket, decodes the wire protocol, relays into an `ActivityRelay`, dismisses on disconnect. |
| `PluginConnectionManager`         | Reconciles `PluginDiscovery`'s output with live `PluginConnection`s; honors per-plugin enable/disable. |
| `PluginPreferences`               | Persists which discovered plugins the user has disabled. |
| `ContentView`                     | Status window: broker connection state, discovered plugins, enable/disable toggles. |

`ActivityRelay` narrows `AtollRPCClient` down to the three activity RPC
calls `PluginConnection` needs, so plugin-relay logic is unit-testable
against a fake without a real Atoll connection (see
`Tests/AtollPluginManagerTests/PluginConnectionIntegrationTests.swift`,
which drives a real Unix socket end to end).

## Status

Implemented: broker connection/authorization, plugin discovery, the
live-activity wire protocol, per-plugin enable/disable, and a real cliamp
integration. Not yet implemented: lock screen widgets and notch experiences
(the manifest schema reserves `category` for them but only `"liveActivity"`
is accepted today), and launching plugins as subprocesses (discovery is
purely passive — a plugin must already be running and listening).
