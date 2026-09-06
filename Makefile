# Plain `swift test` works now that full Xcode is installed; when only the
# Command Line Tools are present, SwiftPM needs explicit search paths for the
# Swift Testing framework (see git history for the flags).
.PHONY: build test run bundle install-dev release site clean

build:
	swift build

test:
	swift test

run:
	swift run ReviewBar

# .app bundle (needs Xcode + XcodeGen). Required for anything bundle-dependent:
# LSUIElement, sandbox entitlements, notifications.
bundle:
	xcodegen generate
	xcodebuild -project ReviewBar.xcodeproj -target ReviewBar -configuration Debug \
		SYMROOT=build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" build

# Notifications need a bundle Launch Services knows about: running the binary
# straight out of build/ fails authorization with UNErrorDomain code 1.
install-dev: bundle
	rm -rf ~/Applications/ReviewBar.app
	cp -R build/Debug/ReviewBar.app ~/Applications/
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/ReviewBar.app
	@echo "Installed ~/Applications/ReviewBar.app"

# Distributable Release build + zip in dist/. Signs and notarizes when
# MACOS_SIGN_IDENTITY and the notarytool credentials are exported; otherwise
# produces an ad-hoc signed build. See docs/RELEASING.md.
release:
	scripts/package-release.sh

# Preview the landing page (site/) locally. It is static — no build step —
# so this just serves the directory and opens it; Ctrl-C stops the server.
# If something already listens on the port (usually an earlier `make site`
# left running in another tab), reuse it rather than fail. Override with
# `make site SITE_PORT=9000`. Never 8765: that is AnkiConnect.
SITE_PORT ?= 8000
site:
	@if lsof -nP -iTCP:$(SITE_PORT) -sTCP:LISTEN >/dev/null; then \
	  echo "Port $(SITE_PORT) is already serving — reusing it (kill it or set SITE_PORT to start fresh)"; \
	  open http://localhost:$(SITE_PORT); \
	else \
	  echo "Serving site/ at http://localhost:$(SITE_PORT) — Ctrl-C to stop"; \
	  (sleep 1; open http://localhost:$(SITE_PORT)) & \
	  cd site && python3 -m http.server $(SITE_PORT); \
	fi

clean:
	rm -rf .build build dist ReviewBar.xcodeproj Support
