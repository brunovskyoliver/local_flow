#!/bin/bash
# Installs the LocalFlow remote dictation server (Feature 014) as a per-user
# launch agent, per specs/014-remote-dictation-server/contracts/flowd-cli.md:
# builds flowd and the flowd-speech worker, installs both under
# <data-dir>/bin and loads two agents: flowd and the server's own MTPLX.
# Feature 018: flowd also serves summaries and meeting work. The Whisper helper
# (localflow-whisper-engine) and the meeting model descriptors go beside
# flowd-speech, the meeting models are downloaded and verified once into
# <data-dir>/Models, and flowd starts the meeting worker next to the speech worker.
#
#   variant      label                               remote listener   local listener   MTPLX            data directory
#   production   org.localflow.LocalFlow.remote      127.0.0.1:8090    127.0.0.1:8091   127.0.0.1:8092   ~/Library/Application Support/LocalFlow Server
#   development  org.localflow.LocalFlow.dev.remote  127.0.0.1:18090   127.0.0.1:18091  127.0.0.1:18092  ~/Library/Application Support/LocalFlow Server Dev
#
# flowd serve always opens its normal listener too; the remote agent uses
# 8091/18091 so it never collides with the app's flowd on 8080/18080. Rewrite
# over the channel goes to the server's own MTPLX (<label>.mtplx on 8092/18092),
# which stays loaded while the agent runs and does not depend on any LocalFlow app
# running. Its API key is generated once into <data-dir>/mtplx-api-key (0600); flowd
# starts through <data-dir>/bin/localflow-remote-flowd, which reads that key, so the
# key never appears in a plist. The MTPLX runtime and model default to the ones the
# installed LocalFlow app set up (--mtplx, --model override them). Logs go to
# ~/Library/Logs/LocalFlow Server[ Dev]/. cloudflared stays the owner's own
# configuration and points the tunnel hostname at the remote listener.
#
# The app's own agents (org.localflow.LocalFlow[.dev].flowd and .mtplx) are
# never replaced, stopped or touched: launchctl is only ever called with this
# script's own label.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/install-remote-server.sh [--dev] [--dry-run] [--speech-worker PATH]
         [--meeting-helper PATH] [--google-client-id IDS] [--apple-audience IDS]
         [--mtplx PATH] [--model DIR]

  --dev                 install the development variant
  --dry-run             print what would be done; build, install and load nothing
  --speech-worker PATH  install this prebuilt flowd-speech instead of building it
  --meeting-helper PATH install this prebuilt Whisper helper (scripts/build-meeting-whisper.sh
                        output) instead of building it
  --google-client-id IDS  comma-separated Google OAuth client IDs to accept; without it
                          flowd refuses Google sign-in
  --apple-audience IDS    comma-separated app bundle IDs to accept for Sign in with Apple;
                          without it flowd refuses Apple sign-in
  --mtplx PATH            the mtplx executable to serve rewrites with (default: the
                          installed LocalFlow app's runtime)
  --model DIR             the MTPLX model directory (default: the installed app's model)
USAGE
}

dev=0
dry_run=0
prebuilt_worker=""
prebuilt_helper=""
google_client_ids=""
apple_audience=""
app_state="$HOME/Library/Application Support/LocalFlow/LocalAI"
mtplx="$app_state/venv/bin/mtplx"
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dev) dev=1 ;;
    --dry-run) dry_run=1 ;;
    --speech-worker)
      [ $# -ge 2 ] || { usage >&2; exit 1; }
      prebuilt_worker="$2"
      shift
      ;;
    --meeting-helper)
      [ $# -ge 2 ] || { usage >&2; exit 1; }
      prebuilt_helper="$2"
      shift
      ;;
    --google-client-id)
      [ $# -ge 2 ] || { usage >&2; exit 1; }
      google_client_ids="$2"
      shift
      ;;
    --apple-audience)
      [ $# -ge 2 ] || { usage >&2; exit 1; }
      apple_audience="$2"
      shift
      ;;
    --mtplx)
      [ $# -ge 2 ] || { usage >&2; exit 1; }
      mtplx="$2"
      shift
      ;;
    --model)
      [ $# -ge 2 ] || { usage >&2; exit 1; }
      model="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
  shift
done

repository="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$dev" -eq 1 ]; then
  label="org.localflow.LocalFlow.dev.remote"
  remote_listen="127.0.0.1:18090"
  listen="127.0.0.1:18091"
  mtplx_port=18092
  data_dir="$HOME/Library/Application Support/LocalFlow Server Dev"
  log_dir="$HOME/Library/Logs/LocalFlow Server Dev"
  dev_flag=("--dev")
else
  label="org.localflow.LocalFlow.remote"
  remote_listen="127.0.0.1:8090"
  listen="127.0.0.1:8091"
  mtplx_port=8092
  data_dir="$HOME/Library/Application Support/LocalFlow Server"
  log_dir="$HOME/Library/Logs/LocalFlow Server"
  dev_flag=()
fi
bin_dir="$data_dir/bin"
plist="$HOME/Library/LaunchAgents/$label.plist"
mtplx_label="$label.mtplx"
mtplx_plist="$HOME/Library/LaunchAgents/$mtplx_label.plist"
backend="http://127.0.0.1:$mtplx_port/v1"
api_key="$data_dir/mtplx-api-key"
if [ -z "$model" ] && [ -s "$app_state/model-path" ]; then model="$(cat "$app_state/model-path")"; fi
if [ "$dry_run" -eq 0 ]; then
  [ -x "$mtplx" ] || { echo "error: no mtplx at $mtplx; set up local AI in LocalFlow or pass --mtplx" >&2; exit 1; }
  [ -d "$model" ] || { echo "error: no MTPLX model directory; pass --model DIR" >&2; exit 1; }
fi
domain="gui/$(id -u)"

# Never act on the app's agents.
for app_label in org.localflow.LocalFlow.flowd org.localflow.LocalFlow.mtplx \
  org.localflow.LocalFlow.dev.flowd org.localflow.LocalFlow.dev.mtplx; do
  if [ "$label" = "$app_label" ] || [ "$mtplx_label" = "$app_label" ]; then
    echo "error: refusing to install over the app's launch agent $app_label" >&2
    exit 1
  fi
done
case "$listen" in
  *:8080|*:18080)
    echo "error: $listen is the app's flowd port" >&2
    exit 1
    ;;
esac

# run prints a command in dry-run mode and runs it otherwise.
run() {
  if [ "$dry_run" -eq 1 ]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

# render_agent LABEL LOG_NAME STDOUT_PATH ARGUMENT...
render_agent() {
  local agent_label="$1" log_name="$2" stdout_path="$3"
  shift 3
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$agent_label</string>
	<key>ProgramArguments</key>
	<array>
PLIST
  local argument
  for argument in "$@"; do
    printf '\t\t<string>%s</string>\n' "$(xml_escape "$argument")"
  done
  cat <<PLIST
	</array>
	<key>KeepAlive</key>
	<true/>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Standard</string>
	<key>StandardOutPath</key>
	<string>$(xml_escape "$stdout_path")</string>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$log_dir/$log_name.stderr.log")</string>
	<key>ThrottleInterval</key>
	<integer>30</integer>
</dict>
</plist>
PLIST
}

render_plist() {
  local arguments=(
    "$bin_dir/localflow-remote-flowd" "$api_key" "$bin_dir/flowd" serve
    --listen "$listen"
    --remote-listen "$remote_listen"
    --data-dir "$data_dir"
    --backend "$backend" --model localflow
    --speech-worker "$bin_dir/flowd-speech"
    --meeting-helper "$bin_dir/localflow-whisper-engine"
    --log-file "$log_dir/flowd.log"
    ${dev_flag[@]+"${dev_flag[@]}"}
  )
  [ -z "$google_client_ids" ] || arguments+=(--google-client-id "$google_client_ids")
  [ -z "$apple_audience" ] || arguments+=(--apple-audience "$apple_audience")
  render_agent "$label" flowd "$log_dir/flowd.stdout.log" "${arguments[@]}"
}

# The same serving flags and memory caps as the app's MTPLX agent (ADR 0026),
# without the app-PID watch: the server's model stays loaded while the agent runs.
# MTPLX prints a browser URL containing its API key on stdout, so stdout is discarded.
render_mtplx_plist() {
  render_agent "$mtplx_label" mtplx /dev/null /usr/bin/env \
    MTPLX_CLEAR_CACHE_AFTER_REQUEST=always MTPLX_MLX_CACHE_LIMIT=268435456 \
    MTPLX_SESSION_BANK_MAX_ENTRIES=1 MTPLX_SESSION_BANK_MAX_BYTES=512M \
    MTPLX_SESSION_BANK_PER_SESSION_BYTES=512M HF_HUB_DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 \
    "$mtplx" serve --host 127.0.0.1 --port "$mtplx_port" \
    --model "$model" --model-id localflow --api-key-file "$api_key" \
    --scheduler-mode serial --batching-preset latency --ssd-session-cache off \
    --context-window 32768 --fan-mode default --reasoning off \
    --adaptive-policy expected_value --no-stats-footer --unsafe-force-unverified --yes
}

echo "Installing $label: remote $remote_listen, local $listen, backend $backend"
echo "MTPLX: $mtplx, model $model"
echo "Data directory: $data_dir"
echo "Logs: $log_dir"

stage="$(mktemp -d "${TMPDIR:-/tmp}/localflow-remote-server.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# 1. flowd, built like scripts/bundle-local-ai.sh.
echo "Building flowd"
if [ "$dry_run" -eq 1 ]; then
  echo "+ (cd $(printf '%q' "$repository/server") && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -buildvcs=false -ldflags=-s -o $(printf '%q' "$stage/flowd") ./cmd/flowd)"
else
  (cd "$repository/server" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
    go build -trimpath -buildvcs=false -ldflags=-s -o "$stage/flowd" ./cmd/flowd)
fi

# 2. flowd-speech.
worker="$stage/xcode/Release/flowd-speech"
if [ -n "$prebuilt_worker" ]; then
  if [ ! -x "$prebuilt_worker" ]; then
    echo "error: --speech-worker $prebuilt_worker is not an executable file" >&2
    exit 1
  fi
  worker="$prebuilt_worker"
  echo "Using prebuilt flowd-speech: $worker"
else
  echo "Building flowd-speech"
  project="$repository/apps/macos/LocalFlow.xcodeproj"
  if ! xcodebuild -list -json -project "$project" 2>/dev/null |
    /usr/bin/python3 -c 'import json,sys; sys.exit(0 if "flowd-speech" in json.load(sys.stdin)["project"]["targets"] else 1)'; then
    echo "error: the Xcode project has no flowd-speech target yet ($project)." >&2
    echo "       Add the worker target (Feature 014 T057-T060) or pass --speech-worker PATH." >&2
    [ "$dry_run" -eq 1 ] || exit 1
  fi
  run xcodebuild -project "$project" -target flowd-speech -configuration Release \
    SYMROOT="$stage/xcode" build
fi

# 2b. The Whisper helper for meeting transcripts (Feature 018), built from the pinned
# whisper.cpp revision with its licences.
helper="$stage/meeting-whisper-native/Engine/sotto-engine"
if [ -n "$prebuilt_helper" ]; then
  if [ ! -x "$prebuilt_helper" ]; then
    echo "error: --meeting-helper $prebuilt_helper is not an executable file" >&2
    exit 1
  fi
  helper="$prebuilt_helper"
  echo "Using prebuilt Whisper helper: $helper"
else
  echo "Building the Whisper helper"
  run env TEMP_DIR="$stage" "$repository/scripts/build-meeting-whisper.sh"
fi

# 3. Install under <data-dir>/bin; the data directory is private (0700).
run mkdir -p "$bin_dir"
run chmod 0700 "$data_dir"
run install -m 0755 "$stage/flowd" "$bin_dir/flowd"
# Reinstalling from <data-dir>/bin (--speech-worker pointing at the installed worker)
# keeps the worker and its bundle; copying them onto themselves would delete the bundle.
worker_installed=0
if [ -e "$bin_dir/flowd-speech" ] && [ "$worker" -ef "$bin_dir/flowd-speech" ]; then worker_installed=1; fi
[ "$worker_installed" -eq 1 ] || run install -m 0755 "$worker" "$bin_dir/flowd-speech"
# The worker reads the pinned descriptors next to itself (flowd-speech provision/serve).
models_src="$repository/apps/macos/LocalFlow/Resources/Models"
run install -m 0644 "$models_src/parakeet-v3.json" "$models_src/parakeet-ctc-110m.json" \
  "$models_src/whisper-large-v3-turbo.json" "$models_src/speaker-diarization-offline.json" \
  "$bin_dir/"
# flowd starts `flowd-speech meeting --helper <bin>/localflow-whisper-engine`. The helper
# and model licences travel with the install (ADR 0019).
if ! { [ -e "$bin_dir/localflow-whisper-engine" ] && [ "$helper" -ef "$bin_dir/localflow-whisper-engine" ]; }; then
  run install -m 0755 "$helper" "$bin_dir/localflow-whisper-engine"
fi
whisper_license="$repository/third_party/sotto/vendor/whisper.cpp/LICENSE"
if [ ! -f "$whisper_license" ] && [ "$dry_run" -eq 0 ]; then
  echo "error: $whisper_license is missing; run scripts/build-meeting-whisper.sh once." >&2
  exit 1
fi
run mkdir -p "$bin_dir/WhisperLicenses"
run install -m 0644 "$repository/third_party/sotto/LICENSE" "$bin_dir/WhisperLicenses/Sotto-LICENSE.txt"
run install -m 0644 "$whisper_license" "$bin_dir/WhisperLicenses/whisper-LICENSE.txt"
for name in Whisper-model Silero JSON miniaudio; do
  run install -m 0644 "$repository/third_party/sotto/Resources/$name-LICENSE.txt" "$bin_dir/WhisperLicenses/"
done
worker_bundle="$(dirname "$worker")/FluidAudio_FluidAudio.bundle"
if [ "$worker_installed" -eq 0 ] && { [ -d "$worker_bundle" ] || [ "$dry_run" -eq 1 ]; }; then
  run rm -rf "$bin_dir/FluidAudio_FluidAudio.bundle"
  run cp -R "$worker_bundle" "$bin_dir/"
fi
run mkdir -p "$log_dir"
run chmod 0700 "$log_dir"
# flowd reads the MTPLX key from a file at start, never from the plist.
if [ "$dry_run" -eq 1 ]; then
  echo "+ write $(printf '%q' "$bin_dir/localflow-remote-flowd") (0755)"
else
  cat >"$stage/localflow-remote-flowd" <<'WRAPPER'
#!/bin/sh
# Starts flowd with the server MTPLX key from the file named by $1.
set -eu
key_file="$1"
shift
LOCALFLOW_BACKEND_TOKEN="$(cat "$key_file")"
[ -n "$LOCALFLOW_BACKEND_TOKEN" ]
export LOCALFLOW_BACKEND_TOKEN
exec "$@"
WRAPPER
  sh -n "$stage/localflow-remote-flowd"
  install -m 0755 "$stage/localflow-remote-flowd" "$bin_dir/localflow-remote-flowd"
fi
if [ "$dry_run" -eq 1 ]; then
  echo "+ generate $(printf '%q' "$api_key") (0600) unless present"
elif [ ! -s "$api_key" ]; then
  (umask 077 && openssl rand -hex 32 >"$api_key")
fi

# 4. flowd refuses to serve without the identity key; do not load an agent
# that would only restart every 30 seconds.
if [ ! -f "$data_dir/flowd-remote.sqlite" ]; then
  message="the server is not initialized. Run:
  $(printf '%q' "$bin_dir/flowd") admin --data-dir $(printf '%q' "$data_dir") ${dev_flag[*]+${dev_flag[*]} }init
then run this script again."
  if [ "$dry_run" -eq 1 ]; then
    echo "note: $message"
  else
    echo "error: $message" >&2
    exit 1
  fi
fi

stop_agent() {
  local agent_label="$1"
  if [ "$dry_run" -eq 1 ]; then
    echo "+ launchctl bootout $domain/$agent_label   (only if loaded)"
  elif launchctl print "$domain/$agent_label" >/dev/null 2>&1; then
    launchctl bootout "$domain/$agent_label"
    # bootstrap fails with error 5 while the old job is still being torn down.
    local attempt
    for attempt in $(seq 1 50); do
      launchctl print "$domain/$agent_label" >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi
}

# 4b. Download and verify the meeting models once (Whisper Turbo with its VAD, and the
# offline diarization and voice models); later runs only verify them. A running server's
# workers hold the models' import locks, so flowd stops first; step 5 starts it again.
# If provisioning fails, the earlier agent is started again rather than left down.
stop_agent "$label"
if ! run "$bin_dir/flowd-speech" provision --models "$data_dir/Models" --meeting; then
  [ -f "$plist" ] && launchctl bootstrap "$domain" "$plist" || true
  echo "error: model provisioning failed; $label was started again with its earlier plist." >&2
  exit 1
fi

# 5. Render and load both agents, replacing only earlier copies of these labels.
# MTPLX first, so flowd's backend probe finds it.
install_agent() {
  local agent_label="$1" agent_plist="$2" renderer="$3"
  if [ "$dry_run" -eq 1 ]; then
    echo "+ write $(printf '%q' "$agent_plist") (0644):"
    "$renderer"
  else
    mkdir -p "$(dirname "$agent_plist")"
    "$renderer" >"$stage/agent.plist"
    plutil -lint "$stage/agent.plist" >/dev/null
    install -m 0644 "$stage/agent.plist" "$agent_plist"
  fi
  stop_agent "$agent_label"
  run launchctl bootstrap "$domain" "$agent_plist"
}
install_agent "$mtplx_label" "$mtplx_plist" render_mtplx_plist
install_agent "$label" "$plist" render_plist

echo "Done. $label serves the remote channel on $remote_listen; $mtplx_label serves rewrites on 127.0.0.1:$mtplx_port."
echo "Point the cloudflared tunnel hostname at http://$remote_listen."
