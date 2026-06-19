#!/bin/sh
set -eu

repo=${1:?usage: publish-static.sh REPO OUTDIR BASE_URL}
out=${2:?usage: publish-static.sh REPO OUTDIR BASE_URL}
base_url=${3:?usage: publish-static.sh REPO OUTDIR BASE_URL}

base_url=${base_url%/}

if [ ! -f "$repo/repodata/repomd.xml" ]; then
  echo "missing Fedora repository metadata: $repo/repodata/repomd.xml" >&2
  exit 1
fi

if ! find "$repo" -maxdepth 1 -type f -name '*.rpm' -print -quit | grep -q .; then
  echo "missing Fedora RPM payloads in repository: $repo" >&2
  exit 1
fi

if find "$repo" \( -name '.gnupg*' -o -name 'private-keys-v1.d' \) -print -quit | grep -q .; then
  echo "refusing to publish Fedora repository containing GPG test or secret material: $repo" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp -R "$repo/repodata" "$out/"
find "$repo" -maxdepth 1 -type f -name '*.rpm' -exec cp {} "$out/" \;

cat > "$out/nelix-fedora.repo" <<EOF
[nelix]
name=Nelix
baseurl=${base_url}
enabled=1
gpgcheck=${NELIX_FEDORA_GPGCHECK:-0}
repo_gpgcheck=${NELIX_FEDORA_REPO_GPGCHECK:-0}
EOF
if [ -n "${NELIX_FEDORA_GPGKEY_URL:-}" ]; then
  printf 'gpgkey=%s\n' "$NELIX_FEDORA_GPGKEY_URL" >> "$out/nelix-fedora.repo"
fi

printf 'nelix fedora static publish ok: %s\n' "$out"
