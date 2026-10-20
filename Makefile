.PHONY: build test check verify backup web ios mac swift-test verify-all clean clean-preview user-console-test

check: test
	python3 -m compileall -q build.py pipeline

build:
	python3 build.py

test:
	python3 -m unittest discover -s tests -p "test_*.py" -v
	python3 -c 'from pipeline import build_assets; build_assets()'
	node --check web-preview/js/app.js
	cd website/user && node --test tests/*.test.mjs

user-console-test:
	cd website/user && node --test tests/*.test.mjs

verify: test check

backup:
	@mkdir -p archive/backups
	tar --exclude='./archive/backups' --exclude='./.git' \
		--exclude='*/.build' --exclude='*/.swiftpm' --exclude='*/node_modules' \
		--exclude='*/.simbuild' --exclude='*/.signedbuild' \
		--exclude='*/.devicebuild' --exclude='*/.simrelease' \
		--exclude='*/__pycache__' --exclude='*/.DS_Store' \
		--exclude='./dist' --exclude='./server/dist' \
		-czf "archive/backups/project-backup-$$(date +%Y%m%d-%H%M%S).tar.gz" .

web: test
	@echo "预览地址：http://localhost:8000/web-preview/"
	python3 -m http.server 8000

ios: test
	zsh -c 'source scripts/select_xcode.sh && xcodebuild -project ios/RiverDiary/RiverDiary.xcodeproj -scheme RiverDiary \
		-configuration Debug -destination "generic/platform=iOS Simulator" \
	-derivedDataPath ios/.simbuild build'

mac:
	./macos/RiverDiaryMac/make_app.sh

verify-all: check swift-test ios

swift-test:
	./scripts/test_macos_isolated.sh --disable-sandbox

clean:
	python3 scripts/clean_project.py --apply

clean-preview:
	python3 scripts/clean_project.py
