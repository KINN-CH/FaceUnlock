# FaceUnlock — Xcode 없이 Command Line Tools만으로 .app 을 조립한다.

APP_NAME   := FaceUnlock
BUNDLE_ID  := io.github.kinnch.FaceUnlock
TARGET     := arm64-apple-macos14.0

BUILD_DIR  := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   := $(APP_BUNDLE)/Contents
MACOS_DIR  := $(CONTENTS)/MacOS
RES_DIR    := $(CONTENTS)/Resources

SOURCES    := $(shell find Sources -name '*.swift')
SWIFT_OPTS := -parse-as-library -target $(TARGET) -swift-version 5

.PHONY: all debug release run clean install sign check aligntest model

all: debug

debug:   SWIFT_OPTS += -Onone -g
debug:   bundle sign

release: SWIFT_OPTS += -O -whole-module-optimization
release: bundle sign

bundle: $(SOURCES) Resources/Info.plist
	@mkdir -p $(MACOS_DIR) $(RES_DIR)
	swiftc $(SWIFT_OPTS) -o $(MACOS_DIR)/$(APP_NAME) $(SOURCES)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@if [ -d Resources/Models ]; then cp -R Resources/Models $(RES_DIR)/; fi
	@echo "APPL????" > $(CONTENTS)/PkgInfo
	@echo "==> built $(APP_BUNDLE)"

# ad-hoc 서명. Developer ID 가 있다면 CODESIGN_ID 로 덮어쓴다:
#   make release CODESIGN_ID="Developer ID Application: ..."
CODESIGN_ID ?= -
sign:
	@codesign --force --sign "$(CODESIGN_ID)" \
	    --entitlements Resources/$(APP_NAME).entitlements \
	    --timestamp=none \
	    $(APP_BUNDLE)
	@echo "==> signed as '$(CODESIGN_ID)'"

# 정렬 파이프라인 확인용 CLI. 앱 번들 없이 사진만으로 검증한다.
#   make aligntest && ./build/aligntest photo1.jpg photo2.jpg
ALIGNTEST_SRCS := Tools/AlignTest/main.swift Tools/AlignTest/SelfTest.swift \
    Sources/FaceUnlock/Core/Log.swift \
    Sources/FaceUnlock/Core/VectorMath.swift \
    Sources/FaceUnlock/Core/FaceGeometry.swift \
    Sources/FaceUnlock/Core/FaceDetector.swift \
    Sources/FaceUnlock/Core/FaceAligner.swift \
    Sources/FaceUnlock/Core/EmbeddingModel.swift

aligntest: $(ALIGNTEST_SRCS)
	@mkdir -p $(BUILD_DIR)
	swiftc -target $(TARGET) -swift-version 5 -Onone -g \
	    -o $(BUILD_DIR)/aligntest $(ALIGNTEST_SRCS)
	@echo "==> built $(BUILD_DIR)/aligntest"

# ArcFace 모델 준비. 외부에서 가중치를 내려받으므로 최초 1회만 수동으로 실행한다.
#   가중치는 InsightFace 비상업 연구용 라이선스 — 저장소·배포물에 포함하지 않는다.
model:
	@./scripts/setup_model_env.sh
	@.venv/bin/python tools/fetch_arcface.py

check:
	@codesign -dv --entitlements - $(APP_BUNDLE) 2>&1 | head -20

run: debug
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@open $(APP_BUNDLE)
	@echo "==> launched. 로그: make log"

log:
	@log stream --level info --style compact --predicate 'subsystem == "$(BUNDLE_ID)"'

install: release
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "==> installed to /Applications/$(APP_NAME).app"

clean:
	@rm -rf $(BUILD_DIR)
