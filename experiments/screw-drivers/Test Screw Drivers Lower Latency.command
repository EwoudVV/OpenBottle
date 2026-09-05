#!/bin/bash

set -euo pipefail

launcher_path="${BASH_SOURCE[0]}"
while [[ -L "$launcher_path" ]]; do
    link_dir="$(cd -P "$(dirname "$launcher_path")" && pwd)"
    link_target="$(readlink "$launcher_path")"
    if [[ "$link_target" == /* ]]; then
        launcher_path="$link_target"
    else
        launcher_path="$link_dir/$link_target"
    fi
done
launcher_dir="$(cd "$(dirname "$launcher_path")" && pwd)"

exec "$launcher_dir/Test Screw Drivers MetalFX.command" --lower-latency
