cmake_minimum_required(VERSION 3.16)
project(dsh_host LANGUAGES CXX)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "OHOS")
  message(FATAL_ERROR "Use the OpenHarmony native SDK for the Ark module; desktop tests have a separate harness")
endif()
if(DEFINED PACKAGE_FIND_FILE)
  include(${PACKAGE_FIND_FILE})
endif()
find_package(Threads REQUIRED)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
get_filename_component(DSH_REPOSITORY "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../.." ABSOLUTE)
set(DSH_NODE_LIBRARY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a"
    CACHE PATH "Packaged libnode.so, which holds the embedded runner")
set(DSH_NODE_HEADERS "$ENV{DSH_NODE_HEADERS}" CACHE PATH "Pinned Node 24.22.1 include/node or source src directory")
set(DSH_NODE_NAPI_RENAME_HEADER "${DSH_REPOSITORY}/runtime/ohos/node/napi-rename.h"
    CACHE FILEPATH "Mainline-generated Node N-API rename header; verification input only")
if(NOT CMAKE_READELF)
  find_program(CMAKE_READELF NAMES llvm-readelf readelf HINTS "${OHOS_SDK_NATIVE}/llvm/bin")
endif()
if(NOT CMAKE_READELF OR NOT EXISTS "${DSH_NODE_LIBRARY_DIR}/libnode.so")
  message(FATAL_ERROR "Supply readelf and the separately built libnode in entry/libs/arm64-v8a")
endif()
set(DSH_NAPI_VERIFY "${DSH_REPOSITORY}/runtime/ohos/host/napi_isolation.py")
set(DSH_NAPI_INPUTS --node-headers "${DSH_NODE_HEADERS}"
    --rename-header "${DSH_NODE_NAPI_RENAME_HEADER}"
    --libnode "${DSH_NODE_LIBRARY_DIR}/libnode.so" --readelf "${CMAKE_READELF}")
execute_process(COMMAND "${Python3_EXECUTABLE}" "${DSH_NAPI_VERIFY}" ${DSH_NAPI_INPUTS}
    RESULT_VARIABLE DSH_NAPI_RESULT)
if(NOT DSH_NAPI_RESULT EQUAL 0)
  message(FATAL_ERROR "The supplied libnode/header failed the N-API ownership gate")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${DSH_NAPI_VERIFY}" "${DSH_NODE_NAPI_RENAME_HEADER}"
    "${DSH_NODE_LIBRARY_DIR}/libnode.so")
add_library(dsh_node SHARED IMPORTED)
set_target_properties(dsh_node PROPERTIES IMPORTED_LOCATION "${DSH_NODE_LIBRARY_DIR}/libnode.so")
add_library(dsh_host SHARED host_core.cpp napi_host.cpp)
target_compile_features(dsh_host PRIVATE cxx_std_17)
target_compile_options(dsh_host PRIVATE -fvisibility=hidden -fexceptions -frtti)
target_link_libraries(dsh_host PRIVATE libace_napi.z.so libhilog_ndk.z.so Threads::Threads dsh_node)
# The HAP loads from its own library directory; a build-tree RUNPATH would leak the host's paths.
set_target_properties(dsh_host PROPERTIES SKIP_BUILD_RPATH ON)
target_link_options(dsh_host PRIVATE -Wl,-z,defs -Wl,-z,nodelete)
# No Node include path or rename -include is present in this Ark target.
add_custom_command(TARGET dsh_host POST_BUILD
  COMMAND "${Python3_EXECUTABLE}" "${DSH_NAPI_VERIFY}" ${DSH_NAPI_INPUTS}
          --role ark --consumer "$<TARGET_FILE:dsh_host>"
          --report "${CMAKE_CURRENT_BINARY_DIR}/napi-isolation.json"
  VERBATIM)
