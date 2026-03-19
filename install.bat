@echo off
setlocal enabledelayedexpansion
title Roblox Bridge — Installer v1.3.0

echo.
echo  +-------------------------------------------------+
echo  ^|      Roblox Bridge v1.3.0  --  Installer       ^|
echo  +-------------------------------------------------+
echo.

:: ── 1. Copy Roblox Studio plugin ──────────────────────────────────
set "PLUGINS_DIR=%LOCALAPPDATA%\Roblox\Plugins"

if not exist "%PLUGINS_DIR%" (
    echo  Creating Roblox Plugins folder...
    mkdir "%PLUGINS_DIR%"
)

echo  [1/3]  Copying RobloxBridge.lua  --^>  Roblox Plugins...
copy /Y "%~dp0roblox-plugin\RobloxBridge.lua" "%PLUGINS_DIR%\RobloxBridge.lua" >nul
if errorlevel 1 (
    echo  ERROR: Could not copy plugin file. Close Roblox Studio and try again.
    pause & exit /b 1
)
echo         OK: %PLUGINS_DIR%\RobloxBridge.lua

:: ── 2. Package the VS Code extension as a .vsix ───────────────────
echo.
echo  [2/3]  Packaging VS Code extension (needs Node + internet once)...

cd /d "%~dp0vscode-extension"

:: Remove any stale .vsix from a previous run
del /Q "*.vsix" >nul 2>&1

:: Use npx to run @vscode/vsce without a global install
call npx --yes @vscode/vsce package --no-yarn --allow-missing-repository --skip-license >nul 2>&1

:: Check whether a .vsix was actually created
set "VSIX_FILE="
for %%f in (*.vsix) do set "VSIX_FILE=%%f"

if not defined VSIX_FILE (
    echo.
    echo  ERROR: Packaging failed.
    echo.
    echo  Possible fixes:
    echo    - Make sure you are connected to the internet (npx needs to download vsce once)
    echo    - Make sure Node.js is installed  (node --version)
    echo.
    echo  Manual fallback:
    echo    1. Open this folder in VS Code:  %~dp0vscode-extension
    echo    2. Press F5  (runs the extension in dev mode -- works without packaging)
    pause & exit /b 1
)

echo         Created: %VSIX_FILE%

:: ── 3. Install the .vsix into VS Code ─────────────────────────────
echo.
echo  [3/3]  Installing extension into VS Code...

:: Find code.cmd (the CLI wrapper — NOT code.exe which doesn't support --install-extension)
set "CODE_CMD="
if exist "%LOCALAPPDATA%\Programs\Microsoft VS Code\bin\code.cmd" (
    set "CODE_CMD=%LOCALAPPDATA%\Programs\Microsoft VS Code\bin\code.cmd"
)
if not defined CODE_CMD (
    if exist "%ProgramFiles%\Microsoft VS Code\bin\code.cmd" (
        set "CODE_CMD=%ProgramFiles%\Microsoft VS Code\bin\code.cmd"
    )
)
if not defined CODE_CMD (
    if exist "%ProgramFiles(x86)%\Microsoft VS Code\bin\code.cmd" (
        set "CODE_CMD=%ProgramFiles(x86)%\Microsoft VS Code\bin\code.cmd"
    )
)

if not defined CODE_CMD (
    echo  WARNING: Could not find VS Code CLI automatically.
    echo  Install the extension manually:
    echo    1. Open VS Code
    echo    2. Ctrl+Shift+P  --^>  "Extensions: Install from VSIX..."
    echo    3. Select:  %~dp0vscode-extension\%VSIX_FILE%
    goto :done
)

echo         Using: %CODE_CMD%
call "%CODE_CMD%" --install-extension "%~dp0vscode-extension\%VSIX_FILE%" --force
if errorlevel 1 (
    echo  Auto-install failed. Install manually:
    echo    Ctrl+Shift+P  --^>  "Extensions: Install from VSIX..."
    echo    Select: %~dp0vscode-extension\%VSIX_FILE%
    goto :done
)
echo         Extension installed!

:done
echo.
echo  +=========================================================+
echo  ^|   Installation complete!  (v1.3.0)                    ^|
echo  +=========================================================+
echo.
echo   HOW TO USE:
echo.
echo   1. RESTART VS Code completely (close and reopen)
echo   2. Press Ctrl+Shift+P
echo   3. Type:  Roblox Bridge: Start Server   ^<-- look for this
echo      (status bar at the bottom turns orange)
echo   4. Open Roblox Studio with your game
echo   5. Look for the "Roblox Bridge" toolbar at the top of Studio
echo   6. Click [Export -^>]
echo      Your scripts appear as files in VS Code instantly!
echo.
echo   WHAT'S NEW in v1.3.0:
echo.
echo   * Output Channel  — dedicated live log panel in VS Code for sync activity
echo   * TreeView Panel  — sidebar showing synced scripts by Roblox service
echo   * init.lua Support  — Rojo-compatible init.lua / init.server.lua / init.client.lua
echo   * Two-Way Delete  — scripts deleted in Studio can be removed from disk (opt-in)
echo   * Auto-Export  — optionally rescan workspace on Studio connect
echo   * New Script Templates  — right-click to create Script/LocalScript/ModuleScript
echo   * Redesigned Widget  — animated pulse, color-coded log, progress bar in Studio
echo   * Enhanced Status Bar  — file count, sync time, animation in VS Code
echo   * Write-Guard  — prevents file watcher loops on bridge-written files
echo   * Bug Fixes  — deprecated API replacements, body limits, graceful shutdown
echo.
pause
exit /b 0
