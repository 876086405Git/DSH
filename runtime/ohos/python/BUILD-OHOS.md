# CPython 3.14.7 正式构建输入（922 / ohos10 追加1）

基底 6459f947。以 ohos10 `REF-本机完整依赖libpython真机通过-20261108.zip` 的 README、build-deps.sh 和设备原始输出为准。桥使用 C Node-API、现有 napi-rename.h 与 libnode 的 dsh_napi_*，不依赖 libc++ 的 C++ ABI，不引用 V8/libuv/OpenSSL 私有符号。不修改 runtime/ohos/node。REF 探针能运行不等于本组合的 Node 桥、子解释器和关闭流程已在手机验证。

固定输入：CPython 3.14.7、OpenSSL 3.5.9、libffi 3.8.0、SQLite amalgamation 3.54.1（3540100）。三个扩展依赖静态进入 libpython；zlib 使用鸿蒙系统 `libz.so`。这是本机新 REF 已验证的组合，替代旧文档的构建候选。

| 已下载字节 | 身份与检查 |
|---|---|
| REF ZIP | SHA256 `9e02b56c8d51ec1fe461cb3fae357d4e8622de0dab0cfe8bed32c1a43a8880ca` |
| `REF/libpython3.14.so` | 17,242,880 B；SHA256 `4ff425ab68e719a7b5f98ffcc98c37f82897353f464287b541bc765b83014447` |
| 实际 ELF | AArch64 ELF64；NEEDED 为 `libz.so`、`libc.so`；SONAME `libpython3.14.so`；无 RPATH/RUNPATH |
| 必需模块 | `_ssl`、`_hashlib`、`_sqlite3`、`_ctypes`、`zlib` 的 PyInit 符号在实际 ELF 中均已定义 |

REF 报告 89 个内置模块；仍缺 `_bz2`、`_lzma`、`_zstd`、`_uuid`、`readline`、`_curses`、`_dbm`。原始设备记录中的 ssl/hashlib/sqlite3/ctypes 和显式系统目录 HTTPS 已由本机验证；本组合正式入口仍需复验。

直接使用 REF 库时，把原字节 `libpython3.14.so` 与匹配构建的 `pyconfig.h` 放进新的 Python 输入目录，再把该目录传给 `build-host.py --python-build`，源 Include 来自同版 3.14.7。REF 不包含 pyconfig.h，不能用桌面头替代。桥命令见 PRODUCTION.md；输出为 `libdsh_python.so` 和不改字节的 `libpython3.14.so`。旧 ohos9 REF 的缺模块库不再作为正式输入。

新库实际源码归档没有全部附在 REF 中；本说明不补造 OpenSSL/libffi/SQLite 的 SHA256，也不把 SQLite 源码 SHA3-256 当 ZIP SHA256。CPython `Python-3.14.7.tar.xz` 的旧 REF 来源散列为 `3b48dac8fb59f62eaa67ac83c1eb12bda1b7a08406dd286e252c11a66be27f81`，本轮未重新下载源码复算。

以下整理自 REF 的命令针对 Linux x86_64 宿主，要求已解压、已核对来源哈希的源码，`SRC`/`BUILD`/`PREFIX` 均为绝对目录。`${OHOS_SDK}` 指向本机 SDK7，构建目录使用新的路径。先用 `sha256sum -c sources.sha256`，清单由本机建立。追加了 README 要求的 `ac_cv_header_linux_qrtr_h=no`，以及 `--openssldir=/etc/ssl` 去掉编译机目录；因此重建所得库应记录新哈希，不能继续沿用 REF 库哈希。本沙箱未执行 SDK 交叉编译。

```sh
set -eu
: "${OHOS_SDK:?}" "${SRC:?}" "${BUILD:?}" "${PREFIX:?}"
L="$OHOS_SDK/native/llvm/bin"
export CC="$L/aarch64-unknown-linux-ohos-clang"
export CXX="$L/aarch64-unknown-linux-ohos-clang++"
export AR="$L/llvm-ar" RANLIB="$L/llvm-ranlib" READELF="$L/llvm-readelf"
export CFLAGS='-O2 -fPIC' CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_LIBDIR="$BUILD/empty-pc" PKG_CONFIG_PATH=
mkdir -p "$BUILD/empty-pc" "$PREFIX/lib" "$PREFIX/include"

# OpenSSL: compiled-in default/base providers, no runtime provider modules.
mkdir -p "$BUILD/openssl"
cd "$BUILD/openssl"
"$SRC/openssl-3.5.9/Configure" linux-aarch64 no-shared no-tests no-docs no-apps \
  --prefix="$PREFIX" --libdir=lib --openssldir=/etc/ssl -O2 -fPIC
make -j6
make install_sw

mkdir -p "$BUILD/libffi"
cd "$BUILD/libffi"
"$SRC/libffi-3.8.0/configure" --host=aarch64-linux-musl \
  --build=x86_64-pc-linux-gnu --prefix="$PREFIX" --libdir="$PREFIX/lib" \
  --disable-shared --enable-static --with-pic --disable-docs
make -j6
make install

# Amalgamation avoids executing target configure probes.
cd "$BUILD"
"$CC" -O2 -fPIC -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION=1 \
  -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_MATH_FUNCTIONS \
  -c "$SRC/sqlite-amalgamation-3540100/sqlite3.c" -o sqlite3.o
"$AR" rcs "$PREFIX/lib/libsqlite3.a" sqlite3.o
cp "$SRC/sqlite-amalgamation-3540100/sqlite3.h" "$PREFIX/include/"
cp "$SRC/sqlite-amalgamation-3540100/sqlite3ext.h" "$PREFIX/include/"

mkdir -p "$BUILD/python"
cd "$BUILD/python"
MODULE_BUILDTYPE=static \
LIBFFI_CFLAGS="-I$PREFIX/include" LIBFFI_LIBS="$PREFIX/lib/libffi.a" \
LIBSQLITE3_CFLAGS="-I$PREFIX/include" LIBSQLITE3_LIBS="$PREFIX/lib/libsqlite3.a -lm" \
"$SRC/Python-3.14.7/configure" --host=aarch64-linux-musl --build=x86_64-pc-linux-gnu \
  --with-build-python=python3.14 --enable-shared --without-ensurepip --disable-test-modules \
  --without-static-libpython --prefix=/dshpy --with-openssl="$PREFIX" \
  --with-openssl-rpath=no \
  ac_cv_file__dev_ptmx=no ac_cv_file__dev_ptc=no ac_cv_buggy_getaddrinfo=no \
  ac_cv_header_libintl_h=no ac_cv_header_linux_qrtr_h=no
make -j6 INSTSONAME=libpython3.14.so
"$READELF" -d libpython3.14.so
"$L/llvm-nm" libpython3.14.so | rg 'PyInit_(_ssl|_hashlib|_sqlite3|_ctypes|zlib)$'
"$L/llvm-strip" --strip-debug libpython3.14.so
```

必须检查 configure 最终模块清单和实际 import，五个模块不能是 missing/disabled。`NEEDED` 不得含动态 libssl/libcrypto/libffi/libsqlite3 或版本化 `libz.so.1`；准确的系统 `libz.so` 允许。SONAME 必须是 `libpython3.14.so`，不能带 RPATH/RUNPATH。REF 库仅依赖 libc.so/libz.so；最终 HAP 仍须做依赖闭包与 N-API 审计，不能从 Linux guest 复制系统库。

正式桥在第一次 Python 初始化前设置 C 环境 `SSL_CERT_DIR=/etc/security/certificates`，目录来自 REF 真机证据；`setenv` 失败明确报 `ERR_OHOS_PYTHON_CERTIFICATES`。每作业的 Python env 仍是独立字典，不改 App 环境。普通默认 SSL/urllib 同时加载打包 CA 与系统默认根，显式 cafile/capath/cadata 不扩大信任根；不会关闭证书或主机名校验。Linux 真实共享库测试用不同打包根/系统根先红后绿覆盖这条接线；手机正式 Node 入口尚待验证。

Node probe addon交叉编译（需CPython构建目录pyconfig.h、源Include和固定Node24.22.1头文件）：

```sh
"$CC" -shared -fPIC -O2 -std=c11 -D_POSIX_C_SOURCE=200809L \
  -include "$REPO/runtime/ohos/node/napi-rename.h" \
  -I"$NODE_SOURCE/src" -I"$SRC/Python-3.14.7/Include" -I"$BUILD/python" \
  "$REPO/runtime/ohos/python/probe.c" -L"$BUILD/python" -lpython3.14 \
  -L"$LIBNODE_DIR" -lnode -Wl,-z,defs -Wl,-soname,libdsh_python_probe.so \
  -o "$BUILD/libdsh_python_probe.so"
"$L/llvm-nm" -D --undefined-only "$BUILD/libdsh_python_probe.so"
```

禁止出现原名napi_*/node_api_*导入；应为dsh_napi_*。入口napi_register_module_v1由addon导出，不改名。正式入口推荐Node addon；探针不注册到生产启动。probe需标准库已安装（产品用PyConfig显式home/module_search_paths；此探针还依赖宿主默认路径），因此此编译命令不等于可直接装HAP运行。

“只增加一个libpython”指所有Python扩展/其依赖只进该库；Node桥若独立构建还增加一个小addon。要严格只增加一个ELF，需把相同C桥对象链入libdsh_host并经纯C协议对Node导出（不能把Ark napi_env送进Node）。这需要主线宿主链接调整，不能绕过隔离审计。

最初设计使用的官方资料（当前版本和设备事实以本轮 REF 为准）：
- https://docs.python.org/3.14/c-api/init_config.html
- https://docs.python.org/3.14/c-api/subinterpreters.html
- https://nodejs.org/api/n-api.html
- https://github.com/openssl/openssl/blob/openssl-3.5.4/INSTALL.md
- https://openssl-library.org/source/license/index.html
- https://github.com/libffi/libffi/releases/tag/v3.4.8
- https://github.com/libffi/libffi/blob/v3.4.8/LICENSE
- https://sqlite.org/releaselog/3_50_4.html
- https://sqlite.org/copyright.html
- https://zlib.net/zlib_license.html
