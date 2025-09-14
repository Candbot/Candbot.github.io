#!/usr/bin/env bash
# server_experiment.sh
# Run on server VM (where your compiled ./server binary lives).
# This script:
#  - applies tc shaping (delay + rate) on the server interface per test,
#  - starts the server binary to receive the file,
#  - resets qdisc after each test,
#  - writes received files into ./received_files
#
# Edit configuration variables below if needed.

set -u
IFS=$'\n\t'

### === Configuration (edit if needed) ===
SERVER_IP="${SERVER_IP:-10.10.1.2}"   # server VM private IP
PORT="${PORT:-3120}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_BIN="${SERVER_BIN:-${SCRIPT_DIR}/server}"    # must be executable

# === Re-adjusted Parameters for Gradual Failure ===
# With the cascade failure bug fixed, these parameters should show a better curve.
DELAYS=("0ms" "20ms" "40ms" "80ms")
BWS=("1Mbps" "10Mbps" "25Mbps" "50Mbps")
SIZES=("10K" "100K" "1M" "10M" "20M")

OUT_DIR="${OUT_DIR:-./received_files}"
mkdir -p "$OUT_DIR"

# detect interface (use IFNAME env var if set by Vagrant provisioning)
IFACE="${IFNAME:-}"
if [ -z "$IFACE" ]; then
  IFACE="$(ip -o -4 addr show | awk '/10\.10\.1\./{print $2; exit}')"
fi
if [ -z "$IFACE" ]; then
  echo "ERROR: Could not detect network interface. Set IFNAME in environment or edit script." >&2
  exit 1
fi

if [ ! -x "$SERVER_BIN" ]; then
  echo "ERROR: server binary not found or not executable at $SERVER_BIN" >&2
  exit 1
fi

### === Helpers ===
cleanup_qdisc() {
  sudo tc qdisc del dev "$IFACE" root 2>/dev/null || true
}

# (apply_tc_server function is unchanged)
apply_tc_server() {
  local rate="$1" delay="$2" rate_tc burst_kbit latency_ms delay_ms kbps num
  delay_ms="${delay%ms}"
  rate_tc="$(echo "$rate" | sed -E 's/Mbps/mbit/; s/Kbps/kbit/; s/kbps/kbit/; s/MBIT/mbit/; s/KBIT/kbit/')"
  if [[ "$rate" == *"Mbps" ]]; then
    num="${rate%Mbps}"; kbps=$(( num * 1000 ))
  elif [[ "$rate" == *"Kbps" ]] || [[ "$rate" == *"kbps" ]]; then
    num="${rate%Kbps}"; num="${num%kbps}"; kbps="$num"
  else
    num="${rate}"; kbps=$(( num * 1000 ))
  fi
  burst_kbit=$(awk -v k="$kbps" -v dm="$delay_ms" 'BEGIN{ b = k * (dm / 1000); if (b < 64) b = 64; b = b * 1.2; printf("%d", (b + 0.5)); }')
  latency_ms=$(awk -v dm="$delay_ms" 'BEGIN{ lm = dm * 2 + 200; if (lm < 200) lm = 200; printf("%d", lm); }')
  sudo tc qdisc del dev "$IFACE" root 2>/dev/null || true
  if command -v tcset >/dev/null 2>&1; then
    if sudo tcset "$IFACE" --rate "$rate" --delay "$delay" >/dev/null 2>&1; then
      echo "Applied tcset: rate=$rate delay=$delay on $IFACE"; return 0
    else
      echo "tcset present but failed for rate=$rate delay=$delay — falling back to tc + tbf"
    fi
  fi
  sudo tc qdisc add dev "$IFACE" root handle 1: netem delay "$delay" >/dev/null 2>&1 || true
  sudo tc qdisc add dev "$IFACE" parent 1: handle 10: tbf rate "$rate_tc" burst "${burst_kbit}kbit" latency "${latency_ms}ms" >/dev/null 2>&1 || true
  echo "Applied tc fallback on $IFACE: rate=$rate_tc delay=$delay burst=${burst_kbit}kbit latency=${latency_ms}ms"
}


on_exit() {
  echo "Server script exiting: cleaning up qdisc and old received files..."
  cleanup_qdisc
  # also kill any lingering server on exit
  sudo fuser -k "${PORT}/tcp" 2>/dev/null || true
  echo "Cleanup done."
}
trap on_exit EXIT

### === Main loop ===
echo "Server experiment starting on $SERVER_IP:$PORT (interface: $IFACE)"
echo "Server binary: $SERVER_BIN"
echo "Output dir: $OUT_DIR"
echo

for delay in "${DELAYS[@]}"; do
  for bw in "${BWS[@]}"; do
    for size in "${SIZES[@]}"; do
      ts="$(date +%s%3N)"   # ms timestamp
      outfile="${OUT_DIR}/recv_size${size}_bw${bw}_delay${delay}_${ts}.bin"

      echo "-------------------------------------------"
      echo "TEST (server side): delay=$delay | bw=$bw | expected filesize=$size"
      apply_tc_server "$bw" "$delay"

      # === ROBUSTNESS FIX ===
      # Forcefully kill any process that might be lingering on the port from a
      # previous failed run. This prevents the cascade failure.
      echo "Ensuring port ${PORT} is free..."
      sudo fuser -k "${PORT}/tcp" 2>/dev/null || true
      sleep 0.1 # Give a moment for the port to be released

      # Start server (will block until client sends & server exits)
      echo "Starting server to write to: $outfile"
      "$SERVER_BIN" "$SERVER_IP" "$PORT" "$outfile" &
      SERVER_PID=$!
      echo "Server PID: $SERVER_PID"

      # Wait for the server binary to finish (client should connect and send)
      wait "$SERVER_PID"
      SERVER_RC=$?
      if [ "$SERVER_RC" -ne 0 ]; then
        echo "Warning: server process exited with code $SERVER_RC for test (delay=$delay bw=$bw size=$size)"
      else
        echo "Server finished normally for this test; file at: $outfile"
      fi

      # remove shaping (so each test starts from clean qdisc)
      cleanup_qdisc

      # small pause to allow client/server sockets to fully close
      sleep 0.2
    done
  done
done

echo "All server-side tests finished."
exit 0