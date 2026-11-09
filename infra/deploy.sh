#!/usr/bin/env bash
# Build and run Mom on its server (docs/multi-target.md):
#   infra/deploy.sh [IP]          SYNC_UNIT=1 also installs the unit and env fetcher.
# Erlang and Elixir are in /opt/erlang and /opt/elixir (Hex prebuilt builds).
set -euo pipefail
IP=${1:-$(aws ec2 describe-instances --filters Name=tag:Name,Values=mom Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)}
KEY=${KEY:-$HOME/.ssh/mom.pem}
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new"
cd "$(dirname "$0")/.."
echo "==> mom at $IP"
rsync -az --delete --exclude='_build*' --exclude='deps' --exclude='.git' --exclude='.elixir_ls' --exclude='*.dump' \
  -e "$SSH" ./ "ubuntu@$IP:/opt/mom-build/"
if [ "${SYNC_UNIT:-}" = 1 ]; then
  rsync -az -e "$SSH" infra/mom.service infra/fetch-env.sh "ubuntu@$IP:/tmp/"
  $SSH "ubuntu@$IP" "sudo install -m 0644 /tmp/mom.service /etc/systemd/system/mom.service \
    && sudo install -m 0755 /tmp/fetch-env.sh /opt/mom-env/fetch-env.sh && sudo systemctl daemon-reload && sudo systemctl enable mom"
fi
$SSH "ubuntu@$IP" << 'REMOTE'
set -euo pipefail
export MIX_ENV=prod HOME=/home/ubuntu PATH=/opt/erlang/bin:/opt/elixir/bin:$PATH
cd /opt/mom-build
mix local.hex --force --if-missing >/dev/null; mix local.rebar --force --if-missing >/dev/null
mix deps.get --only prod
mix release mom --overwrite
sudo systemctl stop mom || true
rsync -a --delete --exclude=var _build/prod/rel/mom/ /opt/mom/
sudo systemctl start mom
sleep 3; curl -fsS localhost:4400/health && echo
REMOTE
