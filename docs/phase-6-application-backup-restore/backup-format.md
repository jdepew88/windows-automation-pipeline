# Backup package format (`windows-deployment-builder/app-backup`, format version 1)

```
WDB-AppBackup-20261021-120000-a1b2c3\
  backup-manifest.json        what is in the backup, with the SHA-256 and size of every file
  SUMMARY.txt                 the preview: included, left out (with reasons), never included, notes
  RESTORE-INSTRUCTIONS.txt    where to put it, how to validate and restore by hand
  data\<adapter>\<logical>    the settings (filtered), e.g. data\vscode\settings.json,
                              data\vscode\snippets\python.json, data\putty\Sessions.json
```

With `-Zip` the same tree is also written as an uncompressed (stored) ZIP.

## Manifest

| Member | Content |
|---|---|
| `format`, `formatVersion` (1), `backupId` (16 hex), `folderName`, `createdUtc` | identity |
| `collector` | `name`, `version` |
| `source` | `osName`, `osBuild`, `architecture` (no user or computer name) |
| `inventoryId` | the inventory it belongs to, or empty |
| `adapters[]` | `id`, `name`, `adapterVersion`, `restoreMode` (`automatic`/`review`), `items[]` (`logical`, `kind`, `path` = `data/<id>/<logical>`, `size`, `sha256`), `excluded[]` (`logical`, `reason`), `notes[]` |
| `unsupported[]` | requested adapters that are not supported, with the reason |
| `totals` | files, bytes |
| `notice` | what a settings backup does not contain |

The website and the deployment refer to a backup by **the SHA-256 of `backup-manifest.json`** (as
written: UTF-8, no BOM). The manifest in turn hashes every file, so the pinned hash fixes the whole
backup.

Registry items (`kind` `registryTree`/`registryValues`) are JSON exports
(`windows-deployment-builder/registry-export`): the HKCU path, then key → value name →
`{ type: String|DWord, data }`. DWORDs are stored unsigned.

## Limits

| Limit | Value |
|---|---|
| file | 1 MB (settings files are small; anything larger is reported as data) |
| adapter | 5 MB |
| backup | 20 MB |
| files in one folder item | 100 |
| manifest | 1 MB |
| ZIP | 2000 entries, 50 MB expanded, compression ratio ≤ 100 for entries over 1 MB |
| registry | 500 keys, 200 values per key, 4096 characters per string |

## Validation (`Test-WdbBackup`; a failure stops every restore)

1. The manifest exists, is not a link, is ≤ 1 MB, is UTF-8 JSON of this format and version.
2. When a hash is expected (deployment, recovery tool): the manifest's SHA-256 equals it.
3. Backup id and folder name match their patterns.
4. For each adapter known to this version (unknown or newer adapters are skipped with a warning,
   never trusted): every item's logical name is one the adapter's **trusted definition** restores,
   its path is exactly `data/<adapter>/<logical>`, it stays inside the backup folder without crossing
   a link, the file exists with the listed size and SHA-256, and the size limits hold.
5. No link anywhere under `data\`. Files not listed are reported and never used.

ZIP extraction (`Expand-WdbBackupArchive`) goes into a new empty folder and refuses rooted, drive,
`..`, alternate-stream and control-character names, any entry outside the backup layout, too many
entries, too many bytes and compression bombs, before writing anything.

Staging (`Copy-WdbBackup`) copies only the manifest and the listed files, then validates the copy.
Restore destinations always come from the adapter definitions in the script; the backup can only
name items, never paths, programs or commands.
