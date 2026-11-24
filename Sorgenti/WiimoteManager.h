#pragma once

// Wii Remote support.
//
// The Wii Remote is a classic-Bluetooth HID device. Once it has been paired
// with the Mac (e.g. with Dolphin's WiimotePair utility, which handles the
// reversed-MAC PIN that macOS can't enter on its own), macOS exposes it as an
// ordinary IOHIDDevice. That is the same path Dolphin itself uses on macOS
// (hidapi -> IOHIDManager), so no private APIs or extra entitlements are
// needed here.
//
// The manager translates Wii Remote / Nunchuk / Classic Controller input into
// the Joy-Con 2 button words used everywhere else in the daemon, so the
// existing HID gamepad pipeline maps it onto the Switch layout unchanged.

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDDevice.h>
#include <functional>
#include <string>
#include "JoyConDecoder.h"

enum class WiimoteExtension { None, Nunchuk, Classic, MotionPlus, Unknown };

struct WiimoteGamepadState {
    // Same bit layout as ExtractButtonState(buffer, Left/Right).
    uint32_t leftButtons = 0;
    uint32_t rightButtons = 0;
    StickData leftStick = {0, 0, 0, 0};
    StickData rightStick = {0, 0, 0, 0};
    uint8_t triggerL = 0;
    uint8_t triggerR = 0;
    bool connected = false;
    // Physical buttons held, one bit per source (WiiSource in the .mm):
    // 0 Up 1 Down 2 Left 3 Right 4 A 5 B 6 One 7 Two 8 Minus 9 Plus 10 Home ...
    uint32_t sources = 0;

    // Motion, already rotated into the DSU/CemuHook convention (see
    // WiimoteManager.mm). Accel in g, gyro in degrees per second.
    bool hasAccel = false;
    bool motionPlusActive = false;
    float accelX = 0, accelY = 0, accelZ = 0;
    float gyroPitch = 0, gyroYaw = 0, gyroRoll = 0;
    uint64_t timestampUs = 0;
    int batteryPercent = -1;
    // Calibrazione giroscopio: 0 = fatta, 1 = in attesa (appoggialo fermo su un
    // piano), 2 = misura in corso.
    int calibration = 0;
    // MotionPlus integrato (Wii Remote Plus, ID 01…) o adattatore esterno (ID 00…).
    bool motionPlusBuiltIn = false;
};

// status: "connected" | "disconnected" | "extension" | "input"
using WiimoteEventCallback = std::function<void(const char *status,
                                                const std::string &detailJSON)>;
using WiimoteStateCallback = std::function<void(const WiimoteGamepadState &state)>;

@interface WiimoteManager : NSObject

- (void)setEventCallback:(WiimoteEventCallback)callback;
- (void)setStateCallback:(WiimoteStateCallback)callback;
- (void)start;
- (void)stop;
- (void)setRumble:(BOOL)on;
// Più telecomandi: un gestore esterno (JFWiiHub) assegna a ogni istanza il proprio
// dispositivo invece di usare start/stop.
- (void)attachDevice:(IOHIDDeviceRef)device;
- (void)detachDevice:(IOHIDDeviceRef)device;
- (BOOL)ownsDevice:(IOHIDDeviceRef)device;
// Numero giocatore 0…3: accende il LED corrispondente sul telecomando.
- (void)setPlayerIndex:(int)index;
// Flip individual gyro axes if motion feels mirrored in a game.
- (void)setInvertPitch:(BOOL)pitch yaw:(BOOL)yaw roll:(BOOL)roll;
// Re-learn gyro bias and stick centres. Keep the controller still ~1 s.
- (void)recalibrate;
// layout: "auto" | "upright" | "sideways"; overrides: source name -> target
// name (e.g. @{@"wii.b": @"zr"}). Names are listed in WiimoteManager.mm.
- (void)setLayoutMode:(NSString *)mode overrides:(NSDictionary<NSString *, NSString *> *)overrides;

@property (nonatomic, readonly) WiimoteGamepadState currentState;

@end
