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
# Windows (Git Bash) build — depot_tools bootstrap + vpython3 + gn/ninja
# -----------------------------
if is_windows; then
  log "Detected Windows (Git Bash)."
  need_cmd git
  need_cmd cygpath
  need_cmd powershell.exe

  # Locate vswhere (common locations)
  VSWHERE_CANDIDATES=(
    "/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    "/c/Program Files/Microsoft Visual Studio/Installer/vswhere.exe"
  )
  VSWHERE_BASH=""
  for p in "${VSWHERE_CANDIDATES[@]}"; do
    [[ -f "$p" ]] && { VSWHERE_BASH="$p"; break; }
  done
  [[ -n "$VSWHERE_BASH" ]] || { err "vswhere.exe not found. Install VS (or Build Tools) with C++ & Windows SDK."; exit 2; }
  VSWHERE_WIN="$(cygpath -w "$VSWHERE_BASH")"

  DEP_DIR="$SRC/.deps"
  mkdir -p "$DEP_DIR"
  DEP_DIR_WIN="$(cygpath -w "$DEP_DIR")"
  WIN_SRC="$(cygpath -w "$SRC")"

  # depot_tools (keep local)
  DEPOT_DIR="$DEP_DIR/depot_tools"
  if [[ ! -d "$DEPOT_DIR" ]]; then
    log "Cloning depot_tools → $DEPOT_DIR"
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_DIR"
  fi
  WIN_DEPOT_DIR="$(cygpath -w "$DEPOT_DIR")"

  WIN_BAT_PATH="$(cygpath -w "$DEP_DIR/perfetto_build_win.bat")"
  WIN_PS1_PATH="$(cygpath -w "$DEP_DIR/perfetto_run_win.ps1")"

  # Batch script:
  #  - Load MSVC env
  #  - Bootstrap depot_tools (update_depot_tools) so pinned Python & gn/ninja are available
  #  - Use vpython3 for install-build-deps (best effort)
  #  - Use gn/ninja from depot_tools
  cat > "$DEP_DIR/perfetto_build_win.bat" <<BAT
@echo off
setlocal enableextensions
set "VSWHERE=$VSWHERE_WIN"
for /f "usebackq delims=" %%I in (\`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath\`) do set "VSINSTALL=%%~fI"
if "%VSINSTALL%"=="" (
  echo ERROR: Visual Studio with C++ toolset not found.
  exit /b 1
)
call "%VSINSTALL%\\VC\\Auxiliary\\Build\\vcvars64.bat"

rem -- Ensure depot_tools on PATH and bootstrap it
set "PATH=$WIN_DEPOT_DIR;%PATH%"
set "DEPOT_TOOLS_UPDATE=1"
set "DEPOT_TOOLS_WIN_TOOLCHAIN=0"

if exist "%WIN_DEPOT_DIR%\\update_depot_tools.bat" (
  call "%WIN_DEPOT_DIR%\\update_depot_tools.bat"
) else (
  call update_depot_tools
)
if errorlevel 1 (
  echo ERROR: update_depot_tools failed.
  exit /b 1
)

rem Sanity: ensure gn & vpython3 now exist
where gn >nul 2>&1 || (echo ERROR: gn not found on PATH after bootstrap.& exit /b 1)
where ninja >nul 2>&1 || (echo ERROR: ninja not found on PATH after bootstrap.& exit /b 1)
where vpython3 >nul 2>&1 || (echo ERROR: vpython3 not found on PATH after bootstrap.& exit /b 1)

cd /d "$WIN_SRC"

echo.
echo === install-build-deps (best effort via vpython3) ===
vpython3 tools\\install-build-deps
if errorlevel 1 (
  echo NOTE: install-build-deps returned non-zero. Continuing…
)

echo.
echo === GN gen (Windows release) ===
gn gen out\\win_release --args="is_debug=false target_os=\"win\" extra_cflags=\"/wd4996\" extra_cxxflags=\"/wd4996\""
if errorlevel 1 exit /b 1

echo.
echo === Ninja build: trace_processor_shell ===
ninja -C out\\win_release trace_processor_shell
if errorlevel 1 exit /b 1

echo.
echo Build completed. Artifacts in out\\win_release
exit /b 0
BAT

  # PowerShell runner: param first, forward exit code
  cat > "$DEP_DIR/perfetto_run_win.ps1" <<'PS1'
param([string]$BatPath)
$ErrorActionPreference = 'Stop'
& $BatPath
exit $LASTEXITCODE
PS1

  log "Running Windows build steps via PowerShell runner:"
  log "  BAT: $WIN_BAT_PATH"
  log "  PS1: $WIN_PS1_PATH"

  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS1_PATH" "$WIN_BAT_PATH"

  log "Done. Windows build artifacts in: $SRC/out/win_release"
  log "Note: On Windows we build the supported subset (trace_processor_shell)."
  exit 0
fi


err "Unsupported OS: $(uname -s). This script targets macOS and Windows Git Bash."
exit 2