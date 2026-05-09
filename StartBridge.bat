@echo off
cd /d "C:\Program Files (x86)\Steam\steamapps\common\Fallout 4"
start "" "C:\Program Files\Ollama\ollama.exe" serve
timeout /t 3 /nobreak > nul

:: Dropped the 'w' so you get a command window to watch the AI think!
start "" python C:\Fallout4AI\V10_bridge.py

echo Bridge ULTIMATE active. Launch Fallout 4 via F4SE.
pause