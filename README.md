# 🌐 Instant Linux Browser

A professional, interactive Bash script to deploy fully functional, web-accessible browsers (Chromium & Firefox) on your Linux server using Docker. Perfectly optimized for mobile management via SSH.

## ✨ Features
- **Interactive Menu:** Easily install or uninstall browsers.
- **Secure Access:** Supports custom usernames and passwords for the Web-GUI.
- **One-Line Setup:** No manual configuration needed.


---

## 🚀 Quick Installation

Run this single command on your Ubuntu/Debian server to start the manager:

```bash
bash <(curl -fsSL (https://raw.githubusercontent.com/Mammad3861/Instant-Linux-Browser/main/browser.sh))
```

# 🛠 Available Options
​Install Chromium: Accessible on port 3000.
​Install Firefox: Accessible on port 4000.
​Uninstall: Completely removes containers and cleans up.

## 🔒 Security Recommendations
For production environments, it is highly recommended to:
- Use a strong password (at least 12 characters).
- Run the browser behind a Reverse Proxy (like Nginx or Traefik) to enable HTTPS.
- Use a Firewall (UFW/IPTables) to restrict access to specific IP addresses if possible.

## ⚙️ Advanced Configuration
The script automatically handles the following environment variables for optimal performance:
- `PUID/PGID`: Set to 1000 for proper permission handling.
- `shm-size`: Allocated 1GB to prevent tab crashing in Chromium.
- `seccomp`: Configured to allow secure browser sandboxing.

## 🛠 Troubleshooting
If you encounter a "Connection Refused" error:
1. Ensure the ports (3000 for Chromium, 4000 for Firefox) are open in your server's security group/firewall.
2. Check if Docker is running using `sudo systemctl status docker`.
3. View container logs with `docker logs chromium` or `docker logs firefox`.


# ​📄 License
​This project is under the MIT License.
