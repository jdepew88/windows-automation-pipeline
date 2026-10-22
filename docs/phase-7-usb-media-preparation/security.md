# Security model of the assistant

The assistant is treated as a privileged disk utility.

| Threat | Control |
|---|---|
| Wrong disk | eligibility rules (`disk-safety.md`); no default disk; typed per-disk confirmation code |
| Disk substitution / renumbering | fingerprint re-check before every write phase and immediately before erasing; refused if the number changed |
| Outdated selection | plans carry a random id; a remembered disk is never reused; an interrupted erase needs a new plan |
| Malicious package ZIP | entry names normalised and checked (no rooted, drive, `..`, reserved characters), only the answer file and `WindowsDeployment/` allowed, size and count limits, extracted into a new staging folder, every file hashed against the manifest, unlisted files refused, answer file hash and embedded scripts checked, answer file of another package detected |
| Tampered manifest | strict format/version/scope/package-id checks; the answer file must embed exactly the manifest's scripts and the same package id |
| Untrusted ISO | mounted read-only; signatures of setup.exe and the boot loader; optional SHA-256; metadata parsed without DTDs; nothing on it is run |
| Malicious backup | validated by the Phase 6 validator shipped with the assistant (never from a package or backup) against the pinned manifest hash; folder name must match; ZIP backups extracted safely; only listed files copied; re-validated on the drive |
| Another customer's backup | refused: name and manifest hash must match the deployment |
| Links / reparse points | refused inside package folders and backups |
| Arbitrary script execution | nothing from a package, ISO or backup is executed or dot-sourced; JSON is data only |
| Command injection | cmdlets with typed parameters; no command strings, no `Invoke-Expression` |
| Unsafe temp paths | staging under `%LOCALAPPDATA%\WindowsDeploymentBuilder\media\staging\<guid>`, removed after use; a user's source backup folder is never removed |
| Privilege misuse | only Create elevates; the elevated process re-validates every input |
| Credential leakage | answer file contents are never printed or logged; reports contain identifiers, hashes and paths only; backup contents never reach logs or reports (tested) |
| Network | none, except the optional read-only release-page check (`-CheckOnline`); nothing is uploaded |
| Boot security | Secure Boot untouched; boot files copied unchanged; no BCD or boot-sector changes |
| False success | journal + verification; interrupted/cancelled = Incomplete; boot never claimed |
