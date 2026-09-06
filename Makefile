APP      = OhMyWowCCTV
SCHEME   = OhMyWowCCTV
DERIVED  = build/DerivedData
DIST     = dist
APP_PATH = $(DIST)/$(APP).app
WOW_ADDONS = /Applications/World\ of\ Warcraft/_retail_/Interface/AddOns

.PHONY: gen build test run install addon clean open

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(DERIVED) CODE_SIGN_IDENTITY=- build | tail -5
	rm -rf $(APP_PATH) && mkdir -p $(DIST)
	cp -R $(DERIVED)/Build/Products/Release/$(APP).app $(APP_PATH)
	@echo "→ $(APP_PATH)"

test: gen
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -derivedDataPath $(DERIVED) \
		CODE_SIGN_IDENTITY=- test 2>&1 | grep -E "Test Case|Executed|error:|\*\* TEST" | tail -30

run: build
	@pkill -x $(APP) || true
	@for i in $$(seq 1 40); do pgrep -x $(APP) >/dev/null || break; sleep 0.5; done
	open $(APP_PATH)

install: build
	@pkill -x $(APP) || true
	@for i in $$(seq 1 40); do pgrep -x $(APP) >/dev/null || break; sleep 0.5; done
	@pgrep -x $(APP) >/dev/null && { echo "이전 인스턴스가 종료되지 않아 강제 종료합니다"; pkill -9 -x $(APP); sleep 1; } || true
	rm -rf /Applications/$(APP).app
	cp -R $(APP_PATH) /Applications/$(APP).app
	open /Applications/$(APP).app
	@echo "→ /Applications/$(APP).app"

addon:
	rm -rf $(WOW_ADDONS)/OhMyWowCCTV
	cp -R Addon/OhMyWowCCTV $(WOW_ADDONS)/OhMyWowCCTV
	@echo "→ $(WOW_ADDONS)/OhMyWowCCTV"

open: gen
	open $(APP).xcodeproj

clean:
	rm -rf build $(DIST) $(APP).xcodeproj
