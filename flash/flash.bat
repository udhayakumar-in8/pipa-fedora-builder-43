@echo off
rem Flash this Fedora image to a Xiaomi Pad 6 (pipa) in fastboot mode.
rem Boot the tablet into fastboot (hold Volume Down + Power), connect USB,
rem then double-click this file or run it from a command prompt.
setlocal
cd /d "%~dp0"

where fastboot >nul 2>&1 || (echo ERROR: fastboot not found. Install Android platform-tools and add it to PATH. & goto :fail)
if not exist boot.img (echo ERROR: boot.img not found next to this script & goto :fail)
if not exist root.img (echo ERROR: root.img not found next to this script & goto :fail)

echo Waiting for a device in fastboot mode...
set "product="
for /f "tokens=2 delims=: " %%p in ('fastboot getvar product 2^>^&1 ^| findstr /b "product:"') do set "product=%%p"
if /i not "%product%"=="pipa" (echo ERROR: connected device is "%product%", expected "pipa" ^(Xiaomi Pad 6^) & goto :fail)

echo.
echo WARNING: this ERASES the userdata partition (all Android data) and
echo replaces the boot image on both slots with Fedora.
set /p answer=Type YES to continue: 
if not "%answer%"=="YES" (echo Aborted. & goto :fail)

fastboot flash boot_ab boot.img || goto :fail
fastboot flash userdata root.img || goto :fail
fastboot erase dtbo || goto :fail
fastboot reboot

echo.
echo Done. First boot takes a minute or two (the root filesystem is resized).
echo Login: udhayakumar / 147147 - you will be asked to set a new password.
pause
exit /b 0

:fail
pause
exit /b 1
