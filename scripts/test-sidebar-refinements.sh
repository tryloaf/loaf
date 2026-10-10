#!/bin/zsh
set -eu
cd "${0:A:h}/.."
mkdir -p build/tests
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
loaf_objects=(${${(f)"$(rg --files build/DerivedData/Build/Intermediates.noindex/loaf.build/Debug/loaf.build/Objects-normal/arm64 -g '*.o')"}:#*/LoafApp.o})
xcrun swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -I build/DerivedData/Build/Products/Debug -F build/DerivedData/Build/Products/Debug -Xlinker -rpath -Xlinker "$PWD/build/DerivedData/Build/Products/Debug" tests/SidebarRefinementTests.swift "${loaf_objects[@]}" build/DerivedData/Build/Products/Debug/ZIPFoundation.o -o build/tests/sidebar-refinement-tests
app="build/tests/SidebarRefinementChecks.app"
mkdir -p "$app/Contents/MacOS"
cp build/tests/sidebar-refinement-tests "$app/Contents/MacOS/SidebarRefinementChecks"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib,sys,os
from pathlib import Path
p=plistlib.loads(Path('loaf/Info.plist').read_bytes())
p.update(CFBundleExecutable='SidebarRefinementChecks',CFBundleIdentifier='app.tryloaf.loaf.sidebar-refinement-checks',CFBundlePackageType='APPL',LoafRepository=str(Path.cwd()),LoafHeadless=os.environ.get('LOAF_SIDEBAR_HEADLESS')=='1')
Path(sys.argv[1]).write_bytes(plistlib.dumps(p))
PY
codesign --force --sign - "$app"
: > build/tests/sidebar-refinement-native.log
: > build/tests/sidebar-refinement-errors.log
open -W -n --stdout "$PWD/build/tests/sidebar-refinement-native.log" --stderr "$PWD/build/tests/sidebar-refinement-errors.log" "$app"
cat build/tests/sidebar-refinement-native.log
rg -q '^PASS:' build/tests/sidebar-refinement-native.log
