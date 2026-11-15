# remote-focus

Drive the **Claude** and **Codex** desktop apps on macOS from the couch with a **Xiaomi Remote 2 Pro** (Bluetooth TV remote with a mic).

The stack:

| Piece | Role |
|---|---|
| Xiaomi Remote 2 Pro | Bluetooth remote: D-pad, OK, back, home, menu, TV, volume ±, power, voice key |
| SayAll (macOS app) | Pairs the remote, uses its mic, maps every button to a key / action |
| Typeless | Voice dictation (hold the voice key, speak — whispering works if you hold the mic end close) |
| **remote-focus** (this repo) | Adds generic accessibility-based navigation on top of SayAll while Claude / Codex is frontmost |

## Design principle

remote-focus only uses what the apps themselves expose through macOS accessibility (ARIA landmarks, editable text, keyboard focus). It has **no per-app hacks** except one: the "previous / next session" shortcut, which differs per app by design. Arrow keys and OK are passed to the app untouched, so each app keeps its own keyboard behavior.

## Button map (with remote-focus running)

| Remote button | Action |
|---|---|
| Voice (hold) | Dictate with Typeless |
| OK | Return (send) · long-press: focus the input box (SayAll) |
| D-pad | Native arrow keys, passed to the app |
| ↑ / ↓ when a long item is cut off | Scroll it until fully visible first, then hand the key back to the app |
| Back | Delete a character when in text; otherwise Esc (close menu / go up one level) |
| Power | Esc (stop the agent) |
| Home | ⌘N new chat · long-press: undo |
| Menu / TV | Open Claude / open Codex |
| Volume + / − (tap) | Move keyboard focus to the next / previous section (sidebar, conversation, artifact panel, input box…) — whatever landmarks the app exposes, in document order. Double-tap = two steps |
| Volume + / − (hold) | Previous / next session (Claude ⌥↑↓, Codex ⌘⌥←→) |

Without remote-focus running, the remote still works: volume ± become SayAll's scroll up / down.

Claude and Codex behave slightly differently (e.g. Claude steps through chat messages one by one, Codex scrolls smoothly; Codex's session list does not react to plain arrow keys). That comes from each app's own keyboard handling, not from special-casing in this tool.

## SayAll configs

In `sayall/` (SayAll → Settings → import):

- `sayall-with-remotefocus.json` — use together with remote-focus (volume ± tap/hold are handled by remote-focus).
- `sayall-standalone.json` — SayAll only; volume ± long-press switch Claude sessions via ⌥↑↓.

## Build & run

Requires macOS 13+ and the Swift toolchain (Xcode Command Line Tools).

```bash
swift build -c release
.build/release/remote-focus --verbose
```

On first run grant your terminal **Accessibility** and **Input Monitoring** (System Settings → Privacy & Security). `--verbose` logs which section was selected and where focus actually landed.

Diagnostics: `.build/release/ax-dump claude` (or `codex`) writes the window's accessibility tree to `~/Downloads/ax-dump-<app>.txt`.

## Known limitations

- Depends on two SayAll internals: the marker it puts on synthetic events (`0x5849414F`, "XIAO") and its key-repeat timing (first repeat after ~0.35 s, then every 0.1 s).
- SayAll's long-press OK ("focus input") may pick Codex's side-chat input when side chat is open.
- When the Claude input box grows (e.g. an image attachment), the last lines of the final message can stay hidden behind it — the conversation simply cannot scroll further.
- A few thresholds are empirical (minimum section size, 80 px scroll step, 0.35 s settle time).

## License

MIT — see [LICENSE](LICENSE).
