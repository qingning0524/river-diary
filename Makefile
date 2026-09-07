.PHONY: build test check verify backup web ios mac swift-test clean

check: build
	node --check js/app.js
	python3 -m compileall -q build.py pipeline
	python3 -m json.tool data/data.json > /dev/null

build:
	python3 build.py

test: build
	python3 -m unittest discover -s tests -p "test_*.py" -v
	node --check js/app.js

verify: test check

backup:
	@mkdir -p backups
	tar --exclude='./backups' --exclude='./ios/.build' --exclude='./ios/.devicebuild' \
		--exclude='./ios/.simbuild' --exclude='./ios/.simrelease' \
		--exclude='./macos/RiverDiaryMac/.build' --exclude='./macos/RiverDiaryMac/.swiftpm' \
		--exclude='./dist/River Diary.app' \
		-czf "backups/project-backup-$$(date +%Y%m%d-%H%M%S).tar.gz" .

web: test
	python3 -m http.server 8000

ios: test
	DEVELOPER_DIR=/Users/fa1lingdown/Downloads/Xcode-beta.app/Contents/Developer \
	xcodebuild -project ios/RiverDiary/RiverDiary.xcodeproj -scheme RiverDiary \
		-configuration Debug -destination 'generic/platform=iOS Simulator' \
	-derivedDataPath ios/.simbuild build CODE_SIGNING_ALLOWED=NO

mac: build
	./macos/RiverDiaryMac/make_app.sh

swift-test:
	cd macos/RiverDiaryMac && \
		DEVELOPER_DIR="/Users/fa1lingdown/Downloads/Xcode-beta.app/Contents/Developer" \
		SDKROOT="/Users/fa1lingdown/Downloads/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
		SWIFTPM_CACHE_PATH=".build/spm-cache" \
		CLANG_MODULE_CACHE_PATH=".build/clang-module-cache" \
		SWIFT_MODULE_CACHE_PATH=".build/swift-module-cache" \
		swift test --disable-sandbox

clean:
	rm -rf __pycache__ tests/__pycache__ pipeline/__pycache__ .simbuild ios/.simbuild
