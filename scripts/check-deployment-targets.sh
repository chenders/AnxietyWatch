#!/bin/bash
# Fail CI if Xcode re-introduces deployment targets into the pbxproj.
# These must only be set in Config/*.xcconfig files.

set -euo pipefail

PBXPROJ="AnxietyWatch.xcodeproj/project.pbxproj"

if grep -q 'IPHONEOS_DEPLOYMENT_TARGET\|WATCHOS_DEPLOYMENT_TARGET' "$PBXPROJ"; then
  echo "ERROR: Deployment targets found in $PBXPROJ"
  echo "These must only be set in Config/*.xcconfig."
  echo "Xcode may have silently re-added them. Remove the lines from the pbxproj."
  echo ""
  grep -n 'DEPLOYMENT_TARGET' "$PBXPROJ"
  exit 1
fi

echo "OK: No deployment targets in pbxproj — xcconfig is the sole source."
