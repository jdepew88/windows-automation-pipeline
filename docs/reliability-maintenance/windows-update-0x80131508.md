# Windows Update 0x80131508 (`IndexOutOfRangeException`): root cause and repair (engine 2.0.0)

## Evidence and what it does and does not show

**Field observation.** The owner reported the spare-computer installation of 2026-11-26. No PDF screenshots, logs or report files from that computer were available in this workspace. A search of the workspace and the owner's Desktop, Downloads and Documents folders found none, and `Deployment report.lnk` is only a shortcut. So this is what was reported, not what was read:

- the morning snapshot showed 0 updates installed and 16 failed;
- all 16 failures had the same `0x80131508 COR_E_INDEXOUTOFRANGE`, with the text "Index was outside the bounds of the array";
- the failures spanned unrelated packages: Intel, NVIDIA and Realtek drivers and Windows security updates;
- retries and a Windows Update component reset did not change anything.

**Files that would confirm it on that computer.** Read-only; nothing has to be changed to collect them:

- `C:\ProgramData\WindowsDeploymentBuilder\Updates\logs\engine.log`. Engine 1.3.0 logged `Install call failed: …` / `Download call failed: …` with the PowerShell stack trace; the line number in that trace identifies the statement.
- `C:\ProgramData\WindowsDeploymentBuilder\Updates\result.json` and `state.json`. The `errorSource` and `lastException` fields show `engine` and `IndexOutOfRangeException`.
- `C:\ProgramData\WindowsDeploymentBuilder\reports\deployment-report.txt` and `.json`. These are the files the "Deployment report" shortcut points at.

`Invoke-WindowsUpdateRetry.ps1 -Mode ExportDiagnostics` collects all of them into one ZIP and changes nothing.

## Root cause (reproduced)

In engines 1.0.0 to 1.3.0, `New-WduCollection` built a `Microsoft.Update.UpdateColl` and returned it as `$coll`, the last statement of the function.

PowerShell enumerates any enumerable object a function outputs, and the WUA update collection is enumerable. So the caller never received the collection:

| Updates in the collection | What `$coll = New-WduCollection …` received |
| --- | --- |
| 1 (every download, since 1.2.0 downloads one at a time) | the bare `IUpdate` COM object |
| several (an installation batch) | `System.Object[]` |
| 0 | `$null` |

Assigning anything other than a real `IUpdateCollection` to `IUpdateDownloader.Updates` or `IUpdateInstaller.Updates` makes PowerShell's COM property binder throw `System.IndexOutOfRangeException: Index was outside the bounds of the array.` (HRESULT `0x80131508`). This happens before Windows Update is called at all.

Reproduced on Windows 11 (build 26220) with Windows PowerShell 5.1, using real WUA objects (read-only: searched, never downloaded or installed):

```
search: 4 update(s) offered
1.3.0 pattern with a real update: received System.__ComObject; assignment raised System.IndexOutOfRangeException 0x80131508: Index was outside the bounds of the array.
[none] 2.0.0 path: collection of 0 accepted by downloader (0) and installer (0)
[one]  2.0.0 path: collection of 1 accepted by downloader (1) and installer (1)
[all]  2.0.0 path: collection of 4 accepted by downloader (4) and installer (4)
```

**Consequences, all consistent with the field report:**

- **The engine never installed anything.** Every download and every installation since engine 1.0.0 failed the same way. The updates that appeared installed after earlier deployments were installed by Windows' own automatic updates running alongside.
- **Unrelated packages failed identically.** The exception came from the engine, not from any update, so Intel, NVIDIA, Realtek and security updates all showed the same error.
- **Optional drivers always failed.** Windows does not install optional drivers automatically, and since 1.2.0 they were included by default.
- **Retries and resets could not help.** The failure is deterministic. A component reset (SoftwareDistribution, catroot2) changes nothing in a PowerShell binder. Engine 1.3.0 also labelled the error "the update's installer or the calling code" and reset components anyway.
- **The simulation tests missed it.** They replace the whole WUA adapter, and the adapter is where the defect was.

## Repair (engine 2.0.0)

1. **The collection survives the return.** `New-WduCollection` returns `, $coll`. `Invoke-WduOperation` also returns its value with the unary comma.
2. **Each assignment is checked first.** `Assert-WduCollection` verifies the type and count before any assignment. An unrolled value is reported as an *engine defect*, naming the type it received.
3. **Results are mapped by identity.** Per-update results are matched by update identity (`Item(i).Identity.UpdateID`), not by position. A missing result is reported as missing, never invented.
4. **Every WUA call is a named operation.** An exception records:
   - the operation, for example `install: assign updates to installer`;
   - the real exception type, after unwrapping `SetValueInvocationException`;
   - the HRESULT and message;
   - the script line and statement;
   - the stack trace.

   These go into `state.json`/`result.json` (`engineExceptions`) and the log.
5. **An engine exception is one engine error, not one failure per update.**
   - The updates' attempts are not used up by it.
   - A batch is isolated one update at a time.
   - The same exception (same operation, type and line) twice stops the stage, as `EngineException` with a technician action.
   - Components are not reset, and the application stage is not held back, because the task is removed.
6. **A component reset happens only when warranted.** Only `WU_E_DM_*` (download cache), `WU_E_DS_*` (data store) or `CRYPT_E_NOT_FOUND` (catalog database) failures trigger one.

**Regression tests** (`tests/powershell/Engine.Tests.ps1`):

- **"ROOT CAUSE (live COM, read-only)".** Uses real WUA objects to show that the 1.3.0 pattern throws exactly this exception and the 2.0.0 path does not.
- **"the field failure (16 updates, same engine exception) is ONE engine error".** Checks:
  - no installer failures;
  - two identical engine exceptions;
  - all 16 updates reported as not attempted;
  - no component reset;
  - the task removed;
  - no update attempt used up.

## What is and is not proven

- **Proven on real Windows (read-only):**
  - the defect;
  - the corrected collection path, with real updates and a real downloader and installer;
  - the device recorded for each driver.
- **Proven by simulation:**
  - readiness;
  - passes A to D;
  - categories;
  - isolation;
  - restart and resume;
  - verification.
- **Not yet proven:** a real download and installation by engine 2.0.0. The first real proof is the spare-computer retry described in [`spare-computer-retest.md`](spare-computer-retest.md).
