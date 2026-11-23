# cmake/Fable2Ps5.cmake
# PlayStation 5 homebrew title build, with the PS5 payload SDK's toolchain
# (toolchain/prospero.cmake) and Mihawk's PS5_Vulkan (RADV linked into the
# title). Modelled on re:Blue PS5's cmake/RebluePs5.cmake. See docs/PS5.md.
#
#   FABLE2_PS5_VULKAN_DIR   PS5_Vulkan checkout with its RADV release archive
#   FABLE2_PS5_TITLE_ID     PPSAxxxxx title id written to sce_sys/param.json
#   REXSDK_DIR              the ReXGlue SDK tree with its PS5 changes
#                           (thirdparty/rexglue-sdk, branch fable2-ps5)
#   REXGLUE_HOST_TOOL       host rexglue from that tree (runs codegen)
#
# Unlike re:Blue, Fable 2 renders through the SDK's Xenos GPU (Vulkan), which
# translates the game's shaders at run time: there is no host shader step.

set(CMAKE_CXX_SCAN_FOR_MODULES OFF)

# The console's CPU is an 8-core Zen 2.
add_compile_options(-march=znver2)

get_filename_component(_fable2_ps5_parent "${CMAKE_SOURCE_DIR}/.." ABSOLUTE)
set(FABLE2_PS5_VULKAN_DIR "${_fable2_ps5_parent}/PS5_Vulkan" CACHE PATH "PS5_Vulkan checkout (RADV for the console)")
set(FABLE2_PS5_TITLE_ID "PPSA99214" CACHE STRING "Title id of the PS5 homebrew title")
set(FABLE2_PS5_TITLE_NAME "Fable II" CACHE STRING "Home screen name of the PS5 homebrew title")
set(FABLE2_PS5_DIST_DIR "${CMAKE_BINARY_DIR}/dist" CACHE PATH "Where the title folder <TITLE_ID>/ is written")

if(NOT EXISTS "${FABLE2_PS5_VULKAN_DIR}/.deps/native/radv-release/lib/libvulkan_radeon.ps5.a")
    message(WARNING "No RADV release archive in ${FABLE2_PS5_VULKAN_DIR}; the title link will fail. "
        "Build it with PS5_Vulkan's tools/build-radv.sh release (docs/PS5.md).")
endif()

# Every executable is linked as a PS5 title by ps5/link-title.sh, which gets
# CMake's objects and fully resolved static libraries and runs PS5_Vulkan's
# link recipe (RADV, the SDK's platform layer, the CRT, the fake SELF).
set(_fable2_ps5_link_config "${CMAKE_BINARY_DIR}/ps5-link.conf")
file(WRITE "${_fable2_ps5_link_config}"
    "vulkan='${FABLE2_PS5_VULKAN_DIR}'\n"
    "sdk='${PS5_PAYLOAD_SDK}'\n"
    "title_id='${FABLE2_PS5_TITLE_ID}'\n"
    "title_name='${FABLE2_PS5_TITLE_NAME}'\n"
    "dist='${FABLE2_PS5_DIST_DIR}'\n"
    "param_template='${CMAKE_SOURCE_DIR}/ps5/sce_sys/param.json'\n"
    "icon='${CMAKE_SOURCE_DIR}/ps5/sce_sys/icon0.png'\n"
    "env_example='${CMAKE_SOURCE_DIR}/ps5/ps5-env.example.txt'\n"
    "config_template='${CMAKE_SOURCE_DIR}/config/fable2_config.toml'\n"
    "work='${CMAKE_BINARY_DIR}/ps5-link'\n")
set(CMAKE_CXX_LINK_EXECUTABLE
    "bash \"${CMAKE_SOURCE_DIR}/ps5/link-title.sh\" \"${_fable2_ps5_link_config}\" <TARGET> <OBJECTS> <LINK_LIBRARIES>")
set(CMAKE_C_LINK_EXECUTABLE "${CMAKE_CXX_LINK_EXECUTABLE}")
