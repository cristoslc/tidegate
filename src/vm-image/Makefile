# Build and test workflow for Tidegate VM guest image (SPEC-006).
#
# Targets:
#   build   — Build Docker image
#   export  — Export rootfs tarball from image
#   test    — Run all validation tests
#   lint    — Run shellcheck on init.sh
#   clean   — Remove build artifacts and image
.POSIX:
SHELL = /bin/sh

IMAGE_TAG = tidegate-agent:latest
ROOTFS_TAR = rootfs.tar
PROJECT_ROOT = ../..

.PHONY: build export test lint clean

build:
	docker build -t $(IMAGE_TAG) -f Dockerfile .

export: build
	@rm -f $(ROOTFS_TAR)
	@CID=$$(docker create $(IMAGE_TAG)) && \
		docker export "$$CID" > $(ROOTFS_TAR) && \
		docker rm "$$CID" >/dev/null
	@echo "Exported rootfs to $(ROOTFS_TAR)"

test:
	@cd $(PROJECT_ROOT) && sh test/vm-image/test-kernel-config.sh
	@cd $(PROJECT_ROOT) && sh test/vm-image/test-init-functions.sh
	@cd $(PROJECT_ROOT) && sh test/vm-image/test-dockerfile.sh
	@cd $(PROJECT_ROOT) && sh test/vm-image/test-guest-image.sh

lint:
	shellcheck init.sh
	@echo "Lint passed"

clean:
	rm -f $(ROOTFS_TAR)
	docker rmi $(IMAGE_TAG) 2>/dev/null || true
