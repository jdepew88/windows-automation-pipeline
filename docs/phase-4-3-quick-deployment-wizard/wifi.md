# Wi-Fi from SSID and password (Phase 4.3)

## What happens on the computer

1. The answer file embeds `C:\Windows\Setup\Scripts\Wifi.xml` (a WLAN profile) and
   `Add-WifiProfile.ps1`, and hides nothing else: Ethernet and the OOBE network page are unchanged.
2. **specialize:** `Add-WifiProfile.ps1 -Stage Specialize` waits up to 60 s for the WLAN AutoConfig
   service, looks for a physical 802.11 adapter whose driver is loaded, and runs
   `netsh wlan add profile filename=… user=all` (then `netsh wlan connect` when "Connect
   automatically" is on).
3. **First sign-in:** if specialize had no adapter/driver or Windows rejected the profile, the
   script runs once more (`-Stage FirstLogon`) **before** the existing sensitive-file cleanup deletes
   `Wifi.xml`. Afterwards the result is final.
4. The result is written to `C:\ProgramData\WindowsDeploymentBuilder\Network\wifi-result.json`
   and `wifi.log` (status, stage, profile name, adapter count, message; never the key) and appears
   in the deployment report as a follow-up when it is not `Added`.

| Status | Meaning |
|---|---|
| `Added` | profile added for all users |
| `ConnectRequested` / `ConnectFailed` | profile added; a connection was requested (not verified) / the request failed (Windows connects when in range) |
| `NoWirelessAdapter` | no Wi-Fi adapter with a working driver (retried at first sign-in, then final) |
| `NoWirelessService` | no WLAN AutoConfig service on this installation |
| `ImportFailed` | `netsh` rejected the profile (retried once) |
| `ProfileMissing`, `Failed` | file missing / unexpected error |

Wireless networking cannot work before Windows has a driver for the adapter. A driver installed
later by Windows Update or the manufacturer is **not** followed by another attempt: the report tells
the person to connect by hand. Whether a real adapter connects has to be validated in a VM or on
hardware.

## Input handling

* SSID: 1–32 bytes UTF-8; any characters. The exact bytes go to `SSIDConfig/SSID/hex`; the readable
  name is XML-escaped. SSIDs with double quotes, leading/trailing spaces or non-ASCII characters get
  a stable ASCII profile label (`WiFi-<hex>`), because `netsh` arguments cannot carry them safely;
  the network itself is matched by its hex SSID. (Before Phase 4.3, quotes were rejected.)
* Password: 8–63 printable ASCII characters (WPA2/WPA3 passphrase) or a 64-digit hexadecimal key
  (`keyType networkKey`). Empty SSID or password is an error at the field. Open networks need none.
* Security: WPA2-Personal (AES), WPA3-Personal with WPA2 transition, Open. Hidden network
  (`nonBroadcast`) and "Connect automatically" are optional.
* Both the wizard (step 3) and Advanced › Wi-Fi edit the same fields; SSID and password appear on
  the same page as the mode choice.

## Security model

The Wi-Fi password is stored **in plain text** in `autounattend.xml` (inside the ZIP and on the USB
drive) and in `C:\Windows\Panther\unattend.xml` and `Wifi.xml` on the installed computer until the
first sign-in deletes them (unless "Keep sensitive files" is on). Nothing is encrypted and no
reversible obfuscation is used. Therefore:

* the field is masked by default (show/hide button), uses `autocomplete="new-password"`, and is
  never written to `localStorage` (the configuration is not persisted at all);
* `exportProfile()` and `profiles/windows-settings.json` in the ZIP omit it (unless "Include
  passwords" is ticked on export); the manifest says `containsSecrets: true`;
* the review shows only "Password entered (not shown)";
* Final Review requires a confirmation that the ZIP and USB drive contain the password; in Advanced
  the download buttons ask once per session;
* `Add-WifiProfile.ps1` never logs the XML, redacts the key from `netsh` output and keeps it in a
  variable that is cleared afterwards;
* generation happens in the browser; nothing is sent to Cloudflare or any server.
