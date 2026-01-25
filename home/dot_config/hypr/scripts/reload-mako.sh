#!/bin/bash
killall mako
sleep 1
mako &
notify-send -u low "Mako" "Reloaded"
