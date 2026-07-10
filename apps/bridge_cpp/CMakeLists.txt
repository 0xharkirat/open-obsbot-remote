cmake_minimum_required(VERSION 3.16)
project(obsbot_bridge LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# OBSBOT SDK lives outside this app (gitignored). User fetches separately.
# See docs/GETTING_THE_SDK.md
set(SDK_ROOT "${CMAKE_SOURCE_DIR}/../../third_party/obsbot-sdk")
if (NOT EXISTS "${SDK_ROOT}/include/dev/dev.hpp")
    message(FATAL_ERROR
        "OBSBOT SDK not found at ${SDK_ROOT}.\n"
        "See docs/GETTING_THE_SDK.md for how to obtain it.")
endif()
set(SDK_INCLUDE "${SDK_ROOT}/include")
if (APPLE)
    # Prefer a hand-lipo'd universal libdev when the release build has
    # staged one (see scripts/build-bridge-mac.sh). Falls back to the
    # single-arch slices shipped by the SDK for dev builds where a
    # specific arch is targeted.
    if (EXISTS "${SDK_ROOT}/macos/universal-release/libdev.dylib")
        set(SDK_LIB_DIR "${SDK_ROOT}/macos/universal-release")
    elseif (CMAKE_OSX_ARCHITECTURES MATCHES "x86_64" AND NOT CMAKE_OSX_ARCHITECTURES MATCHES "arm64")
        set(SDK_LIB_DIR "${SDK_ROOT}/macos/x86_64-release")
    else()
        set(SDK_LIB_DIR "${SDK_ROOT}/macos/arm64-release")
    endif()
else()
    message(FATAL_ERROR "MVP supports macOS only")
endif()

# crow / asio
find_path(ASIO_INCLUDE_DIR asio.hpp HINTS /opt/homebrew/include /usr/local/include REQUIRED)

add_executable(obsbot-bridge
    src/main.cpp
    src/device_manager.cpp
    src/device_session.cpp
    src/persist.cpp
    src/ws_server.cpp
    src/protocol.cpp
    src/log.cpp
    src/video_capture.mm
    src/mjpeg_server.cpp
    src/auth.cpp
)

set_source_files_properties(src/video_capture.mm PROPERTIES
    COMPILE_FLAGS "-fobjc-arc"
)

target_compile_definitions(obsbot-bridge PRIVATE
    ASIO_STANDALONE
    CROW_DISABLE_STATIC_DIR
)

target_include_directories(obsbot-bridge PRIVATE
    ${SDK_INCLUDE}
    ${ASIO_INCLUDE_DIR}
    ${CMAKE_SOURCE_DIR}/third_party
    ${CMAKE_SOURCE_DIR}/src
)

target_link_directories(obsbot-bridge PRIVATE ${SDK_LIB_DIR})
target_link_libraries(obsbot-bridge PRIVATE dev
    "-framework AVFoundation"
    "-framework CoreMedia"
    "-framework CoreVideo"
    "-framework CoreImage"
    "-framework ImageIO"
    "-framework CoreGraphics"
    "-framework Foundation"
    "-framework UniformTypeIdentifiers"
)

target_compile_options(obsbot-bridge PRIVATE
    -Wall -Wno-deprecated-declarations -Wno-switch -Wno-unused-parameter
)

set_target_properties(obsbot-bridge PROPERTIES
    INSTALL_RPATH "@executable_path"
    BUILD_WITH_INSTALL_RPATH TRUE
)

# copy libdev.dylib next to binary so it loads
add_custom_command(TARGET obsbot-bridge POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${SDK_LIB_DIR}/libdev.dylib"
        "$<TARGET_FILE_DIR:obsbot-bridge>/libdev.dylib"
)
