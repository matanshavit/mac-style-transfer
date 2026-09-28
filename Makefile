DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/StyleCam.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/StyleCam.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
VIDEO ?= data/video/Johnny_1280x720_60.y4m
STYLE ?=

.PHONY: generate build build-signed install run-demo cli clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project StyleCam.xcodeproj -scheme StyleCam -configuration Debug \
		-derivedDataPath $(DERIVED) CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
		STYLECAM_APP_ENTITLEMENTS=App/StyleCam-NoTeam.entitlements build

build-signed: generate
	xcodebuild -project StyleCam.xcodeproj -scheme StyleCam -configuration Release \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

# macOS only activates the camera extension from an app in /Applications, and it finds the
# extension by identifier, so build copies registered with LaunchServices must be removed.
install: build-signed
	rm -rf /Applications/StyleCam.app
	ditto $(RELEASE_APP) /Applications/StyleCam.app
	-$(LSREGISTER) -u $(RELEASE_APP) $(APP)

# Plays a y4m video instead of the camera, so it needs no camera permission.
run-demo: build
	@test -f "$(VIDEO)" || { echo "No video at $(VIDEO). Run make run-demo VIDEO=path/to/file.y4m"; exit 1; }
	open -n $(APP) --args -StyleCamVideoFile "$(abspath $(VIDEO))" $(if $(STYLE),-StyleCamStyle $(STYLE))

cli:
	swift build -c release --package-path Packages/StyleKit

clean:
	rm -rf build StyleCam.xcodeproj
