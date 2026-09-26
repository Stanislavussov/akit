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

install: generate   ## release build: AKit.app into ~/Applications, the akit command into ~/.local/bin
	xcodebuild -project AKit.xcodeproj -scheme AKit -configuration Release \
	  -derivedDataPath $(DERIVED)/release -quiet build
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/AKit.app
	cp -R $(DERIVED)/release/Build/Products/Release/AKit.app $(HOME)/Applications/
	$(MAKE) install-cli
	@echo "Installed ~/Applications/AKit.app"

install-cli:   ## only the akit command, into ~/.local/bin
	cd AKitCore && swift build -c release --product akit
	mkdir -p $(HOME)/.local/bin
	install -m 755 AKitCore/.build/release/akit $(HOME)/.local/bin/akit
	@echo "Installed ~/.local/bin/akit"
	@case ":$$PATH:" in *":$(HOME)/.local/bin:"*) ;; *) echo "Add ~/.local/bin to PATH: echo 'export PATH=\"\$$HOME/.local/bin:\$$PATH\"' >> ~/.zprofile";; esac

icon:   ## redraw the app icon
	swift tools/make-icon.swift

release: generate   ## dist/AKit.zip: universal AKit.app + akit, for GitHub Releases (install.sh downloads it)
	rm -rf dist && mkdir -p dist/AKit
	xcodebuild -project AKit.xcodeproj -scheme AKit -configuration Release \
	  -derivedDataPath $(DERIVED)/universal ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build
	cp -R $(DERIVED)/universal/Build/Products/Release/AKit.app dist/AKit/
	cd AKitCore && swift build -c release --product akit --arch arm64 --arch x86_64
	cp AKitCore/.build/apple/Products/Release/akit dist/AKit/
	cd dist && ditto -c -k --norsrc --noextattr --keepParent AKit AKit.zip && rm -rf AKit
	@echo "Built dist/AKit.zip. Publish: gh release create v$$(date +%Y.%m.%d) dist/AKit.zip --generate-notes"

.PHONY: generate open build run restart test snapshot install install-cli icon release
