# niori.el — personal medical records for Emacs

niori is a personal medical information manager: your
**medications, visits, lab tests and vaccinations** in a single local
SQLite database, presented through a dashboard that surfaces what needs
attention — upcoming appointments, abnormal results, boosters that
are due.  The reports and scans behind those records (PDF, DOCX,
images) live in the same directory, attached to the record they belong
to.

It is an Emacs port of the
[niori](https://github.com/ianikeev/niori) Common Lisp/CLOG
application and keeps its NetBeans-Platform-style module
architecture, translated to Emacs idioms (see
[ARCHITECTURE.md](ARCHITECTURE.md) for the concept mapping). Rather
than reimplementing UI toolkits, it composes the platform Emacs
already provides: `tabulated-list-mode` rosters, `widget` forms, the
built-in `sqlite` binding, Modus themes, transient menus.

- Runs as a **package inside your Emacs**, or as a **standalone
  application** on a stock, configuration-free Emacs (`bin/niori`).
- **Your data stays yours**: one data directory under the XDG data
  dirs — the SQLite database plus every attached document —
  offline by default, with an optional GPG-encrypted Org export and
  automatic revision snapshots you can diff with `ediff`.
- FHIR R4 export (MedicationStatement, Encounter, Observation,
  Immunization bundles) and an authenticated FHIR client.
- GPL-3.0-or-later, lexical binding everywhere, GNU ELPA
  dependencies only.

## Features

| Module       | What you track                                        | Dashboard section                          |
|--------------|-------------------------------------------------------|--------------------------------------------|
| Medications  | name, dosage, form, dates, prescriber, instructions   | active medications list                    |
| Visits       | date, doctor, facility, reason, diagnosis, notes      | upcoming visits (next 30 days)             |
| Lab tests    | date, name, result, unit, reference range, flag       | latest result per test with abnormal flags |
| Vaccinations | date, vaccine, dose, route, lot, provider, next due   | boosters due / overdue                     |

Cross-cutting:

- **Rosters** (sortable `tabulated-list-mode` buffers), **forms**
  (validated `widget` buffers with date checks), **detail views**
  with buttons.
- **Documents**: attach any file (PDF, DOCX, image, …) to a visit,
  lab test, medication or vaccination; it is copied into the data
  directory next to the database and opened with `doc-view`,
  `image-mode` or an external viewer.
- **Letters** from visit records, with `flyspell` spell-checking and
  optional `yasnippet` templates (snippets ship in `snippets/`).
- **Exports**: Org (optionally encrypted with EasyPG), CSV, FHIR
  JSON.
- **History**: every change or deletion is snapshotted; `D` on any
  record opens an `ediff` against the previous revision.
- **Backups**: `C-c n b` copies the database to a timestamped file.

## Requirements

- Emacs **29.1 or later**, built with SQLite support (the default on
  major distributions; niori checks and tells you if missing).
- Optional: `gpg` (encrypted exports), `hunspell`/`aspell`
  (letter spell-checking), a system opener — `xdg-open` on
  GNU/Linux, `open` on macOS, the shell's own associations on
  MS-Windows — for documents Emacs cannot display (DOCX, XLSX, …),
  any FHIR server (client).

## Installation

### As a package (recommended)

The package is `niori` (this repository is `niori.el`). Once it is
on MELPA:

```elisp
(use-package niori
  :ensure t
  :commands (niori niori-dashboard))
```

To install it straight from this checkout while it is not yet
packaged, add the repository to your load path:

```elisp
(use-package niori
  :load-path "~/src/niori.el"
  :commands (niori niori-dashboard))
```

GNU ELPA dependencies (`compat`, `transient`, `auto-dark`,
`fontaine`) are declared in `niori.el` and installed automatically;
`package.el` users who prefer `use-package` need nothing else. A
MELPA recipe ships in [`recipes/niori`](recipes/niori).

### As a standalone application

```sh
git clone https://github.com/ianikeev/niori.el
./niori.el/bin/niori            # that's it — a full app on emacs -Q
```

First run (when online) installs the GNU ELPA dependencies plus
vertico/consult/orderless/which-key from GNU ELPA; fully offline it
degrades gracefully to built-ins (Modus themes with day/night
switching, `fido-vertical-mode`, plain keymap help). Set
`NIORI_NO_NET=1` to always start offline.

To install it properly with a desktop entry:

```sh
make install            # defaults to ~/.local
# or: make install PREFIX=/usr/local
```

which installs `bin/niori`, the Elisp sources under
`share/emacs/site-lisp/niori/`, the icon, and `etc/niori.desktop`
(rewritten with the absolute `Exec=` path).

## Quick start

`M-x niori` opens the dashboard and enables the key bindings
(`niori-mode`, a global minor mode). Everything is reachable from
there with buttons, or the `C-c n` prefix:

| Keys            | Action                                  |
|-----------------|-----------------------------------------|
| `C-c n d`       | dashboard                                |
| `C-c n m / v / t / c` | medications / visits / lab tests / vaccinations rosters |
| `C-c n a m` etc.| new record (medication, visit, …)        |
| `C-c n E o / c / j` | export as Org / CSV / FHIR JSON     |
| `C-c n D`       | diff a record against its last revision  |
| `C-c n f`       | every document you have attached          |
| `C-c n l`       | compose a letter from a visit            |
| `C-c n b`       | backup the database                      |
| `C-c n ?`       | transient command menu                   |
| `C-c n C-h`     | full keymap overview                     |

In a roster: `RET` opens the record, `a` adds, `e` edits, `d`
deletes, `g` refreshes, `S` or clicking a header sorts, `L` writes a
letter (visits). In a form: `C-c C-c` saves, `C-c C-k` cancels. In a
detail view: `A` attaches a file to the record. In the documents
buffer (`C-c n f`): `RET` opens, `f` opens externally, `o` shows the
folder in Dired, `r` retitles, `d` detaches.

CUA bindings (`C-x`/`C-c`/`C-v` cut/copy/paste) are available for
standalone users: set `niori-standalone-cua` to `t` (or `M-x
cua-mode` anytime).

## Data, privacy and history

- Everything niori writes lives in **one directory** you choose,
  `niori-data-directory` — `$NIORI_DATA_DIR` when set (the standalone
  app has no init file to customize), else the platform convention:
  `$XDG_DATA_HOME/niori` (usually `~/.local/share/niori`), or
  `%LOCALAPPDATA%\niori` on MS-Windows:

  ```
  ~/.local/share/niori/
  ├── niori.db                      the database
  ├── documents/visits/42/2026-11-20-lab-report.pdf
  ├── backups/                      C-c n b output
  ├── exports/                      Org / CSV / FHIR output
  └── letters/                      reserved for saved letters
  ```

  On POSIX systems everything niori writes there is owner-only: the
  directory (mode `0700`, re-applied on open — you are told when an
  existing loose directory is tightened), the documents inside it
  (`documents/` itself appears on the first attach), the database, the
  backups and exports, and the `-journal`/`-wal`/`-shm` files SQLite
  keeps beside the database — those inherit the mode at creation
  instead of needing a chmod that comes too late.  **On MS-Windows
  none of that means anything**: Emacs maps `chmod` to the read-only
  attribute there, so niori leaves protection to the NTFS permissions
  of the directory — which is why the default is the per-user
  `%LOCALAPPDATA%` folder rather than `~/.local`.

  If you share the directory on purpose, `niori-store-tighten-data-directory`
  decides what happens: `t` (default) tightens, `advise` leaves your
  modes alone but tells you once per session, `nil` stays silent.  In
  the latter two, `M-x niori-store-secure-data-directory` fixes the
  tree on demand (it never follows symlinks, so a document imported
  with the opt-in `link` method keeps the permissions of the file you
  own elsewhere).  Attaching a file
  **copies** it (the original stays where it was), so copying or
  syncing that one directory backs up the whole record.  Moving an
  installation is a directory move plus `M-x
  niori-store-switch-data-directory` — which asks before adopting a
  folder that holds no niori data yet, and keeps using the old
  directory if the new one cannot be opened.
- Nothing leaves your machine unless you call the FHIR client.
- Schema changes run through **numbered migrations**
  (`schema_migrations`); new versions upgrade in place.  New *tables*
  — like the `attachments` of a later release — appear on the next
  open without a migration.
- Every update/delete snapshots the previous record into a
  `revisions` table (`niori-store-keep-revisions`), viewable with
  `niori-record-ediff` — an audit trail inside the same file.
- Documents are never deleted silently: detaching asks before removing
  the file (`M-x niori-attachments-check` lists missing files and links
  orphaned by a deleted record; `M-x niori-attachments-purge-orphans`
  cleans them up).
- Exports land in `…/niori/exports/`. The Org export can be
  **encrypted** (`C-u C-c n E o`) with EasyPG to the keys in
  `niori-encryption-recipients`. If you keep narrative notes in Org
  instead, `org-crypt` (built-in) encrypts subtrees on save — niori
  stays out of the way of both styles.
- `niori-store-backup` (`C-c n b`) copies the database with a
  timestamp; keep a copy on offline media.

## FHIR interoperability

`C-c n E j` (or `M-x niori-fhir-export`) writes a module as a FHIR
R4 collection Bundle: medications become `MedicationStatement`,
visits `Encounter`, lab tests `Observation` (numeric results as
`valueQuantity`, flags as `H`/`L`/`A` interpretation codes),
vaccinations `Immunization`. The mapping is intentionally minimal
(display strings, no code-system translation) — right for personal
export and review.

For retrieval, set `niori-fhir-server-url` and keep the bearer token
in `auth-source` (`.authinfo`: `machine fhir.example.com secret
TOKEN`); then `M-x niori-fhir-fetch` issues authenticated requests
with the built-in `url` library and returns parsed JSON.

## Configuration

All defcustoms live under the `niori` group (`M-x customize-group`).
The essentials:

| Variable                          | Default                  | Meaning                                    |
|-----------------------------------|--------------------------|--------------------------------------------|
| `niori-data-directory`            | `~/.local/share/niori`   | database, documents, backups, exports      |
| `niori-data-file`                 | `nil` (inside the above) | put the database elsewhere                 |
| `niori-documents-directory`       | `nil` (inside the above) | put the attached documents elsewhere       |
| `niori-attachments-import-method` | `copy`                   | copy, move or symlink attached files       |
| `niori-attachments-external-opener` | `xdg-open`/`open`/`start` | viewer for formats Emacs cannot display (MS-Windows uses `w32-shell-execute`) |
| `niori-store-tighten-data-directory` | `t`                    | on open: `t` tighten, `advise` report only, `nil` leave alone |
| `niori-store-keep-revisions`      | `t`                      | keep the audit trail                       |
| `niori-visits-upcoming-days`      | `30`                     | dashboard window for visits                |
| `niori-vaccinations-due-days`     | `90`                     | dashboard window for boosters              |
| `niori-letter-flyspell`           | `auto`                   | spell-check letters when a binary exists   |
| `niori-encryption-recipients`     | `nil`                    | GPG keys for encrypted exports             |
| `niori-fhir-server-url`           | `nil`                    | FHIR server base URL                       |
| `niori-appearance-manage`         | `nil` (t standalone)     | whether niori manages theme and font       |
| `niori-appearance-font-family`    | auto-detect              | monospaced font                            |

When niori runs inside your Emacs it never touches your theme or
fonts; the appearance layer only activates for the standalone app
and itself prefers the GNU ELPA `auto-dark` (Modus operandi ↔
modus-vivendi) and `fontaine` packages, with built-in fallbacks.

## Built on the Emacs platform

niori deliberately reuses mature components instead of
inventing alternatives — storage on the built-in `sqlite` binding,
rosters on `tabulated-list-mode`, forms on `widget`, the command
menu on `transient`, export on `org`/`json`, history diffs on
`ediff`, document display on `doc-view`/`image-mode`, spell-check on
`flyspell`, secrets on `auth-source`.
Optional integrations light up automatically when installed:
`which-key`, `vertico`/`consult`/`orderless` (standalone),
`yasnippet`, `csv-mode`, `org-ql`. The full table — including what
was considered and rejected (EmacSQL, pdf-tools, exc.el) and why —
is in [ARCHITECTURE.md](ARCHITECTURE.md#package-reuse).

## Development

```sh
make check      # ERT suite against a throwaway database
make compile    # byte-compile, expected to be warning-free
make install    # PREFIX=/usr/local for system-wide
```

The test suite covers the platform registries, migrations and CRUD,
revision snapshots, module queries, view formatting/validation, CSV
and Org rendering, the data directory, file permissions and
attachments (import, containment, orphans), FHIR serialization and dashboard
rendering — 67 tests, no display required.

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)), like the original niori.
Portions of the architecture documentation reference the original
project by ianikeev.
