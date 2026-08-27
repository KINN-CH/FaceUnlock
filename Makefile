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

.PHONY: all debug release run clean install sign check aligntest model dmg

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

# 서명 정체성 선택.
#
# ad-hoc(`-`) 서명의 지정 요구사항은 바이너리 해시 그 자체라서, 다시 빌드할 때마다
# 손쉬운 사용 권한이 조용히 무효가 된다 (시스템 설정에는 체크된 채로 남는다).
# `./scripts/make_signing_cert.sh` 로 자체 서명 인증서를 만들어 두면 요구사항이
# 신원 기반으로 바뀌어 재빌드에도 권한이 유지된다.
#
# Developer ID 가 있다면 직접 덮어쓴다:
#   make release CODESIGN_ID="Developer ID Application: ..."
LOCAL_CERT := FaceUnlock Local Signing
CODESIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "$(LOCAL_CERT)" | head -1 | awk '{print $$2}')
ifeq ($(strip $(CODESIGN_ID)),)
CODESIGN_ID := -
endif

sign:
	@codesign --force --sign "$(CODESIGN_ID)" \
	    --entitlements Resources/$(APP_NAME).entitlements \
	    --timestamp=none \
	    $(APP_BUNDLE)
ifeq ($(CODESIGN_ID),-)
	@echo "==> signed ad-hoc  ⚠️  다시 빌드하면 손쉬운 사용 권한이 무효가 됩니다."
	@echo "    한 번만 실행하면 해결됩니다:  ./scripts/make_signing_cert.sh"
else
	@echo "==> signed with '$(LOCAL_CERT)' ($(CODESIGN_ID))"
endif

# 정렬 파이프라인 확인용 CLI. 앱 번들 없이 사진만으로 검증한다.
#   make aligntest && ./build/aligntest photo1.jpg photo2.jpg
ALIGNTEST_SRCS := Tools/AlignTest/main.swift Tools/AlignTest/SelfTest.swift \
    Sources/FaceUnlock/Core/Log.swift \
    Sources/FaceUnlock/Core/L10n.swift \
    Sources/FaceUnlock/Core/VectorMath.swift \
    Sources/FaceUnlock/Core/FaceGeometry.swift \
    Sources/FaceUnlock/Core/FaceDetector.swift \
    Sources/FaceUnlock/Core/FaceAligner.swift \
    Sources/FaceUnlock/Core/EmbeddingModel.swift \
    Sources/FaceUnlock/Core/LockMonitor.swift

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

# Swift 전처리 ↔ 원본 ONNX 교차 검증. `make model` 이후 한 번은 돌려야 한다.
xcheck: aligntest
	@FACEUNLOCK_MODEL=Resources/Models/ArcFace.mlpackage \
	    ./build/aligntest --dump-fixture > build/swift_embed.txt
	@.venv/bin/python tools/verify_preprocessing.py

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

# 배포용 DMG. 공증(notarization)이 없으므로 받는 쪽에서 quarantine 을 풀어야 한다.
# README 의 설치 안내를 함께 읽도록 DMG 안에 넣어 둔다.
#
# **ArcFace 가중치는 뺀다.** InsightFace 사전학습 가중치는 비상업 연구용
# 라이선스라 재배포할 수 없다. 받은 사람은 저장소에서 `make model` 을 돌려
# ~/Library/Application Support/FaceUnlock/Models/ 에 넣는다 (README 안내).
# 리소스를 빼면 서명이 깨지므로 뺀 뒤 다시 서명한다.
DIST_DIR := dist
dmg: release
	@rm -rf $(DIST_DIR)/staging $(DIST_DIR)/$(APP_NAME).dmg
	@mkdir -p $(DIST_DIR)/staging
	@cp -R $(APP_BUNDLE) $(DIST_DIR)/staging/
	@rm -rf $(DIST_DIR)/staging/$(APP_NAME).app/Contents/Resources/Models
	@codesign --force --sign "$(CODESIGN_ID)" \
	    --entitlements Resources/$(APP_NAME).entitlements \
	    --timestamp=none \
	    $(DIST_DIR)/staging/$(APP_NAME).app
	@ln -s /Applications $(DIST_DIR)/staging/Applications
	@cp README.md $(DIST_DIR)/staging/'먼저 읽어주세요.md'
	@mkdir -p $(DIST_DIR)/staging/.tools
	@cp tools/fetch_arcface.py $(DIST_DIR)/staging/.tools/
	@install -m 755 scripts/install_model.command '$(DIST_DIR)/staging/모델 설치.command'
	@hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder $(DIST_DIR)/staging \
	    -ov -format UDZO $(DIST_DIR)/$(APP_NAME).dmg
	@rm -rf $(DIST_DIR)/staging
	@echo "==> $(DIST_DIR)/$(APP_NAME).dmg (ArcFace 모델 미포함 — 라이선스상 재배포 불가)"
	@echo "    주의: 공증 없음. 받는 쪽에서 xattr -dr com.apple.quarantine 필요"

clean:
	@rm -rf $(BUILD_DIR)
