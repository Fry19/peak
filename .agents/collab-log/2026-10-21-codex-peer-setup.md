# Peer workflow setup (Codex lead)

- Initial installation adapted Approach's collaboration guidance and helpers to Peak. No Peak peer rules existed when this task began.
- consult attempt · Claude · not started · changed outcome: y — automatic approval review rejected the external CLI call because provider sharing was not explicitly authorized. No peer reply was received. Clarified that repository guidance does not grant external sharing permissions.
- Local checks: snapshot handoff preserved staged, unstaged, deleted, and untracked fixture files and the lead's index; owned-path exports excluded unrelated edits; cleanup refused unapplied changes; simulator locks rejected collisions and non-owner release; local mock CLI calls checked read-only start/resume, review mode, and error reporting. These checks did not contact a peer provider.
- Limits: live cross-provider communication and simulator build/install flows were not exercised. No app or UI behavior changed.

Lesson: importing collaboration guidance does not itself satisfy the active environment's approval requirements for sending repository contents to another provider.
