// =============================================================================
// VortexCam — VMX JNI bridge
// Wraps libvmx.so for NV12 → VMX encoding on Android ARM64.
// Called from OmtStreamPlugin.kt via System.loadLibrary("vmxjni").
// =============================================================================

#include <jni.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdlib>
#include <android/log.h>

#define LOG_TAG "VortexCam/VMX"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ---------------------------------------------------------------------------
// VMX ABI (matches vmxcodec.h from Open Media Transport)
// ---------------------------------------------------------------------------
struct VMX_SIZE   { int Width; int Height; };
enum VMX_PROFILE  { VMX_OMT_LQ=133, VMX_OMT_SQ=166, VMX_OMT_HQ=199 };
enum VMX_COLORSPACE { VMX_CS_BT601=601, VMX_CS_BT709=709 };
enum VMX_ERR      { VMX_OK=0 };
using BYTE = unsigned char;

using FnCreate    = void*(*)(VMX_SIZE, int, int);
using FnDestroy   = void(*)(void*);
using FnEncNV12   = int (*)(void*, BYTE*, int, BYTE*, int, int);
using FnSaveTo    = int (*)(void*, BYTE*, int);
using FnSetQ      = void(*)(void*, int);
using FnSetThrd   = void(*)(void*, int);

static void*       sVmxLib      = nullptr;
static FnCreate    sCreate      = nullptr;
static FnDestroy   sDestroy     = nullptr;
static FnEncNV12   sEncNV12     = nullptr;
static FnSaveTo    sSaveTo      = nullptr;
static FnSetQ      sSetQ        = nullptr;
static FnSetThrd   sSetThrd     = nullptr;

static bool loadVmx() {
    if (sVmxLib) return true;
    sVmxLib = dlopen("libvmx.so", RTLD_LAZY);
    if (!sVmxLib) { LOGE("dlopen libvmx.so failed: %s", dlerror()); return false; }
    sCreate  = (FnCreate)  dlsym(sVmxLib, "VMX_Create");
    sDestroy = (FnDestroy) dlsym(sVmxLib, "VMX_Destroy");
    sEncNV12 = (FnEncNV12) dlsym(sVmxLib, "VMX_EncodeNV12");
    sSaveTo  = (FnSaveTo)  dlsym(sVmxLib, "VMX_SaveTo");
    sSetQ    = (FnSetQ)    dlsym(sVmxLib, "VMX_SetQuality");
    sSetThrd = (FnSetThrd) dlsym(sVmxLib, "VMX_SetThreads");
    if (!sCreate || !sDestroy || !sEncNV12 || !sSaveTo) {
        LOGE("libvmx.so missing required symbols"); dlclose(sVmxLib); sVmxLib = nullptr; return false;
    }
    LOGI("libvmx.so loaded OK");
    return true;
}

// ---------------------------------------------------------------------------
// JNI exports — called from OmtStreamPlugin.kt
// ---------------------------------------------------------------------------
extern "C" {

// Returns native handle (Long) to a VMX encoder instance.
// quality: 0=Low, 1=Medium, 2=High  colorSpace: 601 or 709
JNIEXPORT jlong JNICALL
Java_com_vortex_vortexcam_OmtStreamPlugin_nativeCreateEncoder(
        JNIEnv*, jclass, jint width, jint height, jint quality, jint colorSpace) {
    if (!loadVmx()) return 0;
    VMX_SIZE sz{width, height};
    int profile = (quality == 0) ? VMX_OMT_LQ : (quality == 1) ? VMX_OMT_SQ : VMX_OMT_HQ;
    int cs      = (colorSpace == 601) ? VMX_CS_BT601 : VMX_CS_BT709;
    void* inst  = sCreate(sz, profile, cs);
    if (!inst) { LOGE("VMX_Create failed"); return 0; }
    if (sSetThrd) sSetThrd(inst, 4);  // use 4 threads on phone
    LOGI("VMX encoder created: %dx%d profile=%d", width, height, profile);
    return (jlong)(intptr_t)inst;
}

JNIEXPORT void JNICALL
Java_com_vortex_vortexcam_OmtStreamPlugin_nativeDestroyEncoder(
        JNIEnv*, jclass, jlong handle) {
    if (sDestroy && handle) sDestroy((void*)(intptr_t)handle);
}

// Encodes one NV12 frame to VMX.
// yPlane / uvPlane: direct ByteBuffers from ImageReader.
// Returns encoded VMX data as byte[] or null on error.
JNIEXPORT jbyteArray JNICALL
Java_com_vortex_vortexcam_OmtStreamPlugin_nativeEncodeNV12(
        JNIEnv* env, jclass,
        jlong handle,
        jobject yBuf, jint yStride,
        jobject uvBuf, jint uvStride)
{
    if (!handle || !sEncNV12 || !sSaveTo) return nullptr;
    void* inst = (void*)(intptr_t)handle;

    auto* yPtr  = (BYTE*)env->GetDirectBufferAddress(yBuf);
    auto* uvPtr = (BYTE*)env->GetDirectBufferAddress(uvBuf);
    if (!yPtr || !uvPtr) return nullptr;

    int err = sEncNV12(inst, yPtr, yStride, uvPtr, uvStride, 0 /*progressive*/);
    if (err != VMX_OK) return nullptr;

    // Get maximum encoded size (VMX is intra, ~width*height*2 is safe upper bound)
    // We allocate a generous buffer; SaveTo returns actual size.
    static const int kMaxBuf = 4 * 1024 * 1024;  // 4 MB max per frame
    static thread_local BYTE scratch[4 * 1024 * 1024];

    int encoded = sSaveTo(inst, scratch, kMaxBuf);
    if (encoded <= 0) return nullptr;

    jbyteArray result = env->NewByteArray(encoded);
    if (!result) return nullptr;
    env->SetByteArrayRegion(result, 0, encoded, (jbyte*)scratch);
    return result;
}

} // extern "C"
