@echo off
REM =============================================================================
REM .devcontainer\initialize_win.bat
REM
REM Windows-host equivalent of initialize.sh. Runs on the HOST
REM (initializeCommand) before the container is created or started.
REM Pre-creates, USER-owned, everything the docker daemon would otherwise
REM auto-create as ROOT and thereby brick later steps:
REM   * .env                      - runArgs --env-file hard-fails if missing
REM   * .adlc-artifacts\claude    - mount TARGET; missing targets are created by
REM                                 the daemon as root INSIDE the workspace bind
REM                                 mount, leaving .adlc-artifacts\ unwritable for vscode
REM   * .adlc-artifacts\<svc>_data - bind SOURCES for compose.yaml sidecars
REM   * .adlc-artifacts\frontend\cache - shared pnpm store / yarn cache used by
REM                                 the natively-run frontend dev servers
REM   * %USERPROFILE%\.claude     - mount SOURCE; same root-owned trap if absent
REM
REM KEEP IN SYNC WITH initialize.sh: devcontainer.json runs whichever of the two
REM the host shell can execute, so both must create the same things.
REM =============================================================================
setlocal enabledelayedexpansion

cd /d "%~dp0.."

if not exist ".env" type nul > ".env"

if not exist "%USERPROFILE%\.claude" mkdir "%USERPROFILE%\.claude"
if not exist ".adlc-artifacts\claude" mkdir ".adlc-artifacts\claude"

REM Keep the data-dir list in sync with compose.yaml bind-mount volumes (mssql
REM uses a named Docker volume instead, so it isn't listed here).
if not exist ".adlc-artifacts\mongo_data" mkdir ".adlc-artifacts\mongo_data"
if not exist ".adlc-artifacts\azurite_data" mkdir ".adlc-artifacts\azurite_data"
if not exist ".adlc-artifacts\n8n_data" mkdir ".adlc-artifacts\n8n_data"

REM Shared pnpm store + yarn cache for the frontend sub-apps, which run natively
REM in the devcontainer (see .devcontainer\local-stack-frontend.sh). Their
REM node_modules live in the mspprocess-ui checkout itself; the old per-app
REM nm_<slug> bind sources went away with the frontend container.
if not exist ".adlc-artifacts\frontend\cache" mkdir ".adlc-artifacts\frontend\cache"

endlocal
