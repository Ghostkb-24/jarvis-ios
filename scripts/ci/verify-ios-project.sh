#!/usr/bin/env bash

# The PROJECT_YML override exists only so CI and local checks can exercise a
# missing-input failure without changing the checked-in XcodeGen manifest.
set -u

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
ios_dir="$repo_root/ios"
project_yml="${PROJECT_YML:-$ios_dir/project.yml}"
xcode_project="${XCODE_PROJECT:-$ios_dir/JarvisIOS.xcodeproj}"
xcode_scheme="${XCODE_SCHEME:-$xcode_project/xcshareddata/xcschemes/JarvisIOS.xcscheme}"
xcodebuild_bin="${XCODEBUILD_BIN:-xcodebuild}"
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

scheme_testable_names() {
  awk '
    /<TestAction([[:space:]>])/ { in_test_action = 1 }
    in_test_action && /<Testables([[:space:]>])/ { in_testables = 1 }
    in_test_action && in_testables && /BlueprintName[[:space:]]*=[[:space:]]*"[^"]+"/ {
      value = $0
      sub(/^.*BlueprintName[[:space:]]*=[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      print value
    }
    in_testables && /<\/Testables>/ { in_testables = 0 }
    in_test_action && /<\/TestAction>/ { in_test_action = 0 }
  ' "$xcode_scheme"
}

bundle_id_from_build_settings() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=/) {
        sub(/^PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*/, "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
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
  if [ ! -f "$xcode_scheme" ]; then
    error "Generated shared scheme is missing: $xcode_scheme. Re-run XcodeGen and ensure scheme 'JarvisIOS' is shared."
  else
    scheme_testables="$(scheme_testable_names)"
    for test_target in JarvisIOSTests JarvisIOSUITests; do
      testable_count="$(printf '%s\n' "$scheme_testables" | awk -v expected="$test_target" '$0 == expected { count += 1 } END { print count + 0 }')"
      if [ "$testable_count" -eq 0 ]; then
        error "Generated scheme 'JarvisIOS' TestAction/Testables is missing BlueprintName '$test_target'. Check ios/project.yml and re-run XcodeGen."
      elif [ "$testable_count" -gt 1 ]; then
        error "Generated scheme 'JarvisIOS' TestAction/Testables contains BlueprintName '$test_target' $testable_count times; expected exactly once."
      fi
    done

    while IFS= read -r test_target; do
      [ -n "$test_target" ] || continue
      case "$test_target" in
        JarvisIOSTests|JarvisIOSUITests) ;;
        *) error "Generated scheme 'JarvisIOS' TestAction/Testables contains unexpected BlueprintName '$test_target'; expected only JarvisIOSTests and JarvisIOSUITests." ;;
      esac
    done <<EOF
$scheme_testables
EOF
  fi

  if command -v "$xcodebuild_bin" >/dev/null 2>&1; then
    if project_listing="$("$xcodebuild_bin" -list -project "$xcode_project" 2>&1)"; then
      for target in JarvisIOS JarvisWidget JarvisIOSTests JarvisIOSUITests; do
        if ! listing_has_entry "Targets" "$target"; then
          error "Generated project does not expose required target '$target'. Check ios/project.yml and re-run XcodeGen."
        fi
      done

      if ! listing_has_entry "Schemes" "JarvisIOS"; then
        error "Generated project does not expose required scheme 'JarvisIOS'. Check ios/project.yml and re-run XcodeGen."
      fi
    else
      error "'$xcodebuild_bin -list' could not inspect $xcode_project. Check the generated project and Xcode installation."
    fi

    while IFS='|' read -r target expected_bundle_id; do
      if build_settings="$("$xcodebuild_bin" -showBuildSettings -project "$xcode_project" -target "$target" 2>&1)"; then
        actual_bundle_id="$(printf '%s\n' "$build_settings" | bundle_id_from_build_settings)"
        if [ -z "$actual_bundle_id" ]; then
          error "Build settings for target '$target' do not define PRODUCT_BUNDLE_IDENTIFIER; expected '$expected_bundle_id'."
        elif [ "$actual_bundle_id" != "$expected_bundle_id" ]; then
          error "Bundle identifier mismatch for target '$target': expected '$expected_bundle_id', got '$actual_bundle_id'. Check ios/project.yml and re-run XcodeGen."
        fi
      else
        error "'$xcodebuild_bin -showBuildSettings' could not inspect target '$target'; expected PRODUCT_BUNDLE_IDENTIFIER '$expected_bundle_id'."
      fi
    done <<'EOF'
JarvisIOS|com.jarvisassistant.ios
JarvisWidget|com.jarvisassistant.ios.widget
JarvisIOSTests|com.jarvisassistant.ios-tests
JarvisIOSUITests|com.jarvisassistant.ios-uitests
EOF
  else
    error "xcodebuild executable '$xcodebuild_bin' is unavailable; run this post-generation preflight on macOS with Xcode installed, or set XCODEBUILD_BIN to a test double for local contract tests."
  fi
fi

if [ "$errors" -ne 0 ]; then
  printf 'iOS project preflight failed with %s actionable error(s).\n' "$errors" >&2
  exit 1
fi

printf 'iOS project preflight passed: XcodeGen manifest and generated JarvisIOS project are complete.\n'
