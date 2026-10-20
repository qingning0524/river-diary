#!/bin/zsh
# Build a disposable host with the QA bundle/keychain namespace. Never install
# the production unit-test host over the user's real iPhone application.
set -euo pipefail
repo_root="${0:A:h:h}"
if [[ $# -lt 1 ]]; then
  print -u2 'Usage: scripts/test_ios_isolated.sh <xcode destination> [xcodebuild arguments]'
  exit 64
fi
destination="$1"
shift
source "$repo_root/scripts/select_xcode.sh"
unset SDKROOT
staging=$(/usr/bin/mktemp -d "${TMPDIR%/}/RiverDiary-iOS-Tests.XXXXXX")
export RIVER_IOS_TEST_SOURCE="$repo_root"
export RIVER_IOS_TEST_STAGE="$staging"
python3 - <<'PY'
import os, shutil
from pathlib import Path
root = Path(os.environ['RIVER_IOS_TEST_SOURCE'])
stage = Path(os.environ['RIVER_IOS_TEST_STAGE'])
ios = root / 'ios/RiverDiary'
shutil.copytree(ios / 'RiverDiary', stage / 'RiverDiary', ignore=shutil.ignore_patterns('data.json'))
shutil.copytree(ios / 'RiverDiary.xcodeproj', stage / 'RiverDiary.xcodeproj', ignore=shutil.ignore_patterns('xcuserdata', 'project.xcworkspace'))
for name in ['RiverDiaryTests', 'RiverDiaryUITests', 'RiverDiaryQAResources', 'Info.plist', 'RiverDiaryUITests-Info.plist']:
    (stage / name).symlink_to(ios / name)
project = stage / 'RiverDiary.xcodeproj/project.pbxproj'
text = project.read_text()
text = text.replace('PRODUCT_BUNDLE_IDENTIFIER = local.riverdiary.app;', 'PRODUCT_BUNDLE_IDENTIFIER = studio.riverdiary.ios.qa;')
text = text.replace('PRODUCT_BUNDLE_IDENTIFIER = local.riverdiary.app.tests;', 'PRODUCT_BUNDLE_IDENTIFIER = studio.riverdiary.ios.qa.unittests;')
text = text.replace('relativePath = ../../Packages/RiverDiaryCore;', f'relativePath = "{root / "Packages/RiverDiaryCore"}";')
project.write_text(text)
resources = stage / 'RiverDiary/Resources'
resources.mkdir(exist_ok=True)
shutil.copy2(ios / 'RiverDiaryQAResources/data.json', resources / 'data.json')
print(f'ISOLATED_IOS_TEST_PROJECT={stage}')
PY
exec xcodebuild -project "$staging/RiverDiary.xcodeproj" -scheme RiverDiaryTests \
  -configuration Debug -destination "$destination" \
  -derivedDataPath "$repo_root/ios/.auditunit" -parallel-testing-enabled NO "$@" test
