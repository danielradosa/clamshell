# Clamshell — builds a real .app bundle with the Command Line Tools alone.
#
# Two things about this build are deliberate:
#
#   * It calls swiftc directly instead of using SwiftPM. The PackageDescription
#     shipped in the Command Line Tools is internally inconsistent (its module
#     interface and its dylib disagree on Package.init), so `swift build` cannot
#     parse a manifest at all. One target does not need a package manager.
#
#   * Metal shaders are compiled at runtime from source rather than built into a
#     .metallib. The offline `metal` compiler ships only with Xcode; the Metal
#     runtime compiler does not, so this is what makes an Xcode-free build work.

APP_NAME   := Clamshell
BUNDLE_ID  := com.danielradosa.clamshell
BUILD_DIR  := .build/release
DIST_DIR   := .dist
APP        := $(DIST_DIR)/$(APP_NAME).app
CONTENTS   := $(APP)/Contents

SOURCES := $(wildcard Sources/Clamshell/*.swift) $(wildcard Sources/Clamshell/*/*.swift)

FRAMEWORKS := AppKit SwiftUI Metal MetalKit ScreenCaptureKit IOKit CoreVideo CoreMedia QuartzCore
FRAMEWORK_FLAGS := $(addprefix -framework ,$(FRAMEWORKS))

DEPLOY_TARGET := arm64-apple-macos14.0
SWIFTC_FLAGS  := -O -swift-version 5 -target $(DEPLOY_TARGET)

# Signing identity. A stable certificate is what keeps the Screen Recording
# grant alive across rebuilds — an ad-hoc signature changes the app's code hash
# every build, so TCC treats each build as a new app and asks again. Uses the
# local certificate when it exists and falls back to ad-hoc when it does not.
SIGNING_CERT_NAME := Clamshell Local Signing
CODESIGN_IDENTITY ?= $(shell security find-certificate -c "$(SIGNING_CERT_NAME)" \
    >/dev/null 2>&1 && echo "$(SIGNING_CERT_NAME)" || echo "-")

.PHONY: all build bundle sign run install uninstall clean reset-permission debug \
        setup certificate remove-certificate diagnose dmg

# One command from a fresh clone to a working, permission-stable install.
setup: certificate install reset-permission
	@echo ""
	@echo "Clamshell is installed at /Applications/Clamshell.app."
	@echo "Launch it and grant Screen Recording once — it will stick from now on."
	@open /Applications/Clamshell.app

certificate:
	@Scripts/make-signing-certificate.sh

remove-certificate:
	@Scripts/make-signing-certificate.sh --remove

# Writes ~/Library/Logs/Clamshell-diagnostics.txt describing what the app can
# actually see: permission state, displays, sensor availability and angle.
diagnose:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -f "$(HOME)/Library/Logs/Clamshell-diagnostics.txt"
	@open -a /Applications/$(APP_NAME).app --args --diagnose 2>/dev/null \
		|| open -a "$(APP)" --args --diagnose
	@sleep 4
	@cat "$(HOME)/Library/Logs/Clamshell-diagnostics.txt" 2>/dev/null \
		|| echo "No report written — is Clamshell installed?"

all: bundle sign

build:
	@mkdir -p $(BUILD_DIR)
	@swiftc $(SWIFTC_FLAGS) $(FRAMEWORK_FLAGS) $(SOURCES) -o $(BUILD_DIR)/$(APP_NAME)
	@echo "Built    $(BUILD_DIR)/$(APP_NAME)"

debug: SWIFTC_FLAGS := -Onone -g -swift-version 5 -target $(DEPLOY_TARGET)
debug: build

bundle: build
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@echo "Bundled  $(APP)"

sign:
	@codesign --force --sign "$(CODESIGN_IDENTITY)" "$(APP)"
	@echo "Signed   with: $(CODESIGN_IDENTITY)"
ifeq ($(CODESIGN_IDENTITY),-)
	@echo "  NOTE: ad-hoc signature. macOS will ask for Screen Recording again"
	@echo "        after every rebuild. Run 'make certificate' to stop that."
endif

run: install
	@open "/Applications/$(APP_NAME).app"
	@echo "Launched. Look for the laptop icon in the menu bar."

# A stable install path is what lets the Screen Recording grant persist.
install: all
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP)" /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

uninstall:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf "/Applications/$(APP_NAME).app"

# Ad-hoc signatures change on every rebuild, which can strand the old grant.
reset-permission:
	@tccutil reset ScreenCapture $(BUNDLE_ID) || true

clean:
	@rm -rf .build "$(DIST_DIR)"
	@echo "Cleaned"

# Renders the fold offscreen to PNGs. No window, no display, no permission —
# the only way to eyeball the shader maths without a human at a screen.
PREVIEW_SOURCES := Sources/Clamshell/Render/Shaders.swift \
                   Sources/Clamshell/Render/FoldRenderer.swift \
                   Sources/Clamshell/Model/FoldStyle.swift \
                   Tools/FoldPreview/main.swift

.PHONY: preview
preview:
	@mkdir -p $(BUILD_DIR)
	@swiftc $(SWIFTC_FLAGS) -framework Metal -framework AppKit -framework ImageIO \
		$(PREVIEW_SOURCES) -o $(BUILD_DIR)/FoldPreview
	@$(BUILD_DIR)/FoldPreview $(DIST_DIR)/preview

VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG     := $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg

dmg: all
	@rm -rf "$(DIST_DIR)/dmg" "$(DMG)"
	@mkdir -p "$(DIST_DIR)/dmg"
	@cp -R "$(APP)" "$(DIST_DIR)/dmg/"
	@ln -s /Applications "$(DIST_DIR)/dmg/Applications"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DIST_DIR)/dmg" \
		-ov -format UDZO -quiet "$(DMG)"
	@rm -rf "$(DIST_DIR)/dmg"
	@echo "Built    $(DMG)  ($$(du -h "$(DMG)" | cut -f1))"
