# AtollPluginManager Plugin Protocol

AtollPluginManager is a broker: it holds the single authorized connection to
[Atoll](https://github.com/Ebullioscopic/Atoll) and relays live activities on
behalf of any number of plugins. Atoll's own "App Permissions" list shows
exactly one entry — AtollPluginManager — regardless of how many plugins are
connected through it.

A plugin is any program that:

1. Listens on its own Unix domain socket.
2. Drops a `plugin.json` manifest telling the broker where to find that socket.
3. Speaks the newline-delimited JSON protocol described below once the broker
   connects.

No SDK, no linked library, no particular language. cliamp
([tomdabro/cliamp](https://github.com/tomdabro/cliamp), package
`atollplugin/`) is the reference implementation, in Go.

## Discovery: `plugin.json`

The broker scans (and watches for changes to)
`~/Library/Application Support/AtollPluginManager/Plugins/`. Each plugin gets
its own subfolder containing a `plugin.json`:

```json
{
  "id": "cliamp",
  "name": "cliamp",
  "category": "media",
  "transport": "unixSocket",
  "socketPath": "cliamp.sock",
  "protocolVersion": 1,
  "supportsSeek": true,
  "supportsSkip": true
}
```

| Field             | Type   | Required | Notes                                                                                                  |
|--------------------|--------|----------|----------------------------------------------------------------------------------------------------------|
| `id`               | string | yes      | Unique across every plugin the broker discovers. Non-empty.                                              |
| `name`             | string | yes      | Display name shown in the broker's UI and, for `"media"` plugins, in Atoll's controller picker.          |
| `category`         | string | yes      | `"liveActivity"` (banner) or `"media"` (Now Playing source). See [Live activity protocol](#live-activity-protocol) / [Media source protocol](#media-source-protocol). |
| `transport`        | string | yes      | Only `"unixSocket"` is implemented today.                                                                |
| `socketPath`       | string | yes      | Absolute path (`/…`), or relative to this manifest's own folder. See the length note below.              |
| `protocolVersion`  | int    | no       | Which version of this document the plugin speaks. Defaults to `1` if omitted. See [Versioning](#versioning). |
| `supportsSeek`     | bool   | no       | `category: "media"` only. Whether Atoll should offer seek controls for this source. Defaults to `true`.  |
| `supportsSkip`     | bool   | no       | `category: "media"` only. Whether Atoll should offer next/previous controls. Defaults to `true`.         |

The broker never launches a plugin — this is **passive discovery**. Write
your manifest, start listening, and the broker connects to you (with
reconnect/backoff if it starts before you do, or if you restart).

### Socket path length

`sockaddr_un.sun_path` is capped at **104 bytes** on Darwin, including the
null terminator. Network.framework (what the broker uses to connect)
**crashes the broker process** rather than returning an error when a
resolved path doesn't fit — the broker guards against this by rejecting an
over-length manifest at discovery time with a clear reason instead of
connecting, but *your* socket path still needs to be short in absolute
terms. Prefer a short, dedicated directory (cliamp uses
`~/.local/share/cliamp/atoll-plugin.sock`) over deeply-nested paths.

### Rejected manifests

The broker discards a manifest and records a human-readable reason (visible
in its Settings UI, and via `stderr` while running from a terminal) if it:

- fails to parse as JSON,
- is missing a required field, or has an empty `id`/`name`/`socketPath`,
- declares an unknown `category` or `transport`,
- declares a `protocolVersion` outside what this broker build supports,
- reuses an `id` another already-discovered manifest is using, or
- resolves to a socket path that won't fit `sockaddr_un`.

A rejected manifest never gets a connection attempt; fix it and the next
directory-watch tick (or the next broker launch) picks it up.

## Live activity protocol (`category: "liveActivity"`)

Once the broker connects to your socket, write **one JSON object per line**
(`\n`-terminated) whenever your plugin's state changes. The broker never
initiates — it only reads what you send and, for `presentActivity` /
`updateActivity` / `dismissActivity`, writes back one ack/error line per
message.

### Plugin → broker messages

#### `presentActivity` / `updateActivity`

```json
{"type":"presentActivity","id":"now-playing","title":"Song Title","subtitle":"Artist","icon":"music.note","accentColorHex":"#FF8800","priority":"normal"}
```

| Field            | Type   | Required | Notes                                                                                  |
|-------------------|--------|----------|-------------------------------------------------------------------------------------------|
| `type`            | string | yes      | `"presentActivity"` or `"updateActivity"`.                                               |
| `id`               | string | yes      | Your own identifier for this activity, unique **within your plugin only**. The broker prefixes it with your plugin id (`"<pluginID>:<id>"`) before it ever reaches Atoll, so plugins can't collide with each other. |
| `title`            | string | yes      | Non-empty. The only required content field.                                              |
| `subtitle`         | string | no       |                                                                                          |
| `icon`             | string | no       | An SF Symbol name, e.g. `"music.note"`, `"timer"`. Omit for no icon.                      |
| `accentColorHex`   | string | no       | `"#RRGGBB"` or `"#RRGGBBAA"`. Omit to use Atoll's system accent color.                    |
| `priority`         | string | no       | One of `low` / `normal` / `high` / `critical`. Defaults to `normal`.                     |

`presentActivity` and `updateActivity` build the exact same descriptor —
the distinction only matters to Atoll's own state machine (updating an
activity that was never presented is an error). If you don't already track
whether you've presented a given `id`, send `presentActivity` once, then
`updateActivity` for every change after that, and reset to `presentActivity`
whenever a new broker connection accepts (see
[Reconnection semantics](#reconnection-semantics)).

#### `dismissActivity`

```json
{"type":"dismissActivity","id":"now-playing"}
```

Only `type` and `id` are used.

### Broker → plugin messages

One line per message you sent, in order:

```json
{"type":"ack","id":"now-playing"}
```

```json
{"type":"error","id":"now-playing","message":"Descriptor validation failed: Missing existing activity."}
```

A plugin isn't required to read these — the broker doesn't wait for you to
before processing the next message — but they're useful for debugging a new
integration.

### Reconnection semantics

- If the broker isn't connected when you call your equivalent of `Update`,
  the message is silently dropped. **Track this** — sending
  `updateActivity`/`dismissActivity` for something the broker (and
  therefore Atoll) never actually received will fail. cliamp's
  `atollplugin.Service` only marks an activity "presented" once a send
  actually reaches a connected broker.
- Every new accepted connection should be treated as a broker with **no
  memory of anything from a previous connection's lifetime** — your own
  process restarting, or the broker's own reconnect after Atoll wasn't
  running. Reset your local "presented" bookkeeping to empty when a new
  connection is accepted, and let the next state change send a fresh
  `presentActivity`.
- The broker dismisses whatever activities it still has on record for you
  the moment your socket connection closes, so a crash or restart never
  leaves a stale activity in Atoll's notch.

## Media source protocol (`category: "media"`)

Same framing as the live activity protocol (one JSON object per line), but
there's no register/present/dismiss lifecycle: the manifest's own
`id`/`name`/`supportsSeek`/`supportsSkip` already tell Atoll everything it
needs, so the connection existing at all *is* the registration. You send
snapshots of what's currently playing; the broker relays commands from
Atoll's notch controls back to you.

### Plugin → broker: `nowPlaying`

```json
{"title":"Song Title","artist":"Artist","album":"Album","artworkBase64":"iVBORw0KGgo...","isPlaying":true,"elapsedTime":42.5,"duration":213.0,"isShuffled":false,"repeatMode":"off"}
```

| Field            | Type    | Required | Notes                                                              |
|-------------------|---------|----------|------------------------------------------------------------------------|
| `title`           | string  | yes      | Non-empty. Messages with an empty title are rejected.                  |
| `artist`          | string  | no       |                                                                      |
| `album`           | string  | no       |                                                                      |
| `artworkBase64`   | string  | no       | Base64-encoded artwork image data (PNG/JPEG).                          |
| `isPlaying`       | bool    | yes      |                                                                      |
| `elapsedTime`     | number  | yes      | Seconds.                                                             |
| `duration`        | number  | no       | Seconds. Omit if unknown (e.g. a live stream).                         |
| `isShuffled`      | bool    | no       | Omit if your source doesn't track shuffle state — Atoll's control renders "off" rather than a stale guess. |
| `repeatMode`      | string  | no       | `"off"` / `"one"` / `"all"`. Same "omit if unknown" rule as `isShuffled`. |

Send one of these on every state change (track change, play/pause, seek).
There's no separate "dismiss": if your process disconnects, the broker
unregisters the source from Atoll, same as the live activity protocol's
dismiss-on-disconnect.

### Broker → plugin: `mediaCommand`

```json
{"type":"mediaCommand","command":"seek","seekTo":95.0}
```

| Field       | Type            | Notes                                                                                  |
|--------------|-----------------|--------------------------------------------------------------------------------------------|
| `type`       | string          | Always `"mediaCommand"`.                                                                    |
| `command`    | string          | One of `play`, `pause`, `togglePlayPause`, `nextTrack`, `previousTrack`, `seek`, `toggleShuffle`, `toggleRepeat`. |
| `seekTo`     | number, omitted unless `command == "seek"` | Absolute position in seconds.                                        |

These originate from the user interacting with Atoll's notch controls (or
system media keys Atoll itself observes) for whichever source is currently
selected. Apply them the same way you'd apply an OS media-key event —
`nextTrack`/`previousTrack` only ever arrive if your manifest declared
`supportsSkip: true`, and `seek` only if `supportsSeek: true`.

## Versioning

This protocol is versioned independently of
[AtollRPC](https://github.com/Ebullioscopic/Atoll) (the
`ws://127.0.0.1:9020` JSON-RPC protocol between the broker and Atoll
itself) — a plugin author only ever needs to track the number in this
document, never Atoll's own RPC version, since the broker is the only thing
that speaks AtollRPC.

- Current version: **1** (this document).
- Declare it in your manifest's `protocolVersion` field. Omitting it is
  treated as `1`.
- A broker build rejects a manifest declaring a version outside the range
  it supports, with a clear reason, rather than connecting and failing
  unpredictably on the first message.
- Changes that add an optional field (like `protocolVersion` itself) don't
  bump the version. Changes to required fields, message types, or framing
  do.

## Minimal reference implementation shape

Regardless of language, a plugin needs:

1. Listen on a Unix domain socket at a short, stable path.
2. Write a `plugin.json` (see above) pointing at that socket, into your own
   subfolder of `~/Library/Application Support/AtollPluginManager/Plugins/`.
3. For `category: "liveActivity"`: on accepting a connection, reset local
   "presented" state to empty; on every state change, write one JSON line
   (`presentActivity` / `updateActivity` / `dismissActivity`) to whichever
   connection is currently open — or drop it if none is, without marking
   anything as presented. For `category: "media"`: on every state change,
   write one `nowPlaying` line the same way, and apply `mediaCommand` lines
   the broker sends back.
4. Optionally read back ack/error (`liveActivity`) or `mediaCommand`
   (`media`) lines for debugging or command handling.

See `tomdabro/cliamp`'s `atollplugin/` package for a complete, tested
`category: "media"` example (Go).
