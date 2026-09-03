.PHONY: build test web ios clean sync

sync:
	python3 tools/hermes_sync.py

build:
	python3 tools/hermes_sync.py || true
	python3 build.py

test: build
	python3 -m unittest discover -s tests -p "test_*.py" -v
	node --check js/app.js

web: test
	python3 -m http.server 8000

ios: test
	DEVELOPER_DIR=/Users/fa1lingdown/Downloads/Xcode-beta.app/Contents/Developer \
	xcodebuild -project ios/RiverDiary/RiverDiary.xcodeproj -scheme RiverDiary \
		-configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
		-derivedDataPath ios/.simbuild build CODE_SIGNING_ALLOWED=NO

clean:
	rm -rf __pycache__ tests/__pycache__ .simbuild ios/.simbuild
