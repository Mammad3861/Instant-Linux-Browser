# Instant Linux Browser

A simple Bash installer for running web-accessible Chromium and Firefox Docker containers on a Linux server.

It keeps an interactive menu for installing, uninstalling, checking status, and exiting. It also supports direct non-interactive actions for automation.

<p align="center">
  <img src="preview.jpg" width="600" title="Project Preview">
</p>

## Features

- Interactive Bash menu for install, uninstall, status, and exit.
- Chromium and Firefox containers from linuxserver.io.
- Chromium HTTPS on `3001`; HTTP on `3000` is for a reverse proxy only.
- Firefox HTTPS on `4001`; HTTP on `4000` is for a reverse proxy only.
- Persistent config in `/opt/instant-linux-browser/<browser>/config`.
- Username/password prompts, with `ILB_USERNAME` and `ILB_PASSWORD` overrides.
- Optional trusted HTTPS for a custom domain through the official Caddy image.
- Supports amd64/x86_64 and arm64/aarch64 Linux servers when the upstream image supports them.
- Keeps the one-command interactive installer and direct actions for automation.

## Install

Use only `raw.githubusercontent.com` URLs for curl commands. Do not use normal GitHub page URLs such as `github.com/.../blob/...`, because those return an HTML page, not the raw Bash script.

### One-command interactive installer

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo bash
```

The script reads menu choices and credentials from your controlling terminal, so this remains interactive even though the script is streamed through standard input.

Use the HTTPS browser URL shown after installation. The HTTP URL is for a reverse proxy only.

### Download first

```bash
curl -fsSLO https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh
sudo bash browser.sh
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

## Custom Domain HTTPS

IP/port installation remains the default. To use a real domain, set `ILB_DOMAIN`; `ILB_ACME_EMAIL` is optional:

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-chromium ILB_USERNAME=admin ILB_PASSWORD='change-this-password' ILB_DOMAIN=browser.example.com ILB_ACME_EMAIL=admin@example.com bash
```

When installing interactively, you can also enter a domain after the browser credentials. Leave it blank to keep IP/port mode. Domain mode uses one shared `caddy:2-alpine` container, and Caddy automatically obtains and renews the public certificate.

Before installation:

- point the domain's DNS A and, when used, AAAA records to the VPS;
- open inbound TCP ports `80` and `443`;
- handle any existing nginx, Apache, Caddy, or other service using those ports manually;
- remove incorrect AAAA records, because they can break certificate validation;
- for Cloudflare, use DNS-only mode during initial certificate issuance, then enable proxying only after it is configured correctly.

Domain-enabled browser ports are bound to loopback only; public traffic enters through Caddy. The browser username and password are still required. View proxy logs with:

```bash
docker logs instant-linux-browser-caddy
```

## Direct Actions

```bash
sudo bash browser.sh install-chromium
sudo bash browser.sh install-firefox
sudo bash browser.sh uninstall-chromium
sudo bash browser.sh uninstall-firefox
sudo bash browser.sh diagnostics
```

Environment action form:

```bash
sudo ILB_ACTION=install-chromium bash browser.sh
sudo ILB_ACTION=diagnostics bash browser.sh
```

## Menu Options

- `1` - Install Chromium
- `2` - Uninstall Chromium
- `3` - Install Firefox
- `4` - Uninstall Firefox
- `5` - Diagnostics
- `6` - Exit

If the browser window is closed, right-click the empty desktop and select Chromium or Firefox to launch it again. Keeping the browser closed reduces active CPU and memory usage while the container remains available.

## Chromium Compatibility

Chromium is launched with these flags by default:

```text
--no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox
```

The script passes these flags through `CHROME_CLI` and retains `CHROME_FLAGS` for older setups. It also sets `PIXELFLUX_WAYLAND=false` to use the compatible X11 path on headless VPS servers.

Chromium startup waits briefly for both the container and Chromium process. If either fails, the installer prints recent logs and focused Docker commands for diagnosis.

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
- verifies that the container is running and, for Chromium, that its process exists.

`diagnostics` is read-only: it reports Docker state when available and never installs Docker or starts its daemon.

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
/opt/instant-linux-browser/proxy
```

Domain-route cleanup reuses Caddy while another browser route remains and removes only the project-owned Caddy container after the last route is removed. Browser profiles and persistent Caddy certificate/configuration data are kept. Delete those directories manually only if you no longer need them.

## Security

If exposing the browser to the public internet:

- use a strong password;
- do not expose HTTP port `3000` directly; use it behind a reverse proxy;
- treat `CUSTOM_USER` and `PASSWORD` as basic protection for a trusted local network, not sufficient public Internet protection;
- use HTTPS and a reverse proxy with robust authentication for public exposure;
- restrict access with a firewall, VPN, or IP allow-list.

Empty passwords are allowed, but the script warns when one is selected.

## License

MIT
