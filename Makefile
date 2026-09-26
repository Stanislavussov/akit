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

snapshot: build   ## window snapshot without screen recording: make snapshot OUT=/tmp/akit.png [SECTION=overview] [QUERY=tdd] [DELAY=2] [PROJECT=akit] [HARNESS=pi] [BRAIN=<folder>] [TAB=setup] [OWN=1] [ADD=1] [CAPTURE=1]
	# Ignore saved window state: a running AKit (or one closed without windows) must not
	# stop the snapshot from opening its window. The running app is left alone.
	# Flags without a value go last: Cocoa reads launch arguments as "-key value" pairs, so
	# `--add --delay 2` leaves "2" over, which macOS tries to open as a document; the error
	# alert then keeps the window from ever appearing.
	$(DERIVED)/Build/Products/Debug/AKit.app/Contents/MacOS/AKit -ApplePersistenceIgnoreState YES --snapshot $(or $(OUT),/tmp/akit.png) \
	  $(if $(SECTION),--section $(SECTION)) $(if $(QUERY),--query "$(QUERY)") $(if $(DELAY),--delay $(DELAY)) $(if $(PROJECT),--project $(PROJECT)) \
	  $(if $(HARNESS),--harness $(HARNESS)) $(if $(BRAIN),--brain "$(BRAIN)") $(if $(TAB),--tab $(TAB)) \
	  $(if $(OWN),--own-copy) $(if $(ADD),--add) $(if $(CAPTURE),--capture)

icon:   ## redraw the app icon
	swift tools/make-icon.swift

.PHONY: generate open build run restart test snapshot icon
