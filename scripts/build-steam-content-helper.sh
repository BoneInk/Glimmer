#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${GW_OUT_DIR:-$root/build}"
sdk="$root/.tools/dotnet-10.0.402"
export DOTNET_ROOT="$sdk"
export DOTNET_CLI_HOME="$root/.tools/steam-content-cli"
export NUGET_PACKAGES="$root/.tools/nuget-packages"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
mkdir -p "$out/SteamContent"
"$sdk/dotnet" restore "$root/Workers/SteamContent/SteamContent.csproj" --locked-mode --configfile "$root/Workers/SteamContent/NuGet.Config"
"$sdk/dotnet" publish "$root/Workers/SteamContent/SteamContent.csproj" -c Release --no-restore -o "$out/SteamContent"
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/clang -arch arm64 -dynamiclib -Wall -Wextra -Werror "$root/Workers/SteamContent/NativeFile.c" -o "$out/SteamContent/libGlimmerSteamContentNative.dylib"
