cmake_minimum_required(VERSION 3.16)

# OBJCXX is enabled after project() rather than in its LANGUAGES list, because
# APPLE is not defined until project() has run. Asking for Objective-C++ up
# front makes the whole configure fail on Linux, where no such compiler is
# expected to exist.
project(obsbot_bridge LANGUAGES CXX)
if (APPLE)
    enable_language(OBJCXX)
endif()

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
elseif (UNIX)
    # The SDK ships a Linux build alongside the macOS one. Verified on an
    # x86_64 Arch host against a Tiny 2 Lite: libdev discovers the camera,
    # reads its SN and firmware, and drives the gimbal and zoom, all returning
    # rc=0. Discovery takes ~5s, same asynchronous behaviour as macOS.
    if (CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
        set(SDK_LIB_DIR "${SDK_ROOT}/linux/arm64-release")
    else()
        set(SDK_LIB_DIR "${SDK_ROOT}/linux/x86_64-release")
    endif()
    if (NOT EXISTS "${SDK_LIB_DIR}/libdev.so")
        message(FATAL_ERROR
            "No Linux libdev.so at ${SDK_LIB_DIR}.\n"
            "The SDK archive contains linux/, macos/ and windows/ - copy all "
            "of it, not just the macOS slice. See docs/GETTING_THE_SDK.md.")
    endif()
else()
    message(FATAL_ERROR "Unsupported platform: ${CMAKE_SYSTEM_NAME}")
endif()

# crow / asio
find_path(ASIO_INCLUDE_DIR asio.hpp HINTS /opt/homebrew/include /usr/local/include REQUIRED)

# The only platform-specific translation unit. Everything else in this target
# is portable C++ that talks to libdev, Crow and Asio. The capture layer is
# AVFoundation on macOS and V4L2 on Linux; both implement video_capture.h.
if (APPLE)
    set(CAPTURE_SRC src/video_capture.mm)
else()
    set(CAPTURE_SRC src/video_capture_v4l2.cpp)
endif()

# The H.264 remote path is Linux-only, on purpose rather than by omission.
# It exists because a domestic upload link cannot carry the ~80 Mbps the MJPEG
# preview costs at 1080p30. The macOS build is what runs live services with two
# cameras and OBS on the same machine, and an extra encoder is the last thing
# that host needs, so the code is not compiled into it at all.
if (APPLE)
    set(H264_SRC "")
else()
    set(H264_SRC src/h264_stream.cpp)
endif()

add_executable(obsbot-bridge
    src/main.cpp
    src/device_manager.cpp
    src/device_session.cpp
    src/mix_solver.cpp
    src/persist.cpp
    src/ws_server.cpp
    src/protocol.cpp
    src/log.cpp
    ${CAPTURE_SRC}
    ${H264_SRC}
    src/mjpeg_server.cpp
    src/auth.cpp
)

if (APPLE)
    set_source_files_properties(src/video_capture.mm PROPERTIES
        COMPILE_FLAGS "-fobjc-arc"
    )
endif()

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
if (APPLE)
    target_link_libraries(obsbot-bridge PRIVATE dev
        "-framework AVFoundation"
        "-framework VideoToolbox"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework CoreImage"
        "-framework ImageIO"
        "-framework CoreGraphics"
        "-framework Foundation"
        "-framework UniformTypeIdentifiers"
    )
else()
    # V4L2 needs no library beyond libc: it is ioctls on a device node. The
    # nine Apple frameworks above are all capture and JPEG work that the
    # kernel and the camera do for us here, since MJPEG arrives ready-encoded.
    find_package(Threads REQUIRED)
    target_link_libraries(obsbot-bridge PRIVATE dev Threads::Threads)
endif()

target_compile_options(obsbot-bridge PRIVATE
    -Wall -Wno-deprecated-declarations -Wno-switch -Wno-unused-parameter
)

if (APPLE)
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
else()
    set_target_properties(obsbot-bridge PROPERTIES
        INSTALL_RPATH "$ORIGIN"
        BUILD_WITH_INSTALL_RPATH TRUE
    )
    # Same idea as the macOS copy, but ELF needs the SONAME too: the linker
    # records libdev.so.1, so shipping only the libdev.so symlink target would
    # leave the binary unable to resolve it at run time.
    add_custom_command(TARGET obsbot-bridge POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${SDK_LIB_DIR}/libdev.so.1.0.3"
            "$<TARGET_FILE_DIR:obsbot-bridge>/libdev.so.1.0.3"
        COMMAND ${CMAKE_COMMAND} -E create_symlink
            "libdev.so.1.0.3" "$<TARGET_FILE_DIR:obsbot-bridge>/libdev.so.1"
        COMMAND ${CMAKE_COMMAND} -E create_symlink
            "libdev.so.1.0.3" "$<TARGET_FILE_DIR:obsbot-bridge>/libdev.so"
    )
endif()

# Pure-logic unit test for the mix camera-assignment solver. No SDK, no camera,
# no bridge: it is just graph colouring, so it runs anywhere in under a second.
#   cmake --build build --target mix_solver_test && ./build/mix_solver_test
add_executable(mix_solver_test EXCLUDE_FROM_ALL
    src/mix_solver.cpp
    tests/mix_solver_test.cpp
)
target_include_directories(mix_solver_test PRIVATE src)
