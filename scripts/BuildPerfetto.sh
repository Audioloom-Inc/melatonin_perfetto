#!/usr/bin/env bash
# build_perfetto.sh
# Usage: ./build_perfetto.sh /absolute/path/to/perfetto
# Builds Perfetto on macOS and Windows (Git Bash).
# - macOS: full host tools via GN+Ninja
# - Windows Git Bash: builds supported subset (trace_processor_shell) via MSVC
# Notes:
#   * Demotes deprecated warnings so sprintf deprecations don’t fail the build.

set -euo pipefail

log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 2; }; }

detect_python() {
  if command -v python3 >/dev/null 2>&1; then echo python3
  elif command -v python >/dev/null 2>&1; then echo python
  elif command -v py >/dev/null 2>&1; then echo "py -3"
  else err "Python 3 not found."; exit 2
  fi
}

is_macos()   { [[ "$(uname -s)" == "Darwin" ]]; }
is_windows() { uname -s | grep -qiE 'mingw|msys'; }

ensure_absolute() {
  local p="$1"
  if is_windows; then
    [[ "$p" =~ ^[A-Za-z]:[\\/].* ]] || { err "On Windows, path must be absolute like C:\\path\\to\\perfetto"; exit 2; }
  else
    [[ "$p" = /* ]] || { err "On macOS/Linux, path must start with / (absolute)."; exit 2; }
  fi
}

if [[ $# -ne 1 ]]; then
  err "Expected exactly 1 argument: absolute path to Perfetto source."
  exit 2
fi

SRC="$1"
ensure_absolute "$SRC"
[[ -d "$SRC" ]] || { err "Path does not exist: $SRC"; exit 2; }
if command -v realpath >/dev/null 2>&1; then SRC="$(realpath "$SRC")"; fi

# -----------------------------
# macOS build
# -----------------------------
if is_macos; then
  log "Detected macOS."
  need_cmd git
  need_cmd curl
  PY="$(detect_python)"

  if ! xcode-select -p >/dev/null 2>&1; then
    err "Xcode Command Line Tools are required. Install with: xcode-select --install"
    exit 2
  fi

  cd "$SRC"
  log "Installing Perfetto deps (toolchains, third_party)…"
  "$PY" tools/install-build-deps

  OUT="out/host_release"
  log "GN gen → $OUT (release, demote deprecated decls)"
  tools/gn gen "$OUT" --args='is_debug=false extra_cflags="-Wno-error=deprecated-declarations" extra_cxxflags="-Wno-error=deprecated-declarations"'

  TARGETS=( perfetto traced traced_probes trace_processor_shell traceconv )
  log "Building targets: ${TARGETS[*]}"
  tools/ninja -C "$OUT" "${TARGETS[@]}"

  log "Done. Artifacts in: $OUT"
  exit 0
fi

# -----------------------------
# Windows (Git Bash) build
# -----------------------------
if is_windows; then
  log "Detected Windows (Git Bash)."
  need_cmd git

  VSWHERE="C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe"
  if [[ ! -f "$VSWHERE" ]]; then
    err "vswhere not found at: $VSWHERE
Install Visual Studio (or Build Tools) with the C++ Desktop workload + Windows SDK."
    exit 2
  fi

  DEP_DIR="$SRC/.deps"
  DEPOT_DIR="$DEP_DIR/depot_tools"
  if [[ ! -d "$DEPOT_DIR" ]]; then
    log "Cloning depot_tools → $DEPOT_DIR"
    mkdir -p "$DEP_DIR"
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_DIR"
  fi

  WIN_SRC="$(cygpath -w "$SRC")"
  WIN_DEPOT_DIR="$(cygpath -w "$DEPOT_DIR")"
  BAT_DIR="$DEP_DIR"
  mkdir -p "$BAT_DIR"
  TMPBAT="$BAT_DIR\\perfetto_build_win.bat"

  # Build subset (trace_processor_shell). Demote C4996 (deprecated) to warning.
  cat >"$TMPBAT" <<BAT
@echo off
setlocal enableextensions
set VSWHERE=$VSWHERE
for /f "usebackq delims=" %%I in (\`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath\`) do set VSINSTALL="%%~fI"
if "%VSINSTALL%"=="" (
  echo ERROR: Visual Studio with C++ toolset not found.
  exit /b 1
)
call "%VSINSTALL%\\VC\\Auxiliary\\Build\\vcvars64.bat"
set PATH=$WIN_DEPOT_DIR;%PATH%
cd /d "$WIN_SRC"

where python3 >nul 2>&1 && set PY=python3 || (
  where py >nul 2>&1 && set PY=py -3 || set PY=python
)

echo.
echo === install-build-deps (best effort) ===
%PY% tools\\install-build-deps
if errorlevel 1 (
  echo NOTE: install-build-deps returned non-zero. Continuing…
)

echo.
echo === GN gen (Windows release) ===
tools\\gn gen out\\win_release --args="is_debug=false target_os=\"win\" extra_cflags=\"/wd4996\" extra_cxxflags=\"/wd4996\""
if errorlevel 1 exit /b 1

echo.
echo === Ninja build: trace_processor_shell ===
tools\\ninja -C out\\win_release trace_processor_shell
if errorlevel 1 exit /b 1

echo.
echo Build completed. Artifacts in out\\win_release
BAT

  log "Running Windows build steps via: $TMPBAT"
  cmd.exe /c "$TMPBAT"

  log "Done. Windows build artifacts in: $SRC/out/win_release"
  log "Note: On Windows, this builds the supported subset (trace_processor_shell)."
  exit 0
fi

err "Unsupported OS: $(uname -s). This script targets macOS and Windows Git Bash."
exit 2