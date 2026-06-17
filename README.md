# Instant Linux Browser

A lightweight Bash script to deploy web-accessible Chromium and Firefox containers on a Linux server using Docker.
It is useful when you need a full browser available over SSH-managed infrastructure and want to access it from your laptop or phone.

<p align="center">
  <img src="preview.jpg" width="600" title="Project Preview">
</p>

## Features

- Interactive install and uninstall menu.
- Chromium and Firefox container deployment through linuxserver.io images.
- Web UI username and password prompts.
- Safer persistent config path under `/opt/instant-linux-browser`.
- Chromium startup flags for common Docker/server failures.
- Startup diagnostics with Docker logs when a container fails to launch.

## Quick Installation

For interactive setup, download the script first and then run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh
sudo bash browser.sh
```

For a one-line non-interactive Chromium install:

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-chromium bash
```

For a one-line non-interactive Firefox install:

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-firefox bash
```

For unattended Chromium setup with credentials:

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-chromium ILB_USERNAME=admin ILB_PASSWORD='change-this-password' bash
```

Plain `curl ... | sudo bash` is not supported for the interactive menu. In that mode Bash reads the script from stdin, so the menu cannot safely read your choice from the same stream. Download the script first for menu mode, or pass `ILB_ACTION` for a pipe install.

## Available Options

- Install Chromium: HTTP on port `3000`, HTTPS on port `3001`.
- Install Firefox: HTTP on port `4000`, HTTPS on port `4001`.
- Uninstall Chromium or Firefox containers.
- Run browser diagnostics.

Actions can be passed as either the first argument or `ILB_ACTION`:

```bash
sudo bash browser.sh install-chromium
sudo bash browser.sh uninstall-chromium
sudo bash browser.sh install-firefox
sudo bash browser.sh uninstall-firefox
sudo bash browser.sh diagnostics
sudo ILB_ACTION=diagnostics bash browser.sh
```

## Server Setup

The script is Docker-first. Chromium and Firefox run inside containers, so the host does not need a locally installed browser.

By default, the script installs only host packages it needs to run, such as `curl` and `ca-certificates` when Docker installation requires them.
If you also want host packages commonly required by local headless Chromium and automation tools, opt in with `ILB_INSTALL_HOST_DEPS=1`:

```bash
sudo ILB_INSTALL_HOST_DEPS=1 bash browser.sh install-chromium
```

Optional host dependency list:

```text
ca-certificates curl fonts-liberation libasound2t64/libasound2
libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 libdrm2 libgbm1
libgtk-3-0 libnspr4 libnss3 libx11-xcb1 libxcomposite1 libxdamage1
libxrandr2 xdg-utils
```

If Docker is missing, the script installs Docker using `https://get.docker.com`.

## Chromium Launch Hardening

Chromium is started with these flags by default:

```text
--no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage --disable-gpu
```

These flags help in Docker, root, VPS, and CI-like environments where Chromium often fails because sandboxing or shared memory is restricted.
The container also uses `--shm-size=2gb`.

To override Chromium flags:

```bash
sudo CHROMIUM_FLAGS="--no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage --disable-gpu --disable-software-rasterizer" bash browser.sh
```

## Browser Binary Detection

The script checks common host browser locations for diagnostics:

- `CHROME_BIN`
- `PUPPETEER_EXECUTABLE_PATH`
- `/usr/bin/chromium`
- `/usr/bin/chromium-browser`
- `/usr/bin/google-chrome`
- `/usr/bin/google-chrome-stable`
- `/snap/bin/chromium`

`PLAYWRIGHT_BROWSERS_PATH` is printed when set so CI/server environments are easier to debug.

This project does not use Puppeteer, Playwright, or Selenium directly. If you add them later, recommended install commands are:

```bash
npx puppeteer browsers install chrome
npx playwright install --with-deps chromium
```

## Security Recommendations

If exposing this service to the public internet:

- Use a strong password.
- Put the service behind Nginx, Traefik, or another reverse proxy with HTTPS.
- Restrict access using UFW, cloud firewall rules, VPN, or IP allow-listing.
- Avoid exposing ports `3000`, `3001`, `4000`, or `4001` to the whole internet unless necessary.

## Troubleshooting

Check running containers:

```bash
sudo docker ps
```

View logs:

```bash
sudo docker logs chromium
sudo docker logs firefox
```

Check container state:

```bash
sudo docker inspect chromium --format '{{.State.Status}} {{.State.Error}}'
```

If Chromium exits immediately or shows a black screen:

- Confirm the container is running with `sudo docker ps`.
- Check `sudo docker logs chromium`.
- Keep `--no-sandbox` and `--disable-setuid-sandbox` enabled on restricted servers.
- Confirm ports `3000` and `3001` are open in the host firewall and cloud firewall.
- Try Firefox if the server kernel or architecture blocks Chromium.

If Docker starts but images fail to pull, check DNS and outbound network access from the server.

## License

MIT
