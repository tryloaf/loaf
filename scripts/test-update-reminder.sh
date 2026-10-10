#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p build/tests/update-fixtures
loaf_update_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
loaf_objects=(${${(f)"$(rg --files build/DerivedData/Build/Intermediates.noindex/loaf.build/Debug/loaf.build/Objects-normal/arm64 -g '*.o')"}:#*/LoafApp.o})
xcrun swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -I build/DerivedData/Build/Products/Debug -F build/DerivedData/Build/Products/Debug -Xlinker -rpath -Xlinker "$PWD/build/DerivedData/Build/Products/Debug" tests/UpdateReminderTests.swift "${loaf_objects[@]}" build/DerivedData/Build/Products/Debug/ZIPFoundation.o -o build/tests/update-reminder-tests
app="build/tests/UpdateReminderChecks.app"
mkdir -p "$app/Contents/MacOS"
cp build/tests/update-reminder-tests "$app/Contents/MacOS/UpdateReminderChecks"
python3 - "$loaf_update_port" <<'PY'
import plistlib, sys, os
from pathlib import Path
info=plistlib.loads(Path('loaf/Info.plist').read_bytes())
info.update(CFBundleExecutable='UpdateReminderChecks',CFBundleIdentifier='app.tryloaf.loaf.update-reminder-checks',CFBundleName='loaf update focus checks',LoafBackgroundOnly=os.environ.get('LOAF_BACKGROUND_ONLY')=='1',CFBundleVersion='1',CFBundleShortVersionString='1.0.0',CFBundlePackageType='APPL',SUFeedURL='http://localhost:' + sys.argv[1] + '/update-reminder-appcast.xml',SUEnableAutomaticChecks=False,SUEnableInstallerLauncherService=False,NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
Path('build/tests/UpdateReminderChecks.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
Path('build/tests/update-fixtures/update-reminder-appcast.xml').write_text('''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>loaf test updates</title><item><title>loaf test update</title><sparkle:version>99</sparkle:version><sparkle:shortVersionString>99.0</sparkle:shortVersionString><sparkle:minimumSystemVersion>15.4</sparkle:minimumSystemVersion><enclosure url="https://tryloaf.app/loaf-1.0.0-99.dmg" length="10000" type="application/octet-stream" sparkle:edSignature="fixture"/></item></channel></rss>''')
PY
python3 -m http.server "$loaf_update_port" --bind 127.0.0.1 --directory build/tests/update-fixtures > build/tests/update-reminder-server.log 2>&1 &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
for attempt in {1..40}; do
    if curl --silent --fail "http://localhost:$loaf_update_port/update-reminder-appcast.xml" > /dev/null; then break; fi
    sleep 0.1
done
codesign --force --sign - "$app"
: > build/tests/update-reminder-native.log
: > build/tests/update-reminder-errors.log
open -W -n --stdout "$PWD/build/tests/update-reminder-native.log" --stderr "$PWD/build/tests/update-reminder-errors.log" "$app"
cat build/tests/update-reminder-native.log
rg -q '^PASS: background reminder,' build/tests/update-reminder-native.log
