#!/bin/sh
set -e

[ "$1" = "configure" ] || exit 0

SERVICE=beszel
SERVICE_USER=beszel
DATA_DIR=/var/lib/beszel

# Create group and user
if ! getent group "$SERVICE_USER" >/dev/null; then
	echo "Creating $SERVICE_USER group"
	addgroup --quiet --system "$SERVICE_USER"
fi

if ! getent passwd "$SERVICE_USER" >/dev/null; then
	echo "Creating $SERVICE_USER user"
	adduser --quiet --system "$SERVICE_USER" \
		--ingroup "$SERVICE_USER" \
		--no-create-home \
		--home "$DATA_DIR" \
		--gecos "System user for $SERVICE"
fi

# Create data directory
if [ ! -d "$DATA_DIR" ]; then
	mkdir -p "$DATA_DIR"
	chown "$SERVICE_USER":"$SERVICE_USER" "$DATA_DIR"
	chmod 0750 "$DATA_DIR"
fi

deb-systemd-helper enable "$SERVICE".service
systemctl daemon-reload
deb-systemd-invoke start "$SERVICE".service || echo "could not start $SERVICE.service!"
