#!/bin/sh
set -eu

deb=${1:?usage: make-repo.sh DEB OUTDIR [SUITE]}
out=${2:?usage: make-repo.sh DEB OUTDIR [SUITE]}
suite=${3:-unstable}
component=${NELIX_APT_COMPONENT:-main}
architecture=${NELIX_APT_ARCHITECTURE:-all}
origin=${NELIX_APT_ORIGIN:-Nelix}
label=${NELIX_APT_LABEL:-Nelix local repository}

if [ ! -f "$deb" ]; then
  echo "missing Debian package: $deb" >&2
  exit 1
fi

if ! command -v apt-ftparchive >/dev/null 2>&1; then
  echo "apt-ftparchive is required; install apt-utils" >&2
  exit 1
fi

if ! command -v gzip >/dev/null 2>&1; then
  echo "gzip is required" >&2
  exit 1
fi

package=$(dpkg-deb -f "$deb" Package)
source=$(dpkg-deb -f "$deb" Source 2>/dev/null || printf '%s\n' "$package")
pool_dir="$out/pool/$component/$(printf '%s' "$source" | cut -c 1)/$source"
binary_dir="$out/dists/$suite/$component/binary-$architecture"
release_dir="$out/dists/$suite"
deb_name=$(basename "$deb")

rm -rf "$out"
mkdir -p "$pool_dir" "$binary_dir" "$release_dir"
cp "$deb" "$pool_dir/$deb_name"

(
  cd "$out"
  apt-ftparchive packages "pool/$component" > "dists/$suite/$component/binary-$architecture/Packages"
  gzip -n -c "dists/$suite/$component/binary-$architecture/Packages" \
    > "dists/$suite/$component/binary-$architecture/Packages.gz"
)

cat > "$release_dir/apt-ftparchive.conf" <<EOF
APT::FTPArchive::Release::Origin "$origin";
APT::FTPArchive::Release::Label "$label";
APT::FTPArchive::Release::Suite "$suite";
APT::FTPArchive::Release::Codename "$suite";
APT::FTPArchive::Release::Architectures "$architecture";
APT::FTPArchive::Release::Components "$component";
APT::FTPArchive::Release::Description "Nelix local APT repository";
EOF

(
  cd "$out"
  apt-ftparchive -c "dists/$suite/apt-ftparchive.conf" release "dists/$suite" \
    > "dists/$suite/Release"
)
rm -f "$release_dir/apt-ftparchive.conf"

cat > "$out/sources.list" <<EOF
deb [trusted=yes] file://$(cd "$out" && pwd) $suite $component
EOF

printf 'nelix apt repo ok: %s\n' "$out"
printf 'sources-list: %s\n' "$out/sources.list"
