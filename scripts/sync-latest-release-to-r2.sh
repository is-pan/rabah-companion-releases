#!/usr/bin/env bash
set -euo pipefail

required_commands=(aws gh jq python3 sha256sum sort)
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "$command_name" >&2
    exit 1
  fi
done

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${R2_BUCKET_NAME:?R2_BUCKET_NAME is required}"
: "${DOWNLOAD_BASE_URL:?DOWNLOAD_BASE_URL is required}"

if [[ "$R2_BUCKET_NAME" != "rabah-companion-downloads" ]]; then
  printf 'Refusing to sync or delete objects in unexpected bucket: %s\n' "$R2_BUCKET_NAME" >&2
  exit 1
fi

endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
download_base_url="${DOWNLOAD_BASE_URL%/}"
work_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rabah-companion-r2-sync"

mkdir -p "$work_dir"
find "$work_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
export AWS_REGION=auto
export AWS_EC2_METADATA_DISABLED=true

releases_json="$work_dir/releases.json"
gh api \
  -H "Accept: application/vnd.github+json" \
  "repos/${GITHUB_REPOSITORY}/releases?per_page=100" > "$releases_json"

mapfile -t candidate_tags < <(
  jq -r '
    .[]
    | select(.draft == false)
    | select(.tag_name | test("^companion-v[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | .tag_name
  ' "$releases_json" | sort -V -r
)

selected_release=""
for candidate_tag in "${candidate_tags[@]}"; do
  candidate_release="$(jq -c --arg tag "$candidate_tag" '.[] | select(.tag_name == $tag)' "$releases_json")"
  candidate_version="${candidate_tag#companion-v}"
  candidate_windows="Rabah-Companion-Windows-x64-v${candidate_version}-setup.exe"
  candidate_windows_signature="${candidate_windows}.sig"
  candidate_macos_updater="Rabah-Companion-macOS-arm64-v${candidate_version}.app.tar.gz"
  candidate_macos_signature="${candidate_macos_updater}.sig"

  candidate_macos="$(
    jq -r --arg version "$candidate_version" '
      [
        .assets[].name
        | select(
            . == ("Rabah-Companion-macOS-arm64-v" + $version + ".dmg")
            or . == ("Rabah-Companion-macOS-arm64-v" + $version + "-repacked.dmg")
          )
      ][0] // empty
    ' <<<"$candidate_release"
  )"

  has_windows="$(jq -r --arg name "$candidate_windows" 'any(.assets[]; .name == $name)' <<<"$candidate_release")"
  has_checksums="$(jq -r 'any(.assets[]; .name == "SHA256SUMS.txt")' <<<"$candidate_release")"
  has_windows_signature="$(jq -r --arg name "$candidate_windows_signature" 'any(.assets[]; .name == $name)' <<<"$candidate_release")"
  has_macos_updater="$(jq -r --arg name "$candidate_macos_updater" 'any(.assets[]; .name == $name)' <<<"$candidate_release")"
  has_macos_signature="$(jq -r --arg name "$candidate_macos_signature" 'any(.assets[]; .name == $name)' <<<"$candidate_release")"

  IFS=. read -r version_major version_minor version_patch <<<"$candidate_version"
  requires_updater=false
  if (( version_major > 0 || version_minor > 1 || (version_minor == 1 && version_patch >= 42) )); then
    requires_updater=true
  fi

  updater_complete=true
  if [[ "$requires_updater" == "true" ]] && {
    [[ "$has_windows_signature" != "true" ]] ||
    [[ "$has_macos_updater" != "true" ]] ||
    [[ "$has_macos_signature" != "true" ]];
  }; then
    updater_complete=false
  fi

  if [[ "$has_windows" == "true" && "$has_checksums" == "true" && -n "$candidate_macos" && "$updater_complete" == "true" ]]; then
    selected_release="$candidate_release"
    selected_tag="$candidate_tag"
    version="$candidate_version"
    windows_asset="$candidate_windows"
    macos_asset="$candidate_macos"
    updater_enabled="$requires_updater"
    windows_signature_asset="$candidate_windows_signature"
    macos_updater_asset="$candidate_macos_updater"
    macos_signature_asset="$candidate_macos_signature"
    break
  fi
done

if [[ -z "$selected_release" ]]; then
  printf 'No release contains all required installers, updater signatures, and checksums.\n' >&2
  exit 1
fi

release_url="$(jq -r '.html_url' <<<"$selected_release")"
published_at="$(jq -r '.published_at' <<<"$selected_release")"
release_dir="$work_dir/$selected_tag"
mkdir -p "$release_dir"

printf 'Selected %s (%s)\n' "$selected_tag" "$published_at"
download_args=(
  "$selected_tag"
  --repo "$GITHUB_REPOSITORY"
  --dir "$release_dir"
  --pattern "$windows_asset"
  --pattern "$macos_asset"
  --pattern "SHA256SUMS.txt"
)
if [[ "$updater_enabled" == "true" ]]; then
  download_args+=(
    --pattern "$windows_signature_asset"
    --pattern "$macos_updater_asset"
    --pattern "$macos_signature_asset"
  )
fi
gh release download "${download_args[@]}"

checksum_for() {
  local filename="$1"
  local expected
  local actual

  expected="$(
    awk -v filename="$filename" '
      {
        listed = $2
        sub(/^\\*/, "", listed)
        if (listed == filename) {
          print tolower($1)
          exit
        }
      }
    ' "$release_dir/SHA256SUMS.txt"
  )"

  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'No valid checksum found for %s\n' "$filename" >&2
    exit 1
  fi

  actual="$(sha256sum "$release_dir/$filename" | awk '{print tolower($1)}')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Checksum mismatch for %s\n' "$filename" >&2
    exit 1
  fi

  printf '%s' "$actual"
}

windows_sha256="$(checksum_for "$windows_asset")"
macos_sha256="$(checksum_for "$macos_asset")"

windows_size="$(stat -c '%s' "$release_dir/$windows_asset")"
macos_size="$(stat -c '%s' "$release_dir/$macos_asset")"

version_prefix="versions/${selected_tag}"
windows_version_key="${version_prefix}/${windows_asset}"
macos_version_key="${version_prefix}/${macos_asset}"
checksums_version_key="${version_prefix}/SHA256SUMS.txt"
if [[ "$updater_enabled" == "true" ]]; then
  macos_updater_sha256="$(checksum_for "$macos_updater_asset")"
  python3 - "$release_dir/$macos_updater_asset" <<'PY'
import sys
import tarfile

archive = sys.argv[1]
expected_root = "Rabah Companion.app"
with tarfile.open(archive, "r:gz") as package:
    names = package.getnames()

suspicious = [
    name for name in names
    if name.startswith("._")
    or "/._" in name
    or name == ".DS_Store"
    or name.endswith("/.DS_Store")
]
top_levels = {name.rstrip("/").split("/", 1)[0] for name in names}
if suspicious or top_levels != {expected_root} or expected_root not in {
    name.rstrip("/") for name in names
}:
    print("Refusing unsafe macOS updater archive.", file=sys.stderr)
    print(f"Top-level entries: {sorted(top_levels)}", file=sys.stderr)
    for name in suspicious:
        print(f"  {name}", file=sys.stderr)
    raise SystemExit(1)
PY
  windows_signature_key="${version_prefix}/${windows_signature_asset}"
  macos_updater_key="${version_prefix}/${macos_updater_asset}"
  macos_signature_key="${version_prefix}/${macos_signature_asset}"
fi

upload_file() {
  local source_path="$1"
  local object_key="$2"
  local content_type="$3"
  local cache_control="$4"
  local content_disposition="${5:-}"
  local args=(
    s3 cp "$source_path" "s3://${R2_BUCKET_NAME}/${object_key}"
    --endpoint-url "$endpoint"
    --only-show-errors
    --content-type "$content_type"
    --cache-control "$cache_control"
  )

  if [[ -n "$content_disposition" ]]; then
    args+=(--content-disposition "$content_disposition")
  fi

  aws "${args[@]}"
}

printf 'Uploading immutable version objects...\n'
upload_file \
  "$release_dir/$windows_asset" \
  "$windows_version_key" \
  "application/vnd.microsoft.portable-executable" \
  "public, max-age=31536000, immutable" \
  "attachment; filename=\"$windows_asset\""
upload_file \
  "$release_dir/$macos_asset" \
  "$macos_version_key" \
  "application/x-apple-diskimage" \
  "public, max-age=31536000, immutable" \
  "attachment; filename=\"$macos_asset\""
upload_file \
  "$release_dir/SHA256SUMS.txt" \
  "$checksums_version_key" \
  "text/plain; charset=utf-8" \
  "public, max-age=31536000, immutable"
if [[ "$updater_enabled" == "true" ]]; then
  upload_file \
    "$release_dir/$windows_signature_asset" \
    "$windows_signature_key" \
    "text/plain; charset=utf-8" \
    "public, max-age=31536000, immutable"
  upload_file \
    "$release_dir/$macos_updater_asset" \
    "$macos_updater_key" \
    "application/gzip" \
    "public, max-age=31536000, immutable" \
    "attachment; filename=\"$macos_updater_asset\""
  upload_file \
    "$release_dir/$macos_signature_asset" \
    "$macos_signature_key" \
    "text/plain; charset=utf-8" \
    "public, max-age=31536000, immutable"
fi

printf 'Updating stable latest download paths...\n'
upload_file \
  "$release_dir/$windows_asset" \
  "latest/Rabah-Companion-Windows-x64-setup.exe" \
  "application/vnd.microsoft.portable-executable" \
  "public, max-age=300, must-revalidate" \
  "attachment; filename=\"$windows_asset\""
upload_file \
  "$release_dir/$macos_asset" \
  "latest/Rabah-Companion-macOS-arm64.dmg" \
  "application/x-apple-diskimage" \
  "public, max-age=300, must-revalidate" \
  "attachment; filename=\"$macos_asset\""
upload_file \
  "$release_dir/SHA256SUMS.txt" \
  "latest/SHA256SUMS.txt" \
  "text/plain; charset=utf-8" \
  "public, max-age=300, must-revalidate"

latest_json="$release_dir/latest.json"
jq -n \
  --arg version "$version" \
  --arg tag "$selected_tag" \
  --arg release_url "$release_url" \
  --arg published_at "$published_at" \
  --arg synced_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg windows_url "${download_base_url}/${windows_version_key}" \
  --arg windows_latest_url "${download_base_url}/latest/Rabah-Companion-Windows-x64-setup.exe" \
  --arg windows_sha256 "$windows_sha256" \
  --argjson windows_size "$windows_size" \
  --arg macos_url "${download_base_url}/${macos_version_key}" \
  --arg macos_latest_url "${download_base_url}/latest/Rabah-Companion-macOS-arm64.dmg" \
  --arg macos_sha256 "$macos_sha256" \
  --argjson macos_size "$macos_size" \
  --arg checksums_url "${download_base_url}/${checksums_version_key}" \
  '{
    schema_version: 1,
    version: $version,
    tag: $tag,
    release_url: $release_url,
    published_at: $published_at,
    synced_at: $synced_at,
    windows: {
      architecture: "x86_64",
      url: $windows_url,
      latest_url: $windows_latest_url,
      sha256: $windows_sha256,
      size: $windows_size
    },
    macos: {
      architecture: "arm64",
      url: $macos_url,
      latest_url: $macos_latest_url,
      sha256: $macos_sha256,
      size: $macos_size
    },
    checksums_url: $checksums_url
  }' > "$latest_json"

if [[ "$updater_enabled" == "true" ]]; then
  updater_json="$release_dir/updater-latest.json"
  windows_signature="$(<"$release_dir/$windows_signature_asset")"
  macos_signature="$(<"$release_dir/$macos_signature_asset")"
  release_notes="$(jq -r '.body // ""' <<<"$selected_release")"
  jq -n \
    --arg version "$version" \
    --arg notes "$release_notes" \
    --arg pub_date "$published_at" \
    --arg windows_url "${download_base_url}/${windows_version_key}" \
    --arg windows_signature "$windows_signature" \
    --arg macos_url "${download_base_url}/${macos_updater_key}" \
    --arg macos_signature "$macos_signature" \
    '{
      version: $version,
      notes: $notes,
      pub_date: $pub_date,
      platforms: {
        "windows-x86_64": {
          url: $windows_url,
          signature: $windows_signature
        },
        "darwin-aarch64": {
          url: $macos_url,
          signature: $macos_signature
        }
      }
    }' > "$updater_json"
  upload_file \
    "$updater_json" \
    "updater/latest.json" \
    "application/json; charset=utf-8" \
    "no-cache, no-store, must-revalidate"
  printf 'Updater manifest published for %s (macOS updater SHA-256 %s)\n' \
    "$selected_tag" "$macos_updater_sha256"
else
  aws s3api delete-object \
    --bucket "$R2_BUCKET_NAME" \
    --key "updater/latest.json" \
    --endpoint-url "$endpoint" \
    >/dev/null
fi

# Publish the ordinary manifest last. When updater metadata is required it is
# already available, so download-page and in-app consumers converge together.
upload_file \
  "$latest_json" \
  "latest.json" \
  "application/json; charset=utf-8" \
  "no-cache, no-store, must-revalidate"

printf 'Removing superseded version objects from the isolated download bucket...\n'
while IFS= read -r object_key; do
  [[ -z "$object_key" ]] && continue
  if [[ "$object_key" != "${version_prefix}/"* ]]; then
    aws s3api delete-object \
      --bucket "$R2_BUCKET_NAME" \
      --key "$object_key" \
      --endpoint-url "$endpoint" \
      >/dev/null
  fi
done < <(
  aws s3api list-objects-v2 \
    --bucket "$R2_BUCKET_NAME" \
    --prefix "versions/" \
    --endpoint-url "$endpoint" \
    --query 'Contents[].Key' \
    --output text | tr '\t' '\n'
)

printf 'R2 latest sync completed: %s\n' "$selected_tag"
