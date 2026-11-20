# niori.el architecture

This document explains how the Emacs port of
[niori](https://github.com/ianikeev/niori) maps the original
Common Lisp/CLOG application onto Emacs concepts, and records the
design decisions behind the mapping.

## From NetBeans Platform to Emacs

The original niori is a modular CLOG desktop application modelled on
the NetBeans Platform: modules plug into a runtime, publish services
through a lookup registry, expose commands, and build their views on
top of a shared windowing/persistence layer.

Emacs already is such a platform, so the port maps concepts rather
than code:

| Original (NetBeans / CLOG)            | niori.el                                             |
|---------------------------------------|------------------------------------------------------|
| Module system (`niori-module`)        | `niori-register-module` in **niori-platform.el** — modules register a plist (schema, roster columns, form fields, dashboard function) |
| Lookup / service registry             | `niori-register-service` / `niori-lookup`            |
| Command system (actions)              | `niori-register-command` + `C-c M` keymap + `transient` menu (**niori-menu.el**, **niori-transient.el**) |
| TopComponent / CLOG views             | generic buffers in **niori-view.el**: rosters (`tabulated-list-mode`), forms (`widget`), details (`special-mode` with buttons) |
| Central dashboard view                | **niori-dashboard.el**, sections contributed by each module's `:dashboard-fn` |
| Derby/SQLite persistence + migrations | **niori-store.el** on the built-in `sqlite` binding, numbered migrations in `schema_migrations` |
| Seed data                             | none — the database starts empty; exports replace it   |
| Module JARs                           | one `niori-<module>.el` per clinical domain           |
| Application launcher                  | `bin/niori` + **niori-standalone.el** (`emacs -Q`)    |

## Source layout

```
niori.el              entry point: requires everything, M-x niori
niori-platform.el     module/service/command registries + shared utils
niori-store.el        SQLite: data directory, schemas, migrations, CRUD, revisions, backup
niori-view.el         rosters, widget forms, detail buffers, exports, ediff
niori-dashboard.el    the dashboard buffer
niori-menu.el         C-c M keymap, niori-mode, menu bar
niori-transient.el    transient menu (runtime-defined)
niori-appearance.el   Modus themes (auto-dark) + fonts (fontaine)
niori-medications.el  module: medications
niori-visits.el       module: visits + letters
niori-labs.el         module: lab tests
niori-vaccinations.el module: vaccinations
niori-attachments.el  documents attached to records (the data directory's documents/)
niori-fhir.el         FHIR R4 serialization + client
niori-standalone.el   bootstrap for emacs -Q
bin/niori             launcher script
etc/niori.desktop     desktop entry
recipes/niori         MELPA recipe
snippets/             yasnippet letter templates (optional)
icons/                niori icon (user artwork) + module SVGs
tests/                ERT suite
```

## The data directory

Everything niori writes lives under one user-chosen directory,
`niori-data-directory` (`$NIORI_DATA_DIR`, else
`$XDG_DATA_HOME/niori`, else `~/.local/share/niori`):

```
<data-dir>/
├── .niori-data          layout marker ("layout-version: 1")
├── niori.db             the database
├── documents/           files attached to records, one folder per record
│   └── visits/42/2026-11-20-lab-report.pdf
├── backups/             niori-store-backup output
├── exports/             Org / CSV / FHIR output
└── letters/             reserved for saved letters
```

`niori-store--data-file` derives the database path from it (an
absolute `niori-data-file` still overrides just the database), so the
directory is the unit of backup, sync and relocation.  Everything the
store writes is owner-only: the directory (`0700`, re-applied on every
open so an installation created by an older version is normalised
too), the copied documents, the database, the backups, the exports and
every file SQLite keeps beside the database.

Permissions are the one place where the port is not uniform across
platforms, and pretending otherwise would be a security bug.  On POSIX
hosts the 9 mode bits are the whole story.  On MS-Windows they are not:
Emacs implements `chmod' by toggling the read-only attribute (its own
`sys_umask' says "the only bit we really support is the write bit;
files are always readable on MS-Windows"), and SQLite creates its
sidecars through the Win32 API where our process umask has no say.
`niori-store--modes-supported-p' is the single test for this: where it
is false, niori performs no `chmod` at all and leaves protection to
the NTFS permissions of the directory, which is why
`niori-store--default-data-directory' picks `%LOCALAPPDATA%\niori'
there instead of `~/.local/share'.  `niori-attachments--open-external'
is platform-aware in the same way: `xdg-open', `open' on macOS, and
`w32-shell-execute' on MS-Windows.

Tightening an existing directory is a policy, not a law.
`niori-store-tighten-data-directory' has three states, applied by
`niori-store--tighten-directory' (which returns what it did, so callers
own the wording and a sweep of subdirectories stays quiet):

| Value | On open, when other users can reach the directory |
|---|---|
| `t` (default) | re-apply `0700` and say so in one line |
| `advise` | keep your modes, report **once per session** and name the fix |
| `nil` | keep your modes, say nothing |

`niori-store--report-directory-mode' does the reporting, and
`niori-store-secure-data-directory` is the explicit "fix it now"
command — it works regardless of the policy, walks the tree, and skips
symbolic links so a `link`-imported document keeps the permissions of
the file the user still owns elsewhere.  A deliberately shared folder
(a family NAS, a group-readable backup volume) can therefore be exempt
without being silently overridden on every open, and without being
left unwatched either.

That last part needs care: SQLite creates the rollback journal (and,
in WAL mode, `-wal`/`-shm`) itself, so a `chmod` after the fact always
races the write that matters.  `niori-store--with-private-umask`
narrows the process umask around `sqlite-open`, `sqlite-execute` and
`sqlite-close` instead, so those files are private from the instant
they exist; `niori-store--secure-database-files` then normalises
whatever an earlier run or a copy left behind.  WAL is deliberately
*not* enabled (roadmap P1.1): the data directory is meant to be
synced, and a live `-wal` on a Syncthing/network folder is a
corruption source rather than a performance win.

`niori-store-switch-data-directory` closes the connection,
re-points the variable, reopens (running migrations) and runs
`niori-store-switch-hook`, which the view layer uses to re-render open
buffers.

The `attachments` table stores only paths **relative** to the
documents directory
(`visits/42/2026-11-20-lab-report.pdf`) plus title, size, MIME type and
SHA-256.  `niori-attachments-file` expands a path and refuses one that
would escape the documents directory, so a hand-edited row cannot turn
into an arbitrary file read.  Attaching copies the file by default
(`niori-attachments-import-method` allows move and symlink); detaching
asks before removing a file and never removes one another row still
points at; deleting a *record* asks first and keeps the files, which
`niori-attachments-check` and `niori-attachments-purge-orphans` then
account for.

## Data flow

1. On first use `niori-store-open` creates the data directory (mode
   `0700`, marker file included) and the SQLite file, then runs
   pending migrations. Each module has registered its table DDL via
   `niori-store-register-schema`; migration 1 creates them all,
   `niori-store--ensure-schema` creates any table or index registered
   later (idempotently, with `IF NOT EXISTS`), and future schema
   versions append numbered migrations for *changes* to existing
   tables.
2. Views are generic: `niori-roster`/`niori-form`/`niori-detail`
   take a module symbol and read everything from its registration.
   A module file contains *no buffer code* of its own — only its
   schema, field/column specs, queries, dashboard section and
   letter template.
3. Writes go through `niori-store-insert/update/delete`. Updates
   and deletes first snapshot the current record (JSON, via the
   built-in `json` library) into `revisions`, which powers
   `niori-record-ediff` (ediff between the pretty-printed current
   record and the previous snapshot).
4. After every write the view layer refreshes any open roster,
   detail and dashboard buffers for the module.

## SQL discipline

- Table and column names come exclusively from the schema registry
  (symbols), never from user input; values are always bound
  parameters (`?`), so the query surface is injection-safe.
- `sqlite-execute` returns an affected-row count for empty result
  sets on some builds (observed on Emacs 30.1); `niori-store--exec`
  normalises this to nil so callers only ever see row lists.
- Rows are converted to plists keyed by the registered columns, so
  the rest of the code never touches positional indexes.

## Standalone bootstrap

`bin/niori` resolves the repository root (or the `make install`
site-lisp directory) and execs
`emacs -Q -l niori-standalone.el -f niori-standalone-run`. The
bootstrap:

1. Optionally installs GNU ELPA packages (`compat`, `transient`,
   `auto-dark`, `fontaine` plus the enhancement set
   vertico/consult/orderless/which-key), skipping entirely with
   `NIORI_NO_NET=1` or `niori-standalone-install-packages = nil`;
   unreachable archives degrade to built-in fallbacks.
2. Loads niori, enables appearance management (Modus + fonts),
   vertical completion (vertico, else `fido-vertical-mode`),
   which-key, optionally `cua-mode`, installs the menu-bar entry,
   enables `niori-mode` and opens the dashboard as
   `initial-buffer-choice`.

Every optional package is guarded at runtime: the application must
start on a bare, offline Emacs. `niori-transient.el` defines its
menu through a runtime `eval` so the package byte-compiles and loads
even where `transient` is absent; `niori-menu` falls back to a
which-key overview or the dashboard.

## Package reuse

The port's guiding rule: prefer a mature Emacs component over new
code. Status of everything considered:

| Component | Status in niori.el | How it is used |
|---|---|---|
| `org-mode` (built-in) | used | export of rosters as Org tables/letters (`niori-export-org`) |
| `org-crypt` (built-in) | optional, documented | encrypting Org narrative notes kept outside niori; niori's own encryption uses EasyPG directly |
| `sqlite.el` (built-in, 29+) | used, core | the whole persistence layer |
| EmacSQL | **not used** | extra dependency + external-process backend; parameterised SQL behind the schema registry is smaller and typed |
| `widget.el` (built-in) | used, core | all create/edit forms |
| `tabulated-list-mode` (built-in) | used, core | all rosters |
| `transient` (GNU ELPA) | used when present | `C-c M ?` command menu; runtime-defined, with fallback |
| `which-key` (built-in 30 / GNU ELPA) | used when present | keymap discoverability in standalone |
| `use-package` (built-in) | documented | installation examples in README |
| EasyPG `epa` (built-in) | used | encrypted Org export (needs `gpg` + `niori-encryption-recipients`) |
| `auth-source` (built-in) | used | FHIR bearer tokens from `.authinfo`/keyrings |
| `json` (built-in, native with jansson) | used | revision snapshots and FHIR serialization |
| `url` (built-in) | used | FHIR client (`url-retrieve-synchronously`) |
| `flyspell` (built-in) | used | letter spell-checking (needs hunspell/aspell) |
| `ediff` (built-in) | used | record-vs-revision diffs |
| `org-ql` (GNU ELPA) | optional, documented | structured queries over exported Org archives |
| vertico / consult / orderless (GNU ELPA) | standalone enhancement | auto-installed when online; `fido-vertical-mode` fallback |
| `yasnippet` (MELPA/NonGNU) | optional, guarded | letter templates in `snippets/` |
| `csv-mode` (NonGNU ELPA) | optional, guarded | CSV exports open in it automatically when installed |
| `pdf-tools` (MELPA) | not integrated | attachments are in scope since 0.2: files live in the data directory and open with built-in `doc-view` (`image-mode` for images, an external opener for DOCX); `pdf-tools` remains a drop-in upgrade for PDF display |
| `doc-view`, `image-mode` (built-in) | used | the default viewers for attached PDFs and pictures |
| `mailcap` (built-in) | used | guessing a document's MIME type from its extension |
| `dired` (built-in) | used | "reveal in folder" for an attachment |
| `exc.el` | not integrated | no spreadsheet surface yet; noted as a future viewer for exported CSV |
| `auto-dark`, `fontaine`, `compat` (GNU ELPA) | declared dependencies | Modus day/night switching, font presets, forward-compat helpers |

MELPA-only packages are never hard requirements: the package header
lists GNU ELPA deps only, and every optional integration is guarded
so absence is a graceful downgrade, not an error.

## Design decisions worth remembering

- **Why `C-c M`**: a single reserved-for-the-user prefix (`C-c M`)
  chosen to avoid collision with other packages that use `C-c n` (such as
  deft); the global minor mode means zero footprint until you run `M-x niori`.
- **Why SQLite and not Org files**: the original niori is a
  relational record manager — dates, flags, joins ("latest result
  per test with abnormal flag") are natural in SQL and awkward in
  plain text. Org remains the *export* and *narrative* layer.
- **Why the dashboard is data-driven**: each module owns its
  section; adding a fifth clinical module (say, measurements)
  requires no dashboard changes.
- **Why every record keeps revisions**: medical data is edited
  rarely but mistakes matter; the snapshot table costs one JSON
  write per change and gives a real audit trail without version
  control ceremony.
- **Why the documents live in per-record folders**
  (`documents/visits/42/…`): a file manager and Dired stay useful, the
  record id is a stable, meaningful folder name, and the whole tree
  can be synced as a unit — unlike content-addressed names, which are
  opaque to a human browsing their own medical record.
- **Why attaching copies by default**: the data directory is then a
  complete copy of the record, so "back up this folder" is sufficient
  advice.  Moving or symlinking is available for large scans, at the
  documented cost of no longer being self-contained.
- **Why a detail-section hook instead of a module property**: the
  attachments block belongs to *every* module, so `niori-view` runs
  `niori-detail-sections-hook` and `niori-attachments.el` adds itself.
  No clinical module file mentions attachments, which keeps the
  "modules contain no buffer code" rule intact.
- **Why lexical binding everywhere and GPL-3.0-or-later**: lexical
  binding is modern Elisp hygiene (closures in the widget/button
  callbacks depend on it); the GPL keeps the port license-compatible
  with the original niori.
