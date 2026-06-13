@echo off
setlocal enabledelayedexpansion

set PROJECT_DIR=%~dp0..
set WINDOWS_DIR=%PROJECT_DIR%\desktop\windows
set BUILD_DIR=%WINDOWS_DIR%\build-installer-x64
set INSTALLER_SCRIPT=%WINDOWS_DIR%\installer\VoiceStick.iss

set /p VERSION=<"%PROJECT_DIR%\VERSION"

if "%VERSION%"=="" (
    echo ERROR: Could not read version from %PROJECT_DIR%\VERSION
    exit /b 1
)
echo Building VoiceStick v%VERSION% setup installer...

set VSWHERE="%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "delims=" %%i in ('%VSWHERE% -latest -prerelease -property installationPath') do set VS_PATH=%%i
if not exist "%VS_PATH%\VC\Auxiliary\Build\vcvarsall.bat" (
    if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" (
        set "VS_PATH=%ProgramFiles(x86)%\Microsoft Visual Studio\18\BuildTools"
    )
)
if not exist "%VS_PATH%\VC\Auxiliary\Build\vcvarsall.bat" (
    echo ERROR: Could not find vcvarsall.bat. Is Visual Studio installed?
    exit /b 1
)
call "%VS_PATH%\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul 2>&1

echo.
echo [1/4] CMake RelWithDebInfo build...
cmake -S "%WINDOWS_DIR%" -B "%BUILD_DIR%" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
if errorlevel 1 (
    echo ERROR: CMake configure failed.
    exit /b 1
)

cmake --build "%BUILD_DIR%" --config RelWithDebInfo
if errorlevel 1 (
    echo ERROR: CMake build failed.
    exit /b 1
)

if not exist "%BUILD_DIR%\VoiceStick.exe" (
    echo ERROR: VoiceStick.exe not found in build directory.
    exit /b 1
)
if not exist "%BUILD_DIR%\WinSparkle.dll" (
    echo ERROR: WinSparkle.dll not found in build directory.
    exit /b 1
)

if not defined SIGNING_SHA1 (
    if exist "%~dp0.signing_sha1" (
        for /f "usebackq delims=" %%i in ("%~dp0.signing_sha1") do set "SIGNING_SHA1=%%i"
    )
)
if not defined SIGNING_SHA1 (
    echo ERROR: Set SIGNING_SHA1 env var, or create scripts\.signing_sha1 with your cert thumbprint ^(SHA1^).
    exit /b 1
)

if defined SIGNTOOL_PATH (
    set "SIGNTOOL=%SIGNTOOL_PATH%"
) else (
    set "SIGNTOOL=signtool"
)
where %SIGNTOOL% >nul 2>&1
if errorlevel 1 (
    echo ERROR: signtool not found. Set SIGNTOOL_PATH or add signtool to PATH.
    exit /b 1
)

echo.
echo [2/4] Signing binaries...
set SIGN_ARGS=/v /fd sha256 /sha1 %SIGNING_SHA1% /tr http://rfc3161timestamp.globalsign.com/advanced /td sha256
"%SIGNTOOL%" sign %SIGN_ARGS% "%BUILD_DIR%\VoiceStick.exe"
if errorlevel 1 (
    echo ERROR: Signing VoiceStick.exe failed.
    exit /b 1
)
"%SIGNTOOL%" sign %SIGN_ARGS% "%BUILD_DIR%\WinSparkle.dll"
if errorlevel 1 (
    echo ERROR: Signing WinSparkle.dll failed.
    exit /b 1
)

if defined ISCC_PATH (
    set "ISCC=%ISCC_PATH%"
) else (
    set "ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
)
if not exist "%ISCC%" (
    if exist "%ProgramFiles%\Inno Setup 6\ISCC.exe" (
        set "ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
    )
)
if not exist "%ISCC%" (
    if exist "%LocalAppData%\Programs\Inno Setup 6\ISCC.exe" (
        set "ISCC=%LocalAppData%\Programs\Inno Setup 6\ISCC.exe"
    )
)
if not exist "%ISCC%" (
    echo ERROR: Inno Setup compiler not found. Set ISCC_PATH or install Inno Setup 6.
    exit /b 1
)

echo.
echo [3/4] Building setup.exe with Inno Setup...
"%ISCC%" /DMyAppVersion=%VERSION% /DBuildDir="%BUILD_DIR%" /DProjectDir="%PROJECT_DIR%" "%INSTALLER_SCRIPT%"
if errorlevel 1 (
    echo ERROR: Inno Setup build failed.
    exit /b 1
)

set INSTALLER=%BUILD_DIR%\VoiceStickSetup-%VERSION%.exe
if not exist "%INSTALLER%" (
    echo ERROR: Installer not found: %INSTALLER%
    exit /b 1
)

echo.
echo [4/4] Signing setup installer...
"%SIGNTOOL%" sign %SIGN_ARGS% "%INSTALLER%"
if errorlevel 1 (
    echo ERROR: Signing setup installer failed.
    exit /b 1
)

echo.
echo Success: %INSTALLER%