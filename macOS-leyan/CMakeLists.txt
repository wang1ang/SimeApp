cmake_minimum_required(VERSION 3.20)
project(LeyanIME LANGUAGES CXX Swift)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Engine dependency ───────────────────────────────────────────────────────

include(${CMAKE_CURRENT_LIST_DIR}/../cmake/SimeEngine.cmake)
set(SIME_ENABLE_NCNN ON CACHE BOOL "Enable the GRU reranker" FORCE)
simeapp_add_engine()

# ── Source files ────────────────────────────────────────────────────────────

set(CXX_SOURCES
    # C API
    api/sime_api.cc
)

set(SWIFT_SOURCES
    sources/Main.swift
    sources/SimeInputController.swift
    sources/SimePanel.swift
    sources/SimeView.swift
)

# ── Bundle target ────────────────────────────────────────────────────────────

add_executable(LeyanIME MACOSX_BUNDLE
    ${CXX_SOURCES}
    ${SWIFT_SOURCES}
)

# Include paths for C++ headers
target_include_directories(LeyanIME PRIVATE
    api
)

# Swift bridging header
set_target_properties(LeyanIME PROPERTIES
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER
        "${CMAKE_CURRENT_SOURCE_DIR}/api/sime_api.h"
    XCODE_ATTRIBUTE_SWIFT_INCLUDE_PATHS
        "${CMAKE_CURRENT_SOURCE_DIR}/api"
    MACOSX_BUNDLE_INFO_PLIST
        "${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist"
    MACOSX_BUNDLE_BUNDLE_NAME "乐言输入法"
    MACOSX_BUNDLE_BUNDLE_VERSION "0.16.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.16.0"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.leyan.inputmethod.LeyanIME"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.leyan.inputmethod.LeyanIME"
)

# Link frameworks
target_link_libraries(LeyanIME PRIVATE
    sime_core
    "-framework InputMethodKit"
    "-framework AppKit"
    "-framework Foundation"
    "-framework Carbon"
)

# C++20 and warnings
target_compile_options(LeyanIME PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:
        -Wall -Wextra -pedantic -Wconversion
    >
)

# ── Install ──────────────────────────────────────────────────────────────────

install(TARGETS LeyanIME
    BUNDLE DESTINATION "/Library/Input Methods"
)

# After install, register the input source:
#   /System/Library/CoreServices/InputMethodKit.framework/Versions/A/Resources/\
#     build_tools/imklaunchagent -r com.leyan.inputmethod.LeyanIME
# Then log out and back in, or:
#   sudo killall cfprefsd; sudo killall UserEventAgent
