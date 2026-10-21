.PHONY: build test check verify backup web ios mac mac-signed swift-test verify-all gate clean clean-preview user-console-test privacy-scan-build dmg dmg-signed sponsor-kit

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
	./scripts/verify_build_privacy.sh

mac:
	./macos/RiverDiaryMac/make_app.sh
	./scripts/verify_build_privacy.sh

# 赞助演示用未公证 DMG；不做公证/签名，附安装说明与 SHA-256。
dmg: mac
	./scripts/make_mac_dmg.sh

# 用稳定的 Apple Development 证书签名后再打 DMG；避免每次重构建触发钥匙串 ACL。
dmg-signed: mac-signed
	./scripts/make_mac_dmg.sh

# 把 DMG、安装说明、试用清单、演示截图打成可直接发给种子用户的 zip。
sponsor-kit:
	./scripts/make_sponsor_kit.sh

# 本机日常使用请用这个目标：用开发者证书做稳定签名，钥匙串授权点一次
# “始终允许”后，重新构建也不会再反复弹密码。
mac-signed:
	@identity="$$(security find-identity -v -p codesigning \
		| sed -nE 's/.*"(Apple Development[^"]*)".*/\1/p' | head -1)"; \
	if [ -z "$$identity" ]; then \
		echo "没有找到 Apple Development 证书；请先在 Xcode 登录开发者账号。" >&2; \
		exit 1; \
	fi; \
	echo "Signing with: $$identity"; \
	CODESIGN_IDENTITY="$$identity" ./macos/RiverDiaryMac/make_app.sh

verify-all: check swift-test ios

# 统一发布门禁：必须在干净检出里运行；未跑的关键验证（目前是 iOS 单测）
# 会让门禁返回非零，而不是悄悄跳过。
gate:
	./scripts/release_gate.sh

swift-test:
	./scripts/test_macos_isolated.sh --disable-sandbox

privacy-scan-build:
	./scripts/verify_build_privacy.sh

clean:
	python3 scripts/clean_project.py --apply

clean-preview:
	python3 scripts/clean_project.py
