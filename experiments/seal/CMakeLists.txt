cmake_minimum_required(VERSION 3.13)
project(bench_seal LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# Looks for the SEAL install registered by `cmake --install` when you built
# SEAL natively (Phase 3). If it's not found, pass its location explicitly:
#   cmake .. -DCMAKE_PREFIX_PATH=/path/to/seal/install
find_package(SEAL 4.1 REQUIRED)

add_executable(bench_seal src/bench_seal.cpp)
target_link_libraries(bench_seal PRIVATE SEAL::seal)
