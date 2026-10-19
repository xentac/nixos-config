# 0009 — Paperless documents on local disk, exported nightly to vault

Date: 2026-10-19. Status: accepted.

## Context

paperless-ngx keeps a SQLite database, search index and classifier (its
data dir) and the documents themselves (its media dir: originals, OCR'd
archive PDFs, thumbnails). The data dir can't live on vault: SQLite over
SMB needs byte-range locks, and calibre-web only gets away with `nobrl`
because its mount is read-only. The natural instinct was to put the
documents on the NAS anyway, with only the DB local.

Scanned and emailed documents are irreplaceable, unlike the media
libraries, which `backups.nix` deliberately leaves to vault.

## Decision

Both data and media stay on alba-nix's local btrfs under
`/var/lib/paperless`, covered by the nightly snapshot→restic→B2 job like
all other service state. A nightly `document_exporter` run mirrors every
document (readable file names, plus `manifest.json`) to a dedicated vault
share, `paperless`, as a browsable second copy. Synology snapshots on
that share are the undo for the mirror's deletions.

## Consequences

- One consistent backup: the DB and the files it points at are captured
  by the same read-only snapshot. A split layout would restore a DB
  snapshot against a document folder from a different moment, and leave
  the documents' only offsite copy to whatever backs up vault.
- Paperless doesn't depend on vault (same rule as 0004): a NAS outage
  only fails that night's export.
- Documents use alba-nix's disk (127 GB free at the time; years of
  household paperwork is a few GB). Revisit if it grows enough to matter.
- The export stops paperless for its run (as the stock exporter does),
  so it's scheduled at night.
