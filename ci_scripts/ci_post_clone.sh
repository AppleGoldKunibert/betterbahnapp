#!/bin/sh
# Xcode Cloud: DefaultCredentials.swift is gitignored, so create it from the workflow's secret
# environment variables DB_CLIENT_ID and DB_API_KEY. Without them the build still succeeds, just
# without DB Timetables realtime data (the template's empty key).
set -e

TIMETABLES="$CI_PRIMARY_REPOSITORY_PATH/Packages/BetterBahnKit/Sources/BetterBahnKit/Transit/Timetables"

if [ -z "$DB_CLIENT_ID" ] || [ -z "$DB_API_KEY" ]; then
    echo "warning: DB_CLIENT_ID/DB_API_KEY not set, building without DB Timetables credentials"
    cp "$TIMETABLES/DefaultCredentials.swift.template" "$TIMETABLES/DefaultCredentials.swift"
    exit 0
fi

cat > "$TIMETABLES/DefaultCredentials.swift" <<SWIFT
import Foundation

extension TimetablesCredentials {
    public static let shipped = TimetablesCredentials(clientID: "$DB_CLIENT_ID", apiKey: "$DB_API_KEY")
}
SWIFT
