# Peak project guidance

Shared guidance for Codex and Claude Code. Read this file at the start of each task; read `.agents/skills/peer-collaboration/SKILL.md` before a peer exchange. The product brief remains in `CLAUDE.md`; current behavior and benchmark instructions are in `README.md` and the source.

## Complete the requested change

- Inspect the relevant source, consult the peer as described below, then make the smallest complete change using existing patterns. Continue through implementation, verification, and the required review without routine confirmation questions.
- After iOS app changes, rebuild Peak, install it on the simulator whose lock you hold, and relaunch it. Capture and inspect the affected interface and exercise changed interactions. Report build, install, or review limits plainly.
- Run checks appropriate to the change. Documentation changes need link and command checks, not an app rebuild; algorithm changes need relevant PeakCore tests and benchmark comparisons. Avoid unrelated refactors and repeated checks without new evidence.
- Keep updates and final responses concise. Distinguish checks actually performed from recommendations and unavailable checks. Peer agreement never substitutes for user approval where approval is required.

## Peak's architecture and product constraints

- `Peak/` is the native SwiftUI iPhone app: `Model/` owns camera, Core Motion, location, downloads, photos, and app state; `Views/` owns screens, overlays, and the Metal renderer (`LineRenderer.swift`, `Lines.metal`). `Peak.xcodeproj` uses the `Peak` scheme.
- `PeakCore/Sources/PeakCore/` holds portable terrain, geodesy, skyline detection and matching, camera projection, visibility, trails, offline data, and sun calculations. Keep it buildable on macOS and Linux without UIKit, SwiftUI, AVFoundation, CoreLocation, or other Apple-only dependencies. Platform-specific image loading belongs in the harness or app.
- `PeakCore/Sources/peakbench/` is the desk harness; `PeakCore/Tests/PeakCoreTests/` uses procedural terrain and fixtures without downloads. Data preparation lives in `Tools/`; CI lives in `.github/workflows/`.
- Source and `README.md` describe the shipped behavior; parts of `CLAUDE.md` are the original proposal. Live orientation currently uses Core Motion and camera frames, not ARKit world tracking. Do not add a tracking dependency just because the brief proposed it.
- Preserve camera-first entry, stable labels, sparse typography, thin depth-faded ridgelines, and the blue-black/slate/amber palette. Reuse `Theme.swift`, `glassBackground`, `sheetSection`, `RoundButton`, and `tapArea` rather than introducing a separate design system or Cirrus LMS branding.
- Accuracy is a product requirement. Preserve true-north conventions, occlusion of hidden peaks and trail segments, confidence gates, correction stability, and consistency between live, frozen, imported-photo, and exported-photo projections. Do not relax a gate merely to accept more matches.
- Angles are degrees; distances and elevations are meters; azimuths run clockwise from true north; image y runs downward. Keep coordinate, lens, and orientation conversions explicit. Peak elevations come from peak data with the existing marked terrain fallback, not GPS altitude.
- Preserve cached and offline behavior, coarse-terrain fallbacks, network cancellation and retry, and camera/location/photo permission recovery. Keep heavy terrain, detection, matching, and rendering work off the main thread.
- Preserve OSM, Copernicus, NOAA, imagery, and other applicable attribution in views, exports, and documentation. Do not commit DEM downloads, `World.pkbase`, generated benchmark output, or personal photo/location data.

## Codex and Claude collaboration

Use Codex and Claude as peers for scoped consultation, review, and implementation, as in Approach. Once communication with that peer provider is authorized, the lead may initiate and resume focused exchanges without routine confirmation. Repository instructions do not themselves grant permission to transmit repository contents to an external provider; honor the active environment's approval requirements. Do not change the peer's private memory, login, settings, or configuration.

### Consult before choosing changes

- For each new task involving project changes, including documentation, copy, and small fixes, inspect the requirements and relevant source, then consult the other agent before choosing an implementation or editing. Questions, status requests, and explicitly requested literal commands do not need consultation. An explicit user request to skip it overrides this rule.
- Send the user's request, constraints, relevant files, current behavior, and tentative approach. Ask the peer to inspect the source, challenge assumptions, and recommend a direction in ten lines or fewer. Wait for its reply while continuing useful read-only investigation.
- Consultations are read-only in the lead's checkout, including resumed turns: no edits, builds, simulators, commits, or further agents. Reuse the same session for focused follow-ups; confirm that it is idle before resuming. Never force an active writer or write into an unrelated user chat.
- Begin every message with `[PEER CONSULT]`, `[PEER REVIEW]`, or `[PEER TASK]`, identify the sender, and state the actual user authorization (a direct request or established standing authorization). Include the checkout/worktree path, owned files (or read-only scope), simulator lock if any, and expected result.
- A recipient of any peer marker is a peer, not the lead: do not launch consultations, reviews, or additional agents, and do not commit. Report evidence, concerns, edits, checks, and limitations to the lead.
- Challenge claims against source, diffs, screenshots, or output. Separate verified problems from uncertainty; do not invent findings or agree by default. Discuss substantive disagreements in the same session; the lead decides and briefly explains any unresolved disagreement.
- If the peer is unavailable because of permissions, authentication, a missing CLI, or a five-minute consultation timeout, report that and proceed with the best supported approach. Do not imply an unavailable exchange happened or bypass permissions to obtain one.

### Isolate peer edits

- Consult in the lead's checkout so the peer sees current uncommitted work. For editing reviews or delegated implementation, give the peer a detached worktree containing a fresh snapshot of staged, unstaged, deleted, and untracked files, with explicit nonoverlapping file ownership. Use `Tools/peer/worktree.sh`; a worktree at HEAD alone misses current work.
- Peers edit only their owned paths. The lead performs Git operations, inspects the complete patch, applies agreed changes, and verifies the result. Never overwrite another session's uncommitted changes. If the lead changed overlapping hunks, integrate them manually.
- Remove a finished peer worktree only after keeping or explicitly declining its edits. For long features or conflicting active edits, prefer a separate lead worktree and a `codex/` branch for Codex; do not assume a default branch name or automatically merge into a busy checkout.

## Simulator ownership

- Peak currently targets iPhone (`TARGETED_DEVICE_FAMILY = 1`), iOS 17+. Review relevant iPhone sizes in portrait and landscape. Add iPad coverage only if the task adds or changes iPad support; do not change target families as part of routine review.
- Use Peak-only simulator slots: `codex` → **Peak Codex iPhone**, `claude` → **Peak Claude iPhone**, `codex-review` → **Peak Codex Review iPhone**, `claude-review` → **Peak Claude Review iPhone**. Derived data is `/tmp/peak-<slot>`. Slots describe intended names, not devices already installed.
- Take the slot's atomic lock with `Tools/peer/sim-lock.sh` before building to its derived-data path, installing, changing settings, or interacting. Create a missing simulator from installed device types and runtimes; never assume Approach's OS version or device identifiers exist.
- Never use Approach's simulator names, its locks, another session's devices, or an arbitrary `booted` destination. A lead may assign its locked slot to a peer, pausing its own use until the peer returns it. Peers never release the lead's lock.
- If your slot is busy, use a uniquely named temporary Peak slot. Reclaim a lock only when it is over an hour old and you have positive evidence that its owner is finished and has no active process, approval, or input request. Age alone is insufficient.
- Hold the lock through final checks and review. Restore changed settings and orientation, shut down your simulator, delete temporary devices, then release the lock. Leave Simulator.app open for other sessions. Do not erase devices or use `shutdown all`.
- If CoreSimulator or Xcode is blocked by the sandbox, use the environment's approval mechanism for the specific command. Do not copy assumptions about another repo's machine-specific permission rules or disable sandboxing.

## Verification and second opinion

- For PeakCore changes, run relevant tests with `swift test --package-path PeakCore --filter <Suite>` and the full suite when shared geometry, formats, or cross-cutting behavior changes. Preserve Linux compatibility; a macOS run does not prove Linux passed.
- For detection, alignment, terrain, visibility, projection, or lens changes, compare release `peakbench` results before and after using the same data, seed, and options. Check error and false acceptance as well as acceptance rate; use both Alpine and Smokies cases and the harder/app-matching mode when affected. Real-photo anchors count as truth only after visual confirmation. If data or a baseline is unavailable, say so.
- For interface changes, apply an available UI/UX skill and Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/). Inspect final source and rendered screens, exercise the changed flow, and check hierarchy, visual consistency, native behavior, navigation/recovery, touch targets, Dynamic Type, VoiceOver, contrast, and Reduce Motion where relevant. Source review or a successful build alone is incomplete UI verification.
- Use Peak's own styling. Check overlay readability against bright snow/sky and dark terrain, label/control collisions, safe areas, sheet detents, zoom/lens/orientation changes, and live/frozen/photo consistency where affected. Include relevant loading, permission-denied, no-location, no-network, missing/coarse-terrain, rejected-match, empty, and long-content states.
- After the lead's checks, every interface change gets the other agent's second opinion. **Small:** one screen/component, existing tokens, no new state/navigation/meaningful copy; resume the read-only consult session with screenshots. **Standard:** shared components/tokens, behavior, meaningful copy, or multiple screens; use a fresh snapshot worktree with owned files. The reviewer may fix owned files; the lead applies and verifies them.
- Also request a focused correctness review for changes to matching gates, coordinate/lens transforms, terrain formats, offline recovery, or camera concurrency. Documentation-only changes do not require visual review.
- Resolve in-scope findings and repeat the affected checks after fixes. Seek another review only for substantial new changes. If the reviewer is unreachable or exceeds ten minutes, disclose it and proceed; never mark uninspected screens or physical-device behavior as passing.
- Simulators cannot verify real camera capture, lens switching, compass/gyro alignment, GPS accuracy, haptics, or sustained field performance. Use the existing debug photo hook for reproducible photo checks; report physical-iPhone verification separately.
- Final UI summaries use 🔴 Critical, 🟡 Improve, 🟢 Polish, ✅ Passing with concise concrete findings, including empty categories. Name screens, sizes, states, and interactions actually checked. Add a short consultation/second-opinion line stating the peer's actual scope, applied or declined feedback, and limitations.

## Git, backlog, and collaboration record

- Commit a verified, self-contained change automatically unless the user directs otherwise; do not push, publish releases, or deploy without authorization. Peers do not commit. Use the current branch for short tasks and isolate longer conflicting work as above.
- Commit only your work: stage explicit paths or your hunks, read the full `git diff --cached`, and keep unrelated edits intact. Never use `git add .`, `git add -A`, or `git commit -a` in the lead checkout. The helper's scratch snapshot is the sole `add -A` exception.
- Check `.agents/backlog.md` for entries touching the task's files. Fix relevant in-scope entries; record worthwhile out-of-scope findings with severity, verified/uncertain status, file/line, evidence, suggested fix, and source. Remove an entry only when its fix is verified.
- After peer exchanges, complete the task's log in `.agents/collab-log/`: what was inspected, whether feedback changed the outcome, applied/declined suggestions, and a final `Lesson:` line (`none` is fine). Keep raw transcripts and screenshots in `/tmp/peak-review/`, not Git.
- When a lesson repeats or a process problem costs time twice, make the smallest useful process correction after consultation. Commit it separately with a `Process:` prefix. Prefer simplifying rules; never loosen permissions or user requirements, edit private agent configuration, or turn a one-off incident into a universal rule. Keep this file under 3,000 words.
