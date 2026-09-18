#!/bin/bash
# Wrapper script to run swift test with workaround for codesign detritus error
# The default .build path has issues with extended attributes during codesigning
# This script uses --scratch-path to build in a temporary directory instead

TEMP_BUILD=$(mktemp -d)
trap "rm -rf $TEMP_BUILD" EXIT

swift test --scratch-path "$TEMP_BUILD" "$@"
