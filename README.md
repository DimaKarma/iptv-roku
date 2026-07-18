# IPTV Player for Roku

## Install via the deploy script (Windows)
1. Enable Developer Mode on the Roku TV: `Home x3, Up x2, Right, Left, Right, Left, Right`.
2. Set a password and note the TV's IP address.
3. Open `deploy.ps1` and fill in your `RokuIp` and `RokuPass` at the top of the script.
4. Run `deploy.ps1` in PowerShell. It builds the ZIP archive and uploads it to the TV automatically.

## Install manually
1. Build a ZIP archive from the `manifest` and `config.json` files and the `source`, `components`, and `images` folders (note that `manifest` must sit at the archive root, not inside a folder).
2. Open a browser on your PC and go to `http://<ROKU_IP>`.
3. Enter the username `rokudev` and your Developer Mode password.
4. Click **Upload** and select the ZIP archive you created.
5. Click **Install**.

## Debugging
To view BrightScript logs and errors, use telnet:
```cmd
telnet <ROKU_IP> 8085
```
If `telnet` is not installed on Windows, enable it via "Turn Windows features on or off", or use PuTTY (connection type: Raw, port 8085).
