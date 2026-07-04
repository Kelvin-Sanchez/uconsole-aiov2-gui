# uConsole Radio Control — Feature Backlog

Working backlog for the Godot radio-control UI (`radio-ui`), which runs on the uConsole;
`Main.gd` in this repo is the source of truth. Check items off as they ship.

## Shipped
- [x] Rail power control (SDR / GPS / LoRa / USB) via `aiov2_ctl`, with live ON/OFF state
- [x] Battery / power telemetry readout (source, draw, capacity)
- [x] SDR-in-use guard (confirm before cutting a rail a running SDR tool depends on)
- [x] Customizable rail tiles + management-interface picker (Settings panel, persisted to `~/.config/radio-ui/config.json`)
- [x] Management-interface protection (protected badge, no toggle, hard-confirm on the rail that feeds it)
- [x] "Field-radio instrument panel" visual redesign (Godot Theme, module-row layout)
- [x] Automated UI testing via `wlrctl` + `grim` (screenshots + clicks)

## Backlog

### Wi-Fi auditing (AC1200 / MT7921) — the core mission; needs AC1200 reconnected
- [ ] Monitor-mode toggle on the auditing radio, guarded so it never touches the management interface
- [ ] Nearby-AP scan (SSID / channel / signal), auditing radio only
- [ ] Per-channel activity meter (waterfall/sparkline style from the mockup)
- [ ] Presence-aware USB-radio tiles (auto-detect AC1200 / future MT7612U; grey "not detected" when absent)

### Power (battery device — reuses `aiov2_ctl` subcommands)
- [x] Per-rail draw measurement (`aiov2_ctl --measure <RAIL>`) — threaded "Meas" button per card, shows power delta; verified
- [ ] Battery runtime estimate (from capacity + draw)
- [x] Boot-rail persistence from Settings (`aiov2_ctl --boot-rail`) — read + write verified
- [x] RTC sync button in Settings (`sudo aiov2_ctl --sync-rtc`) — CLI verified
- [ ] Power-draw sparkline over time in the telemetry cluster

### SDR (RTL-SDR / swradio0)
- [x] Reliable in-use detection (fixed `pgrep -f` self-match with `[x]`-bracketed pattern; verified both directions) — unblocks the launcher
- [x] Tool launcher — generalized to a per-card **Launch** button (fills the dead card space) opening a config-driven program menu. Programs live in `config.launchers` (seeded with SDR defaults: rtl_tcp / rtl_power / gqrx); each has a `headless` flag. Launch powers the rail + starts detached via `setsid --fork` (reaped cleanly); menu shows "Stop X" (green) for running programs; zombie-aware detection. `config.launch_headless_only` filter wired for a future headless-only toggle. Verified launch + stop.
- [ ] ADS-B quick view — BLOCKED: `dump1090` not installed on device

### GPS + clock (u-blox)
- [ ] GPS fix panel — BLOCKED: `gpsd` not installed (only clients present)
- [x] RTC sync button (`aiov2_ctl --sync-rtc`) — shipped in Settings

### Quality of life
- [x] Auto-refresh timer (live state without pressing Refresh) — 4s Timer, verified live
- [x] "RF silence" all-off button (cuts every enabled rail except the management-feed rail) — verified
- [x] Autostart on boot — `~/.config/labwc/autostart` launches the app (with double-launch guard); script verified, activates on next boot
- [x] Low-battery / high-temp alerts (CPU temp in telemetry + crit coloring; battery crit when <=20% and discharging) — verified render

## Suggested sequence
1. **Auto-refresh timer** — tiny, makes everything feel live
2. **Per-rail power measurement** — real value, reuses existing tooling, testable now without the AC1200
3. **Wi-Fi auditing panel** — the project's real purpose, once the AC1200 is reconnected

## Notes
- `aiov2_ctl` subcommands available: `--measure`, `--boot-rail`, `--mesh-on-boot`, `--sync-rtc`, `--power`, `--watch`.
- Prototype larger UI features in an HTML mockup first (as with the redesign), then port to a Godot Theme.
- `OS.execute` runs `/bin/sh` (dash) and doesn't invoke a shell for arg lists — avoid multi-statement shell one-liners; use single-binary calls.
