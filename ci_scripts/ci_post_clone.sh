#!/bin/sh
#
# Xcode Cloud runs this automatically after cloning the repository.
#
# Stamps the bundle version (CFBundleVersion) with Xcode Cloud's own build
# number. App Store Connect rejects an upload whose build number isn't higher
# than every previous upload for the same version string, and CURRENT_PROJECT_VERSION
# in the project is a static value — so without this, every upload after the
# first would need a manual bump.
#
# CI_BUILD_NUMBER is provided by Xcode Cloud and increments per workflow run.
# Outside Xcode Cloud the variable is unset and this script does nothing, so
# local builds keep the project's own value.

set -e

if [ -z "$CI_BUILD_NUMBER" ]; then
    echo "CI_BUILD_NUMBER not set — not running in Xcode Cloud, leaving version alone."
    exit 0
fi

cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "Setting bundle version to Xcode Cloud build number: $CI_BUILD_NUMBER"
xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
