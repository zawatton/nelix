#!/bin/sh
set -eu

repo=${1:?usage: publish-static.sh REPO OUTDIR BASE_URL [SUITE]}
out=${2:?usage: publish-static.sh REPO OUTDIR BASE_URL [SUITE]}
base_url=${3:?usage: publish-static.sh REPO OUTDIR BASE_URL [SUITE]}
suite=${4:-unstable}
component=${NELIX_APT_COMPONENT:-main}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

"$script_dir/verify-signed-repo.sh" "$repo" "$suite" "$repo/nelix-archive-keyring.gpg"

if find "$repo" \( -name '.gnupg*' -o -name 'private-keys-v1.d' \) -print -quit | grep -q .; then
  echo "refusing to publish APT repository containing GPG test or secret material: $repo" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp -R "$repo/dists" "$repo/pool" "$out/"
cp "$repo/nelix-archive-keyring.gpg" "$out/"
cp "$repo/sources.list.signed" "$out/"

cat > "$out/sources.list.https" <<EOF
deb [signed-by=/usr/share/keyrings/nelix-archive-keyring.gpg] ${base_url%/} $suite $component
EOF

printf 'nelix apt static publish ok: %s\n' "$out"
printf 'public-source-example: %s\n' "$out/sources.list.https"
