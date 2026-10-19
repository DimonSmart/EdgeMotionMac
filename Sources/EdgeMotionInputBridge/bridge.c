#include "EdgeMotionInputBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
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
// This list owns the framework device values. It intentionally outlives
// start/stop cycles: the private API provides no qualified unregister
// contract, so releasing it while a callback may still be in flight would be
// less safe than retaining it for this process-lifetime bridge session.
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
// EMFailureNotPrepared is the first nonzero failure code below.
static _Atomic int32_t failureCode = 1;
static _Atomic int32_t lastOSStatus;
// Startup and shutdown can be requested by the menu-bar action and the global
// shortcut independently. Keep the transition from Ready to Running atomic so
// a second request cannot reinterpret the first as a missing callback.
static pthread_mutex_t lifecycleLock = PTHREAD_MUTEX_INITIALIZER;
static bool callbackRegistered;
static bool deviceStarted;

typedef enum : int32_t {
    EMFailureNone = 0,
    EMFailureNotPrepared,
    EMFailureFrameworkUnavailable,
    EMFailureRequiredSymbolUnavailable,
    EMFailureCallbackUnavailable,
    EMFailureDeviceEnumeration,
    EMFailureNoBuiltInDevice,
    EMFailureInvalidFrame,
    EMFailureInvalidContact,
    EMFailureDeviceStart,
    EMFailureDeviceStop,
} EMFailureCode;

static void setFailure(EMFailureCode code) {
    atomic_store_explicit(&failureCode, code, memory_order_release);
}

static void setDeviceFailure(EMFailureCode code, OSStatus status) {
    atomic_store_explicit(&lastOSStatus, status, memory_order_release);
    setFailure(code);
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

static void notifyInputFailure(void) {
    EMFrameCallback callback = frameCallback;
    if (callback) {
        callback((EMDecodedFrame){ .contacts = NULL, .contactCount = 0, .timestamp = 0, .sequence = 0 }, callbackContext);
    }
}

static void disableFromCallback(EMFailureCode failure) {
    int32_t expected = EMBridgeRunning;
    if (atomic_compare_exchange_strong_explicit(&bridgeState, &expected, EMBridgeDisabled,
                                                memory_order_acq_rel, memory_order_acquire)) {
        setFailure(failure);
        notifyInputFailure();
    }
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
        disableFromCallback(EMFailureInvalidFrame);
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
            disableFromCallback(EMFailureInvalidContact);
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

static EMBridgeState prepareLocked(void) {
    EMBridgeState state = atomic_load_explicit(&bridgeState, memory_order_acquire);
    if (state == EMBridgeDisabled || state == EMBridgeReady || state == EMBridgeRunning) return state;

    framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY | RTLD_LOCAL);
    if (!framework) {
        setFailure(EMFailureFrameworkUnavailable);
        atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        return EMBridgeDisabled;
    }
    createList = (MTDeviceCreateListFn)dlsym(framework, "MTDeviceCreateList");
    isBuiltIn = (MTDeviceIsBuiltInFn)dlsym(framework, "MTDeviceIsBuiltIn");
    registerCallback = (MTRegisterCallbackFn)dlsym(framework, "MTRegisterContactFrameCallback");
    startDevice = (MTDeviceStartFn)dlsym(framework, "MTDeviceStart");
    stopDevice = (MTDeviceStopFn)dlsym(framework, "MTDeviceStop");
    if (!createList || !isBuiltIn || !registerCallback || !startDevice || !stopDevice) {
        setFailure(EMFailureRequiredSymbolUnavailable);
        atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        return EMBridgeDisabled;
    }
    setFailure(EMFailureNone);
    atomic_store_explicit(&lastOSStatus, 0, memory_order_release);
    atomic_store_explicit(&bridgeState, EMBridgeReady, memory_order_release);
    return EMBridgeReady;
}

EMBridgeState EMBridgePrepare(void) {
    pthread_mutex_lock(&lifecycleLock);
    EMBridgeState state = prepareLocked();
    pthread_mutex_unlock(&lifecycleLock);
    return state;
}

bool EMBridgeStartBuiltIn(EMFrameCallback callback, void *context) {
    pthread_mutex_lock(&lifecycleLock);
    if (!callback) {
        setFailure(EMFailureCallbackUnavailable);
        if (atomic_load_explicit(&bridgeState, memory_order_acquire) != EMBridgeRunning) {
            atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        }
        pthread_mutex_unlock(&lifecycleLock);
        return false;
    }

    EMBridgeState state = prepareLocked();
    // Starting an already-running session is harmless. This check must be
    // inside the lifecycle transition: another action can begin the session
    // after an earlier non-atomic state check.
    if (state == EMBridgeRunning) {
        pthread_mutex_unlock(&lifecycleLock);
        return true;
    }
    if (state != EMBridgeReady) {
        pthread_mutex_unlock(&lifecycleLock);
        return false;
    }
    if (!activeDeviceList) {
        activeDeviceList = createList();
        if (!activeDeviceList) {
            setFailure(EMFailureDeviceEnumeration);
            atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
            pthread_mutex_unlock(&lifecycleLock);
            return false;
        }
        CFIndex deviceCount = CFArrayGetCount(activeDeviceList);
        for (CFIndex i = 0; i < deviceCount; i++) {
            MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(activeDeviceList, i);
            if (device && isBuiltIn(device)) { activeDevice = device; break; }
        }
    }
    if (!activeDevice) {
        setFailure(EMFailureNoBuiltInDevice);
        atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        pthread_mutex_unlock(&lifecycleLock);
        return false;
    }
    if (!callbackRegistered) {
        frameCallback = callback;
        callbackContext = context;
        registerCallback(activeDevice, receiveContacts);
        callbackRegistered = true;
    }
    // Some framework versions may synchronously deliver the first frame as
    // start returns, so make the callback eligible before invoking start.
    atomic_store_explicit(&bridgeState, EMBridgeRunning, memory_order_release);
    deviceStarted = true;
    OSStatus status = startDevice(activeDevice, 0);
    if (status != 0) {
        setDeviceFailure(EMFailureDeviceStart, status);
        // A nonzero result does not document whether the private framework
        // started partially. Leave the bridge disabled and make one bounded
        // cleanup attempt instead of claiming that it is ready to restart.
        (void)stopDevice(activeDevice);
        deviceStarted = false;
        atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
        pthread_mutex_unlock(&lifecycleLock);
        return false;
    }
    // A private framework can synchronously invoke receiveContacts from
    // MTDeviceStart. If that callback rejected its first frame, it owns the
    // transition to Disabled; do not report a successful start to Swift.
    if (atomic_load_explicit(&bridgeState, memory_order_acquire) != EMBridgeRunning) {
        (void)stopDevice(activeDevice);
        deviceStarted = false;
        pthread_mutex_unlock(&lifecycleLock);
        return false;
    }
    pthread_mutex_unlock(&lifecycleLock);
    return true;
}

void EMBridgeStop(void) {
    pthread_mutex_lock(&lifecycleLock);
    EMBridgeState state = (EMBridgeState)atomic_load_explicit(&bridgeState, memory_order_acquire);
    // Prevent a late callback from starting a failure transition while the
    // private framework is being stopped. A concurrent Start waits on this
    // lock, so it cannot mistake this transient Ready state for a completed
    // stop.
    if (state == EMBridgeRunning) {
        atomic_store_explicit(&bridgeState, EMBridgeReady, memory_order_release);
    }
    if (deviceStarted && stopDevice && activeDevice) {
        OSStatus status = stopDevice(activeDevice);
        if (status != 0) {
            setDeviceFailure(EMFailureDeviceStop, status);
            atomic_store_explicit(&bridgeState, EMBridgeDisabled, memory_order_release);
            pthread_mutex_unlock(&lifecycleLock);
            return;
        }
        deviceStarted = false;
    }
    // Disabled is a sticky failure state. It can only become Ready through a
    // future explicit recovery implementation, never merely because Stop was
    // called. Unavailable is likewise not a recoverable prepared bridge.
    if (state == EMBridgeRunning || state == EMBridgeReady) {
        atomic_store_explicit(&bridgeState, EMBridgeReady, memory_order_release);
    }
    // Private callback unregister/reconnect is intentionally not inferred from
    // the reverse-engineered ABI. The retained framework/list/context remain
    // valid for this process-lifetime session; qualified reconnect support is
    // a separate hardware task.
    pthread_mutex_unlock(&lifecycleLock);
}

EMBridgeState EMBridgeCurrentState(void) {
    return (EMBridgeState)atomic_load_explicit(&bridgeState, memory_order_acquire);
}

int32_t EMBridgeLastOSStatus(void) {
    return atomic_load_explicit(&lastOSStatus, memory_order_acquire);
}

const char *EMBridgeFailureReason(void) {
    switch ((EMFailureCode)atomic_load_explicit(&failureCode, memory_order_acquire)) {
    case EMFailureNone: return "";
    case EMFailureNotPrepared: return "not prepared";
    case EMFailureFrameworkUnavailable: return "MultitouchSupport unavailable";
    case EMFailureRequiredSymbolUnavailable: return "required MultitouchSupport symbol unavailable";
    case EMFailureCallbackUnavailable: return "callback unavailable";
    case EMFailureDeviceEnumeration: return "device enumeration failed";
    case EMFailureNoBuiltInDevice: return "no compatible built-in trackpad";
    case EMFailureInvalidFrame: return "invalid callback frame";
    case EMFailureInvalidContact: return "invalid contact layout or values";
    case EMFailureDeviceStart: return "MTDeviceStart failed";
    case EMFailureDeviceStop: return "MTDeviceStop failed";
    }
    return "unknown bridge failure";
}
