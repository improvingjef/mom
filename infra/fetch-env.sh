#!/usr/bin/env bash
# Writes /opt/mom-env/.env from SSM /mom/* at service start (like School's).
set -euo pipefail
REGION=us-east-1
PATH_PREFIX=/mom
TMP=$(mktemp)
trap "rm -f $TMP" EXIT
/usr/local/bin/aws ssm get-parameters-by-path --region "$REGION" --path "$PATH_PREFIX" --with-decryption \
  --query "Parameters[].[Name,Value]" --output text | \
while IFS=$'\t' read -r name value; do
  key="${name##*/}"
  escaped=$(printf "%s" "$value" | sed "s/\"/\\\\\"/g")
  printf "%s=\"%s\"\n" "$key" "$escaped" >> "$TMP"
done
install -o ubuntu -g ubuntu -m 0600 "$TMP" /opt/mom-env/.env
echo "Wrote /opt/mom-env/.env with $(wc -l < /opt/mom-env/.env) keys"
