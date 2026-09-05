APP_NAME := CloudCodex
BUNDLE := dist/$(APP_NAME).app
EXECUTABLE := CloudCodex
CODESIGN_IDENTITY ?= -

.PHONY: build app run clean

build:
	swift build -c release

app: build
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
