;;; niori-store.el --- SQLite persistence for niori  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  ianikeev

;; Author: ianikeev <ianikeev@users.noreply.github.com>
;; URL: https://github.com/ianikeev/niori.el
;; Keywords: convenience, health, database
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of niori.el.

;; niori.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; niori.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with niori.el.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; SQLite persistence layer for niori, built directly on the built-in
;; `sqlite' library (Emacs 29.1+).  The original niori used its own
;; SQL abstraction over SQLite with versioned migrations; this port
;; keeps the same shape:
;;
;;   * table schemas are registered by modules
;;     (`niori-store-register-schema');
;;   * the database runs numbered migrations on first open
;;     (`niori-store-open');
;;   * every update or delete snapshots the previous record into a
;;     `revisions' table so that history can be inspected and diffed
;;     with `ediff' (see `niori-record-ediff' in niori-view.el).
;;
;; All data lives in one user-chosen directory (`niori-data-directory'):
;; the database, the documents the user attached (niori-attachments.el),
;; backups and exports.  The database path is derived from it unless
;; `niori-data-file' names a file explicitly.
;;
;; Health data must not be world readable, so the directory is created
;; 0700, the database and every journal/WAL file SQLite puts beside it
;; are 0600, and SQLite runs under a narrowed umask so the files it
;; creates behind our back are private from the moment they exist.
;;
;; Why not EmacSQL?  niori only needs a handful of parameterised
;; statements; using `sqlite' directly avoids an extra dependency and
;; the external-process backend, while the schema registry below
;; still gives us typed, injection-safe table access.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'niori-platform)

(defgroup niori-store nil
  "Persistence layer of niori."
  :group 'niori)

(defun niori-store--default-data-directory ()
  "Directory niori uses when `niori-data-directory' is not customized.
NIORI_DATA_DIR wins; otherwise the platform convention is followed:
%LOCALAPPDATA% on MS-Windows (the per-user, ACL-protected profile
directory), `XDG_DATA_HOME' elsewhere, then ~/.local/share."
  (let ((env (getenv "NIORI_DATA_DIR")))
    (cond
     ((and env (not (string-empty-p env)))
      (expand-file-name env))
     ((memq system-type '(windows-nt ms-dos))
      (expand-file-name "niori"
                        (or (getenv "LOCALAPPDATA") "~/AppData/Local")))
     (t
      (expand-file-name "niori"
                        (or (getenv "XDG_DATA_HOME") "~/.local/share"))))))

(defcustom niori-data-directory
  (file-name-as-directory (niori-store--default-data-directory))
  "Directory holding every file niori writes.
The SQLite database (`niori.db'), the documents the user attached
(`documents/', see `niori-documents-directory'), `backups/' and
`exports/' all live here, so backing the directory up backs up the
whole record.

The default honours the NIORI_DATA_DIR environment variable, then
`XDG_DATA_HOME', and falls back to ~/.local/share/niori — or to
%LOCALAPPDATA%\\niori on MS-Windows, where that profile directory is the
one protected by NTFS permissions.  The environment variable is the
way to choose a directory for the standalone app, which runs
`emacs -Q' and therefore never loads an init file.  Moving an
existing installation is a directory move plus
\[niori-store-switch-data-directory]."
  :type 'directory
  :group 'niori-store)

(defcustom niori-store-tighten-data-directory t
  "What niori does when other users can reach its data directory.
The values:

  t       re-apply mode 0700 to the data directory and its
          subdirectories on open, and say so.  The default: a health
          record left group- or world-readable by a copied, restored
          or newly shared folder should not stay that way.
  advise  change nothing, but advise once per session and point at
          `niori-store-secure-data-directory'.  Use this to keep your
          own modes and still be told when they are loose.
  nil     change nothing and say nothing.

Reach for `advise' or `nil' if you deliberately share the directory: a
group-readable backup volume, a family NAS, a folder managed by your
own ACLs.  In every state niori still creates the files and
directories *it* makes owner-only.

This option has no effect on MS-Windows, where the POSIX mode bits
cannot express privacy (see `niori-store--modes-supported-p')."
  :type '(choice (const :tag "Tighten automatically" t)
                 (const :tag "Advise but keep my modes" advise)
                 (const :tag "Leave modes alone" nil))
  :group 'niori-store)

(defcustom niori-data-file nil
  "File name of the niori SQLite database, or nil to derive it.
When nil (the default) the database is
`niori-data-directory'/niori.db.  Set this only to keep the
database somewhere else than the rest of the data: an absolute
name here overrides the database path alone, while documents,
backups and exports stay in `niori-data-directory'."
  :type '(choice (const :tag "Inside `niori-data-directory'" nil) file)
  :group 'niori-store)

(defcustom niori-store-keep-revisions t
  "When non-nil, snapshot records into the revisions table on change.
This powers `niori-record-ediff'."
  :type 'boolean
  :group 'niori-store)

(defvar niori-store--db nil
  "The open SQLite connection, or nil.")

(defvar niori-store--db-file nil
  "File name backing `niori-store--db'.")

(defvar niori-store--schemas nil
  "Alist of registered tables: (TABLE . (COLUMN...)).")

(defvar niori-store--ddl nil
  "Alist of registered tables: (TABLE . DDL-STRING).")

(defvar niori-store--indexes nil
  "Alist of registered indexes: (NAME . DDL-STRING).")

(defconst niori-store-layout-version 1
  "Version of the on-disk data directory layout.
Written to the `.niori-data' marker file so a future niori can tell
what it is looking at before touching anything.")

(defconst niori-store--directory-mode #o700
  "Mode given to a newly created data directory (owner only).")

(defun niori-store--columns (table)
  "Registered column symbols of TABLE."
  (or (alist-get table niori-store--schemas)
      (error "niori: unknown table %s" table)))

(defun niori-store-register-schema (table columns ddl)
  "Register TABLE with COLUMNS (symbols) and its CREATE TABLE DDL.
Registration order is preserved; migration 1 creates every
registered table, and `niori-store--ensure-schema' creates any
table registered later.  Registering twice replaces the definition."
  (setf (alist-get table niori-store--schemas) columns)
  (setf (alist-get table niori-store--ddl) ddl))

(defun niori-store-register-index (table name columns &optional unique)
  "Register index NAME over COLUMNS of TABLE.
COLUMNS is a list of column symbols; non-nil UNIQUE makes it a
unique index.  Registered indexes are created with CREATE INDEX IF
NOT EXISTS after migrations, so indexing a table that already
exists needs no numbered migration."
  (niori-store--columns table)
  (setf (alist-get name niori-store--indexes)
        (format "CREATE %sINDEX IF NOT EXISTS %s ON %s (%s)"
                (if unique "UNIQUE " "")
                name table
                (mapconcat #'symbol-name columns ", "))))

;; The platform itself owns the revisions audit table.
(niori-store-register-schema
 'revisions
 '(id table_name record_id changed_at snapshot)
 "CREATE TABLE revisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name TEXT NOT NULL,
  record_id INTEGER NOT NULL,
  changed_at TEXT NOT NULL,
  snapshot TEXT NOT NULL)")

;;;; The data directory

(defun niori-store--data-directory ()
  "Absolute name of `niori-data-directory', with a trailing slash."
  (file-name-as-directory (expand-file-name niori-data-directory)))

(defun niori-store--data-file ()
  "Absolute file name of the niori database."
  (expand-file-name (or niori-data-file "niori.db")
                    (niori-store--data-directory)))

(defun niori-store--marker-file ()
  "Absolute name of the layout marker of the data directory."
  (expand-file-name ".niori-data" (niori-store--data-directory)))

(defun niori-data-subdirectory (name)
  "Absolute name of the NAME subdirectory of the data directory.
The directory (or its parents) is created owner-only when missing,
so callers can write into the result without further checks.  NAME
must resolve to a place inside the data directory."
  (let* ((root (niori-store--data-directory))
         (directory (expand-file-name (file-name-as-directory name) root)))
    (unless (and (string-prefix-p root directory)
                 (not (equal directory root)))
      (error "niori: %s does not name a subdirectory of %s" name root))
    (unless (file-directory-p directory)
      (make-directory directory 'parents)
      (ignore-errors (set-file-modes directory niori-store--directory-mode)))
    (niori-store--tighten-directory directory)
    directory))

(defconst niori-store--private-file-modes #o600
  "Mode given to niori's own files (database, sidecars, documents).")

(defun niori-store--modes-supported-p ()
  "Whether POSIX mode bits can express privacy on this system.
False on MS-Windows: Emacs maps `chmod' to the read-only attribute
there (see `sys_umask' in the Emacs sources: \"the only bit we
really support is the write bit; files are always readable on
MS-Windows\"), and SQLite writes its sidecars through the Win32 API,
which our process umask cannot influence.  niori therefore leaves
protection to the permissions of the directory you choose —
`%LOCALAPPDATA%' by default — instead of pretending that a `0600'
means anything there."
  (not (memq system-type '(windows-nt ms-dos))))

(defun niori-store--secure-file (file)
  "Make FILE readable by its owner only, where the OS has file modes.
A health record should not be world readable just because the umask
says so.  A no-op on MS-Windows, where modes do not carry that
meaning."
  (when (and (niori-store--modes-supported-p)
             (file-exists-p file))
    (ignore-errors (set-file-modes file niori-store--private-file-modes)))
  file)

(defvar niori-store--advised-about nil
  "Directories already reported through the `advise' policy this session.
Keeps `niori-store-tighten-data-directory' = `advise' informative
rather than nagging on every reconnect.")

(defun niori-store--directory-loose-p (directory)
  "Non-nil when users other than the owner can reach DIRECTORY."
  (and (file-directory-p directory)
       (not (zerop (logand (file-modes directory) #o077)))))

(defun niori-store--tighten-directory (directory)
  "Apply `niori-store-tighten-data-directory' to DIRECTORY.
Return `tightened' when the mode was changed, `loose' when other users
can still reach it (either because the policy says to keep hands off
or because the chmod failed) and nil when there is nothing to report.
Callers own the user-facing message, so sweeping subdirectories stays
quiet."
  (when (and (niori-store--modes-supported-p)
             (niori-store--directory-loose-p directory))
    (pcase niori-store-tighten-data-directory
      ('t
       (ignore-errors (set-file-modes directory niori-store--directory-mode))
       (if (niori-store--directory-loose-p directory) 'loose 'tightened))
      ('advise 'loose)
      (_ nil))))

(defun niori-store--report-directory-mode (directory state)
  "Report STATE (see `niori-store--tighten-directory') for DIRECTORY.
A tightening is a one-line message; a directory left loose is a
`display-warning' (once per session) that names the command which
would fix it."
  (pcase state
    ('tightened
     (message "niori: made %s owner-only (customize `niori-store-tighten-data-directory' to keep your own modes)"
              directory))
    ('loose
     (unless (member directory niori-store--advised-about)
       (push directory niori-store--advised-about)
       (display-warning
        'niori
        (format "%s is readable by other users.  M-x niori-store-secure-data-directory fixes it; set `niori-store-tighten-data-directory' to t to have niori do that on every open."
                directory)
        :warning)))))

(defconst niori-store--database-suffixes '("" "-journal" "-wal" "-shm")
  "Suffixes of the files SQLite keeps beside the database.
The rollback journal exists only while a transaction is open, and
`-wal'/`-shm' only in WAL mode, but every one of them can hold pages
of the health record itself and must not be world readable.")

(defmacro niori-store--with-private-umask (&rest body)
  "Evaluate BODY with newly created files restricted to their owner.
SQLite creates its journal, `-wal' and `-shm' files itself, so
instead of chmodding files that do not exist yet the process umask
is narrowed for the duration of the call.  The narrowed value is
`niori-store--directory-mode' (owner rwx), which yields owner-only
files (0600) *and* owner-only directories (0700) — the latter matters
because `sqlite-execute' can run statements such as `VACUUM INTO'
that create one.  Emacs is single threaded, and the previous value is
restored even when BODY signals.  On MS-Windows BODY simply runs:
the emulated umask there only tracks the write bit, so it buys
nothing."
  `(if (not (niori-store--modes-supported-p))
       (progn ,@body)
     (let ((previous (default-file-modes)))
       (unwind-protect
           (progn (set-default-file-modes niori-store--directory-mode)
                  ,@body)
         (set-default-file-modes previous)))))

(defun niori-store--secure-database-files ()
  "Restrict the database and every file SQLite keeps beside it to the owner.
This catches files an earlier run, another program or a copied
directory left with a looser mode; files SQLite creates during this
session are already private through `niori-store--with-private-umask'."
  (let ((file (niori-store--data-file)))
    (dolist (suffix niori-store--database-suffixes)
      (niori-store--secure-file (concat file suffix)))
    ;; A multi-database transaction leaves a randomly named master
    ;; journal beside the database.
    (dolist (master (file-expand-wildcards (concat file "-mj*")))
      (niori-store--secure-file master))))

(defun niori-store-ensure-data-directory ()
  "Create the data directory, its marker and the store's subdirectories.
Idempotent; a directory created here is owner-only (0700) so the
health record inside is not readable by other local users.  Modules
create their own subdirectories on demand with
`niori-data-subdirectory'."
  (let ((root (niori-store--data-directory)))
    (unless (file-directory-p root)
      (make-directory root 'parents)
      (ignore-errors (set-file-modes root niori-store--directory-mode)))
    ;; Say so when a directory an earlier version (or a copy) left group-
    ;; or world-readable: silently overriding a mode you set on purpose
    ;; would be worse than telling you, and staying quiet about a public
    ;; health record would be worse still.
    (niori-store--report-directory-mode
     root (niori-store--tighten-directory root))
    (let ((marker (niori-store--marker-file)))
      (unless (file-exists-p marker)
        (with-temp-file marker
          (insert (format "layout-version: %d\ncreated-by: niori.el\n"
                          niori-store-layout-version)))
        (ignore-errors (set-file-modes marker #o600))))
    (mapc #'niori-data-subdirectory '("backups" "exports"))
    root))

;;;; Opening, closing, migrating

(defun niori-store-opened-p ()
  "Return non-nil when the niori database is open."
  (and niori-store--db t))

(defun niori-store-open ()
  "Open the niori database and run pending migrations.
Signals `user-error' when this Emacs lacks SQLite support."
  (interactive)
  (unless (fboundp 'sqlite-open)
    (user-error "This Emacs was built without SQLite support; niori cannot store data"))
  (unless (and niori-store--db
               niori-store--db-file
               (equal niori-store--db-file (niori-store--data-file)))
    (when niori-store--db
      (ignore-errors (sqlite-close niori-store--db)))
    (let ((file (niori-store--data-file)))
      (niori-store-ensure-data-directory)
      (make-directory (file-name-directory file) 'parents)
      (setq niori-store--db (niori-store--with-private-umask (sqlite-open file))
            niori-store--db-file file)
      (niori-store--secure-database-files))
    (niori-store--migrate))
  niori-store--db)

(defun niori-store-secure-data-directory ()
  "Make the data directory, its subdirectories and files owner-only now.
This is the answer to a \"readable by other users\" warning, and the
thing to run after unpacking a copy of the directory from a machine
whose umask left it world readable.  It does the work regardless of
`niori-store-tighten-data-directory', because asking for it explicitly
is the whole point; symbolic links are never followed, so a document
linked (rather than copied) into the tree keeps the permissions of the
file you own elsewhere."
  (interactive)
  (unless (niori-store--modes-supported-p)
    (user-error "This system has no POSIX file modes; use its file permissions instead"))
  (let ((root (niori-store--data-directory))
        (secured 0))
    (unless (file-directory-p root)
      (user-error "No niori data directory at %s" root))
    (dolist (directory (cons root (directory-files-recursively root "" t)))
      (when (and (file-directory-p directory)
                 (not (file-symlink-p directory)))
        (ignore-errors (set-file-modes directory niori-store--directory-mode))
        (setq secured (1+ secured))))
    (dolist (file (directory-files-recursively root "" nil))
      (unless (or (file-directory-p file) (file-symlink-p file))
        (ignore-errors (set-file-modes file niori-store--private-file-modes))
        (setq secured (1+ secured))))
    (niori-store--secure-database-files)
    (setq niori-store--advised-about (delete root niori-store--advised-about))
    (message "niori: %d file%s and director%s in %s are owner-only"
             secured (if (= secured 1) "" "s")
             (if (= secured 1) "y" "ies") root)
    secured))

(defun niori-store-close ()
  "Close the niori database, if open."
  (interactive)
  (when niori-store--db
    (ignore-errors
      (niori-store--with-private-umask (sqlite-close niori-store--db)))
    (setq niori-store--db nil
          niori-store--db-file nil)))

(defun niori-store--migrate ()
  "Apply pending migrations in ascending version order, then align schemas."
  (niori-store--exec "CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL)")
  (let ((applied (mapcar (lambda (row) (nth 0 row))
                         (niori-store--exec
                          "SELECT version FROM schema_migrations"))))
    (pcase-dolist (`(,version . ,fn) (niori-store--pending-migrations applied))
      (funcall fn)
      (niori-store--exec
       "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)"
       (list version (format-time-string "%Y-%m-%dT%H:%M:%S")))))
  (niori-store--ensure-schema))

(defun niori-store--ensure-schema ()
  "Create every registered table and index that does not exist yet.
Numbered migrations are how an existing table *changes*; this is
how a table or index registered *after* the database was created
comes into being (for instance the `attachments' table of a module
loaded in a later release).  Both operations are idempotent."
  (dolist (cell niori-store--ddl)
    (let ((ddl (niori-store--create-if-not-exists (cdr cell))))
      (when ddl
        (niori-store--exec ddl))))
  (dolist (cell niori-store--indexes)
    (niori-store--exec (cdr cell))))

(defun niori-store--create-if-not-exists (ddl)
  "Return DDL with its CREATE TABLE made idempotent, or nil.
DDL that is not a plain CREATE TABLE statement is left to the
numbered migrations, which is where such statements belong."
  (cond ((not (string-match-p "\\`[[:space:]]*CREATE[[:space:]]+TABLE" ddl)) nil)
        ((string-match-p "IF NOT EXISTS" ddl) ddl)
        (t (replace-regexp-in-string
            "\\`\\([[:space:]]*CREATE[[:space:]]+TABLE\\)"
            "\\1 IF NOT EXISTS" ddl t))))

(defun niori-store--pending-migrations (applied)
  "Alist of pending migrations (VERSION . FN), ascending by version."
  (cl-loop for migration in `((1 . ,#'niori-store--migration-1))
           unless (memq (car migration) applied)
           collect migration))

(defun niori-store--migration-1 ()
  "Initial schema: every table registered so far."
  (dolist (table (mapcar #'car niori-store--schemas))
    (niori-store--exec (alist-get table niori-store--ddl))))

;;;; Execution helpers

(defun niori-store--exec (sql &optional params)
  "Execute SQL with PARAMS (a list) against the niori database.
Return the rows for SELECT statements.  Non-query results (an
affected-row count on some builds, nil elsewhere) are normalised
to nil."
  (niori-store-open)
  (let ((result (niori-store--with-private-umask
                  (if params
                      (sqlite-execute niori-store--db sql params)
                    (sqlite-execute niori-store--db sql)))))
    (and (listp result) result)))

(defun niori-store--rows->plists (table rows)
  "Convert database ROWS to plists keyed by the columns of TABLE."
  (let ((columns (niori-store--columns table)))
    (mapcar (lambda (row)
              (let ((values (if (vectorp row) (append row nil) row)))
                (apply #'nconc (cl-mapcar (lambda (column value)
                                            (list column value))
                                          columns values))))
            rows)))

;;;; CRUD

(defun niori-store--writable-fields (table values)
  "Filter VALUES (an alist) to the writable columns of TABLE."
  (let ((columns (niori-store--columns table)))
    (cl-loop for (field . value) in values
             when (and (memq field columns)
                       (not (memq field '(id created_at updated_at))))
             collect (cons field value))))

(defun niori-store--to-sql (value)
  "Convert VALUE for SQL binding."
  (if (eq value t) 1 value))

(defun niori-store-insert (table values)
  "Insert VALUES (an alist) as a new record of TABLE.
Return the id of the inserted row."
  (niori-store-open)
  (let* ((pairs (niori-store--writable-fields table values))
         (fields (mapcar #'car pairs))
         (now (format-time-string "%Y-%m-%dT%H:%M:%S"))
         (sql (format "INSERT INTO %s (%s, created_at, updated_at) VALUES (%s)"
                      table
                      (mapconcat #'symbol-name fields ", ")
                      (mapconcat (lambda (_) "?")
                                 (append fields '(created_at updated_at)) ","))))
    (niori-store--exec sql
                       (append (mapcar (lambda (pair)
                                         (niori-store--to-sql (cdr pair)))
                                       pairs)
                               (list now now)))
    (let ((rows (niori-store--exec "SELECT last_insert_rowid()")))
      (nth 0 (nth 0 rows)))))

(cl-defun niori-store-select (table &key where params order)
  "Select records from TABLE, returned as plists.
WHERE is an SQL condition string with ? placeholders, PARAMS the
matching values, and ORDER an ORDER BY clause without the keywords."
  (let* ((columns (niori-store--columns table))
         (sql (format "SELECT %s FROM %s"
                      (mapconcat #'symbol-name columns ", ") table)))
    (when where
      (setq sql (concat sql " WHERE " where)))
    (when order
      (setq sql (concat sql " ORDER BY " order)))
    (niori-store--rows->plists table (niori-store--exec sql params))))

(defun niori-store-get (table id)
  "Return record ID of TABLE as a plist, or nil."
  (car (niori-store-select table :where "id = ?" :params (list id))))

(defun niori-store-update (table id values)
  "Update record ID of TABLE with VALUES (an alist)."
  (let* ((pairs (niori-store--writable-fields table values))
         (now (format-time-string "%Y-%m-%dT%H:%M:%S"))
         (sets (mapconcat (lambda (field) (format "%s = ?" field))
                          (append (mapcar #'car pairs) '(updated_at))
                          ", "))
         (sql (format "UPDATE %s SET %s WHERE id = ?" table sets)))
    (niori-store--snapshot table id)
    (niori-store--exec sql
                       (append (mapcar (lambda (pair)
                                         (niori-store--to-sql (cdr pair)))
                                       pairs)
                               (list now id)))
    id))

(defun niori-store-delete (table id)
  "Delete record ID from TABLE, keeping a revision snapshot."
  (niori-store--snapshot table id)
  (niori-store--exec (format "DELETE FROM %s WHERE id = ?" table)
                     (list id))
  id)

(defun niori-store-count (table)
  "Number of records in TABLE."
  (nth 0 (nth 0 (niori-store--exec
                 (format "SELECT COUNT(*) FROM %s" table)))))

;;;; Revision history

(defun niori-store--snapshot (table id)
  "Record a JSON snapshot of the current state of record ID in TABLE."
  (when niori-store-keep-revisions
    (let ((record (niori-store-get table id)))
      (when record
        (niori-store--exec
         "INSERT INTO revisions (table_name, record_id, changed_at, snapshot)
          VALUES (?, ?, ?, ?)"
         (list (symbol-name table)
               id
               (format-time-string "%Y-%m-%dT%H:%M:%S")
               (json-encode record)))))))

(defun niori-store-record-revisions (table id)
  "Revisions of record ID in TABLE, most recent first."
  (niori-store--rows->plists
   'revisions
   (niori-store--exec
    "SELECT id, table_name, record_id, changed_at, snapshot
     FROM revisions
     WHERE table_name = ? AND record_id = ?
     ORDER BY id DESC"
    (list (symbol-name table) id))))

;;;; Switching the data directory

(defvar niori-store-switch-hook nil
  "Hook run after `niori-store-switch-data-directory' reopened the database.
Buffers display data that no longer exists, so the view layer uses
this to re-render everything that is open.")

(defun niori-store-switch-data-directory (directory)
  "Make DIRECTORY the niori data directory and reopen the database.
Closes the current connection, points `niori-data-directory' at
DIRECTORY, reopens (running migrations) and runs
`niori-store-switch-hook'.  This is the whole migration procedure
for an existing installation: move the directory, then call this.

A directory that has neither the `.niori-data' marker nor a database
is confirmed first — pointing niori at the wrong folder must not look
like losing every record — and a failing open restores the previous
data directory instead of leaving the session closed."
  (interactive
   (list (read-directory-name "niori data directory: "
                              (niori-store--data-directory))))
  (let ((previous (niori-store--data-directory))
        (target (file-name-as-directory (expand-file-name directory))))
    (when (and (file-exists-p target) (not (file-directory-p target)))
      (user-error "%s is not a directory" target))
    (when (and (not (file-exists-p (expand-file-name ".niori-data" target)))
               (not (file-exists-p (expand-file-name "niori.db" target)))
               (not (y-or-n-p (format "%s holds no niori database yet.  Start a new record there? "
                                      target))))
      (user-error "Data directory unchanged"))
    (niori-store-close)
    (setq niori-data-directory target)
    (condition-case error
        (niori-store-open)
      (error
       (setq niori-data-directory previous)
       (ignore-errors (niori-store-open))
       (user-error "Could not use %s (%s); still using %s"
                   target (error-message-string error) previous)))
    (run-hooks 'niori-store-switch-hook)
    (message "niori: using data directory %s" target)
    target))

;;;; Backups and exports

(defun niori-store-backup ()
  "Copy the niori database to a timestamped backup file."
  (interactive)
  (let* ((source (niori-store--data-file))
         (directory (niori-data-subdirectory "backups"))
         (target (expand-file-name
                  (format-time-string "niori-%Y%m%d-%H%M%S.db") directory)))
    (unless (file-exists-p source)
      (user-error "No niori database at %s" source))
    (unwind-protect
        (progn
          (niori-store-close)
          (copy-file source target t)
          (niori-store--secure-file target))
      (niori-store-open))
    (message "niori backup written to %s" target)
    target))

(defun niori--export-file (module extension)
  "Return a fresh export file name for MODULE with EXTENSION."
  (expand-file-name (format "%s-%s.%s" module
                            (format-time-string "%Y%m%d") extension)
                    (niori-data-subdirectory "exports")))

(defun niori--json-pretty (string)
  "Return STRING (JSON) re-indented."
  (with-temp-buffer
    (insert string)
    (ignore-errors (json-pretty-print-buffer))
    (buffer-string)))

(provide 'niori-store)

;;; niori-store.el ends here
