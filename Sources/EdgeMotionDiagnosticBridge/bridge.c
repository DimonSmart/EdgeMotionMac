#include "EdgeMotionDiagnosticBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// All MultitouchSupport declarations in this file are reverse-engineered ABI
// assumptions. They must not escape this C boundary.
typedef void *MTDeviceRef;
typedef int32_t OSStatus;

// The fields used below have been observed at these offsets in the 96-byte
// MTTouch layout. Keeping it opaque avoids accidentally trusting a C layout
// merely because it happens to compile with a particular SDK.
typedef struct { uint8_t bytes[96]; } MTTouchAssumption;
_Static_assert(sizeof(MTTouchAssumption) == 96, "MTTouch ABI assumption changed");
enum {
    kTouchTimestampOffset = 8,
    kTouchPathIndexOffset = 16,
    kTouchStateOffset = 20,
    kTouchFingerIDOffset = 24,
    kTouchNormalizedXOffset = 32,
    kTouchNormalizedYOffset = 36,
};

typedef int32_t (*MTPrivateCallback)(MTDeviceRef, const MTTouchAssumption *, int32_t, double, int32_t);
typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef bool (*MTDeviceIsBuiltInFn)(MTDeviceRef);
typedef void (*MTRegisterCallbackFn)(MTDeviceRef, MTPrivateCallback);
typedef OSStatus (*MTDeviceStartFn)(MTDeviceRef, int32_t);
typedef OSStatus (*MTDeviceStopFn)(MTDeviceRef);

static void *framework;
// Retained until process exit: values returned by CFArrayGetValueAtIndex do
// not become caller-owned after the array is released.
static CFArrayRef activeDeviceList;
static MTDeviceRef activeDevice;
static MTDeviceCreateListFn createList;
static MTDeviceIsBuiltInFn isBuiltIn;
static MTRegisterCallbackFn registerCallback;
static MTDeviceStartFn startDevice;
static MTDeviceStopFn stopDevice;
static EMFrameCallback frameCallback;
static void *callbackContext;
static _Atomic int32_t bridgeState = EMBridgeUnavailable;
static char failureReason[160] = "not prepared";

static void setFailure(const char *reason) {
    snprintf(failureReason, sizeof(failureReason), "%s", reason);
}

static void setStartFailure(OSStatus status) {
    snprintf(failureReason, sizeof(failureReason), "MTDeviceStart failed (OSStatus %d)", (int)status);
}

static bool finiteUnit(float value) {
    return isfinite(value) && value >= 0.0f && value <= 1.0f;
}

static int32_t readI32(const MTTouchAssumption *touch, size_t offset) {
    int32_t value;
    memcpy(&value, touch->bytes + offset, sizeof(value));
    return value;
}

static float readF32(const MTTouchAssumption *touch, size_t offset) {
    float value;
    memcpy(&value, touch->bytes + offset, sizeof(value));
    return value;
}

// The framework may invoke this on its own thread. It only copies one bounded
// frame and returns zero, which preserves normal system gesture handling.
static int32_t receiveContacts(MTDeviceRef device, const MTTouchAssumption *touches,
                               int32_t count, double timestamp, int32_t frame) {
    if (atomic_load_explicit(&bridgeState, memory_order_acquire) != EMBridgeRunning ||
        device != activeDevice) {
        return 0;
    }
    if (count < 0 || count > 16 || !isfinite(timestamp) || timestamp <= 0 || frame < 0 ||
        (count > 0 && !touches)) {
        setFailure("invalid callback frame");
        atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        return 0;
    }

    EMDecodedContact decoded[16];
    for (int32_t i = 0; i < count; i++) {
        const MTTouchAssumption *touch = &touches[i];
        int32_t pathIndex = readI32(touch, kTouchPathIndexOffset);
        int32_t state = readI32(touch, kTouchStateOffset);
        int32_t fingerID = readI32(touch, kTouchFingerIDOffset);
        float x = readF32(touch, kTouchNormalizedXOffset);
        float y = readF32(touch, kTouchNormalizedYOffset);
        if (pathIndex < 0 || fingerID < 0 || !finiteUnit(x) || !finiteUnit(y)) {
            setFailure("invalid contact layout or values");
            atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
            return 0;
        }
        EMContactPhase phase = (state == 5 || state == 7) ? EMContactEnded : EMContactMoved;
        decoded[i] = (EMDecodedContact){
            .deviceIdentifier = (int64_t)(uintptr_t)device,
            .pathIndex = pathIndex,
            .fingerIdentifier = fingerID,
            .normalizedX = x,
            .normalizedY = y,
            .timestamp = timestamp,
            .sequence = frame,
            .phase = phase,
        };
    }

    EMFrameCallback callback = frameCallback;
    if (callback) {
        EMDecodedFrame decodedFrame = { .contacts = count == 0 ? NULL : decoded, .contactCount = count,
                                        .timestamp = timestamp, .sequence = frame };
        callback(decodedFrame, callbackContext);
    }
    return 0;
}

EMBridgeState EMBridgePrepare(void) {
    EMBridgeState state = atomic_load_explicit(&bridgeState, memory_order_acquire);
    if (state == EMBridgeDisabled || state == EMBridgeReady || state == EMBridgeRunning) return state;

    framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY | RTLD_LOCAL);
    if (!framework) {
        setFailure("MultitouchSupport unavailable");
        atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        return EMBridgeDisabled;
    }
    createList = (MTDeviceCreateListFn)dlsym(framework, "MTDeviceCreateList");
    isBuiltIn = (MTDeviceIsBuiltInFn)dlsym(framework, "MTDeviceIsBuiltIn");
    registerCallback = (MTRegisterCallbackFn)dlsym(framework, "MTRegisterContactFrameCallback");
    startDevice = (MTDeviceStartFn)dlsym(framework, "MTDeviceStart");
    stopDevice = (MTDeviceStopFn)dlsym(framework, "MTDeviceStop");
    if (!createList || !isBuiltIn || !registerCallback || !startDevice || !stopDevice) {
        setFailure("required MultitouchSupport symbol unavailable");
        atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        return EMBridgeDisabled;
    }
    failureReason[0] = '\0';
    atomic_store_explicit(&bridgeState, EMBridgeReady, memory_order_release);
    return EMBridgeReady;
}

bool EMBridgeStartBuiltIn(EMFrameCallback callback, void *context) {
    if (EMBridgePrepare() != EMBridgeReady || !callback) {
        if (EMBridgeCurrentState() != EMBridgeDisabled) {
            setFailure("callback unavailable");
            atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        }
        return false;
    }
    activeDeviceList = createList();
    if (!activeDeviceList) {
        setFailure("device enumeration failed");
        atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        return false;
    }
    CFIndex deviceCount = CFArrayGetCount(activeDeviceList);
    for (CFIndex i = 0; i < deviceCount; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(activeDeviceList, i);
        if (device && isBuiltIn(device)) { activeDevice = device; break; }
    }
    if (!activeDevice) {
        setFailure("no compatible built-in trackpad");
        atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        return false;
    }
    frameCallback = callback;
    callbackContext = context;
    registerCallback(activeDevice, receiveContacts);
    // Some framework versions may synchronously deliver the first frame as
    // start returns, so make the callback eligible before invoking start.
    atomic_store_explicit(&bridgeState, EMBridgeRunning, memory_order_release);
    OSStatus status = startDevice(activeDevice, 0);
    if (status != 0) {
        setStartFailure(status);
        atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        return false;
    }
    return true;
}

void EMBridgeStop(void) {
    if (atomic_exchange_explicit(&bridgeState, EMBridgeReady, memory_order_acq_rel) == EMBridgeRunning && stopDevice && activeDevice) {
        (void)stopDevice(activeDevice);
    }
    // Intentionally do not unregister the private callback or release the
    // device array/framework. The diagnostic exits immediately after stop;
    // production shutdown/reconnect needs separate hardware qualification.
}

EMBridgeState EMBridgeCurrentState(void) {
    return (EMBridgeState)atomic_load_explicit(&bridgeState, memory_order_acquire);
}

const char *EMBridgeFailureReason(void) { return failureReason; }
