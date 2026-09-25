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

restart: build   ## quit this checkout's AKit, rebuild and start it again (in the app: ⌘⇧R)
	pkill -f "$(CURDIR)/$(DERIVED)/Build/Products/Debug/AKit.app/" || true
	sleep 1
	open $(DERIVED)/Build/Products/Debug/AKit.app

test:   ## core tests (no UI)
	cd AKitCore && swift test

snapshot: build   ## window snapshot without screen recording: make snapshot OUT=/tmp/akit.png [SECTION=overview] [QUERY=tdd] [DELAY=2] [OWN=1] [PROJECT=akit]
	# Ignore saved window state: a running AKit (or one closed without windows) must not
	# stop the snapshot from opening its window. The running app is left alone.
	$(DERIVED)/Build/Products/Debug/AKit.app/Contents/MacOS/AKit -ApplePersistenceIgnoreState YES --snapshot $(or $(OUT),/tmp/akit.png) \
	  $(if $(SECTION),--section $(SECTION)) $(if $(QUERY),--query "$(QUERY)") $(if $(DELAY),--delay $(DELAY)) $(if $(OWN),--own-copy) $(if $(PROJECT),--project $(PROJECT))

icon:   ## redraw the app icon
	swift tools/make-icon.swift

.PHONY: generate open build run restart test snapshot icon
