---
name: peer-collaboration
description: >-
  Run Peak's Codex/Claude peer consultations, scoped implementation and reviews,
  snapshot worktree handoffs, simulator locks, and collaboration records.
  Read before a peer exchange; shared project rules live in AGENTS.md.
---

# Peak peer collaboration

Read `AGENTS.md` for requirements. Run the helpers in `Tools/peer/` from the lead checkout root. All scratch paths use `peak-` so Approach sessions remain separate. Use a unique lowercase, hyphenated feature slug per task, including a short session suffix if the same feature is active elsewhere.

## Consult and resume

Write the prompt to a file outside the repo, then invoke:

```sh
Tools/peer/ask.sh claude consult <feature> "$PWD" /tmp/peak-consult.md
Tools/peer/ask.sh codex consult <feature> "$PWD" /tmp/peak-consult.md
Tools/peer/ask.sh resume <feature> <session-id> /tmp/peak-followup.md [screenshot.png ...]
```

Choose the other agent, not both. The helper saves the prompt, response, errors, session ID, and exchange log. Use a tool call that yields while the process runs so the lead can continue read-only investigation and keep the user informed. Stop a stalled consultation at five minutes or a review at ten; preserve diagnostics, report the limit, and continue as `AGENTS.md` directs.

Consult prompt:

```text
[PEER CONSULT] From <Codex|Claude>. Authorization: <actual user request or established standing authorization>.
Read-only in <absolute lead checkout>; owned files: none. No edits, builds,
simulators, Git writes, or additional agents.
User request: <request and constraints>
Current behavior and relevant files: <paths/lines and observed behavior>
Tentative approach or alternatives: <proposal>
Inspect the current source, challenge assumptions, and recommend a direction
in ten lines or fewer. Separate verified problems from uncertainty.
```

Confirm a session is idle before resuming it: the prior helper process exited with a complete reply and there is no writer, approval, or input request pending. Resume only sessions created for this task; do not inject into an unrelated user session. If Codex reports an active writer, stop rather than retrying or forcing it.

`ask.sh` defaults to `codex` on PATH (with the desktop bundled CLI as fallback) and `claude` on PATH (with `~/.local/bin/claude` as fallback). `PEAK_CODEX_BIN` and `PEAK_CLAUDE_BIN` may point to an installed executable; do not change private agent configuration. A missing executable, login error, or permission denial is an unavailable peer, not a reason to disable permissions.

Codex consultations use the read-only sandbox; review/task sessions use workspace-write. Resume explicitly reapplies that mode because CLI resume does not preserve it automatically. Claude consultations expose only read tools and allowlisted read-only Git commands; review/tasks use normal permission checks with edit acceptance, never permission bypass. CLI invocation may need a specific network/login approval in the current environment. Grant no broader access than the scoped task needs.

## Editing worktrees and handoff

For `[PEER TASK]` or an editing Standard review:

```sh
Tools/peer/worktree.sh create codex claude <feature> Peak/Views/SomeView.swift
Tools/peer/ask.sh claude review <feature> /tmp/peak-worktrees/claude-<feature> /tmp/peak-review.md [screenshot.png ...]
Tools/peer/worktree.sh export codex claude <feature>
git apply --check /tmp/peak-review/codex-<feature>/fixes-claude.patch
git apply /tmp/peak-review/codex-<feature>/fixes-claude.patch
Tools/peer/worktree.sh remove codex claude <feature>
```

Reverse lead/peer names for a Claude lead. Use `task` instead of `review` for delegated implementation. Assign different files to each writer; never assign overlapping paths. State worktree path, owned files, expected behavior, allowed checks, and any assigned simulator slot in the prompt. Peers must not commit, launch other peers, change configuration, or edit outside ownership.

The helper makes a detached snapshot of the lead's tracked and nonignored untracked files, including current changes and deletions, before the peer starts. Ignored resources are excluded: `World.pkbase`, DEM tiles, build products, and photo fixtures must be explicitly provided when needed; never add them to Git. Snapshotting stages/commits only in the scratch worktree; the lead's index and working files remain intact. Avoid hooks on this scratch snapshot.

Export stages only owned paths in the peer worktree, writes their binary patch, and reports edits outside ownership. **Read the patch before applying it.** If it no longer applies, integrate the agreed hunks manually without overwriting current work. Rebuild or rerun relevant checks after integration. The remove command refuses when peer changes differ from the lead checkout; inspect and preserve needed changes before using `--force` to discard declined edits.

For a longer lead feature, choose a suitable base after inspecting current work; use a `codex/<feature>` branch for Codex. Do not assume `master` or `main`, silently exclude needed uncommitted work, or merge over an active checkout. Use the platform's managed-worktree tools when appropriate; scratch peer snapshots are handled by this helper.

## Simulator slots

```sh
Tools/peer/sim-lock.sh status
Tools/peer/sim-lock.sh take codex codex <session-id> <feature>
Tools/peer/sim-lock.sh release codex <session-id>
```

Slots: `codex`, `claude`, `codex-review`, `claude-review`, or `<codex|claude>-temp-<unique-feature>`. Each maps to one Peak-named iPhone and `/tmp/peak-<slot>` derived data. Locks are atomic directories under `/tmp/peak-sim-lock-<slot>`. Another session cannot release your lock. The helper manages locks only; it never creates, boots, or deletes simulators.

Before creating a missing device, inspect installed choices:

```sh
xcrun simctl list devices available
xcrun simctl list devicetypes
xcrun simctl list runtimes
```

Create the exact name printed by `take`, using an installed iPhone device type and iOS runtime compatible with Peak. Do not reuse Approach's names. If occupied, choose a unique temporary slot; tell the user if a temporary device was needed. Add a second temporary slot when a second phone size is relevant. Do not infer stale ownership from age or build timestamps; follow `AGENTS.md` before manually reclaiming a lock.

For the `codex` slot, run these commands separately from the repo/worktree root (adapt the exact name/path for other slots):

```sh
xcrun simctl boot "Peak Codex iPhone"
xcrun simctl bootstatus "Peak Codex iPhone" -b
xcodebuild -project Peak.xcodeproj -scheme Peak -configuration Debug -destination 'platform=iOS Simulator,name=Peak Codex iPhone' -derivedDataPath /tmp/peak-codex CODE_SIGNING_ALLOWED=NO build
xcrun simctl install "Peak Codex iPhone" /tmp/peak-codex/Build/Products/Debug-iphonesimulator/Peak.app
xcrun simctl launch --terminate-running-process "Peak Codex iPhone" com.freiburger.peak
xcrun simctl io "Peak Codex iPhone" screenshot /tmp/peak-review/<lead>-<feature>/camera-portrait.png
```

Skip boot if already booted. Use the built app's actual bundle ID (`plutil -extract CFBundleIdentifier raw -o - /tmp/peak-codex/Build/Products/Debug-iphonesimulator/Peak.app/Info.plist`) if it differs from the launch example. Create the screenshot directory first. If names are ambiguous across runtimes, use the owned device's UDID. Prefer purpose-built simulator/UI tools available in the current session; verify a tap caused the expected change. Shell permission rules are environment-specific; request scoped approval if needed rather than changing private rules.

Before releasing: restore settings/orientation, shut down the owned device with `xcrun simctl shutdown "Peak Codex iPhone"`, and delete only temporary devices you created. Never run `shutdown all`, erase a device, or use an arbitrary `booted` destination. A peer borrowing the lead's slot returns it without releasing the lock.

## Evidence for Peak reviews

Store screenshots and benchmark output under `/tmp/peak-review/<lead>-<feature>/`. Maintain a `manifest.md` recording each artifact's source snapshot/commit, device and OS, screen size, orientation, text size, state, fixture/data source, and interactions actually tested. Identify which checks need a physical phone.

- **Small UI:** affected states on the primary iPhone, changed orientations, and a neighboring screen/component using the same pattern.
- **Standard UI:** affected screens/states on a compact and a larger iPhone, portrait and landscape where supported, larger Dynamic Type, and relevant empty/loading/error/offline/permission states. Cover only states pertinent to the change; list omitted relevant checks as limits.
- **Camera/overlay/photo:** bright and dark backgrounds; label/control overlap; frozen/live transitions; zoom and orientation; photo metadata/manual alignment; export uprightness and readability, as affected. `Peak/Model/PhotoTestHook.swift` accepts `PEAK_TEST_PHOTO` in Debug, opens the fixture without starting the camera, and writes labeled outputs/report to the app's Documents directory. Pass `SIMCTL_CHILD_PEAK_TEST_PHOTO` when launching via simctl, using a readable fixture path and the active environment's command/approval rules.
- **Algorithms:** relevant procedural tests plus release harness comparisons with identical fixtures, seeds, and options. Use `swift run --package-path PeakCore -c release peakbench help` for supported commands and `README.md`/CI for current benchmark cases. Missing DEM data or independently confirmed real-photo anchors is a stated limit, never fabricated evidence.
- **Device only:** live camera/lens behavior, compass/gyro alignment, GPS accuracy, haptics, heat/battery, and sustained frame rate cannot be certified by simulator or synthetic photo results.

Review prompt:

```text
[PEER REVIEW] From <lead>. Authorization: <actual user request or established standing authorization>.
Tier: <Small|Standard|correctness>. Change and user goal: <summary>.
Checkout/worktree: <absolute path>. Owned files: <none for read-only, or list>.
No additional agents or commits. Simulator: <none, or owned slot/UDID and
derived-data path; lead has paused use>. Artifacts: <manifest and paths>.
Interactions and checks already performed: <actual evidence>.
Inspect source, diff, and supplied evidence. For UI, judge against Apple's HIG,
Peak's camera-first minimal design, and Theme.swift/shared components. Check
readability over terrain/sky/snow, stability and occlusion, safe areas, sheets,
orientation, touch targets, accessibility, and recovery states where affected.
For algorithms, challenge coordinate conventions, gates, error/acceptance tradeoffs,
offline behavior, concurrency, and whether fixtures provide independent truth.
Return up to six actionable findings with severity, verified/uncertain status,
file/line or artifact, user impact, and a concrete fix. Small/read-only: recommend
fixes. Standard/task: fix only owned files in scope, then report exactly what
changed and what you checked. Identify the weakest remaining point, or say no
actionable weakness was found within the inspected scope. List out-of-scope
findings and verification limits separately; do not imply unperformed checks passed.
```

Resolve disagreements in the same peer session; the lead chooses and records why. Apply agreed fixes and repeat affected checks on the integrated result. Source-only feedback is a correctness review, not a completed visual review.

## Backlog and task log

Use `.agents/backlog.md` for out-of-scope findings, one bullet each:

```text
- 🟡 verified · YYYY-MM-DD · <peer/task> · path/File.swift:123 — problem — evidence — suggested fix
```

Use 🔴 Critical, 🟡 Improve, or 🟢 Polish, and `verified` or `uncertain`. Check entries for files in scope before starting; delete an entry only when fixed and verified.

`ask.sh` appends exchanges to `.agents/collab-log/<date>-<lead>-<feature>.md`. Replace `changed outcome: ?` with `y` or `n` and what changed or was confirmed. Summarize inspected scope, applied/declined feedback, and limits; end with `Lesson: <specific lesson>` or `Lesson: none`. Dates default to America/New_York for this workspace; set `PEAK_LOG_TZ` if the user's timezone changes. Commit the concise log with the task; raw prompts, sessions, responses, screenshots, and personal photos stay outside Git. For a failed exchange, record the failure honestly rather than leaving an apparent successful consultation.
