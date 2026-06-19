#!/bin/sh
set -eu

repo=${1:?usage: sign-repo.sh REPO [SUITE] [KEYID]}
suite=${2:-unstable}
keyid=${3:-${NELIX_APT_GPG_KEYID:-}}
release="$repo/dists/$suite/Release"
inrelease="$repo/dists/$suite/InRelease"
release_gpg="$repo/dists/$suite/Release.gpg"
keyring="$repo/nelix-archive-keyring.gpg"

if [ ! -f "$release" ]; then
  echo "missing Release file: $release" >&2
  exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
  echo "gpg is required to sign the APT repository" >&2
  exit 1
fi

if [ -z "$keyid" ]; then
  keyid=$(gpg --batch --list-secret-keys --with-colons 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10; exit }')
fi

if [ -z "$keyid" ]; then
  echo "no signing key found; pass KEYID or set NELIX_APT_GPG_KEYID" >&2
  exit 1
fi

gpg --batch --yes --local-user "$keyid" --output "$inrelease" \
  --clearsign "$release"
gpg --batch --yes --local-user "$keyid" --output "$release_gpg" \
  --detach-sign "$release"
gpg --batch --yes --output "$keyring" --export "$keyid"

cat > "$repo/sources.list.signed" <<EOF
deb [signed-by=$(cd "$repo" && pwd)/nelix-archive-keyring.gpg] file://$(cd "$repo" && pwd) $suite ${NELIX_APT_COMPONENT:-main}
EOF

printf 'nelix apt repo signed ok: %s key=%s\n' "$repo" "$keyid"
printf 'signed-sources-list: %s\n' "$repo/sources.list.signed"
