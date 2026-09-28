APP_NAME := CloudCodex
BUNDLE := dist/$(APP_NAME).app
EXECUTABLE := CloudCodex
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
DMG_NAME := $(APP_NAME)-$(subst .,-,$(VERSION))
# Keep the code identity stable so the login Keychain can retain the user's
# access decision across local rebuilds. Callers may still override this when
# producing a build on another Mac.
CODESIGN_IDENTITY ?= Apple Development: Yuntao Zheng (ZK97MFMJ5H)

.PHONY: build app release dmg run clean

build:
	swift build -c release

app: build
	# Keep one stable, user-facing app bundle. Older local builds used a
	# version suffix (for example CloudCodex-48.app), which creates duplicate
	# Dock entries and must not be carried forward.
	find dist -maxdepth 1 -type d -name 'CloudCodex-*.app' -exec rm -rf {} +
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp .build/release/$(EXECUTABLE) "$(BUNDLE)/Contents/MacOS/$(EXECUTABLE)"
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	cp Resources/CloudCodexMiniProgramCode.png "$(BUNDLE)/Contents/Resources/CloudCodexMiniProgramCode.png"
	cp Resources/CustomerServiceQRCode.jpg "$(BUNDLE)/Contents/Resources/CustomerServiceQRCode.jpg"
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" "$(BUNDLE)"

release: app
	rm -f "dist/$(APP_NAME).zip" "dist/$(APP_NAME).zip.sha256"
	ditto -c -k --sequesterRsrc --keepParent "$(BUNDLE)" "dist/$(APP_NAME).zip"
	shasum -a 256 "dist/$(APP_NAME).zip" > "dist/$(APP_NAME).zip.sha256"

dmg: app
	rm -f "dist/$(APP_NAME).dmg" "dist/$(APP_NAME).dmg.sha256" "dist/$(DMG_NAME).dmg" "dist/$(DMG_NAME).dmg.sha256"
	stage="$$(mktemp -d)"; \
	trap 'rm -rf "$$stage"' EXIT; \
	ditto "$(BUNDLE)" "$$stage/$(APP_NAME).app"; \
	ln -s /Applications "$$stage/Applications"; \
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$$stage" -ov -format UDZO "dist/$(DMG_NAME).dmg"
	shasum -a 256 "dist/$(DMG_NAME).dmg" > "dist/$(DMG_NAME).dmg.sha256"

run: app
	open "$(BUNDLE)"

clean:
	swift package clean
	rm -rf dist
