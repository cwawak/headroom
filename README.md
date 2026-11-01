# Headroom (Fork)

> [!WARNING]
> **FORK NOTICE & NO SUPPORT DISCLAIMER**
>
> This repository is an independent **fork** of the original [Headroom project](https://github.com/vinaybhaskarla/headroom).
>
> **NO SUPPORT IS PROVIDED.** This software is maintained purely on an as-is, best-effort basis for personal and community use. There are **no warranties, no SLAs, no guarantees of bug fixes, updates, or feature additions, and no official customer or technical support**. If something does not work in your setup, you are expected to debug, fix, and adapt the code yourself. Issues and pull requests may be ignored or closed without response. Use entirely at your own risk.

---

How much AI quota you have left, in your macOS menu bar.

A gauge needle displays the quota status of the agent you are actively using (or the agent closest to exhaustion); clicking reveals detailed per-agent quota breakdowns with animated drain capsules. It reads only the local disk logs that CLI tools already write to disk — **no network calls, no credentials, no API keys, and zero token consumption.**

Requires macOS 14 (Sonoma) or newer.

![The Headroom menu, showing Codex and Claude quota](docs/menu.png)

---

## What's New in this Fork

This fork accumulates significant enhancements and architectural refinements over upstream:

- **Provider Display Preferences**: Toggle individual AI providers (Codex, Claude, Antigravity) on or off directly from the menu bar preferences without restarting.
- **Short-Limit Toggling**: Option to hide the 5-hour rolling limit per provider to keep the menu clean and focus primarily on weekly quota limits.
- **Quota Rollover & Early Reset Detection (`ResetDetector`)**:
  - Automatically identifies scheduled quota rollover deadlines.
  - Detects **abnormal/free resets** (early drops of 5%+ in usage before the scheduled reset time).
  - Delivers native macOS user notifications via `UNUserNotificationCenter` when resets occur.
- **Automated CI/CD Release Packaging**:
  - Unsigned, ready-to-run `.dmg` and `.app.zip` release artifacts created automatically on version tags via GitHub Actions (`package-release.sh`).
  - No developer account or notarization required for self-hosted distribution or local workflows.
- **Robustness & Hardening**:
  - TOCTOU-safe path resolution and path traversal protections.
  - Resilient FSEvents watcher with throttled debouncing (minimum 6s scan interval) and a slow background safety timer to prevent battery drain and runaway CPU usage.

---

## Agent Support & Epistemics

| Agent | Source | Accuracy | Notes |
| --- | --- | --- | --- |
| **Codex** | `~/.codex/sessions/**/rollout-*.jsonl` | **exact** | Authoritative. The server computes `used_percent` and Codex logs it directly. |
| **Claude** | `~/.claude/projects/**/*.jsonl` | **estimated** | Weighted token ledger divided by a calibrated capacity. |
| **Antigravity** | `state.vscdb` (detected) | **none** | Displays quota status only; does not log balances locally. |

Everything shown in the UI represents **remaining quota**. A reading of "73% left" strictly means 73% remains before exhaustion.

### Why Claude Needs Calibration (and Codex Doesn't)

- **Codex**: Reports the exact percentage enforced by OpenAI's servers. There is nothing to calibrate. Headroom parses the latest session log (sorted by modification time, scanning backward for non-null primary limits) to show exact values.
- **Claude Code**: Logs exact per-message token counts but *never* writes the quota limit against which those counts are measured. Headroom computes the numerator from local transcripts and needs to learn the denominator:
  1. Open **Calibrate from Claude's usage page…** from the Headroom menu.
  2. Navigate to Claude → Settings → Usage in your browser.
  3. Enter the session and weekly "% used" figures and configure the weekly reset day and hour.
  4. Calibration also factors in token usage from Claude Desktop agent sessions (`~/Library/Application Support/Claude/local-agent-mode-sessions/**/audit.jsonl`). Note that `claude.ai` and standard Claude desktop usage outside agent mode do not log locally and represent an irreducible blind spot between calibrations.

### Why Antigravity Shows No Quota

Google's Antigravity client stores quota sentinels in `state.vscdb` rather than local percentages, fetching live quota on demand via authenticated API endpoints. Querying those endpoints would require intercepting and using your private OAuth credentials. Headroom strictly adheres to local-only, non-network introspection. Antigravity is detected when installed, and the menu explicitly notes why numbers cannot be displayed.

---

## Installation

### Pre-built Binaries
Download the latest `Headroom.dmg` or `Headroom.app.zip` from [Releases](../../releases).
Drag `Headroom.app` into `/Applications` and launch it.

*Note for macOS Gatekeeper:* If running an unsigned release build, you may need to right-click the app and choose **Open**, or allow it in **System Settings → Privacy & Security**.

---

## Building from Source

### Prerequisites
- macOS 14.0+
- Xcode 15+ or Swift 6.0+ toolchain

### Build Commands

```bash
# Build an unsigned .app bundle in .build/Headroom.app
./scripts/bundle.sh

# Build a drag-to-Applications DMG and zip package (unsigned)
./scripts/package-release.sh

# Build, sign with Developer ID, harden runtime, and notarize (requires Apple Dev cert)
./scripts/release.sh
./scripts/release.sh notarize
```

### Command Line Tools & Diagnostics

Headroom includes built-in command-line diagnostic tools:

```bash
# Probe what providers and logs Headroom can currently see on your disk
./.build/release/Headroom --probe

# Open the calibration sheet directly for UI inspection
./.build/release/Headroom --demo-calibrate

# Open the status menu directly for screenshot or visual check
./.build/release/Headroom --demo-menu
```

---

## Architecture

| File | Role |
| --- | --- |
| `Sources/Headroom/Model/Reading.swift` | The `Reading` enum representing epistemic certainty (`.authoritative`, `.estimated`, `.unavailable`). |
| `Sources/Headroom/Model/PreferencesStore.swift` | Persistent user preferences for toggling providers and hiding short (5-hour) limits. |
| `Sources/Headroom/App/ResetDetector.swift` | Scheduled rollover and abnormal early reset detection with macOS notifications. |
| `Sources/Headroom/App/AppDelegate.swift` | Status item controller, dynamic NSMenu lifecycle, preferences submenus, and calibration modal. |
| `Sources/Headroom/App/Probe.swift` | CLI diagnostic probe (`--probe`) inspecting provider state without launching the GUI. |
| `Sources/Headroom/Providers/CodexProvider.swift` | Reverse-tail chronological parser reading authoritative Codex rollout logs. |
| `Sources/Headroom/Providers/ClaudeProvider.swift` | Incremental ledger aggregating token counts across Claude Code and Desktop agent transcripts. |
| `Sources/Headroom/Providers/Calibration.swift` | Exponential and moving-average model learning Claude capacity limits. |
| `Sources/Headroom/Providers/AntigravityProvider.swift` | Honest detection without invented numbers or unauthorized network requests. |
| `Sources/Headroom/Watch/FileWatcher.swift` | Centralized FSEvents stream monitoring log directories with throttled debouncing. |
| `Sources/Headroom/Render/MenuRowView.swift` | Custom AppKit view rendering animated drain capsules and quota bars. |

---

## Hard-Won Lessons & Engineering Notes

1. **Claude Code JSONL is not chronological**: 86% of records in real-world transcripts arrive out of order (backward jumps up to 21 hours) due to sub-agents, resumed sessions, and compaction. Logs must be read once and tracked by offset.
2. **Resumed sessions continue appending to original folders**: Codex folders are timestamped `YYYY/MM/DD`, but resuming an old session writes into that older directory. Candidate logs must be ordered by modification time, not directory name.
3. **Dual `rate_limits` shapes in Codex**: `limit_id: "codex"` has primary percentages; `limit_id: "premium"` carries credit sentinels. Backward scanning must skip non-primary limits.
4. **Expired deadlines must not display stale percentages**: An expired `resetsAt` timestamp causes a stale 100% reading to falsely indicate blocking. Reset state must rollover cleanly.
5. **Session windows vs. calendar windows**: Claude uses a 5-hour sliding session window from first interaction, alongside a weekly calendar window resetting at a designated day/time.
6. **Throttling is mandatory**: File watchers triggering on busy CLI agents can consume 15%+ CPU if only debounced. A minimum 6-second scan interval floor keeps background consumption near 0%.
7. **AppKit menu auto-enabling**: Submenu and custom view rows become greyed out unless `menu.autoenablesItems = false`.
8. **App Sandbox is incompatible**: A sandboxed macOS app cannot read arbitrary directories like `~/.claude` or `~/.codex` without recurring file-picker permissions. Headroom operates outside the sandbox.

---

## Known Limitations

- **Estimated Claude quota**: Anthropic does not document exact token weightings across prompt cache hits, cache creations, and output tokens. Estimates may drift over time.
- **claude.ai / web blind spots**: Web and non-agent mobile/desktop usage share account limits but do not emit local logs.
- **Undocumented log formats**: Changes in provider log formats can degrade readings to "unavailable" until parsers are updated.
- **No Official Support**: As noted above, this fork is provided as-is without support.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
Original work Copyright (c) 2026 Vinay Bhaskarla.
Fork contributions Copyright (c) 2026 Christopher Wawak and contributors.
