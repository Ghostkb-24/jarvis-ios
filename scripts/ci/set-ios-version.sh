#!/usr/bin/env bash

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
ios_project_dir="${IOS_PROJECT_DIR:-$repo_root/ios}"
xcode_project="$ios_project_dir/JarvisIOS.xcodeproj"
xcrun_bin="${XCRUN_BIN:-xcrun}"
xcodebuild_bin="${XCODEBUILD_BIN:-xcodebuild}"
marketing_version="${MARKETING_VERSION:-}"
current_project_version="${BUILD_NUMBER:-}"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

setting_value() {
  setting_name="$1"
  awk -v setting_name="$setting_name" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ "^" setting_name "[[:space:]]*=") {
        sub("^" setting_name "[[:space:]]*=[[:space:]]*", "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  '
}

[ -n "$marketing_version" ] || fail "MARKETING_VERSION is required for a signed build (for example, 1.0.0)."
case "$current_project_version" in
  ''|*[!0-9]*) fail "Codemagic BUILD_NUMBER must be a positive integer; got '${current_project_version:-unset}'." ;;
  0) fail "Codemagic BUILD_NUMBER must be greater than zero." ;;
esac

[ -f "$xcode_project/project.pbxproj" ] || fail "Generated project is missing: $xcode_project. Run XcodeGen before setting signed-build versions."
command -v "$xcrun_bin" >/dev/null 2>&1 || fail "xcrun executable '$xcrun_bin' is unavailable; signed versioning requires macOS with Xcode."
command -v "$xcodebuild_bin" >/dev/null 2>&1 || fail "xcodebuild executable '$xcodebuild_bin' is unavailable; signed versioning requires macOS with Xcode."

(
  cd "$ios_project_dir"
  "$xcrun_bin" agvtool new-marketing-version "$marketing_version"
  "$xcrun_bin" agvtool new-version -all "$current_project_version"
)

for target in JarvisIOS JarvisWidget; do
  if ! build_settings="$("$xcodebuild_bin" -showBuildSettings -project "$xcode_project" -target "$target" -configuration Release 2>&1)"; then
    fail "xcodebuild could not inspect signed-build version settings for target '$target'."
  fi

  actual_marketing_version="$(printf '%s\n' "$build_settings" | setting_value MARKETING_VERSION)"
  actual_project_version="$(printf '%s\n' "$build_settings" | setting_value CURRENT_PROJECT_VERSION)"

  [ "$actual_marketing_version" = "$marketing_version" ] || fail "Target '$target' MARKETING_VERSION mismatch: expected '$marketing_version', got '${actual_marketing_version:-unset}'."
  [ "$actual_project_version" = "$current_project_version" ] || fail "Target '$target' CURRENT_PROJECT_VERSION mismatch: expected '$current_project_version', got '${actual_project_version:-unset}'."
done

printf 'Signed iOS versions verified for app and widget: MARKETING_VERSION=%s, CURRENT_PROJECT_VERSION=%s.\n' \
  "$marketing_version" "$current_project_version"
