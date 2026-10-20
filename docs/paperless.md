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
- **Digital:** forward it to the paperless Gmail address, or have bills
  sent there directly (change the delivery address, or a Gmail filter
  in the main account auto-forwards). The mail rule imports PDF and
  image attachments and files the email away.
- **One-offs:** drag onto the web UI.
- No scanner aboard, so no watched folder. If one shows up, add a
  consume folder then.

## What doesn't go in

Anything the finance ledger's ingest pipeline already archives
(github.com/xentac/beancount, PDFs under `finances/data/Documents/`,
filed by account): paystubs, and bank, brokerage, card and mortgage
statements. The ledger is their home; a second copy here would only
drift. Everything else goes here, including tax forms unless the
ingest starts filing those too.

If searching statements' text ever becomes useful, have the ingest
pipeline upload a copy here rather than filing them twice by hand.

## Labelling

Every new document gets the `inbox` tag. Review = open the Inbox saved
view, check or fix correspondent and document type, set `expires` if it
applies, remove `inbox`. Corrections train the auto-matching, so after a
month or two most documents arrive already labelled.

The three axes don't overlap: **type** is what the document *is*,
**correspondent** is who issued or sent it, **tags** are what or whom it's
about. A marine mechanic's bill is an Invoice, from the shop, tagged
`boat`; never a "Boat" type.

- **Correspondent:** the issuer or sender, never the person a document
  is about: a passport's correspondent is the passport office. Let these
  grow naturally.
- **Document type:** a small, fixed set. Add one only when a document
  really fits none of them, and keep the list around 10–12.

  | Type | What it is | Examples |
  | --- | --- | --- |
  | Invoice | a bill: money owed | haul-out, utilities, mechanic |
  | Receipt | proof of payment | fuel dock, chandlery, online orders |
  | Statement | periodic account summary, for accounts the ledger doesn't ingest | a loan or account outside the ledger |
  | Policy | insurance terms and certificates of coverage | boat, health, travel, vehicle |
  | Contract | an agreement both sides signed | slip agreement, purchase agreement, lease |
  | ID / Permit | something that authorizes a person or the boat | passports, licences, boat registration, cruising permits, clearance papers |
  | Certificate | proof of a fact or qualification | survey, radio licence, courses, birth/marriage |
  | Tax form | official tax paperwork | returns, slips, assessments |
  | Medical record | clinical paperwork (bills are Invoices) | results, prescriptions, vaccinations |
  | Correspondence | letters and notices that fit nothing else | official letters, notices |
  | Manual | product documentation | engine and equipment manuals, warranty cards |

- **Tags:** few. Starters: `inbox` (inbox tag), `boat`, `vehicle`,
  `medical`, `tax-<year>` for anything supporting that year's return.
- **Person tags:** one per household member (e.g. `jason`), on
  documents that belong to a specific person: IDs, medical records,
  certificates. Not on household bills or boat papers. Ownership is
  for permissions (everything is shared), not for who a document is
  about.
- **Created date:** paperless's built-in document date, the date *on*
  the document. For IDs, permits and policies that's the issue date; fix
  it in review if the OCR guess is wrong.
- **`expires` (date custom field):** set on documents with a real-world
  deadline: insurance, boat registration, cruising permits, passports,
  warranties. Keep it on every version, old ones included.
- **`replaced by` (document link custom field):** when a renewal
  arrives, set it on the *old* document, pointing at the new one. Links
  are bidirectional, so the new one shows what it replaced, and
  successive renewals form a chain. A document with `replaced by` set is
  history, not something to act on.
- **Saved views:** Inbox (has `inbox`, oldest first); Expiring (has
  `expires` within 90 days, `replaced by` not set, sorted by `expires`).

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
| Document expiring | an `expires` date within the next 30 days, `replaced by` unset | API: field id from `/api/custom_fields/?name__iexact=expires`, then `/api/documents/?custom_field_query=["expires","gte","<today>"]&fields=id,title,custom_fields` |
| Mail fetch failing | IMAP fetch keeps erroring (app password revoked, 2-Step Verification turned off, account locked) | VictoriaLogs: `` _SYSTEMD_UNIT:paperless-task-queue.service ~`\[(ERROR\|CRITICAL)\] \[paperless[._]mail` `` (checks run every 10 min; >12 in 6 h ≈ 2 h of failure) |
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
  permanently. It must also skip documents with `replaced by` set: a
  passport renewed early keeps its old version's future `expires` date.
  `custom_field_query` can combine both, e.g.
  `["AND", [["expires","gte","<today>"], ["replaced by","exists",false]]]`.
- Paperless logs to the console in `[time] [LEVEL] [logger] message`
  form; mail errors come from the `paperless_mail` and
  `paperless.mail.tasks` loggers in the celery worker unit. The query
  above was checked for syntax against this VictoriaLogs, not yet
  against real paperless errors.
- The mailbox is a dedicated Gmail account (GMX signup was too much
  trouble). Google only deletes accounts after 2 years without use;
  logging into the web UI once a year makes that a non-issue. Its app
  password dies if 2-Step Verification is ever turned off or the
  account password changes.
