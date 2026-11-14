cmake_minimum_required(VERSION 3.20)
# Only the three NDK C objects use the SDK's language toolchain. Node C++
# compilation and final linking below use an explicitly verified driver.
project(dsh_image_codec LANGUAGES C)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "OHOS" OR
   NOT OHOS_ARCH STREQUAL "arm64-v8a" OR
   NOT OHOS_STL STREQUAL "c++_static")
  message(FATAL_ERROR "Use the OH SDK toolchain, OHOS_ARCH=arm64-v8a and OHOS_STL=c++_static")
endif()
if(NOT CMAKE_GENERATOR STREQUAL "Ninja")
  message(FATAL_ERROR "This recipe requires Ninja")
endif()
if(NOT CMAKE_C_COMPILER_ID STREQUAL "Clang" OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "The SDK must provide the 64-bit Clang C compiler")
endif()

get_filename_component(_repository "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(DSH_REPOSITORY "${_repository}" CACHE PATH "Repository containing the unchanged N-API verifier and rename header")
set(DSH_OHOS_SDK_NATIVE "" CACHE PATH "Complete SDK 26.0.0.38 native directory")
set(DSH_NODE_HEADERS "" CACHE PATH "Exact Node 24.22.1 include/node directory")
set(DSH_NODE_LIBRARY "" CACHE FILEPATH "Actual isolated OH arm64 libnode.so used by this app")
set(DSH_NODE_BUILD_JSON "" CACHE FILEPATH "Matching build-node.py build.json for the exact libnode")
set(DSH_NODE_CXX_DRIVER "" CACHE FILEPATH "Actual clang++ executable matching the compiler hash in both build records")
set(DSH_NODE_CXX_RUNTIME "" CACHE PATH "Matching build-runtimes.py output with runtimes.json, headers, static libraries and CRT")
set(DSH_NODE_NAPI_RENAME_HEADER "${DSH_REPOSITORY}/runtime/ohos/node/napi-rename.h"
    CACHE FILEPATH "Complete, unchanged Node API rename header")
set(DSH_IMAGE_SOURCE_LIBRARY "" CACHE FILEPATH "SDK arm64 libimage_source.so")
set(DSH_IMAGE_PIXELMAP_LIBRARY "" CACHE FILEPATH "SDK arm64 libpixelmap.so")
set(DSH_IMAGE_PACKER_LIBRARY "" CACHE FILEPATH "SDK arm64 libimage_packer.so")
set(DSH_IMAGE_COLORSPACE_LIBRARY "" CACHE FILEPATH "SDK arm64 libnative_color_space_manager.so")
# Arbitrary flags cannot establish the compiler/runtime relationship. v2 derives
# the target, resource, C++ include and static-link options from verified inputs.
foreach(_old DSH_NODE_CXX_OPTIONS DSH_NODE_LINK_OPTIONS)
  if(DEFINED ${_old} AND NOT "${${_old}}" STREQUAL "")
    message(FATAL_ERROR "${_old} is not supported by recipe v2; supply the paired driver/runtime/build record")
  endif()
endforeach()
set(DSH_IMAGE_DESTROY_COLORSPACE_GETTER "1" CACHE STRING "Compile-time getter policy: 1 destroy, 0 borrow")
set_property(CACHE DSH_IMAGE_DESTROY_COLORSPACE_GETTER PROPERTY STRINGS 1 0)
if(NOT DSH_IMAGE_DESTROY_COLORSPACE_GETTER MATCHES "^[01]$")
  message(FATAL_ERROR "DSH_IMAGE_DESTROY_COLORSPACE_GETTER must be 0 or 1")
endif()
if(DEFINED DSH_IMAGE_CONFIGURED_GETTER AND
   NOT DSH_IMAGE_CONFIGURED_GETTER STREQUAL DSH_IMAGE_DESTROY_COLORSPACE_GETTER)
  message(FATAL_ERROR "Getter policy changes require a separate build directory")
endif()
set(DSH_IMAGE_CONFIGURED_GETTER "${DSH_IMAGE_DESTROY_COLORSPACE_GETTER}" CACHE INTERNAL "This build directory's getter policy" FORCE)

foreach(_required DSH_OHOS_SDK_NATIVE DSH_NODE_HEADERS DSH_NODE_LIBRARY
                  DSH_NODE_BUILD_JSON DSH_NODE_CXX_DRIVER DSH_NODE_CXX_RUNTIME
                  DSH_NODE_NAPI_RENAME_HEADER DSH_IMAGE_SOURCE_LIBRARY
                  DSH_IMAGE_PIXELMAP_LIBRARY DSH_IMAGE_PACKER_LIBRARY
                  DSH_IMAGE_COLORSPACE_LIBRARY)
  if(NOT IS_ABSOLUTE "${${_required}}" OR NOT EXISTS "${${_required}}")
    message(FATAL_ERROR "${_required} must name an existing absolute input")
  endif()
endforeach()
get_filename_component(_sdk "${DSH_OHOS_SDK_NATIVE}" REALPATH)
get_filename_component(_sysroot "${CMAKE_SYSROOT}" REALPATH)
if(NOT _sysroot STREQUAL "${_sdk}/sysroot")
  message(FATAL_ERROR "CMAKE_SYSROOT must be the explicitly supplied SDK's sysroot")
endif()
get_filename_component(_toolchain "${CMAKE_TOOLCHAIN_FILE}" REALPATH)
get_filename_component(_expected_toolchain "${_sdk}/build/cmake/ohos.toolchain.cmake" REALPATH)
if(NOT _toolchain STREQUAL _expected_toolchain)
  message(FATAL_ERROR "The toolchain file must belong to the explicitly supplied SDK")
endif()
get_filename_component(_c_compiler_path "${CMAKE_C_COMPILER}" REALPATH)
file(RELATIVE_PATH _c_compiler_relative "${_sdk}/llvm/bin" "${_c_compiler_path}")
if(IS_ABSOLUTE "${_c_compiler_relative}" OR _c_compiler_relative MATCHES "^\\.\\.")
  message(FATAL_ERROR "The NDK C compiler must come from this SDK's llvm/bin")
endif()
# Node's independent driver is deliberately NOT constrained to the SDK bin.
# Do not put the Node rename or host-fixture selection into global C flags.
foreach(_flags CMAKE_C_FLAGS CMAKE_C_FLAGS_DEBUG CMAKE_C_FLAGS_RELEASE
               CMAKE_C_FLAGS_RELWITHDEBINFO CMAKE_C_FLAGS_MINSIZEREL)
  if("${${_flags}}" MATCHES "napi-rename|DSH_IMAGE_HOST_FIXTURE|NAPI_VERSION")
    message(FATAL_ERROR "${_flags} contains a Node/fixture option")
  endif()
endforeach()

find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(_readelf "${_sdk}/llvm/bin/llvm-readelf")
set(_verify "${CMAKE_CURRENT_LIST_DIR}/verify-build.py")
set(_isolation "${DSH_REPOSITORY}/runtime/ohos/host/napi_isolation.py")
get_filename_component(_runtime "${DSH_NODE_CXX_RUNTIME}" REALPATH)
set(_runtime_record "${_runtime}/runtimes.json")
set(_runtime_libs
  "${_runtime}/lib/libc++.a" "${_runtime}/lib/libc++abi.a" "${_runtime}/lib/libunwind.a"
  "${_runtime}/clang-resource/lib/aarch64-linux-ohos/libclang_rt.builtins.a"
  "${_runtime}/clang-resource/lib/aarch64-linux-ohos/clang_rt.crtbegin.o"
  "${_runtime}/clang-resource/lib/aarch64-linux-ohos/clang_rt.crtend.o")
set(_common
    --sdk-native "${_sdk}" --node-headers "${DSH_NODE_HEADERS}"
    --rename-header "${DSH_NODE_NAPI_RENAME_HEADER}" --libnode "${DSH_NODE_LIBRARY}"
    --node-build-json "${DSH_NODE_BUILD_JSON}" --node-cxx-driver "${DSH_NODE_CXX_DRIVER}"
    --node-cxx-runtime "${_runtime}" --sdk-c-compiler "${CMAKE_C_COMPILER}"
    --readelf "${_readelf}" --isolation-verifier "${_isolation}"
    --image-source "${DSH_IMAGE_SOURCE_LIBRARY}" --pixelmap "${DSH_IMAGE_PIXELMAP_LIBRARY}"
    --image-packer "${DSH_IMAGE_PACKER_LIBRARY}" --color-space "${DSH_IMAGE_COLORSPACE_LIBRARY}"
    --getter-policy "${DSH_IMAGE_DESTROY_COLORSPACE_GETTER}")
set(_input_report "${CMAKE_CURRENT_BINARY_DIR}/image-build-inputs.json")
execute_process(
  COMMAND "${Python3_EXECUTABLE}" -I -B "${_verify}" ${_common} --report "${_input_report}"
  RESULT_VARIABLE _input_result OUTPUT_VARIABLE _input_output ERROR_VARIABLE _input_error)
if(NOT _input_result EQUAL 0)
  message(FATAL_ERROR "Image build input verification failed:\n${_input_output}${_input_error}")
endif()

foreach(_source addon.cc codec_bridge.h codec_ndk.c container_facts.c container_facts.h
                 encoding_ladder.c encoding_ladder.h exports.map)
  if(NOT EXISTS "${CMAKE_CURRENT_LIST_DIR}/${_source}")
    message(FATAL_ERROR "Missing exact image dependency: ${_source}")
  endif()
endforeach()
set(_input_dependencies
  "${_verify}" "${_isolation}" "${DSH_NODE_NAPI_RENAME_HEADER}"
  "${DSH_NODE_HEADERS}/node_version.h" "${DSH_NODE_HEADERS}/node_api.h"
  "${DSH_NODE_HEADERS}/js_native_api.h" "${DSH_NODE_HEADERS}/node_api_types.h"
  "${DSH_NODE_HEADERS}/js_native_api_types.h" "${DSH_NODE_LIBRARY}"
  "${DSH_NODE_BUILD_JSON}" "${DSH_NODE_CXX_DRIVER}" "${_runtime_record}" ${_runtime_libs}
  "${_runtime}/include/c++/v1/__config" "${_runtime}/include/c++/v1/__config_site"
  "${_sdk}/oh-uni-package.json" "${_sdk}/llvm/bin/ld.lld"
  "${DSH_IMAGE_SOURCE_LIBRARY}" "${DSH_IMAGE_PIXELMAP_LIBRARY}"
  "${DSH_IMAGE_PACKER_LIBRARY}" "${DSH_IMAGE_COLORSPACE_LIBRARY}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${_input_dependencies})

# SDK C environment only. No Node include directory, forced rename, fake
# backend or C++ object is introduced into these translation units.
add_library(dsh_image_ndk OBJECT codec_ndk.c container_facts.c encoding_ladder.c)
set_target_properties(dsh_image_ndk PROPERTIES POSITION_INDEPENDENT_CODE ON
  C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF C_VISIBILITY_PRESET hidden)
target_include_directories(dsh_image_ndk PRIVATE "${CMAKE_CURRENT_LIST_DIR}")
target_compile_definitions(dsh_image_ndk PRIVATE
  DSH_IMAGE_DESTROY_COLORSPACE_GETTER=${DSH_IMAGE_DESTROY_COLORSPACE_GETTER})

# Mirror the fixed build-hap-libs.py / build-loader.py input model. CMake's
# SDK CXX compiler and link rules are never used for this Node target.
set(_node_common "${DSH_NODE_CXX_DRIVER}" --target=aarch64-linux-ohos
  "--sysroot=${_sdk}/sysroot" "-resource-dir=${_runtime}/clang-resource"
  -stdlib=libc++ "-stdlib++-isystem${_runtime}/include/c++/v1")
set(_node_object "${CMAKE_CURRENT_BINARY_DIR}/image-node-addon.o")
set(_node_depfile "${CMAKE_CURRENT_BINARY_DIR}/image-node-addon.d")
add_custom_command(OUTPUT "${_node_object}"
  COMMAND ${_node_common} -std=c++17 -O2 -g0 -fPIC -pthread -fexceptions
          -fvisibility=hidden -fvisibility-inlines-hidden -D__MUSL__=1 -DNAPI_VERSION=8
          -include "${DSH_NODE_NAPI_RENAME_HEADER}"
          -I "${DSH_NODE_HEADERS}" -I "${CMAKE_CURRENT_LIST_DIR}"
          -MD -MF "${_node_depfile}" -MT "${_node_object}"
          -c "${CMAKE_CURRENT_LIST_DIR}/addon.cc" -o "${_node_object}"
  DEPENDS "${CMAKE_CURRENT_LIST_DIR}/addon.cc" "${CMAKE_CURRENT_LIST_DIR}/codec_bridge.h"
          ${_input_dependencies}
  DEPFILE "${_node_depfile}"
  COMMAND_EXPAND_LISTS VERBATIM)

set(_image_library "${CMAKE_CURRENT_BINARY_DIR}/libdsh_image_codec.so")
set(_elf_report "${CMAKE_CURRENT_BINARY_DIR}/image-build-elf.json")
set(_complete "${CMAKE_CURRENT_BINARY_DIR}/image-build-complete.stamp")
get_filename_component(_node_library_directory "${DSH_NODE_LIBRARY}" DIRECTORY)
# The stamp is written only after the post-link checks succeed. A leftover
# .so from a failed linker/audit is not a completed build target.
add_custom_command(OUTPUT "${_complete}"
  BYPRODUCTS "${_image_library}" "${_elf_report}"
  COMMAND ${_node_common} -shared -fPIC -pthread
          "${_node_object}" $<TARGET_OBJECTS:dsh_image_ndk>
          "${DSH_IMAGE_SOURCE_LIBRARY}" "${DSH_IMAGE_PIXELMAP_LIBRARY}"
          "${DSH_IMAGE_PACKER_LIBRARY}" "${DSH_IMAGE_COLORSPACE_LIBRARY}"
          "${DSH_NODE_LIBRARY}" -ldl
          "-L${_runtime}/lib" -static-libstdc++ "--ld-path=${_sdk}/llvm/bin/ld.lld"
          "-Wl,-rpath-link,${_node_library_directory}"
          -Wl,-z,defs -Wl,--exclude-libs,ALL -Wl,-soname,libdsh_image_codec.so
          "-Wl,--version-script=${CMAKE_CURRENT_LIST_DIR}/exports.map"
          -o "${_image_library}"
  COMMAND "${Python3_EXECUTABLE}" -I -B "${_verify}" ${_common}
          --baseline-inputs "${_input_report}" --consumer "${_image_library}" --report "${_elf_report}"
  COMMAND "${CMAKE_COMMAND}" -E touch "${_complete}"
  DEPENDS "${_node_object}" dsh_image_ndk $<TARGET_OBJECTS:dsh_image_ndk>
          "${CMAKE_CURRENT_LIST_DIR}/exports.map" ${_input_dependencies}
  COMMAND_EXPAND_LISTS VERBATIM)
add_custom_target(dsh_image_codec ALL DEPENDS "${_complete}")
