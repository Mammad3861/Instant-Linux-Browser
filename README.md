# 🌐 Instant Linux Browser

A lightweight Bash script to deploy web-accessible **Chromium** and **Firefox** containers on a Linux server using Docker.

It is useful when you want a full browser on a VPS/server and want to access it from your laptop or phone.

<p align="center">
  <img src="preview.jpg" width="600" title="Project Preview">
</p>

## ✨ Features

- Interactive Bash menu for install/uninstall/status.
- Chromium and Firefox deployment through linuxserver.io Docker images.
- Supports common **amd64** and **arm64** Linux servers when the upstream Docker image supports the architecture.
- Web UI username/password prompts.
- Persistent config under `/opt/instant-linux-browser`.
- Chromium startup flags for restricted VPS/Docker environments.
- Works with normal downloaded script mode and one-line `curl | sudo bash` mode.

## 🚀 Quick Installation

### Recommended interactive install

Run this on your Ubuntu/Debian server:

```bash
curl -fsSLO https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh
sudo bash browser.sh
```

Then choose the option you want from the menu.

### One-line interactive install

This also works because the script reads menu input from your real terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo bash
```

Important: use the `raw.githubusercontent.com` link above. If you use the normal GitHub page URL, your terminal may download/show HTML instead of the Bash script.

### One-line non-interactive install

Install Chromium:

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-chromium bash
```

Install Firefox:

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-firefox bash
```

Install Chromium with credentials:

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-chromium ILB_USERNAME=admin ILB_PASSWORD='change-this-password' bash
```

## 🛠 Available Options

- `1` / `install-chromium` — Install Chromium on HTTP `3000` and HTTPS `3001`.
- `2` / `uninstall-chromium` — Remove Chromium container.
- `3` / `install-firefox` — Install Firefox on HTTP `4000` and HTTPS `4001`.
- `4` / `uninstall-firefox` — Remove Firefox container.
- `5` / `status` — Show container status.
- `6` / `exit` — Exit.

You can also run actions directly:

```bash
sudo bash browser.sh install-chromium
sudo bash browser.sh uninstall-chromium
sudo bash browser.sh install-firefox
sudo bash browser.sh uninstall-firefox
sudo bash browser.sh status
```

## 🧩 Architecture Support

This project is Docker-based. Docker automatically pulls the image variant that matches your server architecture when available.

Expected server architectures:

- `amd64` / `x86_64`
- `arm64` / `aarch64`

If Docker cannot pull the image, check whether the upstream linuxserver.io image supports your exact CPU architecture.

## 🔒 Security Recommendations

If exposing this service to the public internet:

- Use a strong password.
- Put it behind Nginx, Traefik, or another reverse proxy with HTTPS.
- Restrict access with UFW, cloud firewall rules, VPN, or IP allow-listing.
- Avoid exposing ports `3000`, `3001`, `4000`, or `4001` to the whole internet unless necessary.

## ⚙️ Chromium Notes

Chromium is started with these flags by default:

```text
--no-sandbox --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage --disable-setuid-sandbox
```

These flags help Chromium run on restricted VPS, Docker, root, and CI-like environments.

To override Chromium flags:

```bash
sudo CHROMIUM_FLAGS="--no-sandbox --disable-dev-shm-usage" bash browser.sh install-chromium
```

## 🔍 Troubleshooting

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

If the menu does not wait for your input:

- Use the recommended downloaded-script method:

```bash
curl -fsSLO https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh
sudo bash browser.sh
```

- Or pass an action directly:

```bash
curl -fsSL https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh | sudo ILB_ACTION=install-chromium bash
```

If the terminal shows script/HTML content and exits:

- Make sure you are using the raw link:

```text
https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh
```

- Do not use the normal GitHub page URL like:

```text
https://github.com/Mammad3861/Instant-Linux-Browser/blob/main/browser.sh
```

If Chromium shows a black screen or exits:

- Check `sudo docker logs chromium`.
- Try Firefox first; Firefox is often more stable on some ARM servers.
- Make sure ports `3000` and `3001` are open in both the server firewall and cloud firewall.

## 📄 License

MIT
