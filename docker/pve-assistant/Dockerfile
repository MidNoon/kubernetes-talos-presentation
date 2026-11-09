FROM debian:trixie-slim
ADD https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg /usr/share/keyrings/proxmox-archive-keyring.gpg
RUN chmod 0644 /usr/share/keyrings/proxmox-archive-keyring.gpg \
 && echo 'deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/pve trixie pve-no-subscription' >/etc/apt/sources.list.d/pve.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends proxmox-auto-install-assistant xorriso \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["proxmox-auto-install-assistant"]
