#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

SCHEME="${SCHEME:-Litter}"
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT_DIR="${PROJECT_DIR:-$IOS_DIR}"
PROJECT_PATH="${PROJECT_PATH:-$PROJECT_DIR/Litter.xcodeproj}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.sigkitten.litter}"
APP_STORE_APP_ID="${APP_STORE_APP_ID:-}"
TEAM_ID="${TEAM_ID:-}"
PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-Litter App Store}"
APP_PROVISIONING_PROFILE_SPECIFIER="${APP_PROVISIONING_PROFILE_SPECIFIER:-$PROVISIONING_PROFILE_SPECIFIER}"
LIVE_ACTIVITY_BUNDLE_ID="${LIVE_ACTIVITY_BUNDLE_ID:-com.sigkitten.litter.liveactivity}"
LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER="${LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER:-}"
EXPORT_SIGNING_STYLE="${EXPORT_SIGNING_STYLE:-automatic}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
FASTLANE_METADATA_DIR="${FASTLANE_METADATA_DIR:-$FASTLANE_DIR}"

AUTH_KEY_PATH="${AUTH_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"
AUTH_KEY_ID="${AUTH_KEY_ID:-${ASC_KEY_ID:-}}"
AUTH_ISSUER_ID="${AUTH_ISSUER_ID:-${ASC_ISSUER_ID:-}}"

BUILD_DIR="${BUILD_DIR:-$IOS_DIR/build/appstore}"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
IPA_PATH="$BUILD_DIR/$SCHEME.ipa"

require_cmd asc
require_cmd jq
require_cmd xcodebuild
require_cmd xcodegen

if [[ -x "$SCRIPT_DIR/sanitize-ios-frameworks.sh" ]]; then
    "$SCRIPT_DIR/sanitize-ios-frameworks.sh"
fi

mkdir -p "$BUILD_DIR"

MARKETING_VERSION="$(read_project_marketing_version)"
ensure_semver "$MARKETING_VERSION"
validate_fastlane_metadata "$FASTLANE_METADATA_DIR"

APP_STORE_APP_ID="$(resolve_app_store_app_id "$APP_STORE_APP_ID" "$APP_BUNDLE_ID")"
TEAM_ID="$(resolve_team_id "$TEAM_ID" "$PROJECT_PATH" "$SCHEME" "$CONFIGURATION" "$EXPORT_SIGNING_STYLE" "$APP_PROVISIONING_PROFILE_SPECIFIER")"

if [[ "$EXPORT_SIGNING_STYLE" != "automatic" && "$EXPORT_SIGNING_STYLE" != "manual" ]]; then
    echo "Unsupported EXPORT_SIGNING_STYLE: $EXPORT_SIGNING_STYLE" >&2
    echo "Expected 'automatic' or 'manual'." >&2
    exit 1
fi

if [[ "$EXPORT_SIGNING_STYLE" == "manual" && -z "$APP_PROVISIONING_PROFILE_SPECIFIER" ]]; then
    echo "Manual export signing requires APP_PROVISIONING_PROFILE_SPECIFIER." >&2
    exit 1
fi

if [[ "$EXPORT_SIGNING_STYLE" == "manual" && -z "$LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER" ]]; then
    echo "Manual export signing requires LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER." >&2
    exit 1
fi

if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$(resolve_next_build_number "$APP_STORE_APP_ID")"
fi

auth_args=()
if [[ -n "$AUTH_KEY_PATH" && -n "$AUTH_KEY_ID" && -n "$AUTH_ISSUER_ID" ]]; then
    auth_args=(
        -authenticationKeyPath "$AUTH_KEY_PATH"
        -authenticationKeyID "$AUTH_KEY_ID"
        -authenticationKeyIssuerID "$AUTH_ISSUER_ID"
    )
fi

echo "==> Regenerating Xcode project"
"$PROJECT_DIR/scripts/regenerate-project.sh"

echo "==> Archiving $SCHEME ($MARKETING_VERSION/$BUILD_NUMBER)"
archive_cmd=(
    xcodebuild
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=iOS"
    -archivePath "$ARCHIVE_PATH"
    clean archive
    MARKETING_VERSION="$MARKETING_VERSION"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)

if [[ -n "$TEAM_ID" ]]; then
    archive_cmd+=(DEVELOPMENT_TEAM="$TEAM_ID")
fi

if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
    archive_cmd+=(
        APP_CODE_SIGN_STYLE=Manual
        LIVE_ACTIVITY_CODE_SIGN_STYLE=Manual
        APP_PROVISIONING_PROFILE_SPECIFIER="$APP_PROVISIONING_PROFILE_SPECIFIER"
        LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER="$LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER"
    )
else
    archive_cmd+=(-allowProvisioningUpdates)
fi

if [[ "$EXPORT_SIGNING_STYLE" == "automatic" && "${#auth_args[@]}" -gt 0 ]]; then
    archive_cmd+=("${auth_args[@]}")
fi

"${archive_cmd[@]}"

cat >"$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>app-store-connect</string>
    <key>signingStyle</key>
    <string>${EXPORT_SIGNING_STYLE}</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF

if [[ -n "$TEAM_ID" ]]; then
    /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
fi
if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS_PLIST"
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$APP_BUNDLE_ID string $APP_PROVISIONING_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$LIVE_ACTIVITY_BUNDLE_ID string $LIVE_ACTIVITY_PROVISIONING_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
fi

echo "==> Exporting IPA (signing: $EXPORT_SIGNING_STYLE)"
export_cmd=(
    xcodebuild
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$BUILD_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)

if [[ "$EXPORT_SIGNING_STYLE" == "automatic" ]]; then
    export_cmd+=(-allowProvisioningUpdates)
fi

if [[ "$EXPORT_SIGNING_STYLE" == "automatic" && "${#auth_args[@]}" -gt 0 ]]; then
    export_cmd+=("${auth_args[@]}")
fi

"${export_cmd[@]}"

exported_ipa="$(find "$BUILD_DIR" -maxdepth 1 -name "*.ipa" | head -n 1)"
if [[ -z "$exported_ipa" ]]; then
    echo "No IPA produced in $BUILD_DIR" >&2
    exit 1
fi
if [[ "$exported_ipa" != "$IPA_PATH" ]]; then
    cp "$exported_ipa" "$IPA_PATH"
fi

echo "==> Uploading IPA to App Store Connect (app: $APP_STORE_APP_ID)"
upload_json="$(
    asc builds upload \
        --app "$APP_STORE_APP_ID" \
        --ipa "$IPA_PATH" \
        --version "$MARKETING_VERSION" \
        --build-number "$BUILD_NUMBER" \
        --wait \
        --output json
)"
echo "$upload_json" >"$BUILD_DIR/upload_result.json"

BUILD_ID="$(
    echo "$upload_json" |
        jq -r '.data.id // .data[0].id // empty'
)"
if [[ -z "$BUILD_ID" ]]; then
    BUILD_ID="$(find_build_id "$APP_STORE_APP_ID" "$MARKETING_VERSION" "$BUILD_NUMBER" 50)"
fi
if [[ -z "$BUILD_ID" ]]; then
    echo "Unable to resolve uploaded build id for version $MARKETING_VERSION build $BUILD_NUMBER" >&2
    exit 1
fi

VERSION_ID="$(resolve_app_store_version_id "$APP_STORE_APP_ID" "$MARKETING_VERSION")"
if [[ -z "$VERSION_ID" ]]; then
    echo "==> Creating App Store version $MARKETING_VERSION"
    VERSION_ID="$(
        asc versions create \
            --app "$APP_STORE_APP_ID" \
            --version "$MARKETING_VERSION" \
            --platform IOS \
            --release-type AFTER_APPROVAL \
            --output json |
            jq -r '.data.id // empty'
    )"
else
    echo "==> Reusing App Store version $MARKETING_VERSION ($VERSION_ID)"
    asc versions update \
        --version-id "$VERSION_ID" \
        --release-type AFTER_APPROVAL \
        --output json >/dev/null
fi

if [[ -z "$VERSION_ID" ]]; then
    echo "Unable to resolve App Store version id for $MARKETING_VERSION" >&2
    exit 1
fi

echo "==> Importing repo-managed App Store metadata"
asc migrate import \
    --app "$APP_STORE_APP_ID" \
    --version-id "$VERSION_ID" \
    --fastlane-dir "$FASTLANE_METADATA_DIR" \
    --output json >/dev/null

echo "==> Attaching build $BUILD_ID to version $VERSION_ID"
asc versions attach-build \
    --version-id "$VERSION_ID" \
    --build "$BUILD_ID" \
    --output json >/dev/null

echo "==> Validating App Store submission readiness"
asc validate \
    --app "$APP_STORE_APP_ID" \
    --version-id "$VERSION_ID" \
    --strict \
    --output json >/dev/null

echo "==> Submitting build for App Store review"
asc submit create \
    --app "$APP_STORE_APP_ID" \
    --version-id "$VERSION_ID" \
    --build "$BUILD_ID" \
    --confirm \
    --output json >"$BUILD_DIR/submission_result.json"

echo "==> App Store submission complete"
echo "    App ID:      $APP_STORE_APP_ID"
echo "    Version:     $MARKETING_VERSION"
echo "    Build:       $BUILD_NUMBER"
echo "    Version ID:  $VERSION_ID"
echo "    Build ID:    $BUILD_ID"
echo "    IPA:         $IPA_PATH"
