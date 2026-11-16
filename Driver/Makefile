# Build the PUA Call Mic AudioServerPlugIn.
#   make                      ad-hoc signed bundle in ../build/PuaCallMic.driver
#   make SIGN_IDENTITY="Developer ID Application: …"   sign with a real identity (recommended on macOS 26+)
SIGN_IDENTITY ?= -
OUT := ../build/PuaCallMic.driver
CFLAGS := -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.2 -arch arm64 -arch x86_64 -fvisibility=default

all: $(OUT)

$(OUT): PuaCallMic.c Info.plist
	rm -rf $(OUT)
	mkdir -p $(OUT)/Contents/MacOS
	cp Info.plist $(OUT)/Contents/Info.plist
	clang $(CFLAGS) -bundle -framework CoreAudio -framework CoreFoundation -o $(OUT)/Contents/MacOS/PuaCallMic PuaCallMic.c
	codesign --force --timestamp=none --options runtime --sign "$(SIGN_IDENTITY)" $(OUT)

clean:
	rm -rf $(OUT)

.PHONY: all clean
