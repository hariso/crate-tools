#!/usr/bin/env bash
#
# Measures the disk reads caused by `ANALYZE` on a partitioned time-series table.
#
# Starts a single CrateDB node in Docker, creates a table shaped like the
# History table (20 monthly partitions), loads data, then runs `ANALYZE` on a
# cold page cache and reports:
#   - read_bytes from /proc/<pid>/io: bytes the JVM caused to be read from storage
#   - major page faults from /proc/<pid>/stat: faults on memory-mapped files
#     (doc values) that went to disk
#
# Usage:
#   ./analyze_read_bytes.sh
#   CRATE_VERSION=5.8 ./analyze_read_bytes.sh
#   CRATE_VERSION=nightly ./analyze_read_bytes.sh
#   CRATE_TAR=~/apps/crate/crate-6.6.0-<build>.tar.gz ./analyze_read_bytes.sh
#
# Environment:
#   CRATE_VERSION       image tag of `crate` (default: 6.5); `nightly` pulls and
#                       uses `crate/crate:nightly`
#   CRATE_TAR           CrateDB tarball; if set, runs it in a Debian container
#                       with its bundled JDK instead of a `crate` image;
#                       mutually exclusive with CRATE_VERSION
#   ROWS_PER_PARTITION  rows per monthly partition (default: 50000)
#   PARTITIONS          number of monthly partitions (default: 20)
#   SHARDS              shards per partition (default: 4)
#   HEAP                CrateDB heap (default: 2g)
#   MAX_BYTES_PER_SEC   stats.service.max_bytes_per_sec (default: 5mb)
#
# Notes:
#   - Dropping the page cache uses a privileged container and clears the page
#     cache of the whole host.
#   - Every shard is force-merged to 1 segment.

set -euo pipefail

if [[ -n ${CRATE_VERSION:-} && -n ${CRATE_TAR:-} ]]; then
    echo "Set either CRATE_VERSION or CRATE_TAR, not both" >&2
    exit 1
fi
CRATE_VERSION=${CRATE_VERSION:-6.5}
CRATE_TAR=${CRATE_TAR:-}
ROWS_PER_PARTITION=${ROWS_PER_PARTITION:-500000}
PARTITIONS=${PARTITIONS:-20}
SHARDS=${SHARDS:-1}
HEAP=${HEAP:-8g}
MAX_BYTES_PER_SEC=${MAX_BYTES_PER_SEC:-5mb}

if [[ $CRATE_VERSION == nightly ]]; then
    IMAGE="crate/crate:nightly"
else
    IMAGE="crate:${CRATE_VERSION}"
fi
if [[ -n $CRATE_TAR ]]; then
    NAME=$(basename "$CRATE_TAR" .tar.gz)
else
    NAME=$CRATE_VERSION
fi
CONTAINER="analyze-read-bytes-${NAME//[^a-zA-Z0-9]/-}"
VOLUME="${CONTAINER}-data"
TAR_DIR="/tmp/${CONTAINER}"
URL="http://localhost:44200"
TABLE="doc.history_sim"

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
    if [[ -n $CRATE_TAR ]]; then
        rm -rf "$TAR_DIR"
    fi
}

sql() {
    local stmt resp
    stmt=$(printf '%s' "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')
    resp=$(curl -sS -H 'Content-Type: application/json' -X POST "$URL/_sql" \
        -d "{\"stmt\": \"$stmt\"}")
    if [[ $resp == *'"error"'* ]]; then
        log "SQL failed: $1"
        log "$resp"
        return 1
    fi
    printf '%s\n' "$resp"
}

# First value of the first row.
sql_value() {
    sql "$1" | sed -E 's/.*"rows":\[\[([^],]*).*/\1/; s/"//g'
}

start_crate() {
    if [[ $CRATE_VERSION == nightly ]]; then
        log "Pulling $IMAGE"
        docker pull -q "$IMAGE" >/dev/null
    fi
    docker run -d \
        --name "$CONTAINER" \
        --publish 44200:4200 \
        --volume "${VOLUME}:/data" \
        --cap-add SYS_PTRACE \
        --env CRATE_HEAP_SIZE="$HEAP" \
        "$IMAGE" \
        -Cdiscovery.type=single-node \
        -Cstats.service.interval=0 \
        -Cstats.service.max_bytes_per_sec="$MAX_BYTES_PER_SEC" \
        >/dev/null

    wait_for_crate
}

# Runs the tarball as the current user, because CrateDB refuses to start as root.
# Data lives on a named volume like in start_crate, chowned to that user, so it
# is on disk and not on the tmpfs that holds $TAR_DIR.
# The tarball's crate.yml enables host-based auth, which rejects requests that
# come through the Docker port mapping.
start_from_tar() {
    log "Extracting $CRATE_TAR to $TAR_DIR"
    mkdir -p "$TAR_DIR"
    tar -xzf "$CRATE_TAR" --strip-components=1 -C "$TAR_DIR"
    docker run --rm --volume "${VOLUME}:/data" alpine chown "$(id -u):$(id -g)" /data

    docker run -d \
        --name "$CONTAINER" \
        --publish 44200:4200 \
        --volume "$TAR_DIR:/crate" \
        --volume "${VOLUME}:/data" \
        --user "$(id -u):$(id -g)" \
        --cap-add SYS_PTRACE \
        --env CRATE_HEAP_SIZE="$HEAP" \
        debian:bookworm-slim \
        /crate/bin/crate \
        -Cpath.data=/data \
        -Cnetwork.host=_site_ \
        -Cauth.host_based.enabled=false \
        -Cdiscovery.type=single-node \
        -Cstats.service.interval=0 \
        -Cstats.service.max_bytes_per_sec="$MAX_BYTES_PER_SEC" \
        >/dev/null

    wait_for_crate
}

wait_for_crate() {
    log "Waiting for CrateDB on $URL"
    until [[ $(curl -s -o /dev/null -w '%{http_code}' "$URL/" || true) == 200 ]]; do
        sleep 1
    done
}

crate_pid() {
    docker exec "$CONTAINER" sh -c '
        for d in /proc/[0-9]*; do
            if grep -qa "io.crate.bootstrap.CrateDB" "$d/cmdline" 2>/dev/null; then
                echo "${d#/proc/}"
                exit 0
            fi
        done
        exit 1'
}

# Prints "<read_bytes> <major_faults>" of the CrateDB JVM.
counters() {
    local pid=$1
    docker exec "$CONTAINER" cat "/proc/$pid/io" "/proc/$pid/stat" |
        awk '/^read_bytes:/ { rb = $2 } /^[0-9]+ \(/ { mf = $12 } END { print rb, mf }'
}

drop_page_cache() {
    sync
    docker run --rm --privileged alpine sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
}

create_table() {
    sql "CREATE TABLE $TABLE (
        \"ts\" TIMESTAMP WITHOUT TIME ZONE,
        \"month\" TIMESTAMP WITHOUT TIME ZONE GENERATED ALWAYS AS date_trunc('month', \"ts\"),
        \"signal\" TEXT,
        \"value\" REAL,
        \"tags\" OBJECT(DYNAMIC) AS (
            \"text_1\" TEXT,
            \"text_2\" TEXT,
            \"text_3\" TEXT,
            \"text_4\" TEXT,
            \"text_5\" TEXT,
            \"text_6\" TEXT,
            \"long_1\" BIGINT,
            \"long_2\" BIGINT,
            \"long_3\" BIGINT
        )
    ) CLUSTERED INTO $SHARDS SHARDS
      PARTITIONED BY (\"month\")
      WITH (number_of_replicas = 0)" >/dev/null
}

# Cardinalities within a partition:
#   signal 50, text_1 1k, text_2 min(100k, rows), text_3 unique (md5),
#   text_4 1k, text_5 10k, text_6 1M across partitions,
#   long_1 10, long_2 1M across partitions, long_3 100
load_partition() {
    local p=$1
    local start end step
    start=$(date -u -d "2024-01-01 +${p} month" +%s)000
    end=$(date -u -d "2024-01-01 +$((p + 1)) month" +%s)000
    step=$(((end - start) / ROWS_PER_PARTITION))
    local n=$ROWS_PER_PARTITION
    local i=generate_series
    sql "INSERT INTO $TABLE (\"ts\", \"signal\", \"value\", \"tags\")
        SELECT
            CAST($start + CAST($i AS BIGINT) * $step AS TIMESTAMP WITHOUT TIME ZONE),
            'sig_' || CAST($i % 50 AS TEXT),
            CAST(random() * 1000 AS REAL),
            {
                text_1 = 'ch_' || CAST($i % 1000 AS TEXT),
                text_2 = 'cu_' || CAST($i % 100000 AS TEXT),
                text_3 = md5(CAST($p * $n + $i AS TEXT)),
                text_4 = 'si_' || CAST($i % 1000 AS TEXT),
                text_5 = 've_' || CAST($i % 10000 AS TEXT),
                text_6 = 'lo_' || CAST(($p * $n + $i) % 1000000 AS TEXT),
                long_1 = CAST($i % 10 AS BIGINT),
                long_2 = CAST(($p * $n + $i) % 1000000 AS BIGINT),
                long_3 = CAST($i % 100 AS BIGINT)
            }
        FROM generate_series(0, $((n - 1)))" >/dev/null
}

# Bytes on disk per Lucene file extension, for the extensions ANALYZE may read.
file_sizes() {
    docker exec "$CONTAINER" find /data -type f \
        \( -name '*.dvd' -o -name '*.fdt' -o -name '*.fdx' -o -name '*.cfs' \) \
        -printf '%s %f\n' |
        awk '{
                n = split($2, parts, ".")
                size[parts[n]] += $1
            }
            END {
                for (ext in size) {
                    printf "  .%s %.1f MiB\n", ext, size[ext] / 1048576
                }
            }' |
        sort
}

measure() {
    local version=$1
    local pid rb0 mf0 rb1 mf1 t0 t1
    pid=$(crate_pid)
    drop_page_cache
    read -r rb0 mf0 < <(counters "$pid")
    t0=$(date +%s.%N)
    sql "ANALYZE" >/dev/null
    t1=$(date +%s.%N)
    read -r rb1 mf1 < <(counters "$pid")
    awk -v version="$version" \
        -v t0="$t0" -v t1="$t1" -v rb="$((rb1 - rb0))" -v mf="$((mf1 - mf0))" \
        'BEGIN {
            secs = t1 - t0
            mib = rb / 1048576
            printf "version=%s analyze_s=%.2f read_mib=%.1f major_faults=%d mib_per_s=%.1f\n",
                version, secs, mib, mf, (secs > 0 ? mib / secs : 0)
        }'
}

main() {
    trap cleanup EXIT

    log "Removing leftovers of earlier runs"
    cleanup

    if [[ -n $CRATE_TAR ]]; then
        start_from_tar
    else
        start_crate
    fi
    local version
    version=$(sql_value "SELECT version['number'] FROM sys.nodes LIMIT 1")
    log "CrateDB $version"

    create_table
    for ((p = 0; p < PARTITIONS; p++)); do
        log "Loading partition $((p + 1))/$PARTITIONS ($ROWS_PER_PARTITION rows)"
        load_partition "$p"
    done
    sql "REFRESH TABLE $TABLE" >/dev/null
    log "Force-merging every shard to 1 segment"
    sql "OPTIMIZE TABLE $TABLE WITH (max_num_segments = 1)" >/dev/null
    log "Rows: $(sql_value "SELECT count(*) FROM $TABLE")"
    log "Partitions: $(sql_value "SELECT count(*) FROM information_schema.table_partitions WHERE table_name = 'history_sim'")"
    log "Files on disk:"
    file_sizes >&2

    log "Running ANALYZE on a cold page cache"
    measure "$version"
}

main "$@"
