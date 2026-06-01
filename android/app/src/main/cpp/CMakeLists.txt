cmake_minimum_required(VERSION 3.22)
project(vmxjni)

add_library(vmxjni SHARED vmx_jni.cpp)

# libvmx.so is a prebuilt ARM64 library in jniLibs/arm64-v8a
add_library(vmx SHARED IMPORTED)
set_target_properties(vmx PROPERTIES IMPORTED_LOCATION
    ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libvmx.so)

target_link_libraries(vmxjni
    vmx
    android
    log)
