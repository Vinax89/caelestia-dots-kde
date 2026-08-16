cmake_minimum_required(VERSION 3.16)
project(CaelestiaInstaller CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED True)

# Use ccache if available for dramatically faster rebuilds
find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
    set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
    message(STATUS "ccache found — compiler caching enabled")
endif()

# Set compile flags.
#
# This binary reads the user's sudo password and executes privileged shell
# stages, so it is built with the usual exploit-mitigation set rather than a
# bare -O2. Warnings are on because they were off: a literal "\\n" in a fatal
# error message shipped undetected, and the signed/unsigned comparisons below
# were never surfaced.
set(CMAKE_CXX_FLAGS_RELEASE "-O2")

add_compile_options(
    -Wall
    -Wextra
    -Wno-unused-parameter
    -fstack-protector-strong
    -fPIE
)
add_compile_definitions($<$<NOT:$<CONFIG:Debug>>:_FORTIFY_SOURCE=2>)
add_link_options(-pie -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack)

set(SOURCES
    src/Draw.cpp
    src/Globals.cpp
    src/Input.cpp
    src/main.cpp
    src/Runner.cpp
    src/Term.cpp
    src/UI.cpp
)
include_directories(src)

# Define executable
add_executable(caelestia-install ${SOURCES})
