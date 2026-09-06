#!/bin/bash

set -euo pipefail

action=run
profile=lower-latency
frame_cap=120
case "${1:-}" in
    ""|run|--lower-latency)
        ;;
    --check)
        action=check
        ;;
    --balanced)
        profile=balanced
        frame_cap=60
        ;;
    --check-balanced)
        action=check
        profile=balanced
        frame_cap=60
        ;;
    --check-lower-latency)
        action=check
        ;;
    *)
        echo "Usage: $0 [--check|--balanced|--check-balanced|--lower-latency]" >&2
        exit 64
        ;;
esac

bottles_root="$HOME/Library/Containers/com.franke.Whisky/Bottles"
runtime="$HOME/Library/Application Support/com.franke.Whisky/Libraries"
whisky_cli="/Applications/Whisky.app/Contents/Resources/WhiskyCmd"
wine_binary="$runtime/Wine/bin/wine64"
wineserver="$runtime/Wine/bin/wineserver"
dxmt_root="$runtime/DXMT"

game_suffix='/drive_c/Program Files (x86)/Steam/steamapps/common/Screw Drivers/Screw Drivers.exe'
steam_windows='C:\Program Files (x86)\Steam\steam.exe'
app_id=1279510
virtual_desktop='OpenBottleMetalFX,1728x1117'
scale_factor=2.0

required_files=(
    "$whisky_cli"
    "$wine_binary"
    "$wineserver"
    "$runtime/WhiskyWineVersion.plist"
)
for required_file in "${required_files[@]}"; do
    if [[ ! -e "$required_file" ]]; then
        echo "Missing required file: $required_file" >&2
        exit 1
    fi
done

game_paths=()
while IFS= read -r game_path; do
    game_paths+=("$game_path")
done < <(find "$bottles_root" -type f -path "*$game_suffix" -print 2>/dev/null)

if [[ "${#game_paths[@]}" -eq 0 ]]; then
    echo "Screw Drivers was not found in a Whisky bottle." >&2
    exit 1
fi
if [[ "${#game_paths[@]}" -gt 1 ]]; then
    echo "More than one Screw Drivers installation was found:" >&2
    printf '  %s\n' "${game_paths[@]}" >&2
    echo "Keep one installation or add explicit bottle selection before running this test." >&2
    exit 1
fi

game_executable="${game_paths[0]}"
game_root="$(dirname "$game_executable")"
bottle="${game_executable%%/drive_c/*}"
metadata="$bottle/Metadata.plist"
bottle_name="$(plutil -extract info.name raw "$metadata")"
wine_user="$(id -un)"
player_log="$bottle/drive_c/users/$wine_user/AppData/LocalLow/Creactstudios/Screw Drivers/Player.log"
steam_cloud_log="$bottle/drive_c/Program Files (x86)/Steam/logs/cloud_log.txt"
explorer_hash="$(printf '%s' '/drive_c/windows/explorer.exe' | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
explorer_settings="$bottle/Program Settings/explorer-$explorer_hash.plist"
explorer_history="$bottle/Program Settings/explorer.exe.run-history.plist"
separate_save="$bottle/drive_c/windows/saveables.dat"
active_save="$game_root/saveables.dat"

steam_shared_configs=()
while IFS= read -r shared_config; do
    steam_shared_configs+=("$shared_config")
done < <(find "$bottle/drive_c/Program Files (x86)/Steam/userdata" \
    -type f -path '*/7/remote/sharedconfig.vdf' -print 2>/dev/null)

if [[ "${#steam_shared_configs[@]}" -ne 1 ]]; then
    echo "Expected one Steam sharedconfig.vdf, found ${#steam_shared_configs[@]}." >&2
    echo "Cloud safety cannot be verified, so the game will not start." >&2
    exit 1
fi
steam_shared_config="${steam_shared_configs[0]}"

steam_cloud_is_disabled() {
    awk -v app_id="$app_id" '
        BEGIN {
            in_app = 0
            opened = 0
            depth = 0
            found = 0
        }
        !in_app && $0 ~ "^[[:space:]]*\\\"" app_id "\\\"[[:space:]]*$" {
            in_app = 1
            next
        }
        in_app {
            opens = gsub(/\{/, "{")
            closings = gsub(/\}/, "}")
            if ($0 ~ /"cloudenabled"[[:space:]]+"0"/) {
                found = 1
            }
            if (opens > 0) {
                opened = 1
            }
            depth += opens - closings
            if (opened && depth <= 0) {
                exit(found ? 0 : 1)
            }
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$steam_shared_config"
}

dll_names=(d3d11.dll dxgi.dll d3d10core.dll winemetal.dll)
dll_dirs=(system32 syswow64)
for dll_dir in "${dll_dirs[@]}"; do
    source_arch=x64
    [[ "$dll_dir" == "syswow64" ]] && source_arch=x32
    for dll_name in "${dll_names[@]}"; do
        source_file="$dxmt_root/$source_arch/$dll_name"
        if [[ ! -f "$source_file" ]]; then
            echo "Missing DXMT payload: $source_file" >&2
            exit 1
        fi
    done
done

if [[ "$action" == "check" ]]; then
    echo "Screw Drivers MetalFX test is ready."
    echo "Bottle: $bottle_name"
    echo "Bottle path: $bottle"
    echo "Wine: $("$wine_binary" --version)"
    echo "DXMT: $(plutil -extract dxmtVersion raw "$runtime/WhiskyWineVersion.plist")"
    echo "Render: 1728x1117"
    echo "Output target: 3456x2234"
    echo "Profile: $profile"
    echo "Frame cap: $frame_cap"
    if steam_cloud_is_disabled; then
        echo "Steam Cloud for app $app_id: disabled (local saves only)"
    else
        echo "Steam Cloud for app $app_id: enabled or unknown"
        exit 1
    fi
    if [[ -f "$separate_save" ]]; then
        echo "Separate direct-launch save detected at C:\\windows. Preserve or migrate it before cleanup."
    fi
    exit 0
fi

if ! steam_cloud_is_disabled; then
    echo "Steam Cloud is not disabled for Screw Drivers." >&2
    echo "The game will not start because this launcher is local-save only." >&2
    exit 1
fi

if [[ -f "$separate_save" ]]; then
    echo "A separate direct-launch save exists at C:\\windows." >&2
    echo "Choose which save to keep active before starting another test." >&2
    exit 1
fi

if pgrep -f "$bottle" >/dev/null 2>&1; then
    echo "The $bottle_name bottle is already running. Close it before starting the test." >&2
    exit 1
fi

run_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
run_dir="$HOME/Library/Logs/OpenBottle/screw-drivers-metalfx-$profile-$run_stamp"
original_dir="$run_dir/original"
mkdir -p "$original_dir"

explorer_settings_existed=0
explorer_history_existed=0
restored=0

hash_optional() {
    local target="$1"
    local output="$2"
    if [[ -f "$target" ]]; then
        shasum -a 256 "$target" >> "$output"
    else
        echo "MISSING  $target" >> "$output"
    fi
}

hash_state() {
    local output="$1"
    : > "$output"
    shasum -a 256 "$metadata" >> "$output"
    hash_optional "$explorer_settings" "$output"
    hash_optional "$explorer_history" "$output"
    for dll_dir in "${dll_dirs[@]}"; do
        for dll_name in "${dll_names[@]}"; do
            hash_optional "$bottle/drive_c/windows/$dll_dir/$dll_name" "$output"
        done
    done
}

kill_bottle() {
    WINEPREFIX="$bottle" "$wineserver" -k >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
        if ! pgrep -f "$bottle" >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
}

restore_original() {
    if [[ "$restored" -eq 1 ]]; then
        return
    fi

    kill_bottle
    cp -p "$original_dir/Metadata.plist" "$metadata"
    if [[ "$explorer_settings_existed" -eq 1 ]]; then
        cp -p "$original_dir/explorer-settings.plist" "$explorer_settings"
    else
        rm -f "$explorer_settings"
    fi
    if [[ "$explorer_history_existed" -eq 1 ]]; then
        cp -p "$original_dir/explorer-history.plist" "$explorer_history"
    else
        rm -f "$explorer_history"
    fi
    for dll_dir in "${dll_dirs[@]}"; do
        for dll_name in "${dll_names[@]}"; do
            target="$bottle/drive_c/windows/$dll_dir/$dll_name"
            backup="$original_dir/$dll_dir/$dll_name"
            if [[ -f "$backup" ]]; then
                cp -p "$backup" "$target"
            else
                rm -f "$target"
            fi
        done
    done

    restored=1
    hash_state "$run_dir/restored.sha256"
    if ! cmp -s "$run_dir/original.sha256" "$run_dir/restored.sha256"; then
        echo "Restoration hash check failed. Keep this recovery folder: $run_dir" >&2
        return 1
    fi
    echo "Original bottle settings and renderer files restored."
}

cp -p "$metadata" "$original_dir/Metadata.plist"
if [[ -f "$explorer_settings" ]]; then
    explorer_settings_existed=1
    cp -p "$explorer_settings" "$original_dir/explorer-settings.plist"
fi
if [[ -f "$explorer_history" ]]; then
    explorer_history_existed=1
    cp -p "$explorer_history" "$original_dir/explorer-history.plist"
fi
for dll_dir in "${dll_dirs[@]}"; do
    mkdir -p "$original_dir/$dll_dir"
    for dll_name in "${dll_names[@]}"; do
        target="$bottle/drive_c/windows/$dll_dir/$dll_name"
        if [[ -f "$target" ]]; then
            cp -p "$target" "$original_dir/$dll_dir/$dll_name"
        fi
    done
done
hash_state "$run_dir/original.sha256"

trap restore_original EXIT
trap 'exit 130' INT TERM HUP

if [[ "$explorer_settings_existed" -eq 0 ]]; then
    plutil -create xml1 "$explorer_settings"
    plutil -insert arguments -string "" "$explorer_settings"
    plutil -insert environment -xml '<dict/>' "$explorer_settings"
    plutil -insert locale -string "" "$explorer_settings"
fi

plutil -replace graphicsConfig.backend -string dxmt "$metadata"
plutil -replace metalConfig.metalHud -bool false "$metadata"
plutil -remove environment.DXVK_FRAME_RATE "$explorer_settings" >/dev/null 2>&1 || true
plutil -remove environment.DXMT_CONFIG "$explorer_settings" >/dev/null 2>&1 || true
plutil -remove environment.DXMT_METALFX_SPATIAL_SWAPCHAIN "$explorer_settings" >/dev/null 2>&1 || true
plutil -insert environment.DXMT_CONFIG \
    -string "d3d11.preferredMaxFrameRate=$frame_cap;d3d11.metalSpatialUpscaleFactor=$scale_factor" \
    "$explorer_settings"
plutil -insert environment.DXMT_METALFX_SPATIAL_SWAPCHAIN -string 1 "$explorer_settings"

{
    echo "started_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "bottle_name=$bottle_name"
    echo "macos=$(sw_vers -productVersion)"
    echo "hardware=$(sysctl -n hw.model)"
    echo "wine=$("$wine_binary" --version)"
    echo "dxmt=$(plutil -extract dxmtVersion raw "$runtime/WhiskyWineVersion.plist")"
    echo "render_resolution=1728x1117"
    echo "scale_factor=$scale_factor"
    echo "profile=$profile"
    echo "frame_cap=$frame_cap"
    echo "launch_method=steam-offline-applaunch"
    echo "local_save_only=true"
    if [[ -f "$active_save" ]]; then
        echo "active_save_before_sha256=$(shasum -a 256 "$active_save" | awk '{print $1}')"
    fi
} > "$run_dir/run-info.txt"

cloud_log_start_line=0
if [[ -f "$steam_cloud_log" ]]; then
    cloud_log_start_line="$(wc -l < "$steam_cloud_log" | tr -d ' ')"
fi

launch_epoch="$(date +%s)"
"$whisky_cli" run "$bottle_name" 'C:\windows\explorer.exe' -- \
    "/desktop=$virtual_desktop" "$steam_windows" -offline -applaunch "$app_id" \
    -screen-fullscreen 0 -screen-width 1728 -screen-height 1117 \
    > "$run_dir/launcher.log" 2>&1 &
steam_launcher_pid=$!

game_pid=""
for _ in $(seq 1 180); do
    game_pid="$(ps -axo pid=,command= \
        | awk '$2 ~ /^C:\\/ && index($0,"Screw Drivers.exe") && !index($0,"explorer.exe") && !index($0,"UnityCrashHandler64.exe") {print $1}' \
        | tail -n 1 || true)"
    [[ -n "$game_pid" ]] && break
    sleep 1
done
if [[ -z "$game_pid" ]]; then
    echo "Screw Drivers did not start within 180 seconds." >&2
    exit 1
fi

echo "game_pid=$game_pid" >> "$run_dir/run-info.txt"
echo "game_process_seconds=$(( $(date +%s) - launch_epoch ))" >> "$run_dir/run-info.txt"
game_unix_cwd="$(lsof -a -p "$game_pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true)"
if [[ -n "$game_unix_cwd" ]]; then
    echo "game_unix_cwd=$game_unix_cwd" >> "$run_dir/run-info.txt"
fi

current_log=0
for _ in $(seq 1 30); do
    log_mtime="$(stat -f '%m' "$player_log" 2>/dev/null || echo 0)"
    if [[ "$log_mtime" -ge "$launch_epoch" ]] \
        && grep -q 'Initialize engine version' "$player_log" 2>/dev/null; then
        current_log=1
        break
    fi
    sleep 1
done
if [[ "$current_log" -ne 1 ]]; then
    echo "Screw Drivers did not create a current Player.log." >&2
    exit 1
fi

echo "directory,dll,target_sha256,source_sha256" > "$run_dir/backend-verification.csv"
for dll_dir in "${dll_dirs[@]}"; do
    source_arch=x64
    [[ "$dll_dir" == "syswow64" ]] && source_arch=x32
    for dll_name in "${dll_names[@]}"; do
        target="$bottle/drive_c/windows/$dll_dir/$dll_name"
        source_file="$dxmt_root/$source_arch/$dll_name"
        target_hash="$(shasum -a 256 "$target" | awk '{print $1}')"
        source_hash="$(shasum -a 256 "$source_file" | awk '{print $1}')"
        printf '%s,%s,%s,%s\n' "$dll_dir" "$dll_name" "$target_hash" "$source_hash" \
            >> "$run_dir/backend-verification.csv"
        if [[ "$target_hash" != "$source_hash" ]]; then
            echo "DXMT verification failed for $dll_dir/$dll_name." >&2
            exit 1
        fi
    done
done

echo "epoch,utc,pid,cpu_percent,rss_kb,threads,elapsed" > "$run_dir/process-samples.csv"
echo
echo "Screw Drivers is running with DXMT + MetalFX 2x."
echo "Frame cap: $frame_cap FPS ($profile profile)."
echo "Compare sharpness, motion, UI scale, and artifacts."
echo "Quit the game normally when you are done; this window will restore the original setup."
echo "Run record: $run_dir"
echo

while kill -0 "$game_pid" >/dev/null 2>&1; do
    sample="$(ps -p "$game_pid" -o %cpu= -o rss= -o etime= 2>/dev/null | awk '{$1=$1; print}' || true)"
    if [[ -n "$sample" ]]; then
        read -r cpu_percent rss_kb elapsed <<< "$sample"
        threads="$(ps -M -p "$game_pid" 2>/dev/null | awk 'NR > 1 {count++} END {print count + 0}')"
        printf '%s,%s,%s,%s,%s,%s,%s\n' \
            "$(date +%s)" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$game_pid" \
            "$cpu_percent" "$rss_kb" "$threads" "$elapsed" >> "$run_dir/process-samples.csv"
    fi
    sleep 1
done

cp -p "$player_log" "$run_dir/Player.log" 2>/dev/null || true
echo "ended_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$run_dir/run-info.txt"

echo "Checking that Steam Cloud stayed inactive..."
for _ in 1 2 3 4 5; do
    sleep 1
done
if [[ -f "$steam_cloud_log" ]]; then
    tail -n "+$(( cloud_log_start_line + 1 ))" "$steam_cloud_log" \
        > "$run_dir/cloud-log-delta.log"
else
    : > "$run_dir/cloud-log-delta.log"
fi
unexpected_sync="$(grep -F "[AppID $app_id] Starting sync" "$run_dir/cloud-log-delta.log" \
    | grep -F -v 'Starting sync (init,)' \
    | grep -F -v 'Starting sync (eval,)' \
    | grep -F -v 'Starting sync (AC Launch,Sync Disabled,)' \
    | grep -F -v 'Starting sync (AC Exit,Sync Disabled,)' || true)"
if [[ -n "$unexpected_sync" ]]; then
    echo "cloud_guard=unexpected-mode" >> "$run_dir/run-info.txt"
    printf '%s\n' "$unexpected_sync" > "$run_dir/unexpected-cloud-mode.log"
    echo "Warning: Steam entered an unexpected cloud-sync mode." >&2
    echo "The local save has been left in place and should be backed up before another run." >&2
elif grep -F -q "[AppID $app_id] Starting sync (AC Launch,Sync Disabled,)" \
    "$run_dir/cloud-log-delta.log"; then
    echo "cloud_guard=sync-disabled" >> "$run_dir/run-info.txt"
elif grep -F -q "[AppID $app_id] Starting sync" "$run_dir/cloud-log-delta.log"; then
    echo "cloud_guard=unconfirmed" >> "$run_dir/run-info.txt"
    echo "Warning: Steam evaluated cloud state without a disabled marker." >&2
    echo "The local save has been left in place and should be backed up before another run." >&2
else
    echo "cloud_guard=inactive" >> "$run_dir/run-info.txt"
fi

if [[ -f "$separate_save" ]]; then
    echo "save_location_error=C:\\windows" >> "$run_dir/run-info.txt"
    echo "Warning: this run wrote another separate save under C:\\windows." >&2
    echo "It has been left in place for recovery." >&2
fi

if [[ -f "$active_save" ]]; then
    echo "active_save_after_sha256=$(shasum -a 256 "$active_save" | awk '{print $1}')" \
        >> "$run_dir/run-info.txt"
fi

restore_original
wait "$steam_launcher_pid" 2>/dev/null || true
trap - EXIT INT TERM HUP

echo "Test complete. The original setup was restored."
