# Windows images, editions and release freshness

## Reading an image without DISM

`Read-WdmImageInfo` reads the documented WIM header (208 bytes: `MSWIM` magic, part number and
count, image count, the XML resource header at offset 72) and the uncompressed UTF-16 XML resource
of `install.wim`, `install.esd` or the first `install.swm`. No elevation, no extraction, no DISM. The
XML is parsed with DTDs prohibited. Per image: index, name, display name, `EDITIONID`, architecture
(`ARCH` 0 x86, 9 amd64, 12 arm64), installation type, build, revision (`SPBUILD`), languages, size.
Encrypted or damaged ESD files and images with unreadable metadata are refused.

## Edition selection

The package states `media.requirements` (generic-key deployments): the builder's edition id, the
image `EditionId` (`pro` → `Professional`, `home` → `Core`, `home_single` → `CoreSingleLanguage`,
`pro_workstations` → `ProfessionalWorkstation`, …), the architectures and the minimum build (22000).

- The image is chosen by **EditionId**, never by index or display name (consumer media has Pro at
  index 6, not 1; a display name "Windows 11 Pro" with EditionId `Core` does not count).
- No matching edition → **blocked**. Windows Home is never used for a Pro deployment and the answer
  file is never changed.
- Several matching images → the indexes are listed; the first is assumed (Setup chooses by the
  generic key).
- Interactive, firmware-key and custom-key deployments state no edition: the editions on the media
  are reported and only the architecture is enforced.
- `sources\ei.cfg` / `pid.txt` are reported because they can override the edition.
- Generic keys select an edition; they are not licences. The Final Review licensing note is unchanged.

## Release freshness

`windows-releases.json` is copied from Microsoft's
[Windows 11 release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)
(page updated 2026-10-13, verified 2026-10-22): version, build, availability, end of updates for
Home/Pro and for Enterprise/Education, latest revision. At that date: 26H2 (26300.9711), 26H1
(28000.3231, new devices only), 25H2 (26200.9711), 24H2 (26100.9711; Home/Pro end of updates),
23H2 (22631.7652; Home/Pro end of updates), 22H2 and 21H2 (end of updates).

| Status | Meaning |
|---|---|
| Current | the image is at the latest known revision of its build |
| Outdated | older revision: Windows Update installs the rest after setup; the image is **not** fully patched |
| EndOfService | the release no longer gets updates for this edition family; prefer current media |
| NewerThanKnown | build newer than the most recent release in the data |
| Unknown | build not in the data |
| Unsupported | below build 22000 (not Windows 11): blocked |

Offline (default) the cached data and its verification date are shown. `-CheckOnline` downloads the
same page once (read-only GET) and takes newer revisions or releases from it; if that fails, the
report says so and uses the cache. Distinguished in the report: feature release (version), build,
servicing level (revision) and the source with its date.

## ISO provenance

The assistant states exactly what was checked: the ISO's SHA-256 against a hash you entered (from
Microsoft's download page), and the Authenticode signatures of `setup.exe` and the UEFI boot loader
(must be valid and signed by Microsoft Corporation). Without an entered hash the report says
"Not established". It never claims an ISO is official.
