# Short commands. Run from the akit folder in a terminal.
DERIVED = build

generate:   ## regenerate AKit.xcodeproj from project.yml
	xcodegen generate --quiet

open: generate   ## open the project in Xcode
	open AKit.xcodeproj

build: generate   ## build the app from the terminal
	xcodebuild -project AKit.xcodeproj -scheme AKit -configuration Debug \
	  -derivedDataPath $(DERIVED) -quiet build

run: build   ## build and launch
	open $(DERIVED)/Build/Products/Debug/AKit.app

test:   ## core tests (no UI)
	cd AKitCore && swift test

snapshot: build   ## window snapshot without screen recording: make snapshot OUT=/tmp/akit.png [SECTION=overview] [QUERY=tdd] [DELAY=2] [OWN=1]
	pkill -x AKit || true
	$(DERIVED)/Build/Products/Debug/AKit.app/Contents/MacOS/AKit --snapshot $(or $(OUT),/tmp/akit.png) \
	  $(if $(SECTION),--section $(SECTION)) $(if $(QUERY),--query "$(QUERY)") $(if $(DELAY),--delay $(DELAY)) $(if $(OWN),--own-copy)

icon:   ## redraw the app icon
	swift tools/make-icon.swift

.PHONY: generate open build run test snapshot icon
