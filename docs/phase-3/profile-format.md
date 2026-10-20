# Application profile format (Phase 3)

The builder uses **two** JSON formats for applications. They do different jobs and are kept
separate.

| | Microsoft WinGet package list | Builder application profile |
|---|---|---|
| Purpose | Portable package specification for `winget import` / `winget export` | Editing: named, categorised, composable profiles |
| Schema | [`packages.schema.2.0.json`](https://github.com/microsoft/winget-cli/blob/master/schemas/JSON/packages/packages.schema.2.0.json) | `format: "windows-deployment-builder/app-profiles"`, `formatVersion: 1` (strict Zod schema in `src/engine/schema/applications.ts`) |
| Identity | `PackageIdentifier` per `SourceDetails` | `packageIdentifier` + `source` (same rule) |
| Carries | Identifier, optional `Version`, `Scope` (`InitialOverrideArguments`, `InitialCustomSwitches`, `Channel` exist in the schema) | Display name, category, description, inheritance, version/scope, built-in flag, details of unsupported sources |
| Never carries | | Credentials, installer arguments, anything executable |
| Generated as | `winget-packages.json` (deployment asset; "Export selection as WinGet JSON") | `application-profile.json` (deployment asset); "Export all profiles"; per-profile "Export" (Advanced) |
| Read by | `winget import`, the builder's importer, **ApplicationEngine.ps1** (package specification) | The builder's importer |

## Builder profile file

```json
{
  "format": "windows-deployment-builder/app-profiles",
  "formatVersion": 1,
  "exportedUtc": "2026-10-19T12:00:00.000Z",
  "profiles": [
    {
      "id": "family-pc",
      "name": "Family PC",
      "category": "custom",
      "description": "",
      "builtin": false,
      "inherits": ["everyday"],
      "packages": [
        { "packageIdentifier": "Mozilla.Firefox", "source": "winget", "displayName": "Mozilla Firefox", "version": "", "scope": "" },
        { "packageIdentifier": "9MSPC6MP8FM4", "source": "msstore", "displayName": "Microsoft Whiteboard", "version": "", "scope": "machine" }
      ]
    }
  ]
}
```

| Field | Rule |
|---|---|
| `id` | `^[a-z0-9][a-z0-9-]{0,47}$`, unique |
| `name` | 1–80 characters |
| `category` | `everyday`, `gaming`, `developer`, `laptop`, `touch`, `custom` |
| `builtin` | Built-in profiles can be populated and cleared, not renamed or deleted. Imported profiles are always `false`. |
| `inherits` | Ids of other profiles whose packages are included first. Cycles are an error. |
| `packages[].source` | `winget` or `msstore` are installable. Any other source is kept, with `sourceDetails`, as **unresolved** and is never installed. |
| `packages[].packageIdentifier` | winget: 2–8 dot-separated segments of `A-Z a-z 0-9 _ + -` (each ≤ 32). msstore: `9` + 11 or `XP` + 12 characters. Stricter than WinGet on purpose, because the value ends up on a command line. All 165 identifiers of a real `winget export` (development PC, 2026-10-19) pass. |
| `packages[].version` | Empty = latest, else `^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$` |
| `packages[].scope` | `""`, `user` or `machine` |
| `packages[].sourceDetails` | Only for unsupported sources (`Name`, `Identifier`, `Argument`, `Type`) |

The schema is **strict**: unknown members are rejected, not ignored. A file that contains, for
example, a `"password"` or a token cannot be imported. Packages with invalid identifiers are
skipped with a warning; the rest of the profile is imported.

Examples:
- [`examples/empty-profiles.app-profiles.json`](examples/empty-profiles.app-profiles.json): the
  six built-in profiles as shipped (all empty).
- [`tests/fixtures/applications/illustrative-profiles.json`](../../tests/fixtures/applications/illustrative-profiles.json):
  populated **test fixture** (illustrative, not a recommendation or an owner default).
- [`tests/fixtures/applications/winget-export.json`](../../tests/fixtures/applications/winget-export.json):
  a native WinGet export in Microsoft's format.

## In the deployment profile (schema v3)

The deployment profile (`profiles/owner-default.json`, "Export profile") holds the selection under
`applications.selection`:

```json
"selection": {
  "profiles": [ …all profiles, built-in and custom… ],
  "selectedProfiles": ["everyday", "gaming"],
  "added": [ …individually added packages… ],
  "removed": ["winget:7zip.7zip"]
}
```

Combined selection = packages of the selected profiles (with inheritance, in order), then `added`,
minus `removed`. Keys are `source:packageidentifier` in lower case. A display name never decides
identity. When the same key appears more than once it is installed once. If the version or scope
differ, the first occurrence wins, except that an individual addition always wins; both cases are
warned about.

Additional Software entries live in `additionalSoftware.items` (see `orchestration.md`).

## Importing

"Import WinGet or profile JSON…" accepts either format. It detects a WinGet list by its `Sources`
member.

- **Never overwrites.** Every import creates **new** custom profiles (ids and names get a suffix if
  taken) and adds them to the selection. Existing profiles, additions and removals are unchanged,
  and the notice says so. Untick the new profile to leave it out.
- **WinGet lists** are validated against every rule of `packages.schema.2.0.json`: required members,
  types, the `WinGetVersion` pattern, the `CreationDate` date-time format, the `Scope` enum and
  `Packages` minItems 1. Then:
  - `SourceDetails` must match Microsoft's `winget` or `msstore` source exactly (Identifier, Type,
    Argument). A source that only borrows the name becomes `winget (unverified)` and stays
    unresolved, so it can never merge with or be installed as the real package.
  - `InitialOverrideArguments`, `InitialCustomSwitches` and `Channel` are **dropped** with a
    warning. Installer arguments from imported files are never used.
  - Invalid identifiers are reported and skipped. A plausible display name never makes a package
    valid.
  - Limits: 5 MB, 2000 packages.
- Migration from older deployment profiles: the record-only `deferred.wingetPackages` list from
  Milestone 1 is moved into an **unselected** profile "Imported from an older profile", so the
  answer file does not change until someone selects it.

## Exporting

- **WinGet JSON**: schema-valid, grouped by source, with Microsoft's `SourceDetails`, and only
  installable packages. Real `winget import` (1.29.250) accepted a generated file. The deployment
  asset leaves out `CreationDate` so the output is reproducible.
- **Profiles**: the builder format. Credentials cannot occur because the schema has no field for
  them.

Profiles live only in the page's memory unless exported, as for the rest of the app. The only
thing kept in browser storage is the Basic/Advanced view choice.
