#!/bin/zsh
# Build and test the package on the Mac; prints only errors, warnings and the test summary.
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
strip() { sed $'s/\x1b\\[[0-9;]*m//g' }
swift build 2>&1 | strip > .build-check.log
if grep -q "error:" .build-check.log; then grep -E "(error|warning):" -A3 .build-check.log | grep -v "^Failed frontend" | head -60; echo "BUILD FAILED"; exit 1; fi
grep -E "warning:" .build-check.log | sort -u | head -20
echo "BUILD OK"
[[ "$1" == "--no-test" ]] && exit 0
swift test 2>&1 | strip > .test-check.log
grep -E "(✘|error:|failed|passed after|Expectation failed)" .test-check.log | head -60
tail -2 .test-check.log
