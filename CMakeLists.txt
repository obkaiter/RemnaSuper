cmake_minimum_required(VERSION 3.18)
project(RemnaSuperTui LANGUAGES CXX)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "RemnaSuper TUI requires Linux")
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(CURSES REQUIRED IMPORTED_TARGET ncursesw panelw menuw formw)
pkg_check_modules(VTERM REQUIRED IMPORTED_TARGET vterm>=0.1.4)
find_package(nlohmann_json 3.10.5 REQUIRED)
find_library(UTIL_LIBRARY util REQUIRED)

file(STRINGS VERSION REMNASUPER_VERSION LIMIT_COUNT 1)
if(NOT REMNASUPER_VERSION MATCHES "^[0-9]+(\\.[0-9]+)+$")
    message(FATAL_ERROR "Invalid VERSION")
endif()

add_executable(remnasuper-tui
    src/main.cpp
    src/terminal.cpp
    src/jobs.cpp
)
target_compile_features(remnasuper-tui PRIVATE cxx_std_17)
target_compile_definitions(remnasuper-tui PRIVATE REMNASUPER_VERSION="${REMNASUPER_VERSION}")
target_compile_options(remnasuper-tui PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(remnasuper-tui PRIVATE PkgConfig::CURSES PkgConfig::VTERM nlohmann_json::nlohmann_json "${UTIL_LIBRARY}")

option(REMNASUPER_SANITIZERS "Enable address and undefined behavior sanitizers" OFF)
if(REMNASUPER_SANITIZERS)
    target_compile_options(remnasuper-tui PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
    target_link_options(remnasuper-tui PRIVATE -fsanitize=address,undefined)
endif()

install(TARGETS remnasuper-tui DESTINATION bin)
