#!/bin/sh
# Downloads the runs older than a year from D1 into backups/<day>.json.gz (one file per day, plus the
# station names), checks each file, and only then deletes that day from D1. Run it from your Mac
# whenever you like, e.g. once a month: `Cloudflare/stats/backup.sh`. Needs `npx wrangler login` once.
set -eu
cd "$(dirname "$0")"
DB=betterbahn-stats
CUTOFF=$(date -v-1y +%F 2>/dev/null || date -d '1 year ago' +%F)
mkdir -p backups

query() {
    npx --yes wrangler d1 execute "$DB" --remote --json --command "$1"
}

# Prints the rows of wrangler's JSON answer (stdin) as one JSON array.
rows() {
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(JSON.parse(s).flatMap(x=>x.results??[]))))'
}

query "SELECT * FROM stations" | rows | gzip -c > backups/stations.json.gz

days=$(query "SELECT DISTINCT service_day AS day FROM runs WHERE service_day < '$CUTOFF' ORDER BY day" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>JSON.parse(s).flatMap(x=>x.results??[]).forEach(r=>console.log(r.day)))')

for day in $days; do
    file="backups/$day.json.gz"
    expected=$(query "SELECT count(*) AS n FROM runs WHERE service_day = '$day'" \
        | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)[0].results[0].n))')
    query "SELECT * FROM runs WHERE service_day = '$day'" | rows | gzip -c > "$file.tmp"
    saved=$(gzip -dc "$file.tmp" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).length))')
    if [ "$saved" != "$expected" ]; then
        echo "$day: saved $saved of $expected runs, nothing deleted" >&2
        rm -f "$file.tmp"
        exit 1
    fi
    mv "$file.tmp" "$file"
    query "DELETE FROM runs WHERE service_day = '$day'" > /dev/null
    echo "$day: $saved runs saved to $file and deleted from D1"
done
echo "Done. Runs before $CUTOFF are in $(pwd)/backups."
