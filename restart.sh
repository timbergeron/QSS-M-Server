#!/bin/sh

###############################################################################
# QSS-M Dedicated Server Launcher with Automatic TLS Certificate Management
#
# This script starts and supervises a QSS-M dedicated Quake server configured
# to accept secure WebSocket connections using TLS.
#
# Before starting the server, the script:
#
#   1. Changes to the QSS-M installation directory.
#
#   2. Checks the expiration date of the TLS certificate currently copied into
#      the QSS-M directory.
#
#   3. If the certificate is missing, unreadable, expired, or has 30 days or
#      fewer remaining, asks whether the Let's Encrypt certificate should be
#      renewed and copied into the QSS-M directory.
#
#   4. Runs Certbot with root privileges when renewal is requested.
#
#   5. Copies the renewed private key and full certificate chain from:
#
#        /etc/letsencrypt/live/denver.quakeone.com/
#
#      into:
#
#        /home/admin/qssm/
#
#      The private key is installed with permissions 600, and the certificate
#      is installed with permissions 644. Both files are owned by admin.
#
#   6. Starts QSS-M as a 16-player dedicated server on UDP/WebSocket port 26000
#      using protocol 666 and advertises its secure WebSocket address as:
#
#        wss://denver.quakeone.com:26000
#
#   7. If QSS-M crashes or exits with a nonzero status, waits 10 seconds and
#      starts it again. If QSS-M exits normally with status 0, this script also
#      exits normally.
#
# The internal --renew-only option is used when the non-root script invokes
# itself through sudo. It renews and copies the certificates without starting
# the QSS-M server.
#
# Requirements:
#
#   - QSS-M-l64 must exist in /home/admin/qssm and be executable.
#   - OpenSSL, Certbot, sudo, and GNU date must be installed.
#   - A Let's Encrypt certificate named denver.quakeone.com must already exist.
#   - The user running this script must be allowed to invoke it through sudo.
#   - DNS and firewall configuration must allow denver.quakeone.com:26000.
###############################################################################

DOMAIN="denver.quakeone.com"
CERT_NAME="denver.quakeone.com"
PORT="26000"
USER_NAME="admin"
QSSM_DIR=""
RENEW_AT_DAYS=30

LIVE_DIR="/etc/letsencrypt/live/$CERT_NAME"
KEY_SRC="$LIVE_DIR/privkey.pem"
CERT_SRC="$LIVE_DIR/fullchain.pem"

KEY_FILE="$QSSM_DIR/privkey.pem"
CERT_FILE="$QSSM_DIR/fullchain.pem"

cd "$QSSM_DIR" || exit 1

cert_days_left() {
  enddate=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2-)
  [ -n "$enddate" ] || return 1

  end_epoch=$(date -d "$enddate" +%s 2>/dev/null)
  now_epoch=$(date +%s)

  echo $(( (end_epoch - now_epoch) / 86400 ))
}

renew_and_copy_certs() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Requesting sudo to renew/copy TLS certs..."
    sudo "$0" --renew-only
    return $?
  fi

  certbot renew --cert-name "$CERT_NAME" || exit 1

  install -o "$USER_NAME" -g "$USER_NAME" -m 600 "$KEY_SRC" "$KEY_FILE" || exit 1
  install -o "$USER_NAME" -g "$USER_NAME" -m 644 "$CERT_SRC" "$CERT_FILE" || exit 1

  echo "Updated QSS-M TLS files:"
  echo "  $KEY_FILE"
  echo "  $CERT_FILE"
  openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates
}

if [ "$1" = "--renew-only" ]; then
  renew_and_copy_certs
  exit 0
fi

if [ ! -r "$CERT_FILE" ]; then
  echo "No readable TLS cert found:"
  echo "  $CERT_FILE"
  days_left=-1
else
  days_left=$(cert_days_left) || days_left=-1
fi

if [ "$days_left" -ge 0 ]; then
  echo "TLS cert for $DOMAIN has about $days_left day(s) left."
else
  echo "TLS cert is missing or unreadable."
fi

if [ "$days_left" -le "$RENEW_AT_DAYS" ]; then
  echo
  echo "Cert is missing, expired, or within $RENEW_AT_DAYS days of expiring."
  printf "Renew/copy certs now? [y/N] "
  read answer

  case "$answer" in
    y|Y|yes|YES)
      renew_and_copy_certs || exit 1
      ;;
    *)
      echo "Skipping renewal."
      ;;
  esac
fi

while true; do
  ./QSS-M-l64 \
    -useice \
    -privkey "$KEY_FILE" \
    -pubkey "$CERT_FILE" \
    -dedicated 16 \
    -port "$PORT" \
    -protocol 666 \
    -condebug \
    +developer 1 \
    +sv_addr_ws "wss://$DOMAIN:$PORT"

  code=$?
  [ "$code" -eq 0 ] && exit 0
  sleep 10
done