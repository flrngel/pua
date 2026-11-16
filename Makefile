# make            build CLI (release) and driver
# make driver SIGN_IDENTITY="Developer ID Application"   sign the driver with your identity
SIGN_IDENTITY ?= -

all: cli driver

cli:
	swift build -c release
	@echo "CLI: .build/release/pua"

driver:
	$(MAKE) -C Driver SIGN_IDENTITY="$(SIGN_IDENTITY)"

clean:
	swift package clean
	$(MAKE) -C Driver clean

.PHONY: all cli driver clean
