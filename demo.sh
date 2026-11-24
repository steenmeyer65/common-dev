#!/usr/bin/env bash
# Add one repository-specific runner; never stop/reconfigure the foundation runner.
set +x
set -Eeuo pipefail
umask 077
repo='https://github.com/steenmeyer65/T-CloudPOC'
runner_dir='/opt/tcloud-actions-runner'
runner_user='tcloud-runner'
runner_home='/var/lib/tcloud-runner'
mode="${1:---plan}"
if [[ "$mode" == '--plan' ]]; then
  cat <<'PLAN'
Additive host setup for steenmeyer65/T-CloudPOC:
  account: tcloud-runner (unprivileged, no sudo)
  home: /var/lib/tcloud-runner
  install/work: /opt/tcloud-actions-runner
  label: tcloud-ci (plus GitHub default Linux/X64/self-hosted labels)
  service: a separate vendor-generated actions.runner.*T-CloudPOC* service
  restrictions: no IMDS, foundation files, home directories or Docker socket;
                no privilege escalation; 1 CPU and 1500 MB memory limit
  credentials: one-hour repository registration token, prompted without echo
  download: official actions/runner release; SHA-256 digest checked
No change is made in plan mode. No AWS IAM or T-Cloud resources are changed.
Run with --install only inside the authorized EC2 administrator session.
PLAN
  exit 0
fi
[[ "$mode" == '--install' && $# -eq 1 ]] || { echo 'Usage: bash install-tcloud-runner.sh [--plan|--install]' >&2; exit 2; }
[[ "$EUID" -eq 0 ]] || { echo 'Installation needs an authorized root/admin session on the runner host.' >&2; exit 3; }
[[ "$(uname -m)" == 'x86_64' ]] || { echo 'This installer supports Linux x64 only.' >&2; exit 3; }
[[ -d /run/systemd/system ]] || { echo 'A systemd host is required.' >&2; exit 3; }
for tool in curl jq tar sha256sum runuser useradd systemctl install hostname; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 3; }
done
[[ ! -e "$runner_dir" ]] || { echo 'T-Cloud runner directory already exists; inspect it instead of overwriting registration.' >&2; exit 4; }
! id "$runner_user" >/dev/null 2>&1 || { echo 'T-Cloud runner account already exists; inspect the earlier installation.' >&2; exit 4; }
[[ -r /dev/tty && -w /dev/tty ]] || { echo 'Use an interactive administrator session; tokens are never CLI arguments.' >&2; exit 3; }

# Confirm that metadata is reachable from the host, then require the isolated
# service to reject it. Discard the token response body; never request IAM keys.
code=$(curl --noproxy '*' -s --connect-timeout 2 --max-time 4 -o /dev/null -w '%{http_code}' \
  -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token || true)
[[ "$code" == '200' ]] || { echo 'Cannot establish the host IMDS baseline; review host isolation before installing.' >&2; exit 5; }

scratch=$(mktemp -d /tmp/tcloud-runner-install.XXXXXXXX)
trap 'unset registration ACTIONS_RUNNER_INPUT_TOKEN; rm -f "$scratch/release.json" "$scratch/runner.tar.gz"; rmdir "$scratch"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  https://api.github.com/repos/actions/runner/releases/latest -o "$scratch/release.json"
version=$(jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$scratch/release.json")
asset="actions-runner-linux-x64-${version#v}.tar.gz"
url=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' "$scratch/release.json")
digest=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .digest | select(test("^sha256:[0-9a-f]{64}$"))' "$scratch/release.json")
[[ "$url" == "https://github.com/actions/runner/releases/download/$version/$asset" ]] || { echo 'Unexpected release asset URL.' >&2; exit 5; }
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$url" -o "$scratch/runner.tar.gz"
printf '%s  %s\n' "${digest#sha256:}" "$scratch/runner.tar.gz" | sha256sum --check --status
# Validate archive paths before unprivileged extraction into a new directory.
if tar -tzf "$scratch/runner.tar.gz" | grep -E '(^/|(^|/)\.\.(/|$))' >/dev/null; then
  echo 'Unsafe archive path.' >&2; exit 5
fi
printf 'Verified official runner %s (%s).\n' "$version" "$digest"
printf 'Paste only the T-CloudPOC registration token from Settings > Actions > Runners: ' >/dev/tty
IFS= read -r -s registration </dev/tty
printf '\n' >/dev/tty
[[ "$registration" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid registration-token format.' >&2; exit 5; }

useradd --system --user-group --create-home --home-dir "$runner_home" --shell /sbin/nologin "$runner_user"
install -d -m 0700 -o "$runner_user" -g "$runner_user" "$runner_dir"
# Root opens the checked archive; extraction itself runs without root privileges.
runuser -u "$runner_user" -- tar -xzf - -C "$runner_dir" < "$scratch/runner.tar.gz"
cd "$runner_dir"
(
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE GH_TOKEN GITHUB_TOKEN SSH_AUTH_SOCK
  export ACTIONS_RUNNER_INPUT_TOKEN="$registration"
  runuser -u "$runner_user" -- ./config.sh --unattended --url "$repo" \
    --name "tcloud-poc-$(hostname -s)" --labels tcloud-ci --work _work
)
unset registration
# Use GitHub's own service installer, then sandbox only this new service.
./svc.sh install "$runner_user"
service=$(cat .service)
[[ "$service" =~ ^actions\.runner\..*T-CloudPOC.*\.service$ && "$service" != *AWS-Foundation* && "$service" != */* ]] || {
  echo 'Unexpected generated service name; service has not been started.' >&2; exit 6;
}
install -d -m 0755 "/etc/systemd/system/$service.d"
cat > "$runner_dir/check-isolation.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
# These files and sockets must be hidden in the new service mount namespace.
for path in /opt/actions-runner /home/actions /root /run/docker.sock; do
  if [[ -r "$path" ]]; then echo "Isolation check failed: $path is accessible" >&2; exit 1; fi
done
for host in '169.254.169.254' '[fd00:ec2::254]'; do
  code=$(curl --globoff --noproxy '*' -s --connect-timeout 1 --max-time 2 -o /dev/null -w '%{http_code}' \
    -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' "http://$host/latest/api/token" || true)
  if [[ "$code" == '200' ]]; then echo 'Isolation check failed: instance metadata is reachable' >&2; exit 1; fi
done
CHECK
chmod 0755 "$runner_dir/check-isolation.sh"
chown root:root "$runner_dir/check-isolation.sh"
cat > "/etc/systemd/system/$service.d/isolation.conf" <<'UNIT'
[Service]
NoNewPrivileges=yes
CapabilityBoundingSet=
PrivateTmp=yes
PrivateDevices=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/opt/tcloud-actions-runner /var/lib/tcloud-runner
InaccessiblePaths=-/opt/actions-runner -/home/actions -/root -/run/docker.sock -/var/run/docker.sock -/var/lib/amazon/ssm
RestrictSUIDSGID=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
IPAddressDeny=169.254.169.254/32 fd00:ec2::254/128
CPUQuota=100%
MemoryHigh=1G
MemoryMax=1500M
TasksMax=256
ExecStartPre=/opt/tcloud-actions-runner/check-isolation.sh
Environment=AWS_EC2_METADATA_DISABLED=true
Environment=AWS_SHARED_CREDENTIALS_FILE=/dev/null
Environment=AWS_CONFIG_FILE=/dev/null
Environment=ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/tcloud-actions-runner/check-isolation.sh
UNIT
systemctl daemon-reload
systemctl start "$service"
systemctl is-active --quiet "$service"
printf 'New service is active: %s\n' "$service"
printf 'Verify T-CloudPOC > Settings > Actions > Runners shows tcloud-poc-* as Idle.\n'
printf 'Then run T-Cloud runner check. No Terraform plan/apply/destroy was started.\n'
