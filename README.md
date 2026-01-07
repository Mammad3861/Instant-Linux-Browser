# 🌐 Instant Linux Browser

A professional, interactive Bash script to deploy fully functional, web-accessible browsers (Chromium & Firefox) on your Linux server using Docker. Perfectly optimized for mobile management via SSH.

## ✨ Features
- **Interactive Menu:** Easily install or uninstall browsers.
- **Auto Timezone:** Automatically detects your server's timezone.
- **Secure Access:** Supports custom usernames and passwords for the Web-GUI.
- **One-Line Setup:** No manual configuration needed.
- **Persistent Data:** Configurations and history are saved in `/root/`.

---

## 🚀 Quick Installation

Run this single command on your Ubuntu/Debian server to start the manager:

```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh](https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh))
```

# 🛠 Available Options
​Install Chromium: Accessible on port 3000.
​Install Firefox: Accessible on port 4000.
​Uninstall: Completely removes containers and cleans up.

# ​📱 Mobile Friendly
​Designed to be managed via mobile SSH clients like Termius or JuiceSSH. Once installed, access your server-side browser from any mobile web browser.

# ​📄 License
​This project is under the MIT License.
