#!/usr/bin/env bash
set -euo pipefail

if nix_path="$(type -p nix)" ; then
  echo "Aborting: Nix is already installed at ${nix_path}"
  exit
fi

# GitHub command to put the following log messages into a group which is collapsed by default
echo "::group::Installing Nix"

# Create a temporary workdir
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Configure Nix
add_config() {
  echo "$1" >> "$workdir/nix.conf"
}
# Set jobs to number of cores
add_config "max-jobs = auto"
# Allow binary caches for user
add_config "trusted-users = root ${USER:-}"
# Add github access token
if [[ -n "${INPUT_GITHUB_ACCESS_TOKEN:-}" ]]; then
  add_config "access-tokens = github.com=$INPUT_GITHUB_ACCESS_TOKEN"
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  add_config "access-tokens = github.com=$GITHUB_TOKEN"
fi
# Append extra nix configuration if provided
if [[ -n "${INPUT_EXTRA_NIX_CONFIG:-}" ]]; then
  add_config "$INPUT_EXTRA_NIX_CONFIG"
fi
if [[ ! $INPUT_EXTRA_NIX_CONFIG =~ "experimental-features" ]]; then
  add_config "experimental-features = nix-command flakes auto-allocate-uids"
fi

# Nix installer flags
installer_options=(
  --no-channel-add
  --darwin-use-unencrypted-nix-store-volume
  --nix-extra-conf-file "$workdir/nix.conf"
)

# only use the nix-daemon settings if on darwin (which get ignored) or systemd is supported
if [[ (! $INPUT_INSTALL_OPTIONS =~ "--no-daemon") && ($OSTYPE =~ darwin || -e /run/systemd/system) ]]; then
  installer_options+=(
    --daemon
    --daemon-user-count 1
  )
  add_config "auto-allocate-uids = true"
else
  # "fix" the following error when running nix*
  # error: the group 'nixbld' specified in 'build-users-group' does not exist
  add_config "build-users-group ="
  sudo mkdir -p /etc/nix
  sudo chmod 0755 /etc/nix
  sudo cp "$workdir/nix.conf" /etc/nix/nix.conf
fi

if [[ -n "${INPUT_INSTALL_OPTIONS:-}" ]]; then
  IFS=' ' read -r -a extra_installer_options <<< "$INPUT_INSTALL_OPTIONS"
  installer_options=("${extra_installer_options[@]}" "${installer_options[@]}")
fi

echo "installer options: ${installer_options[*]}"

# There is --retry-on-errors, but only newer curl versions support that
curl_retries=5
while ! curl -sS -o "$workdir/install" -v --fail -L "${INPUT_INSTALL_URL:-https://releases.nixos.org/nix/nix-2.15.1/install}"
do
  sleep 1
  ((curl_retries--))
  if [[ $curl_retries -le 0 ]]; then
    echo "curl retries failed" >&2
    exit 1
  fi
done

sh "$workdir/install" "${installer_options[@]}"

if [[ $OSTYPE =~ darwin ]]; then
  # macOS needs certificates hints
  cert_file=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt
  echo "NIX_SSL_CERT_FILE=$cert_file" >> "$GITHUB_ENV"
  export NIX_SSL_CERT_FILE=$cert_file
  sudo launchctl setenv NIX_SSL_CERT_FILE "$cert_file"
fi

# Set paths
echo "/nix/var/nix/profiles/default/bin" >> "$GITHUB_PATH"
# new path for nix 2.14
echo "$HOME/.nix-profile/bin" >> "$GITHUB_PATH"

if [[ -n "${INPUT_NIX_PATH:-}" ]]; then
  echo "NIX_PATH=${INPUT_NIX_PATH}" >> "$GITHUB_ENV"
fi

# Close the log message group which was opened above
echo "::endgroup::"
