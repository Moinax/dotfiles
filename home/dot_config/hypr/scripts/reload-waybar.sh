#!/bin/bash
killall -9 waybar
sleep 1
waybar &
notify-send -u low "Waybar" "Reloaded"
