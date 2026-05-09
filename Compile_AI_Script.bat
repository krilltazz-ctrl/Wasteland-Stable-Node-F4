@echo off
set COMPILER="C:\Program Files (x86)\Steam\steamapps\common\Fallout 4\Papyrus Compiler\PapyrusCompiler.exe"
set SCRIPT="C:\Fallout4AI\FO4_AIChatQuestScript.psc"
set FLAGS="C:\Program Files (x86)\Steam\steamapps\common\Fallout 4\Data\Scripts\Source\Base\Institute_Papyrus_Flags.flg"
set IMPORTS="C:\Fallout4AI;C:\Program Files (x86)\Steam\steamapps\common\Fallout 4\Data\Scripts\Source\User;C:\Program Files (x86)\Steam\steamapps\common\Fallout 4\Data\Scripts\Source\Base;C:\Program Files (x86)\Steam\steamapps\common\Fallout 4\Data\Scripts\Source"
set OUTPUT="C:\Program Files (x86)\Steam\steamapps\common\Fallout 4\Data\Scripts"

%COMPILER% %SCRIPT% -f=%FLAGS% -i=%IMPORTS% -o=%OUTPUT%
pause