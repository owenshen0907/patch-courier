# Storage Migrations

Patch Courier stores daemon state in SQLite at `~/Library/Application Support/PatchCourier/mailroom.sqlite3` by default. The project is still pre-1.0, but schema changes should be predictable because this database contains mailbox cursors, durable turns, approval requests, message replay records, and operator configuration.

## Current Policy

- `SQLiteMailroomStore.currentSchemaVersion` is the single supported schema version for the daemon store.
- The SQLite `PRAGMA user_version` value records the applied schema version.
- A database with `user_version == 0` is treated as a legacy pre-versioned database and is migrated in place with idempotent `CREATE TABLE IF NOT EXISTS`, `ALTER TABLE ... ADD COLUMN`, and `CREATE INDEX IF NOT EXISTS` steps.
- A database with a version newer than the running binary fails closed. Users should run a newer Patch Courier binary instead of letting an older daemon write into a future schema.
- Migrations run inside a transaction after the database is opened and `journal_mode = WAL` is enabled.

## Adding a Schema Change

1. Increase `SQLiteMailroomStore.currentSchemaVersion`.
2. Add a focused migration block for the new version in `migrateIfNeeded()`.
3. Keep migrations additive where possible: new tables, new nullable columns, new indexes, or backfilled values with safe defaults.
4. Avoid destructive rewrites unless a backup/export path is documented in the same change.
5. Add tests that cover upgrading from the previous version and refusing a newer version.
6. Update this document if the compatibility policy changes.

## Compatibility Notes

The schema is not a public API before v1.0. The supported guarantee is operational: current binaries should upgrade older local daemon databases safely, and older binaries should not mutate newer databases.
