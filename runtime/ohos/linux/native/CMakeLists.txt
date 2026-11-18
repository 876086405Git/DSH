cmake_minimum_required(VERSION 3.16)
project(dsh_linux LANGUAGES C)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "OHOS")
  message(FATAL_ERROR "Use the OH SDK toolchain; Linux host tests use build.py --host-test")
endif()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(DSH_TINYEMU_ARCHIVE "" CACHE FILEPATH "Fixed tinyemu-2019-12-21.tar.gz")
set(DSH_NODE_HEADERS "" CACHE PATH "Node 24.22.1 headers")
set(DSH_NODE_LIBRARY "" CACHE FILEPATH "Renamed signed target libnode.so")
set(DSH_NODE_RENAME_HEADER "" CACHE FILEPATH "Mainline napi-rename.h")
set(DSH_OH_SDK_NATIVE "" CACHE PATH "OH SDK native root")
foreach(input DSH_TINYEMU_ARCHIVE DSH_NODE_HEADERS DSH_NODE_LIBRARY DSH_NODE_RENAME_HEADER DSH_OH_SDK_NATIVE)
  if(NOT EXISTS "${${input}}")
    message(FATAL_ERROR "Missing ${input}")
  endif()
endforeach()
file(GLOB DSH_LINUX_PATCHES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/patches/*.patch")
set(DSH_LINUX_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/generated-linux")
add_custom_command(OUTPUT "${DSH_LINUX_OUTPUT}/libdsh_linux.so"
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${DSH_LINUX_OUTPUT}"
  COMMAND "${Python3_EXECUTABLE}" -I -B "${CMAKE_CURRENT_SOURCE_DIR}/build.py"
    --source-archive "${DSH_TINYEMU_ARCHIVE}" --node-headers "${DSH_NODE_HEADERS}"
    --output "${DSH_LINUX_OUTPUT}" --cc "${CMAKE_C_COMPILER}"
    --sdk-native "${DSH_OH_SDK_NATIVE}" --libnode "${DSH_NODE_LIBRARY}"
    --rename-header "${DSH_NODE_RENAME_HEADER}"
  DEPENDS build.py source-lock.json binding.c embed-fatal.c embed-fatal.h embed-ram.c embed-ram.h fs_export.c fs_export.h temu_embed.h
    ${DSH_LINUX_PATCHES} "${DSH_TINYEMU_ARCHIVE}" "${DSH_NODE_LIBRARY}" "${DSH_NODE_RENAME_HEADER}"
  VERBATIM)
add_custom_target(dsh_linux ALL DEPENDS "${DSH_LINUX_OUTPUT}/libdsh_linux.so")
