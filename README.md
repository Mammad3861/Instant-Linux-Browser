# Instant Linux Browser

A simple Bash installer for running web-accessible Chromium and Firefox Docker containers on a Linux server.

It keeps an interactive menu for installing, uninstalling, checking status, and exiting. It also supports direct non-interactive actions for automation.

<p align="center">
  <img src="preview.jpg" width="600" title="Project Preview">
</p>

## Features

- Interactive Bash menu for install, uninstall, status, and exit.
- Chromium and Firefox containers from linuxserver.io.
- Chromium HTTP on `3000` and HTTPS on `3001`.
- Firefox HTTP on `4000` and HTTPS on `4001`.
- Persistent config in `/opt/instant-linux-browser/<browser>/config`.
- Username/password prompts, with `ILB_USERNAME` and `ILB_PASSWORD` overrides.
- Supports amd64/x86_64 and arm64/aarch64 Linux servers when the upstream image supports them.
- Works when downloaded first or when run through `curl | sudo bash`.

## Install

Use only `raw.githubusercontent.com` URLs for curl commands. Do not use normal GitHub page URLs such as `github.com/.../blob/...`, because those return an HTML page, not the raw Bash script.

### Interactive

```bash
curl -fsSLO https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh
sudo bash browser.sh
```

### One-line interactive

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo bash
```

### Non-interactive Chromium

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-chromium bash
```

### Non-interactive Firefox

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-firefox bash
```

You can also pass credentials:

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-chromium ILB_USERNAME=admin ILB_PASSWORD='change-this-password' bash
```

## Direct Actions

```bash
sudo bash browser.sh install-chromium
sudo bash browser.sh install-firefox
sudo bash browser.sh uninstall-chromium
sudo bash browser.sh uninstall-firefox
sudo bash browser.sh status
```

Environment action form:

```bash
sudo ILB_ACTION=install-chromium bash browser.sh
sudo ILB_ACTION=status bash browser.sh
```

## Menu Options

- `1` - Install Chromium
- `2` - Uninstall Chromium
- `3` - Install Firefox
- `4` - Uninstall Firefox
- `5` - Show status/diagnostics
- `6` - Exit

## Chromium Startup Flags

Chromium is launched with these flags by default:

```text
--no-sandbox --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage --disable-setuid-sandbox
```

The script passes them to the linuxserver/chromium container through both `CHROME_CLI` and `CHROME_FLAGS`.

To override them:

```bash
sudo CHROMIUM_FLAGS="--no-sandbox --disable-dev-shm-usage" bash browser.sh install-chromium
```

## Docker Notes

The script checks that Docker is installed and running. On Ubuntu/Debian systems, it can install Docker from the system package repositories if Docker is missing.

Before starting a browser, the script:

- checks the server architecture;
- checks that required ports are available;
- pulls the selected Docker image;
- creates the persistent config directory;
- starts the container;
- verifies that the container is still running.

If startup fails, check logs:

```bash
sudo docker logs chromium
sudo docker logs firefox
```

## Uninstall

Uninstall removes the container but keeps persistent config:

```text
/opt/instant-linux-browser/chromium/config
/opt/instant-linux-browser/firefox/config
```

Delete those directories manually only if you no longer need the browser profile data.

## Security

If exposing the browser to the public internet:

- use a strong password;
- restrict access with a firewall, VPN, or IP allow-list;
- consider putting it behind Nginx, Traefik, or another HTTPS reverse proxy;
- avoid exposing ports `3000`, `3001`, `4000`, or `4001` publicly unless needed.

Empty passwords are allowed, but the script warns when one is selected.

## License

MIT
