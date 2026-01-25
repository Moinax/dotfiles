#!/bin/bash
killall hyprpaper
sleep 1
hyprpaper &
notify-send -u low "Hyprpaper" "Reloaded"
