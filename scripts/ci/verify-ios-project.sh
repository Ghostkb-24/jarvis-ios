#!/usr/bin/env bash

# The PROJECT_YML override exists only so CI and local checks can exercise a
# missing-input failure without changing the checked-in XcodeGen manifest.
set -u

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
ios_dir="$repo_root/ios"
project_yml="${PROJECT_YML:-$ios_dir/project.yml}"
xcode_project="${XCODE_PROJECT:-$ios_dir/JarvisIOS.xcodeproj}"
errors=0

error() {
  printf 'ERROR: %s\n' "$1" >&2
  errors=$((errors + 1))
}

contains_line_in_section() {
  section="$1"
  expected_line="$2"
  awk -v section="$section:" -v expected_line="$expected_line" '
    $0 == section { in_section = 1; next }
    in_section && /^[^[:space:]]/ { exit }
    in_section && $0 == expected_line { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$project_yml"
}

contains_text_in_section() {
  section="$1"
  expected_text="$2"
  awk -v section="$section:" -v expected_text="$expected_text" '
    $0 == section { in_section = 1; next }
    in_section && /^[^[:space:]]/ { exit }
    in_section && index($0, expected_text) { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$project_yml"
}

listing_has_entry() {
  section="$1"
  expected_entry="$2"
  printf '%s\n' "$project_listing" | awk -v section="$section" -v expected_entry="$expected_entry" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    trim($0) == section ":" { in_section = 1; next }
    in_section && trim($0) == expected_entry { found = 1; exit }
    in_section && trim($0) ~ /^[[:alpha:]][[:alpha:] ]+:$/ { exit }
    END { exit found ? 0 : 1 }
  '
}

if [ ! -f "$project_yml" ]; then
  error "XcodeGen manifest is missing: $project_yml. Restore ios/project.yml before generating the project."
else
  for target in JarvisIOS JarvisWidget JarvisIOSTests JarvisIOSUITests; do
    if ! contains_line_in_section "targets" "  $target:"; then
      error "Required XcodeGen target '$target' is missing from $project_yml under targets:."
    fi
  done

  if ! contains_line_in_section "schemes" "  JarvisIOS:"; then
    error "Required Xcode scheme 'JarvisIOS' is missing from $project_yml under schemes:."
  fi

  for bundle_id in \
    com.jarvisassistant.ios \
    com.jarvisassistant.ios.widget \
    com.jarvisassistant.ios-tests \
    com.jarvisassistant.ios-uitests; do
    if ! grep -Fq "PRODUCT_BUNDLE_IDENTIFIER: $bundle_id" "$project_yml"; then
      error "Required bundle identifier '$bundle_id' is missing from $project_yml."
    fi
  done

  for test_target in JarvisIOSTests JarvisIOSUITests; do
    if ! contains_text_in_section "schemes" "- name: $test_target"; then
      error "Required test target '$test_target' is missing from the JarvisIOS scheme in $project_yml."
    fi
  done
fi

if [ "$errors" -eq 0 ] && [ ! -d "$xcode_project" ]; then
  error "Generated project is missing: $xcode_project. Run 'cd ios && xcodegen generate' before this preflight."
elif [ "$errors" -eq 0 ] && [ ! -f "$xcode_project/project.pbxproj" ]; then
  error "Generated project is incomplete: $xcode_project/project.pbxproj is missing. Re-run XcodeGen."
elif [ "$errors" -eq 0 ]; then
  if command -v xcodebuild >/dev/null 2>&1; then
    if project_listing="$(xcodebuild -list -project "$xcode_project" 2>&1)"; then
      for target in JarvisIOS JarvisWidget JarvisIOSTests JarvisIOSUITests; do
        if ! listing_has_entry "Targets" "$target"; then
          error "Generated project does not expose required target '$target'. Check ios/project.yml and re-run XcodeGen."
        fi
      done

      if ! listing_has_entry "Schemes" "JarvisIOS"; then
        error "Generated project does not expose required scheme 'JarvisIOS'. Check ios/project.yml and re-run XcodeGen."
      fi
    else
      error "xcodebuild could not inspect $xcode_project. Check the generated project and Xcode installation."
    fi

    for bundle_id in \
      com.jarvisassistant.ios \
      com.jarvisassistant.ios.widget \
      com.jarvisassistant.ios-tests \
      com.jarvisassistant.ios-uitests; do
      if ! grep -Fq "PRODUCT_BUNDLE_IDENTIFIER = $bundle_id;" "$xcode_project/project.pbxproj"; then
        error "Generated project is missing bundle identifier '$bundle_id'. Check ios/project.yml and re-run XcodeGen."
      fi
    done
  else
    error "xcodebuild is unavailable; run this post-generation preflight on macOS with Xcode installed."
  fi
fi

if [ "$errors" -ne 0 ]; then
  printf 'iOS project preflight failed with %s actionable error(s).\n' "$errors" >&2
  exit 1
fi

printf 'iOS project preflight passed: XcodeGen manifest and generated JarvisIOS project are complete.\n'
