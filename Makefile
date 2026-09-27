DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/StyleCam.app

.PHONY: generate build build-signed cli clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project StyleCam.xcodeproj -scheme StyleCam -configuration Debug \
		-derivedDataPath $(DERIVED) CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build

build-signed: generate
	xcodebuild -project StyleCam.xcodeproj -scheme StyleCam -configuration Debug \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates build

cli:
	swift build -c release --package-path Packages/StyleKit

clean:
	rm -rf build StyleCam.xcodeproj
