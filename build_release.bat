@echo off
echo Building FutaGlow Release DLL...
zig build -Doptimize=ReleaseFast
echo.
echo Build complete. You can find FutaGlow.dll in the zig-out/lib directory.
pause