#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export DOTNET_ROOT="$root/.tools/dotnet-10.0.402"
export DOTNET_CLI_HOME="$root/.tools/steam-content-cli"
export NUGET_PACKAGES="$root/.tools/nuget-packages"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
"$root/scripts/build-steam-content-helper.sh" >&2
"$DOTNET_ROOT/dotnet" restore "$root/Tests/SteamContent/SteamContentSessionTests.csproj" --configfile "$root/Workers/SteamContent/NuGet.Config" >&2
"$DOTNET_ROOT/dotnet" build "$root/Tests/SteamContent/SteamContentSessionTests.csproj" -c Release --no-restore >&2
probe="$root/Tests/SteamContent/bin/Release/net10.0/osx-arm64"
cp "$root/build/SteamContent/libGlimmerSteamContentNative.dylib" "$probe/"
fixture="$(mktemp -d /private/tmp/gw-steam-session.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
"$probe/SteamContentSessionTests" "$fixture"
