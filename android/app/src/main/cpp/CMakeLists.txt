cmake_minimum_required(VERSION 3.22)
project(vmxjni)

# vmx_jni.cpp loads libvmx.so at runtime via dlopen() — see loadVmx().
# We must NOT link against libvmx.so at build time: an IMPORTED target with an
# absolute IMPORTED_LOCATION bakes the build-server path into libvmxjni.so's
# DT_NEEDED, so the Android loader looks for the .so at that nonexistent path
# on the phone (UnsatisfiedLinkError). dlopen("libvmx.so") finds it inside the
# APK's lib/arm64-v8a/ at runtime because gradle packages everything under
# jniLibs/ automatically — no link-time reference required.
add_library(vmxjni SHARED vmx_jni.cpp)

target_link_libraries(vmxjni
    android
    log
    dl)   # dlopen / dlsym / dlerror
