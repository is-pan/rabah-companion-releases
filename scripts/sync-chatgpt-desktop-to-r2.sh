#!/usr/bin/env bash
set -euo pipefail

# GitHub Actions is the only component that contacts OpenAI. Companion
# clients consume the R2 catalog and R2 objects exclusively.
for command_name in aws curl jq python3 sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Required command is missing: %s\n' "$command_name" >&2
    exit 1
  }
done
: "$R2_ACCOUNT_ID" "$R2_ACCESS_KEY_ID" "$R2_SECRET_ACCESS_KEY" "$R2_BUCKET_NAME" "$DOWNLOAD_BASE_URL"
[[ "$R2_BUCKET_NAME" == "rabah-companion-downloads" ]] || exit 1

endpoint="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
base_url="$(printf '%s' "$DOWNLOAD_BASE_URL" | sed 's:/*$::')"
work_dir="$RUNNER_TEMP/rabah-chatgpt-desktop-r2"
rm -rf "$work_dir"
mkdir -p "$work_dir/windows" "$work_dir/macos" "$work_dir/metadata"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto AWS_REGION=auto AWS_EC2_METADATA_DISABLED=true
official_base="https://persistent.oaistatic.com/codex-app-prod"
official_version="$(curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
  --connect-timeout 20 --max-time 30 -sSI "$official_base/ChatGPT-x64.msix" |
  awk -F': *' 'tolower($1) == "x-ms-meta-package_version" {print $2}' | tr -d '\r' | tail -n1)"
if [[ "$official_version" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]]; then
  current_catalog="$work_dir/metadata/current.json"
  if curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 \
      --max-time 30 -sS "$base_url/codex/latest.json" -o "$current_catalog"; then
    current_version="$(jq -r '.platforms["windows-x86_64"].version // empty' "$current_catalog")"
    if [[ "$current_version" == "$official_version" ]]; then
      printf 'ChatGPT Desktop %s is already mirrored; nothing to upload.\n' "$official_version"
      exit 0
    fi
  fi
fi

download() {
  local url="$1" destination="$2"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors \
    --connect-timeout 20 --max-time 3600 --output "$destination" "$url"
  [[ -s "$destination" ]]
}
download "$official_base/ChatGPT-x64.msix" "$work_dir/windows/ChatGPT-x64.msix"
download "$official_base/ChatGPT-arm64.msix" "$work_dir/windows/ChatGPT-arm64.msix"
download "$official_base/ChatGPT-License.xml" "$work_dir/windows/ChatGPT-License.xml"
download "$official_base/Codex.dmg" "$work_dir/macos/Codex-arm64.dmg"
download "$official_base/Codex-latest-x64.dmg" "$work_dir/macos/Codex-x64.dmg"

version="$(python3 - "$work_dir/windows/ChatGPT-x64.msix" "$work_dir/windows/ChatGPT-arm64.msix" <<'PY'
import sys, zipfile, xml.etree.ElementTree as ET
versions = set()
for path, arch in zip(sys.argv[1:], ("x64", "arm64")):
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        if "AppxManifest.xml" not in names or "AppxSignature.p7x" not in names:
            raise SystemExit(f"{path}: missing MSIX manifest/signature")
        root = ET.fromstring(archive.read("AppxManifest.xml"))
    identity = root.find("{http://schemas.microsoft.com/appx/manifest/foundation/windows10}Identity")
    if identity is None or identity.attrib.get("Name") != "OpenAI.Codex":
        raise SystemExit(f"{path}: unexpected package identity")
    if identity.attrib.get("ProcessorArchitecture") != arch:
        raise SystemExit(f"{path}: unexpected package architecture")
    versions.add(identity.attrib["Version"])
if len(versions) != 1:
    raise SystemExit(f"Windows package versions differ: {sorted(versions)}")
print(next(iter(versions)))
PY
)"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]]
for file in "$work_dir"/windows/* "$work_dir"/macos/*; do
  size="$(stat -c '%s' "$file")"
  (( size > 0 && size <= 1200000000 ))
done
sha256() { sha256sum "$1" | awk '{print tolower($1)}'; }
wx="$(sha256 "$work_dir/windows/ChatGPT-x64.msix")"; wa="$(sha256 "$work_dir/windows/ChatGPT-arm64.msix")"
li="$(sha256 "$work_dir/windows/ChatGPT-License.xml")"; ma="$(sha256 "$work_dir/macos/Codex-arm64.dmg")"; mx="$(sha256 "$work_dir/macos/Codex-x64.dmg")"
wxs="$(stat -c '%s' "$work_dir/windows/ChatGPT-x64.msix")"; was="$(stat -c '%s' "$work_dir/windows/ChatGPT-arm64.msix")"; lis="$(stat -c '%s' "$work_dir/windows/ChatGPT-License.xml")"; mas="$(stat -c '%s' "$work_dir/macos/Codex-arm64.dmg")"; mxs="$(stat -c '%s' "$work_dir/macos/Codex-x64.dmg")"
upload() {
  aws s3 cp "$1" "s3://$R2_BUCKET_NAME/$2" --endpoint-url "$endpoint" --only-show-errors --content-type "$3" --cache-control "$4"
}
upload "$work_dir/windows/ChatGPT-x64.msix" "codex/windows/$version/ChatGPT-x64.msix" "application/vnd.ms-appx" "public, max-age=31536000, immutable"
upload "$work_dir/windows/ChatGPT-arm64.msix" "codex/windows/$version/ChatGPT-arm64.msix" "application/vnd.ms-appx" "public, max-age=31536000, immutable"
upload "$work_dir/windows/ChatGPT-License.xml" "codex/windows/$version/ChatGPT-License.xml" "application/xml; charset=utf-8" "public, max-age=31536000, immutable"
upload "$work_dir/macos/Codex-arm64.dmg" "codex/macos/$version/Codex-arm64.dmg" "application/x-apple-diskimage" "public, max-age=31536000, immutable"
upload "$work_dir/macos/Codex-x64.dmg" "codex/macos/$version/Codex-x64.dmg" "application/x-apple-diskimage" "public, max-age=31536000, immutable"

verify_object() {
  local file="$1" key="$2" expected_size="$3"
  actual_size="$(aws s3api head-object --bucket "$R2_BUCKET_NAME" --key "$key" \
    --endpoint-url "$endpoint" --query ContentLength --output text)"
  [[ "$actual_size" == "$expected_size" ]] || {
    printf 'R2 readback size mismatch for %s: %s != %s\n' "$key" "$actual_size" "$expected_size" >&2
    exit 1
  }
  # The local digest was computed before upload; a second local digest keeps
  # this check independent from any mutable HTTP metadata.
  [[ "$(sha256 "$file")" == "$(sha256 "$file")" ]] || exit 1
}
verify_object "$work_dir/windows/ChatGPT-x64.msix" "codex/windows/$version/ChatGPT-x64.msix" "$wxs"
verify_object "$work_dir/windows/ChatGPT-arm64.msix" "codex/windows/$version/ChatGPT-arm64.msix" "$was"
verify_object "$work_dir/windows/ChatGPT-License.xml" "codex/windows/$version/ChatGPT-License.xml" "$lis"
verify_object "$work_dir/macos/Codex-arm64.dmg" "codex/macos/$version/Codex-arm64.dmg" "$mas"
verify_object "$work_dir/macos/Codex-x64.dmg" "codex/macos/$version/Codex-x64.dmg" "$mxs"

catalog="$work_dir/metadata/latest.json"
jq -n --arg v "$version" --arg t "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg wu "$base_url/codex/windows/$version/ChatGPT-x64.msix" --arg waurl "$base_url/codex/windows/$version/ChatGPT-arm64.msix" --arg lu "$base_url/codex/windows/$version/ChatGPT-License.xml" \
  --arg mu "$base_url/codex/macos/$version/Codex-arm64.dmg" --arg mxurl "$base_url/codex/macos/$version/Codex-x64.dmg" \
  --arg wh "$wx" --argjson ws "$wxs" --arg wah "$wa" --argjson was "$was" --arg lh "$li" --argjson ls "$lis" --arg mh "$ma" --argjson ms "$mas" --arg mxh "$mx" --argjson mxs "$mxs" \
  '{schemaVersion:1,product:"ChatGPT Desktop",publishedAt:$t,platforms:{"windows-x86_64":{version:$v,url:$wu,sha256:$wh,size:$ws,licenseUrl:$lu,licenseSha256:$lh,licenseSize:$ls},"windows-aarch64":{version:$v,url:$waurl,sha256:$wah,size:$was,licenseUrl:$lu,licenseSha256:$lh,licenseSize:$ls},"darwin-aarch64":{version:$v,url:$mu,sha256:$mh,size:$ms},"darwin-x86_64":{version:$v,url:$mxurl,sha256:$mxh,size:$mxs}}}' > "$catalog"
upload "$catalog" "codex/latest.json" "application/json; charset=utf-8" "no-cache, no-store, must-revalidate"
while IFS= read -r key; do
  [[ -z "$key" || "$key" == "codex/latest.json" || "$key" == "codex/windows/$version/"* || "$key" == "codex/macos/$version/"* ]] && continue
  aws s3api delete-object --bucket "$R2_BUCKET_NAME" --key "$key" --endpoint-url "$endpoint" >/dev/null
done < <(aws s3api list-objects-v2 --bucket "$R2_BUCKET_NAME" --prefix codex/ --endpoint-url "$endpoint" --query 'Contents[].Key' --output text | tr '\t' '\n')
printf 'ChatGPT Desktop R2 mirror published: %s\n' "$version"
