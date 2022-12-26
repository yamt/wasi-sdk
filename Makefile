# Any copyright is dedicated to the Public Domain.
# http://creativecommons.org/publicdomain/zero/1.0/

ROOT_DIR=${CURDIR}
LLVM_PROJ_DIR?=$(ROOT_DIR)/src/llvm-project

# Windows needs munging
ifeq ($(OS),Windows_NT)

PREFIX?=c:/wasi-sdk
# we need to explicitly call bash -c for makefile $(shell ...), otherwise we'll try under
# who knows what
BASH=bash -c

ifeq (x$(MSYSTEM),x)
$(error On Windows, this Makefile only works in MSYS2 environments such as git-bash.)
endif

# msys needs any /-prefixed arguments, or =/ containing, to turn into //
# because it tries to path-expand the / into the msys root.  // escapes this.
ESCAPE_SLASH=/

BUILD_PREFIX=$(PREFIX)

# assuming we're running under msys2 (git-bash), PATH needs /c/foo format directories (because
# it itself is :-delimited)
PATH_PREFIX=$(shell cygpath.exe -u $(BUILD_PREFIX))

else

PREFIX?=/opt/wasi-sdk
DESTDIR=$(abspath build/install)
BUILD_PREFIX=$(DESTDIR)$(PREFIX)
PATH_PREFIX=$(BUILD_PREFIX)
ESCAPE_SLASH?=
BASH=

endif

CLANG_VERSION=$(shell $(BASH) ./llvm_version.sh $(LLVM_PROJ_DIR))
VERSION:=$(shell $(BASH) ./version.sh)
DEBUG_PREFIX_MAP=-fdebug-prefix-map=$(ROOT_DIR)=wasisdk://v$(VERSION)

default: build
	@echo "Use -fdebug-prefix-map=$(ROOT_DIR)=wasisdk://v$(VERSION)"

check:
	CC="clang --sysroot=$(BUILD_PREFIX)/share/wasi-sysroot" \
	CXX="clang++ --sysroot=$(BUILD_PREFIX)/share/wasi-sysroot -fno-exceptions" \
	PATH="$(PATH_PREFIX)/bin:$$PATH" tests/run.sh

clean:
	rm -rf build $(DESTDIR)

build/llvm.BUILT:
	mkdir -p build/llvm
	cd build/llvm && cmake -G Ninja \
		-DCMAKE_BUILD_TYPE=MinSizeRel \
		-DLLVM_ENABLE_TERMINFO=OFF \
		-DLLVM_ENABLE_ZLIB=OFF \
		-DLLVM_ENABLE_ZSTD=OFF \
		-DLLVM_STATIC_LINK_CXX_STDLIB=ON \
		-DLLVM_HAVE_LIBXAR=OFF \
		-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
		-DCMAKE_INSTALL_PREFIX=$(PREFIX) \
		-DLLVM_TARGETS_TO_BUILD=WebAssembly \
		-DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-wasi \
		-DLLVM_ENABLE_PROJECTS="lld;clang;clang-tools-extra" \
		$(if $(patsubst 9.%,,$(CLANG_VERSION)), \
	             $(if $(patsubst 10.%,,$(CLANG_VERSION)), \
		          -DDEFAULT_SYSROOT=../share/wasi-sysroot, \
			  -DDEFAULT_SYSROOT=$(PREFIX)/share/wasi-sysroot), \
		     -DDEFAULT_SYSROOT=$(PREFIX)/share/wasi-sysroot) \
		-DLLVM_INSTALL_BINUTILS_SYMLINKS=TRUE \
		-DLLVM_ENABLE_LIBXML2=OFF \
		$(LLVM_PROJ_DIR)/llvm
	DESTDIR=$(DESTDIR) ninja $(NINJA_FLAGS) -C build/llvm \
		install-clang \
		install-clang-format \
		install-clang-tidy \
		install-clang-apply-replacements \
		install-lld \
		install-llvm-mc \
		install-llvm-ranlib \
		install-llvm-strip \
		install-llvm-dwarfdump \
		install-clang-resource-headers \
		install-ar \
		install-ranlib \
		install-strip \
		install-nm \
		install-size \
		install-strings \
		install-objdump \
		install-objcopy \
		install-c++filt \
		llvm-config
	touch build/llvm.BUILT

build/wasi-libc.BUILT: build/llvm.BUILT
	$(MAKE) -C $(ROOT_DIR)/src/wasi-libc \
		CC=$(BUILD_PREFIX)/bin/clang \
		AR=$(BUILD_PREFIX)/bin/llvm-ar \
		NM=$(BUILD_PREFIX)/bin/llvm-nm \
		SYSROOT=$(BUILD_PREFIX)/share/wasi-sysroot
	$(MAKE) -C $(ROOT_DIR)/src/wasi-libc \
		CC=$(BUILD_PREFIX)/bin/clang \
		AR=$(BUILD_PREFIX)/bin/llvm-ar \
		NM=$(BUILD_PREFIX)/bin/llvm-nm \
		SYSROOT=$(BUILD_PREFIX)/share/wasi-sysroot \
		THREAD_MODEL=posix
	touch build/wasi-libc.BUILT

build/compiler-rt.BUILT: build/llvm.BUILT build/wasi-libc.BUILT
	# Do the build, and install it.
	mkdir -p build/compiler-rt
	cd build/compiler-rt && cmake -G Ninja \
		-DCMAKE_SYSROOT=$(BUILD_PREFIX)/share/wasi-sysroot \
		-DCMAKE_C_COMPILER_WORKS=ON \
		-DCMAKE_CXX_COMPILER_WORKS=ON \
		-DCMAKE_AR=$(BUILD_PREFIX)/bin/ar \
		-DCMAKE_MODULE_PATH=$(ROOT_DIR)/cmake \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DCMAKE_TOOLCHAIN_FILE=$(ROOT_DIR)/wasi-sdk.cmake \
		-DCOMPILER_RT_BAREMETAL_BUILD=On \
		-DCOMPILER_RT_BUILD_XRAY=OFF \
		-DCOMPILER_RT_INCLUDE_TESTS=OFF \
		-DCOMPILER_RT_HAS_FPIC_FLAG=OFF \
		-DCOMPILER_RT_ENABLE_IOS=OFF \
		-DCOMPILER_RT_DEFAULT_TARGET_ONLY=On \
		-DWASI_SDK_PREFIX=$(BUILD_PREFIX) \
		-DCMAKE_C_FLAGS="$(DEBUG_PREFIX_MAP)" \
		-DLLVM_CONFIG_PATH=$(ROOT_DIR)/build/llvm/bin/llvm-config \
		-DCOMPILER_RT_OS_DIR=wasi \
		-DCMAKE_INSTALL_PREFIX=$(PREFIX)/lib/clang/$(CLANG_VERSION)/ \
		-DCMAKE_VERBOSE_MAKEFILE:BOOL=ON \
		$(LLVM_PROJ_DIR)/compiler-rt/lib/builtins
	DESTDIR=$(DESTDIR) ninja $(NINJA_FLAGS) -C build/compiler-rt install
	# Install clang-provided headers.
	cp -R $(ROOT_DIR)/build/llvm/lib/clang $(BUILD_PREFIX)/lib/
	touch build/compiler-rt.BUILT

# Flags for libcxx and libcxxabi.
LIBCXX_CMAKE_FLAGS = \
    -DCMAKE_C_COMPILER_WORKS=ON \
    -DCMAKE_CXX_COMPILER_WORKS=ON \
    -DCMAKE_AR=$(BUILD_PREFIX)/bin/ar \
    -DCMAKE_MODULE_PATH=$(ROOT_DIR)/cmake \
    -DCMAKE_TOOLCHAIN_FILE=$(ROOT_DIR)/wasi-sdk.cmake \
    -DCMAKE_STAGING_PREFIX=$(PREFIX)/share/wasi-sysroot \
    -DLLVM_CONFIG_PATH=$(ROOT_DIR)/build/llvm/bin/llvm-config \
    -DCMAKE_VERBOSE_MAKEFILE:BOOL=ON \
    -DCXX_SUPPORTS_CXX11=ON \
    -DLIBCXX_ENABLE_THREADS:BOOL=OFF \
    -DLIBCXX_HAS_PTHREAD_API:BOOL=OFF \
    -DLIBCXX_HAS_EXTERNAL_THREAD_API:BOOL=OFF \
    -DLIBCXX_BUILD_EXTERNAL_THREAD_LIBRARY:BOOL=OFF \
    -DLIBCXX_HAS_WIN32_THREAD_API:BOOL=OFF \
    -DLLVM_COMPILER_CHECKED=ON \
    -DCMAKE_BUILD_TYPE=RelWithDebugInfo \
    -DLIBCXX_ENABLE_SHARED:BOOL=OFF \
    -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY:BOOL=OFF \
    -DLIBCXX_ENABLE_EXCEPTIONS:BOOL=OFF \
    -DLIBCXX_ENABLE_FILESYSTEM:BOOL=OFF \
    -DLIBCXX_CXX_ABI=libcxxabi \
    -DLIBCXX_CXX_ABI_INCLUDE_PATHS=$(LLVM_PROJ_DIR)/libcxxabi/include \
    -DLIBCXX_HAS_MUSL_LIBC:BOOL=ON \
    -DLIBCXX_ABI_VERSION=2 \
    -DLIBCXXABI_ENABLE_EXCEPTIONS:BOOL=OFF \
    -DLIBCXXABI_ENABLE_SHARED:BOOL=OFF \
    -DLIBCXXABI_SILENT_TERMINATE:BOOL=ON \
    -DLIBCXXABI_ENABLE_THREADS:BOOL=OFF \
    -DLIBCXXABI_HAS_PTHREAD_API:BOOL=OFF \
    -DLIBCXXABI_HAS_EXTERNAL_THREAD_API:BOOL=OFF \
    -DLIBCXXABI_BUILD_EXTERNAL_THREAD_LIBRARY:BOOL=OFF \
    -DLIBCXXABI_HAS_WIN32_THREAD_API:BOOL=OFF \
    -DLIBCXXABI_ENABLE_PIC:BOOL=OFF \
    -DWASI_SDK_PREFIX=$(BUILD_PREFIX) \
    -DUNIX:BOOL=ON \
    --debug-trycompile

build/libcxx.BUILT: build/llvm.BUILT build/compiler-rt.BUILT build/wasi-libc.BUILT
	# Do the build.
	mkdir -p build/libcxx
	cd build/libcxx && cmake -G Ninja $(LIBCXX_CMAKE_FLAGS) \
		-DCMAKE_SYSROOT=$(BUILD_PREFIX)/share/wasi-sysroot \
		-DCMAKE_C_FLAGS="$(DEBUG_PREFIX_MAP)" \
		-DCMAKE_CXX_FLAGS="$(DEBUG_PREFIX_MAP)" \
		-DLIBCXX_LIBDIR_SUFFIX=$(ESCAPE_SLASH)/wasm32-wasi \
		-DLIBCXXABI_LIBDIR_SUFFIX=$(ESCAPE_SLASH)/wasm32-wasi \
		-DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
		$(LLVM_PROJ_DIR)/runtimes
	ninja $(NINJA_FLAGS) -C build/libcxx
	# Do the install.
	DESTDIR=$(DESTDIR) ninja $(NINJA_FLAGS) -C build/libcxx install
	touch build/libcxx.BUILT

build/config.BUILT:
	mkdir -p $(BUILD_PREFIX)/share/misc
	cp src/config/config.sub src/config/config.guess $(BUILD_PREFIX)/share/misc
	mkdir -p $(BUILD_PREFIX)/share/cmake
	cp wasi-sdk.cmake $(BUILD_PREFIX)/share/cmake
	cp wasi-sdk-pthread.cmake $(BUILD_PREFIX)/share/cmake
	touch build/config.BUILT

build: build/llvm.BUILT build/wasi-libc.BUILT build/compiler-rt.BUILT build/libcxx.BUILT build/config.BUILT

strip: build/llvm.BUILT
	./strip_symbols.sh $(BUILD_PREFIX)

package: build/package.BUILT

build/package.BUILT: build strip
	mkdir -p dist
	./deb_from_installation.sh $(shell pwd)/dist "$(VERSION)" "$(BUILD_PREFIX)"
	./tar_from_installation.sh "$(shell pwd)/dist" "$(VERSION)" "$(BUILD_PREFIX)"
	touch build/package.BUILT

.PHONY: default clean build strip package check
