#!/usr/bin/env bash
# client_experiment.sh
# Run on client VM (where your compiled ./client binary lives).
# This script:
#  - creates input files of exact sizes with dd (reliable bs/count),
#  - iterates identical parameter order to the server,
#  - runs the client binary and captures transmission time or error,
#  - records every combination into results.csv with an 'error' column,
#  - retries a few times to reduce transient failures.
#
# Edit configuration variables below if needed.

set -u -o pipefail
IFS=$'\n\t'

### === Configuration (edit if needed) ===
SERVER_IP="${SERVER_IP:-10.10.1.2}"  # server VM private IP
PORT="${PORT:-3120}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_BIN="${CLIENT_BIN:-${SCRIPT_DIR}/client}"  # must be executable

# === MODIFIED PARAMETERS ===
# These parameters MUST MATCH the server script exactly.
DELAYS=("0ms" "15ms" "30ms" "60ms")
BWS=("1Mbps" "10Mbps" "25Mbps" "50Mbps")
SIZES=("10K" "100K" "1M" "10M" "20M")

SEND_DIR="${SEND_DIR:-./send_files}"
mkdir -p "$SEND_DIR"

RESULTS_CSV="${RESULTS_CSV:-./results_with_errors.csv}"
echo "delay,bandwidth,filesize,transmission_ms,error" > "$RESULTS_CSV"

# runtime controls
RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-120}"   # timeout for a single client run
RETRIES="${RETRIES:-3}"                            # retries per combination
RETRY_SLEEP="${RETRY_SLEEP:-0.5}"                  # seconds between retries

# detect interface if needed for logs (we do not apply tc on client)
IFACE="${IFNAME:-}"
if [ -z "$IFACE" ]; then
  IFACE="$(ip -o -4 addr show | awk '/10\.10\.1\./{print $2; exit}')"
fi

if [ ! -x "$CLIENT_BIN" ]; then
  echo "ERROR: client binary not found or not executable at $CLIENT_BIN" >&2
  exit 1
fi

### === Helper: create file of requested size reliably ===
create_file_of_size() {
  local filepath="$1" size="$2" bs count
  if [ -f "$filepath" ]; then
    # If file exists, verify size quickly; if matches, skip recreation
    local actual
    actual=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
    # compute expected size in bytes
    local expected
    if [[ "$size" =~ ^([0-9]+)K$ ]]; then
      expected=$(( ${BASH_REMATCH[1]} * 1024 ))
    elif [[ "$size" =~ ^([0-9]+)M$ ]]; then
      expected=$(( ${BASH_REMATCH[1]} * 1024 * 1024 ))
    else
      expected=0
    fi
    if [ "$actual" -eq "$expected" ]; then
      return 0
    else
      echo "Existing file $filepath has size $actual (expected $expected) — recreating."
      rm -f "$filepath"
    fi
  fi

  # Map size strings to dd bs/count
  if [[ "$size" =~ ^([0-9]+)K$ ]]; then
    bs="${BASH_REMATCH[1]}K"
    count=1
  elif [[ "$size" =~ ^([0-9]+)M$ ]]; then
    num="${BASH_REMATCH[1]}"
    bs="1M"; count="$num"
  else
    # fallback: create a 1K file
    bs="1K"; count=1
  fi

  echo "Creating $filepath (bs=${bs}, count=${count})..."
  dd if=/dev/zero of="$filepath" bs="$bs" count="$count" status=none conv=fsync || {
    echo "dd failed for bs=$bs count=$count; removing file and retrying with bs=1M/count=0"
    rm -f "$filepath"
    dd if=/dev/zero of="$filepath" bs=1M count=0 status=none || true
  }
  sync
}

### === Run client test with retries and parse result ===
run_one_test() {
  local delay="$1" bw="$2" size="$3" infile="$4"
  local attempt out rc ms error

  for attempt in $(seq 1 "$RETRIES"); do
    echo "Client test attempt $attempt/$RETRIES for delay=$delay bw=$bw size=$size"
    # Use timeout to avoid hangs (timeout in coreutils)
    out="$(timeout "${RUN_TIMEOUT_SECONDS}" "$CLIENT_BIN" "$SERVER_IP" "$PORT" "$infile" 2>&1)"
    rc=$?
    # rc==124 -> timeout (GNU timeout uses 124). If child exited with non-zero, rc != 0.
    if [ $rc -eq 124 ]; then
      error="TIMEOUT"
      echo "Attempt $attempt: TIMEOUT after ${RUN_TIMEOUT_SECONDS}s"
    elif [ $rc -ne 0 ]; then
      # non-zero exit: capture message
      # sanitize first 200 chars of output for error column
      error="$(echo "$out" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-200)"
      error="EXIT${rc}: ${error:-(no output)}"
      echo "Attempt $attempt: client exited $rc — ${error}"
    else
      # rc == 0: try to extract "Transmission took <N> ms"
      ms="$(echo "$out" | awk -F'took' '/Transmission took/ { sub(/^[[:space:]]+/, "", $2); print $2 }' | awk '{print $1}' | tr -cd '[:digit:]')"
      if [ -n "$ms" ]; then
        echo "Attempt $attempt: success — ${ms} ms"
        echo "${delay},${bw},${size},${ms}," >> "$RESULTS_CSV"
        return 0
      else
        # rc==0 but parse failed; include entire output snippet as error
        error="$(echo "$out" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-200)"
        error="PARSE_FAIL: ${error:-(no output)}"
        echo "Attempt $attempt: parse failed — ${error}"
      fi
    fi

    # If we reach here, attempt failed; if not last attempt, sleep and retry
    if [ "$attempt" -lt "$RETRIES" ]; then
      sleep "$RETRY_SLEEP"
      echo "Retrying..."
    else
      # last attempt and still failed — record an error row
      echo "${delay},${bw},${size},,${error}" >> "$RESULTS_CSV"
      return 1
    fi
  done
}

### === Main loop ===
echo "Client experiment starting. Server: $SERVER_IP:$PORT"
echo "Client binary: $CLIENT_BIN"
echo "Send dir: $SEND_DIR"
echo "Results: $RESULTS_CSV"
echo

for delay in "${DELAYS[@]}"; do
  for bw in "${BWS[@]}"; do
    for size in "${SIZES[@]}"; do
      infile="${SEND_DIR}/send_size${size}.bin"
      create_file_of_size "$infile" "$size"

      echo "-------------------------------------------"
      echo "TEST (client side): delay=$delay | bw=$bw | size=$size"
      # Note: per your request, we DO NOT apply any tc on client side.
      # We still label the test with delay & bw to match the server's shaping.

      # run test with retries; this will write an entry to RESULTS_CSV
      run_one_test "$delay" "$bw" "$size" "$infile" || true

      # small pause between tests
      sleep 0.2
    done
  done
done

echo
echo "All client-side tests finished. Results written to: $RESULTS_CSV"
echo
if command -v column >/dev/null 2>&1; then
  column -t -s, "$RESULTS_CSV" || cat "$RESULTS_CSV"
else
  cat "$RESULTS_CSV"
fi

# keep send files for inspection; do not auto-delete them
exit 0