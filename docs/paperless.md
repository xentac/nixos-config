# Paperless: how we use it

paperless-ngx on alba-nix (`modules/server/paperless.nix`), at
`https://paperless.stalk-darter.ts.net` (tailnet only). Storage and
backups: `docs/adr/0009`. Setup steps: `docs/alba-nix.md`, "Paperless".

The goal is that filing a document is one step and finding it is a
search. Everything is OCR'd, so even an unreviewed document can be found
by its text; review is about *labels* and *expiry dates*, not about
making documents findable.

## Getting documents in

- **Paper:** photograph it with the phone app (Paperless Mobile on
  Android, Swift Paperless on iOS) over Tailscale. One page per photo;
  the app combines multi-page documents.
- **Digital:** forward it to the GMX paperless address, or have bills
  sent there directly (change the delivery address, or a Gmail filter
  in the main account auto-forwards). The mail rule imports PDF and
  image attachments and files the email away.
- **One-offs:** drag onto the web UI.
- No scanner aboard, so no watched folder. If one shows up, add a
  consume folder then.

## Labelling

Every new document gets the `inbox` tag. Review = open the Inbox saved
view, check or fix correspondent and document type, set `expires` if it
applies, remove `inbox`. Corrections train the auto-matching, so after a
month or two most documents arrive already labelled.

- **Correspondent:** who sent it. Let these grow naturally.
- **Document type:** a small, fixed set. Starter list:
  Invoice, Receipt, Statement, Policy, Contract, Registration / Permit,
  Certificate, Tax, Medical, Letter, Manual. Add one only when a
  document really fits none of them.
- **Tags:** few. Starters: `inbox` (inbox tag), `boat`, `vehicle`,
  `tax-<year>` for anything the accountant will want.
- **`expires` (date custom field):** set on documents with a real-world
  deadline: insurance, boat registration, cruising permits, passports,
  warranties. When a renewal arrives, clear `expires` on the old one.
- **Saved views:** Inbox (has `inbox`, oldest first); Expiring (has
  `expires` within 90 days, sorted by it).

Two household accounts, everything shared: create both in the UI and
give both the same group, used as the default owner/permissions so
nobody manages permissions per upload.

## Alerting (deferred)

Review is meant to be prompted by alerts rather than a calendar habit,
but alerting on alba-nix is being designed separately (as of
2026-10-19 Grafana has no contact points or rules). What paperless
should alert on, and how each can be measured:

| Alert | Condition | Source |
| --- | --- | --- |
| Inbox needs review | oldest `inbox` document older than 14 days | API: `GET /api/documents/?is_in_inbox=true&ordering=added&page_size=1&fields=id,added` (`count` and `results[0].added`) |
| Document expiring | an `expires` date within the next 30 days | API: field id from `/api/custom_fields/?name__iexact=expires`, then `/api/documents/?custom_field_query=["expires","gte","<today>"]&fields=id,title,custom_fields` |
| Mail fetch failing | IMAP fetch keeps erroring (GMX turned IMAP off, app password revoked, account idled out) | VictoriaLogs: `` _SYSTEMD_UNIT:paperless-task-queue.service ~`\[(ERROR\|CRITICAL)\] \[paperless[._]mail` `` (checks run every 10 min; >12 in 6 h ≈ 2 h of failure) |
| alba-nix disk filling | root filesystem > 85% | `node_filesystem_avail_bytes{mountpoint="/"}` |
| Nightly export failing | `paperless-export.service` failed | node_exporter systemd collector |

Notes for whoever builds it:

- The API calls need a token. Use a dedicated view-only `metrics` user
  (view permission on documents, tags, custom fields), not an admin's.
- The inbox metric should be emitted even when the inbox is empty (age
  0), so "no data" means the collector broke, which is worth alerting on
  in its own right: a silent pipeline is the failure this exists to catch.
- Expired documents stay in paperless forever, so the expiry check must
  only look at dates from today onward, or old passports alert
  permanently.
- Paperless logs to the console in `[time] [LEVEL] [logger] message`
  form; mail errors come from the `paperless_mail` and
  `paperless.mail.tasks` loggers in the celery worker unit. The query
  above was checked for syntax against this VictoriaLogs, not yet
  against real paperless errors.
- GMX free accounts can be restricted after ~6 months without a web
  login, and it's unclear whether IMAP counts. Until the mail alert
  exists, log into GMX's web UI every few months.
