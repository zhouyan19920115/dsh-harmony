@echo off 2>nul 1>nul
chcp 65001 >nul
@echo off
cls 2>nul
setlocal EnableExtensions DisableDelayedExpansion
rem ===================================================================
rem  DSH Harmony - desktop launcher. Double click this file.
rem
rem  Keep this window open: closing it stops the desktop service.
rem
rem  TWO WAYS TO RUN:
rem    - the standalone build: dsh-harmony-bridge.exe sits next to this
rem      file. It carries its own Node.js, so this PC needs NOTHING
rem      installed. The launcher uses it and skips the Node check.
rem    - the source build: bridge\src\cli.js. Then Node.js 20+ has to
rem      be installed.
rem
rem  WHY THIS FILE IS PURE ASCII:
rem  cmd.exe re-reads a batch file after "chcp" changes the code page and
rem  loses its byte alignment, so a batch file that contains Chinese text
rem  breaks itself (lines get cut in half) as soon as it switches to
rem  UTF-8. A pure ASCII file cannot break that way.
rem  All Chinese text therefore lives in install-desktop.ps1, which
rem  PowerShell reads correctly (UTF-8 with BOM), and it is printed by
rem  calling that script with -Message.
rem
rem  Options:
rem    --with-relay      also start the cloud relay (needed for remote use)
rem    --port <n>        port (default 8787)
rem    --host <addr>     listen address (default 0.0.0.0)
rem    --dry-run         run the checks only, do not start the service
rem    everything else is forwarded to bridge\src\cli.js
rem ===================================================================

set "HERE=%~dp0"
rem Two layouts: the repository (tools\start-desktop.cmd) and the package, where this
rem file sits in the root of "DSH-Harmony-Desktop".
set "ROOT=%HERE%.."
if exist "%ROOT%\bridge\src\cli.js" for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\bridge\src\cli.js" for %%I in ("%HERE%") do set "ROOT=%%~fI"
cd /d "%ROOT%"

set "BRIDGE=%ROOT%\bridge\src\cli.js"
set "RELAY=%ROOT%\relay\src\cli.js"
set "RELAY_ACCOUNTS=%ROOT%\relay\accounts.json"
set "PS1=%HERE%install-desktop.ps1"
set "EXE=%ROOT%\dsh-harmony-bridge.exe"
if not exist "%EXE%" set "EXE=%HERE%dsh-harmony-bridge.exe"
set "RELAY_EXE=%ROOT%\dsh-harmony-relay.exe"
if not exist "%RELAY_EXE%" set "RELAY_EXE=%HERE%dsh-harmony-relay.exe"

set "PORT=8787"
set "HOST=0.0.0.0"
set "RELAY_PORT=8788"
set "RELAY_TLS_PORT=8789"
set "WITH_RELAY=0"
set "DRY_RUN=0"
set "DAEMON=0"
set "PASS="
set "RELAY_ARGS="

rem ---------------------------------------------------------------- arguments
:parse
if "%~1"=="" goto parsed
if /I "%~1"=="--with-relay" ( set "WITH_RELAY=1" & shift & goto parse )
if /I "%~1"=="--no-relay" ( set "WITH_RELAY=0" & shift & goto parse )
if /I "%~1"=="--port" ( set "PORT=%~2" & shift & shift & goto parse )
if /I "%~1"=="--host" ( set "HOST=%~2" & shift & shift & goto parse )
if /I "%~1"=="--relay-port" ( set "RELAY_PORT=%~2" & shift & shift & goto parse )
if /I "%~1"=="--relay-tls-port" ( set "RELAY_TLS_PORT=%~2" & shift & shift & goto parse )
if /I "%~1"=="--dry-run" ( set "DRY_RUN=1" & shift & goto parse )
if /I "%~1"=="--daemon" ( set "DAEMON=1" & shift & goto parse )
set "PASS=%PASS% "%~1""
shift
goto parse
:parsed

rem ---------------------------------------------------------------- runtime
rem The standalone exe carries its own Node.js: no installation, no PATH, no check.
set "USE_EXE=0"
if not exist "%EXE%" goto need_node
set "USE_EXE=1"
rem The message block (Chinese, or the English fallback) says it all.
call :say standalone
goto have_runtime
:need_node
where node >nul 2>nul
if errorlevel 1 goto no_node
set "NODE_VER="
for /f "usebackq delims=" %%v in (`node -v 2^>nul`) do set "NODE_VER=%%v"
if not defined NODE_VER goto no_node
echo   Node.js %NODE_VER%
node -e "process.exit(+process.versions.node.split('.')[0] < 20 ? 1 : 0)"
if errorlevel 1 goto old_node
:have_runtime

rem ---------------------------------------------------------------- port
netstat -ano | findstr /c:":%PORT% " | findstr /c:"LISTENING" >nul 2>nul
if not errorlevel 1 goto port_busy

rem ---------------------------------------------------------------- relay
if "%WITH_RELAY%"=="0" goto no_relay
rem The desktop -> relay link must be encrypted (security review P0), so the relay gets a
rem TLS listener and the bridge dials wss://. The certificate is self signed: the bridge
rem verifies it against the file (--relay-ca) and the phone pins its SHA256 fingerprint.
set "RELAY_CERT_DIR=%LOCALAPPDATA%\dsh-harmony\relay-tls"
set "RELAY_CERT=%RELAY_CERT_DIR%\relay-cert.pem"
set "RELAY_KEY=%RELAY_CERT_DIR%\relay-key.pem"
set "RELAY_FINGERPRINT="
set "RELAY_CERT_FILE=%TEMP%\dsh-relay-cert.txt"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -SelfSignedCert -CertDir "%RELAY_CERT_DIR%" -CertName "%COMPUTERNAME%" -CertHosts "localhost,127.0.0.1" > "%RELAY_CERT_FILE%" 2>nul
if exist "%RELAY_CERT_FILE%" (
  for /f "tokens=1,* delims==" %%A in ('findstr /b /c:"CERT=" "%RELAY_CERT_FILE%" 2^>nul') do set "RELAY_CERT=%%B"
  for /f "tokens=1,* delims==" %%A in ('findstr /b /c:"KEY=" "%RELAY_CERT_FILE%" 2^>nul') do set "RELAY_KEY=%%B"
  for /f "tokens=1,* delims==" %%A in ('findstr /b /c:"FINGERPRINT=" "%RELAY_CERT_FILE%" 2^>nul') do set "RELAY_FINGERPRINT=%%B"
)
del "%RELAY_CERT_FILE%" >nul 2>nul
if not exist "%RELAY_CERT%" goto relay_no_cert
if "%USE_EXE%"=="0" goto relay_with_node
rem The standalone build: the relay is its own executable, no Node.js needed.
if not exist "%RELAY_EXE%" goto no_relay_exe
if not exist "%ROOT%\relay" mkdir "%ROOT%\relay" >nul 2>nul
if not exist "%RELAY_ACCOUNTS%" (
  echo   [*] No relay account yet - creating one - the tokens are generated locally.
  "%RELAY_EXE%" --account-create --account-name "my account" --device-id dev-desktop --device-name "%COMPUTERNAME%"
)
start "DSH Harmony relay" /min "%RELAY_EXE%" --port %RELAY_PORT% --tls-port %RELAY_TLS_PORT% --tls-cert "%RELAY_CERT%" --tls-key "%RELAY_KEY%" --bridge-port %PORT%
echo   Cloud relay started in a new window (port %RELAY_PORT%, TLS %RELAY_TLS_PORT%).
set "RELAY_ARGS_FILE=%TEMP%\dsh-relay-args.txt"
rem PowerShell reads the registry, so this also works without Node.js.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RelayArgs -Accounts "%RELAY_ACCOUNTS%" -RelayPort %RELAY_TLS_PORT% -Cert "%RELAY_CERT%" > "%RELAY_ARGS_FILE%" 2>nul
if errorlevel 1 goto relay_no_args
set /p RELAY_ARGS=<"%RELAY_ARGS_FILE%"
del "%RELAY_ARGS_FILE%" >nul 2>nul
goto relay_ready
:relay_with_node
if not exist "%RELAY%" goto no_relay_file
if not exist "%RELAY_ACCOUNTS%" (
  echo   [*] No relay account yet - creating one - the tokens are generated locally.
  node "%RELAY%" --account-create --account-name "my account" --device-id dev-desktop --device-name "%COMPUTERNAME%"
)
start "DSH Harmony relay" /min node "%RELAY%" --port %RELAY_PORT% --tls-port %RELAY_TLS_PORT% --tls-cert "%RELAY_CERT%" --tls-key "%RELAY_KEY%" --bridge-port %PORT%
echo   Cloud relay started in a new window (port %RELAY_PORT%, TLS %RELAY_TLS_PORT%).
set "RELAY_ARGS_FILE=%TEMP%\dsh-relay-args.txt"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RelayArgs -Accounts "%RELAY_ACCOUNTS%" -RelayPort %RELAY_TLS_PORT% -Cert "%RELAY_CERT%" > "%RELAY_ARGS_FILE%" 2>nul
if errorlevel 1 goto relay_no_args
set /p RELAY_ARGS=<"%RELAY_ARGS_FILE%"
del "%RELAY_ARGS_FILE%" >nul 2>nul
goto relay_ready

:no_relay
echo   Cloud relay: not started (only needed when the phone is not on the same WiFi).
echo   To drive this PC from another network run: tools\start-desktop.cmd --with-relay
goto relay_ready

:relay_no_cert
echo   [!] The TLS certificate of the relay could not be created.
echo       The relay is NOT started: a relay that is reached over the internet
echo       must use wss:// (security review P0).
echo.
pause
exit /b 1

:relay_no_args
echo   [!] No usable device in the relay registry, the bridge starts without the relay.
echo       Create one: node relay\src\cli.js --account-create --device-id dev-desktop --device-name "%COMPUTERNAME%"
:relay_ready
if "%WITH_RELAY%"=="1" (
  echo.
  echo   Desktop -^> relay link - encrypted:
  echo     url         : wss://127.0.0.1:%RELAY_TLS_PORT%/bridge
  echo     certificate : %RELAY_CERT%
  echo     sha256      : %RELAY_FINGERPRINT%
  echo     The phone pins this fingerprint the first time it connects.
)
echo.

rem ---------------------------------------------------------------- hints
call :say banner

if "%DRY_RUN%"=="1" (
  echo   --dry-run: all checks done, the service was not started.
  exit /b 0
)

rem ---------------------------------------------------------------- start
if "%DAEMON%"=="1" goto start_daemon
echo   Starting the bridge. Its output follows: LAN address / token / pairing code / QR code
echo   ------------------------------------------------------------
echo.
echo   NEXT: open the phone App -> tap "discover" -> pick this PC (no token needed).
echo.
echo.
if "%USE_EXE%"=="1" goto start_exe
node "%BRIDGE%" --port %PORT% --host %HOST% %PASS% %RELAY_ARGS%
goto bridge_stopped
:start_exe
"%EXE%" --port %PORT% --host %HOST% %PASS% %RELAY_ARGS%
:bridge_stopped
set "EXITCODE=%ERRORLEVEL%"
echo.
echo   The bridge has stopped (exit code %EXITCODE%).
pause
exit /b %EXITCODE%

rem ---------------------------------------------------------------- daemon
:start_daemon
rem The background mode: this window closes, the bridge keeps running and writes
rem its output (address, token, pairing code) into the log file.
if not exist "%ROOT%\logs" mkdir "%ROOT%\logs" >nul 2>nul
set "DAEMON_LOG=%ROOT%\logs\bridge-daemon.log"
if "%USE_EXE%"=="1" (
  start "DSH Harmony bridge" /min cmd /c ""%EXE%" --port %PORT% --host %HOST% %PASS% %RELAY_ARGS% > "%DAEMON_LOG%" 2>&1"
) else (
  start "DSH Harmony bridge" /min cmd /c "node "%BRIDGE%" --port %PORT% --host %HOST% %PASS% %RELAY_ARGS% > "%DAEMON_LOG%" 2>&1"
)
echo   The bridge runs in the background now.
echo   Its log (address / token / pairing code): %DAEMON_LOG%
echo   Stop it with:  taskkill /fi "WINDOWTITLE eq DSH Harmony bridge*" /t /f
exit /b 0

rem ---------------------------------------------------------------- helpers
rem Print a Chinese message block through the PowerShell side (it owns the Chinese text).
rem Falls back to English when PowerShell or the script is not available.
:say
if exist "%PS1%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Message %~1 -Port %PORT%
  if not errorlevel 1 exit /b 0
)
if /I "%~1"=="nonode" echo   [!] Node.js 20 or newer is required. Download: https://nodejs.org/en/download
if /I "%~1"=="portbusy" echo   [!] Port %PORT% is already in use. Try: tools\start-desktop.cmd --port 8899
if /I "%~1"=="banner" echo   Same WiFi - open the App - tap "discover" - pick this PC.
if /I "%~1"=="standalone" echo   Standalone build - no Node.js needed on this PC.
exit /b 0

rem ---------------------------------------------------------------- failures
:no_node
call :say nonode
echo   [!] Node.js 20 or newer is required. Download: https://nodejs.org/en/download
echo.
pause
exit /b 1

:old_node
echo   [!] This Node.js is too old, the project needs 20 or newer.
echo       Download: https://nodejs.org/en/download
echo.
pause
exit /b 1

:port_busy
call :say portbusy
echo   [!] Port %PORT% is already in use. Try: tools\start-desktop.cmd --port 8899
echo.
pause
exit /b 1

:no_relay_node
echo   [!] The cloud relay is a Node.js program, and this PC has no Node.js.
echo       The bridge itself still runs (the standalone exe), only the relay is skipped.
echo       Install Node.js 20+ to use the relay: https://nodejs.org/en/download
echo.
pause
exit /b 1

:no_relay_exe
rem No relay executable: fall back to Node.js when this PC has it.
where node >nul 2>nul
if not errorlevel 1 goto relay_with_node
echo   [!] The cloud relay executable (%RELAY_EXE%) is not in this package.
echo       The bridge itself still works, only the relay is skipped.
echo.
pause
exit /b 1

:no_relay_file
echo   [!] %RELAY% not found, the cloud relay cannot be started.
echo       Direct LAN access does not need the relay, drop --with-relay and continue.
echo.
pause
exit /b 1
