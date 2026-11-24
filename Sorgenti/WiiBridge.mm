#import "WiiBridge.h"
#import "WiimoteManager.h"
#import "WiimotePairer.h"
#import <IOKit/hid/IOHIDManager.h>

static JFWiiState JFConvert(const WiimoteGamepadState &s) {
    JFWiiState out = {};
    out.connected = s.connected;
    // WiimoteManager's sources: 0..10 core buttons, 11/12 Nunchuk C/Z.
    out.buttons = s.sources & 0x1FFF;
    out.nunchukX = s.leftStick.x;
    out.nunchukY = s.leftStick.y;
    out.motionPlus = s.motionPlusActive;
    out.accelX = s.accelX; out.accelY = s.accelY; out.accelZ = s.accelZ;
    out.gyroPitch = s.gyroPitch; out.gyroYaw = s.gyroYaw; out.gyroRoll = s.gyroRoll;
    out.battery = s.batteryPercent;
    out.calibration = s.calibration;
    out.motionPlusBuiltIn = s.motionPlusBuiltIn;
    return out;
}

@implementation JFWiiHub {
    IOHIDManagerRef _manager;
    WiimoteManager *_slots[4];
}

static void JFHubMatched(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef device) {
    (void)r; (void)sender; [(__bridge JFWiiHub *)ctx deviceMatched:device];
}
static void JFHubRemoved(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef device) {
    (void)r; (void)sender; [(__bridge JFWiiHub *)ctx deviceRemoved:device];
}

- (void)start {
    if (_manager) return;
    _manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *matching = @[
        @{ @kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @0x0306 },   // Wii Remote
        @{ @kIOHIDVendorIDKey: @0x057E, @kIOHIDProductIDKey: @0x0330 },   // Wii Remote Plus (-TR)
    ];
    IOHIDManagerSetDeviceMatchingMultiple(_manager, (__bridge CFArrayRef)matching);
    IOHIDManagerRegisterDeviceMatchingCallback(_manager, JFHubMatched, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(_manager, JFHubRemoved, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    // Accesso esclusivo, così il demone di JoyCon2Mac non li trasforma anche in gamepad.
    if (IOHIDManagerOpen(_manager, kIOHIDOptionsTypeSeizeDevice) != kIOReturnSuccess) {
        IOHIDManagerOpen(_manager, kIOHIDOptionsTypeNone);
    }
}

- (void)stop {
    for (int i = 0; i < 4; i++) {
        [_slots[i] stop];
        _slots[i] = nil;
    }
    if (_manager) {
        IOHIDManagerUnscheduleFromRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(_manager, kIOHIDOptionsTypeNone);
        CFRelease(_manager);
        _manager = nullptr;
    }
}

- (void)deviceMatched:(IOHIDDeviceRef)device {
    int free = -1;
    for (int i = 0; i < 4; i++) {
        if (_slots[i] && [_slots[i] ownsDevice:device]) return;
        if (!_slots[i] && free < 0) free = i;
    }
    if (free < 0) return;   // già 4 telecomandi
    WiimoteManager *m = [[WiimoteManager alloc] init];
    __weak JFWiiHub *weakSelf = self;
    int slot = free;
    [m setStateCallback:[weakSelf, slot](const WiimoteGamepadState &s) {
        JFWiiHub *me = weakSelf;
        if (me && me.onState) me.onState(slot, JFConvert(s));
    }];
    [m setPlayerIndex:slot];
    _slots[slot] = m;
    [m attachDevice:device];
}

- (void)deviceRemoved:(IOHIDDeviceRef)device {
    for (int i = 0; i < 4; i++) {
        if (_slots[i] && [_slots[i] ownsDevice:device]) {
            [_slots[i] detachDevice:device];   // manda lo stato "scollegato"
            _slots[i] = nil;
        }
    }
}

- (void)setRumble:(BOOL)on slot:(int)slot { if (slot >= 0 && slot < 4) [_slots[slot] setRumble:on]; }
- (void)recalibrateSlot:(int)slot { if (slot >= 0 && slot < 4) [_slots[slot] recalibrate]; }

@end

@implementation JFWiiPairer {
    WiimotePairer *_pairer;
}

- (BOOL)isRunning { return _pairer.isRunning; }

- (void)startWithTimeout:(NSTimeInterval)timeout {
    if (!_pairer) _pairer = [[WiimotePairer alloc] init];
    __weak JFWiiPairer *weakSelf = self;
    [_pairer setCallback:[weakSelf](const char *state, const std::string &message) {
        NSString *st = [NSString stringWithUTF8String:state];
        NSString *msg = [NSString stringWithUTF8String:message.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            JFWiiPairer *me = weakSelf;
            if (me && me.onUpdate) me.onUpdate(st, msg);
        });
    }];
    [_pairer startWithTimeout:timeout];
}

- (void)cancel { [_pairer cancel]; }

@end

@implementation JFWiiReader {
    WiimoteManager *_manager;
}

- (void)start {
    if (_manager) return;
    _manager = [[WiimoteManager alloc] init];
    __weak JFWiiReader *weakSelf = self;
    [_manager setStateCallback:[weakSelf](const WiimoteGamepadState &s) {
        JFWiiReader *me = weakSelf;
        if (!me || !me.onState) return;
        JFWiiState out = {};
        out.connected = s.connected;
        // WiimoteManager's sources: 0..10 core buttons, 11/12 Nunchuk C/Z.
        out.buttons = s.sources & 0x1FFF;
        out.nunchukX = s.leftStick.x;
        out.nunchukY = s.leftStick.y;
        out.motionPlus = s.motionPlusActive;
        out.accelX = s.accelX; out.accelY = s.accelY; out.accelZ = s.accelZ;
        out.gyroPitch = s.gyroPitch; out.gyroYaw = s.gyroYaw; out.gyroRoll = s.gyroRoll;
        out.battery = s.batteryPercent;
        out.calibration = s.calibration;
        out.motionPlusBuiltIn = s.motionPlusBuiltIn;
        me.onState(out);
    }];
    [_manager start];
}

- (void)stop {
    [_manager stop];
    _manager = nil;
}

- (void)setRumble:(BOOL)on { [_manager setRumble:on]; }
- (void)recalibrate { [_manager recalibrate]; }

@end
