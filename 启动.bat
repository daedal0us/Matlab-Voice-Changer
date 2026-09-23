@echo off
rem 双击本文件即可启动图形界面（voice_changer_app）。
rem
rem cd /d "%~dp0" 是必需的：直接双击 .bat 时工作目录是资源管理器所在目录，
rem 不加这一行 MATLAB 会在别处启动、找不到 voice_changer_app。
rem
rem start "" 让命令行立刻返回，MATLAB 桌面照常打开；去掉 start 会一直占着窗口。
cd /d "%~dp0"
start "" matlab -r "voice_changer_app"
