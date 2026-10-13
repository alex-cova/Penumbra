#!/bin/zsh
# P6 spike: can an iOS-simulator app, built with plain swiftc, be driven from the Mac?
# Builds host.swift into an app bundle, installs and launches it on a simulator, and checks that
# it (1) connects to a Unix socket on the Mac, (2) writes a PNG to a Mac path, (3) dlopens a
# simulator-built dylib. Usage: run.sh [<device udid>]   (default: the first available iPhone)
set -euo pipefail
here=${0:A:h}
work=$(mktemp -d /tmp/umbra-ios-spike.XXXX)          # short: sun_path holds about 100 bytes
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
device=${1:-$(xcrun simctl list devices available iPhone | grep -Eo '[0-9A-F-]{36}' | head -1)}
triple=arm64-apple-ios18.0-simulator

mkdir -p $work/App.app
xcrun swiftc -sdk $sdk -target $triple -parse-as-library -swift-version 5 $here/host.swift -o $work/App.app/host
xcrun swiftc -sdk $sdk -target $triple -emit-library -parse-as-library $here/dylib.swift -o $work/libspike.dylib
cp $here/Info.plist $work/App.app/Info.plist
codesign -f -s - $work/App.app

xcrun simctl bootstatus $device -b >/dev/null          # boots headless when it is not running
python3 -I -c "
import socket
s=socket.socket(socket.AF_UNIX); s.bind('$work/s.sock'); s.listen(1); s.settimeout(30)
c,_=s.accept(); print('socket:', c.recv(100))" &
xcrun simctl install $device $work/App.app
SIMCTL_CHILD_UMBRA_OUT=$work/out.png SIMCTL_CHILD_UMBRA_SOCK=$work/s.sock SIMCTL_CHILD_UMBRA_DYLIB=$work/libspike.dylib \
  xcrun simctl launch $device com.umbra.preview.spike
sleep 2
file $work/out.png
cat $work/out.png.dlopen.txt; echo
xcrun simctl terminate $device com.umbra.preview.spike
wait
