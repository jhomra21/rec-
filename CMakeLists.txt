cmake_minimum_required(VERSION 3.22)
project(rec VERSION 0.1.0 LANGUAGES CXX)

add_library(rec STATIC)
target_compile_features(rec PUBLIC cxx_std_20)
target_include_directories(rec PUBLIC "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>" "$<INSTALL_INTERFACE:include>")

if(APPLE)
    enable_language(OBJCXX)
    target_sources(rec PRIVATE src/platform/macos/recorder.mm)
    set_source_files_properties(src/platform/macos/recorder.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_compile_definitions(rec PRIVATE GL_SILENCE_DEPRECATION)
    target_link_libraries(rec PUBLIC
        "-framework Foundation" "-framework ScreenCaptureKit" "-framework AVFoundation"
        "-framework CoreMedia" "-framework CoreVideo" "-framework CoreGraphics"
        "-framework VideoToolbox" "-framework AudioToolbox" "-framework CoreAudio")
else()
    target_sources(rec PRIVATE src/platform/unsupported.cpp)
endif()

add_executable(rec-cli src/main.cpp)
target_link_libraries(rec-cli PRIVATE rec)
set_target_properties(rec-cli PROPERTIES OUTPUT_NAME rec)
if(APPLE)
    # Privacy prompts read usage descriptions from the executable's embedded Info.plist.
    target_link_options(rec-cli PRIVATE
        "LINKER:-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_SOURCE_DIR}/support/Info.plist")
    set_property(TARGET rec-cli APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/support/Info.plist")
endif()

install(TARGETS rec rec-cli EXPORT recTargets)
install(DIRECTORY include/ DESTINATION include)
