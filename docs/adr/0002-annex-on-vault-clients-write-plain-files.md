# 0002 — git-annex runs on vault; clients write plain files over SMB

Date: 2026-09-13. Status: accepted.

## Context

The media libraries are git-annex repos (deliberately: a disconnected
download→sync cycle, and write-locked files once annexed). On baxter,
downloads landed in a local clone and git-annex synced them to vault.
With the stack moving to alba-nix and data accessed over SMB, someone
still has to run `git annex add`/`sync` for new imports — and locked
working trees mean annexed files are symlinks, which SMB clients can't
manipulate as such.

## Decision

Vault owns the annex, exclusively. The working trees on vault
(`media/Videos`, the dedicated `adult` share) stay **locked**; a
scheduled job on vault (DSM Task Scheduler, not the assistant daemon —
it would hold inotify watches and resident memory on a small NAS) runs
`git annex add` + `git annex sync` periodically. alba-nix and every
other client are completely git-annex-ignorant: they read annexed files
as the read-only regular files Synology's SMB presents, and write new
imports as plain files that the next scheduled run annexes.

The adult repo moves out of xentac's home share into a dedicated share
so the VM never mounts personal credentials or directories.

## Consequences

- Sonarr/radarr imports and upgrades work with no annex awareness:
  new file = plain write; upgrade = delete symlink (annex-safe: the
  object stays in `.git/annex/objects` until vault prunes) + plain write.
- A file is unprotected between import and the next annex run — bounded
  by the job interval (hourly).
- Write-locking after annexing is a feature ("safer than sorrier"), not
  a bug: nothing on the VM is expected to modify an annexed file.
- Requires git-annex runnable on DSM (community package or a small
  container on vault) — an appliance-side manual setup step.
