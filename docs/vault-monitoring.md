# Monitoring vault (Synology DSM 7) from Prometheus

Research notes from September 2026. Question: how do we get vault
(stock Synology, stays stock) into the VictoriaMetrics + Grafana stack
on alba-nix — especially per-drive SMART data — without treating the
NAS as a general-purpose Linux box?

Constraint recap: installing anything on the NAS is a cost. Exporters
should run on alba-nix and be nixpkgs-packaged where possible.

## Option 1: SNMP (agentless, exporter on alba-nix)

DSM ships an SNMP agent with Synology-specific MIBs under enterprise
OID `.1.3.6.1.4.1.6574`, documented in the official
[MIB Guide PDF](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Firmware/DSM/All/enu/Synology_DiskStation_MIB_Guide.pdf)
(last updated Mar 2025). Enable it under Control Panel → Terminal &
SNMP ([DSM help](https://kb.synology.com/en-us/DSM/help/DSM/AdminCenter/system_snmp?version=7)).
Poll-only: the guide's introduction states DSM
[does not provide SNMP trap capability](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Firmware/DSM/All/enu/Synology_DiskStation_MIB_Guide.pdf).

What the relevant MIBs expose (all from the MIB Guide):

- **SYNOLOGY-DISK-MIB** (`.6574.2`): per disk — `diskStatus`
  (Normal(1)…Crashed(5)), `diskTemperature`, `diskBadSector`,
  `diskRetry`, `diskIdentifyFail`, `diskRemainLife` (DSM 7.0+), and
  `diskHealthStatus` (Normal/Warning/Critical/Failing, DSM 7.1+ —
  this is Storage Manager's own health verdict).
- **SYNOLOGY-SMART-MIB** (`.6574.5`): the full SMART attribute table,
  "same as Storage Manager does" — one row per (disk, attribute) with
  `diskSMARTInfoDevName`, `diskSMARTAttrName` (e.g.
  `Raw_Read_Error_Rate`), `diskSMARTAttrId`, `diskSMARTAttrCurrent`,
  `diskSMARTAttrWorst`, `diskSMARTAttrThreshold`, `diskSMARTAttrRaw`,
  `diskSMARTAttrRaw64` (Counter64), `diskSMARTAttrStatus`. So yes:
  per-drive SMART current/worst/threshold/raw is all there.
- **SYNOLOGY-RAID-MIB** (`.6574.3`): array status incl. `Degrade(11)`,
  `Crashed(12)`, scrubbing states.
- **SYNOLOGY-STORAGEIO-MIB** (`.6574.101`) / **SPACEIO** (`.6574.102`):
  per-disk and per-volume IO counters and load %.

Scraping it: prometheus-community's snmp_exporter ships a generated
default config whose
[generator.yml includes a `synology` module](https://github.com/prometheus/snmp_exporter/blob/main/generator/generator.yml)
walking `synoSystem`, `synoDisk`, `synoRaid`, `synoUPS`,
`synologyDiskSMART`, `synologyService`, and the storage IO tables —
i.e. the SMART table is covered out of the box, no custom MIB
generation needed
([README: "Most use cases should be covered by our default configuration"](https://github.com/prometheus/snmp_exporter)).
NixOS packages it as
[`services.prometheus.exporters.snmp`](https://github.com/NixOS/nixpkgs/tree/master/nixos/modules/services/monitoring/prometheus/exporters)
(`snmp.nix`), so it runs on alba-nix and vmagent scrapes it like any
other exporter. There's a ready-made Grafana dashboard built on this
module ([Synology NAS Details, ID 14284](https://grafana.com/grafana/dashboards/14284-synology-nas-details/)).

Cost on the NAS: flipping one checkbox. Nothing installed.

## Option 2: dedicated Synology exporters

Surveyed; all are small and none is in nixpkgs:

- [nlamirault/syno_exporter](https://github.com/nlamirault/syno_exporter)
  — SNMP-based, **deprecated by its author in favor of
  snmp_exporter**.
- [jantman/prometheus-synology-api-exporter](https://github.com/jantman/prometheus-synology-api-exporter)
  — Python, talks to the DSM web API via `synologydsm-api`; built
  because SNMP lacks per-disk/per-volume IO *utilization %*. Author
  labels it "experimental/alpha and essentially unsupported"; WIP
  badge, ~0 stars. Needs DSM credentials.
- [KatowProject/synology-exporter](https://github.com/KatowProject/synology-exporter)
  — Go `.spk` that runs *on* DSM 7, reads `/proc` and shells out to
  `sudo smartctl` for per-drive SMART. New
  ([v0.1.0](https://github.com/KatowProject/synology-exporter/releases/tag/v0.1.0)),
  ~0 stars, and it's an on-device install — exactly the cost we're
  avoiding.

Nothing here beats SNMP unless we someday need IO-utilization
percentages or DSM-API-only data.

## Option 3: agents on the NAS

- **node_exporter**: SynoCommunity packages it
  ([node-exporter spk, v1.10.2, Feb 2026, DSM 7.1](https://synocommunity.com/package/node-exporter)).
  Good host metrics, but node_exporter has no SMART collector — people
  bolt SMART on via textfile-collector scripts
  ([example](https://github.com/micha37-martins/S.M.A.R.T-disk-monitoring-for-Prometheus)).
  Third-party package source on the NAS + still no SMART.
- **smartctl on DSM is rough**: DSM ships an old smartmontools, and
  Scrutiny's own
  [Synology install doc](https://github.com/AnalogJ/scrutiny/blob/master/docs/INSTALL_SYNOLOGY_COLLECTOR.md)
  has you install Entware to get smartmontools ≥7.2, run the collector
  from a root Task Scheduler job with a hand-maintained device list,
  and warns in caps that a DSM upgrade may bork the Entware install.
  Users hit `smartctl returned an error code (4)` / checksum errors on
  Synology ([scrutiny#96](https://github.com/AnalogJ/scrutiny/issues/96)).
  smartctl_exporter would inherit all of this.
- **Scrutiny** ([AnalogJ/scrutiny](https://github.com/AnalogJ/scrutiny)):
  hub-and-spoke — a web/API hub backed by **InfluxDB** (required),
  with smartctl-wrapping collectors cron-run on each machine (daily by
  default). Actively maintained
  ([v0.9.4, Sep 2026](https://github.com/AnalogJ/scrutiny/releases)),
  and nixpkgs has both hub and collector as
  [`services.scrutiny`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/monitoring/scrutiny.nix).
  But it is **its own silo**: no Prometheus/OpenMetrics endpoint — the
  [feature request has been open since 2020](https://github.com/AnalogJ/scrutiny/issues/74)
  — and reaching the vault's drives means the on-DSM collector dance
  above (a [SynoCommunity package request](https://github.com/SynoCommunity/spksrc/issues/6226)
  is still open). Its unique value is failure-rate analysis against
  Backblaze data, not integration.

## Option 4: Telegraf + SNMP (comparison point)

Telegraf's [snmp input plugin](https://github.com/influxdata/telegraf/blob/master/plugins/inputs/snmp/README.md)
polls the same MIBs, configured by hand-listing OIDs/tables in
telegraf.conf (MIB files optional). One write-up does exactly this for
`diskSMARTTable` and ships a
[Grafana dashboard (14548)](https://dpron.com/synology-smart/).
Telegraf is in nixpkgs
([`services.telegraf`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/monitoring/telegraf.nix))
and can output Prometheus format, but it buys nothing over
snmp_exporter's pre-generated synology module here — it just moves the
OID bookkeeping into our config.

## What the community reports

- **DSM itself is retreating from showing SMART**: DSM 7.2.1 (Sep
  2023) removed the SMART attribute table from Storage Manager, and
  Synology support pointed users at SNMP as the replacement
  ([SynoForum thread](https://www.synoforum.com/threads/how-to-solve-the-smart-move.12430/)).
  The SNMP SMART table is the *supported* path, not a side door.
- snmp_exporter setup friction: people who hand-roll configs see only
  if_mib metrics until they use the right module
  ([snmp_exporter#519](https://github.com/prometheus/snmp_exporter/issues/519)),
  and raw SNMP walks return the string columns (dev name, attr name)
  hex-encoded, which confused at least one config attempt
  ([snmp_exporter#271](https://github.com/prometheus/snmp_exporter/issues/271)).
  The shipped synology module's DisplayString overrides exist to
  handle exactly this — use it rather than regenerating.
- The MIB guide marks the SMART MIB as supported on "DSM" only (not
  DSM UC), and documents no NVMe-specific rows; attribute sets vary
  per drive by design ("every disk may have different SMART
  attributes" —
  [MIB Guide](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Firmware/DSM/All/enu/Synology_DiskStation_MIB_Guide.pdf)).
  Worth an `snmpwalk` against `.1.3.6.1.4.1.6574.5` on vault to
  confirm what our exact model/drives actually publish before wiring
  alerts to specific attribute names.

## Comparison

| | On-NAS install | Per-drive SMART | In nixpkgs | Maintained |
|---|---|---|---|---|
| snmp_exporter (synology module) | none (enable SNMP) | attr name/current/worst/threshold/raw + health status + temp | yes (`services.prometheus.exporters.snmp`) | prometheus-community |
| DSM-API exporters | none (needs DSM creds) | mostly no; IO util % instead | no | alpha / abandoned |
| node_exporter spk | SynoCommunity pkg | no (textfile hacks) | n/a (runs on NAS) | spk current |
| Scrutiny | collector + Entware + root cron | yes, via smartctl | yes (`services.scrutiny`) | active, but InfluxDB silo, no Prom endpoint |
| Telegraf snmp | none | same SNMP data, manual OID config | yes (`services.telegraf`) | active |

## Recommendation (lightly held)

SNMP + the stock snmp_exporter `synology` module on alba-nix looks
like the clear fit: zero install on vault, per-drive SMART
current/worst/threshold/raw plus Storage Manager's own
`diskHealthStatus`, everything nixpkgs-packaged, and it's the path
Synology itself points at post-7.2.1. First step is enabling SNMP on
vault and snmpwalking `.6574.5` to see what the SMART table really
contains for our drives; alert on `diskHealthStatus`/`diskStatus` and
a handful of raw attributes (reallocated sectors, pending sectors)
rather than the whole table. Scrutiny stays on the shelf unless we
decide we want its failure-threshold analysis badly enough to pay the
Entware-on-DSM tax — it wouldn't feed VictoriaMetrics anyway.
