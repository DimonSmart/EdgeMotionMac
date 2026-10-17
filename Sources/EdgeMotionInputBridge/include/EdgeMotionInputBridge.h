#ifndef EDGE_MOTION_DIAGNOSTIC_BRIDGE_H
#define EDGE_MOTION_DIAGNOSTIC_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

// This header intentionally exposes decoded, stable values only.  Private
// MultitouchSupport types and function pointers stay in bridge.c.
typedef enum : int32_t {
    EMBridgeUnavailable = 0,
    EMBridgeReady = 1,
    EMBridgeRunning = 2,
    EMBridgeDisabled = 3
} EMBridgeState;

typedef enum : int32_t {
    EMContactBegan = 1,
    EMContactMoved = 2,
    EMContactEnded = 3
} EMContactPhase;

typedef struct {
    int64_t deviceIdentifier;
    int32_t pathIndex;
    int32_t fingerIdentifier;
    float normalizedX;
    float normalizedY;
    double timestamp;
    int64_t sequence;
    EMContactPhase phase;
} EMDecodedContact;

typedef struct {
    const EMDecodedContact *contacts;
    int32_t contactCount;
    double timestamp;
    int64_t sequence;
} EMDecodedFrame;

typedef void (*EMFrameCallback)(const EMDecodedFrame frame, void *context);

/// Opens the private framework with dlopen and resolves every required symbol.
/// Failure is a normal, sticky disabled state.
EMBridgeState EMBridgePrepare(void);
/// Starts only a built-in device. Registration/start failure disables the bridge.
bool EMBridgeStartBuiltIn(EMFrameCallback callback, void *context);
void EMBridgeStop(void);
EMBridgeState EMBridgeCurrentState(void);
const char *EMBridgeFailureReason(void);

#endif
