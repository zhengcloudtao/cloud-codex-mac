APP_NAME := CloudCodex
BUNDLE := dist/$(APP_NAME).app
EXECUTABLE := CloudCodex
# Keep the code identity stable so the login Keychain can retain the user's
# access decision across local rebuilds. Callers may still override this when
# producing a build on another Mac.
CODESIGN_IDENTITY ?= Apple Development: Yuntao Zheng (ZK97MFMJ5H)

.PHONY: build app run clean

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
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" "$(BUNDLE)"

run: app
	open "$(BUNDLE)"

clean:
	swift package clean
	rm -rf dist
