#import "WiimotePairer.h"
#import <IOBluetooth/IOBluetooth.h>
#import <objc/message.h>
#include <iostream>
#include <mach/mach_error.h>

@interface WiimotePairer () <IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate>
@end

// Debug log next to the app's build folder (…/build/wiimote_pair.log) so the
// pairing steps can be inspected without Console.app.
static void PairLog(NSString *line) {
    std::cout << "[WiimotePair] " << [line UTF8String] << std::endl;
    static NSString *path = nil;
    if (!path) {
        // VirtualJoyCon2: accanto all'app (…/VirtualJoyCon2/wiimote_pair.log).
        NSString *bundle = [[NSBundle mainBundle] bundlePath];
        path = [[bundle stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"wiimote_pair.log"];
    }
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss.SSS";
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], line];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) {
        [entry writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [h seekToEndOfFile];
    [h writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static BOOL LooksLikeWiimoteName(NSString *name) {
    return [name containsString:@"Nintendo RVL-CNT-01"] || [name containsString:@"RVL-CNT"];
}

@implementation WiimotePairer {
    WiimotePairingCallback _callback;
    IOBluetoothDeviceInquiry *_inquiry;
    IOBluetoothDevicePair *_pair;
    NSTimer *_timeoutTimer;
    NSString *_deviceName;
    BOOL _running;
}

- (void)setCallback:(WiimotePairingCallback)callback { _callback = callback; }
- (BOOL)isRunning { return _running; }

- (void)report:(const char *)state message:(NSString *)message {
    std::cout << "[WiimotePair] " << state << ": " << (message ? [message UTF8String] : "") << std::endl;
    if (_callback) {
        _callback(state, message ? std::string([message UTF8String]) : std::string());
    }
}

- (void)startWithTimeout:(NSTimeInterval)timeout {
    if (_running) {
        return;
    }
    if (![IOBluetoothHostController defaultController] ||
        [IOBluetoothHostController defaultController].powerState != kBluetoothHCIPowerStateON) {
        [self report:"failed" message:@"Bluetooth is off"];
        return;
    }
    _running = YES;
    PairLog([NSString stringWithFormat:@"start; host=%@", [[IOBluetoothHostController defaultController] addressAsString]]);

    // A stale bond (e.g. from an earlier attempt in System Settings) stops
    // the remote from showing up in the inquiry and from reconnecting.
    // Drop any Wii Remote that macOS lists as paired but is not connected.
    for (IOBluetoothDevice *known in [IOBluetoothDevice pairedDevices]) {
        NSString *knownName = known.name ?: @"";
        if (!LooksLikeWiimoteName(knownName)) continue;
        PairLog([NSString stringWithFormat:@"already known: %@ %@ connected=%d", knownName, known.addressString, known.isConnected]);
        if (!known.isConnected) {
            SEL removeSel = NSSelectorFromString(@"remove");
            if ([known respondsToSelector:removeSel]) {
                ((void (*)(id, SEL))objc_msgSend)(known, removeSel);
                PairLog(@"removed stale pairing so it can be paired again");
            }
        }
    }

    _inquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
    _inquiry.searchType = kIOBluetoothDeviceSearchClassic;
    _inquiry.updateNewDeviceNames = YES;
    _inquiry.inquiryLength = 8;
    IOReturn r = [_inquiry start];
    if (r != kIOReturnSuccess) {
        [self finish:"failed" message:[NSString stringWithFormat:@"Could not start Bluetooth search (%s)", mach_error_string(r)]];
        return;
    }
    _timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:timeout repeats:NO block:^(NSTimer *t) {
        (void)t;
        [self finish:"timeout" message:@"No Wii Remote found. Press the red SYNC button and try again."];
    }];
    [self report:"searching" message:@"Press the red SYNC button under the battery cover"];
}

- (void)cancel {
    if (_running) {
        [self finish:"cancelled" message:@"Pairing cancelled"];
    }
}

- (void)finish:(const char *)state message:(NSString *)message {
    [_timeoutTimer invalidate];
    _timeoutTimer = nil;
    if (_inquiry) {
        _inquiry.delegate = nil;
        [_inquiry stop];
        _inquiry = nil;
    }
    if (_pair) {
        _pair.delegate = nil;
        [_pair stop];
        _pair = nil;
    }
    _running = NO;
    PairLog([NSString stringWithFormat:@"finish: %s %@", state, message ?: @""]);
    [self report:state message:message];
}

#pragma mark - Inquiry

- (void)considerDevice:(IOBluetoothDevice *)device {
    if (!_running || _pair) {
        return;
    }
    NSString *name = device.name ?: @"";
    BluetoothClassOfDevice cod = device.classOfDevice;
    BluetoothDeviceClassMajor major = (BluetoothDeviceClassMajor)((cod >> 8) & 0x1F);
    PairLog([NSString stringWithFormat:@"found %@ name='%@' class=0x%06X", device.addressString, name, (unsigned)cod]);

    // Inquiry results often arrive before the name is known. Wii Remotes
    // report themselves as a peripheral (class 0x002504 / 0x000508): ask for
    // the name directly instead of waiting for it.
    if (name.length == 0 && major == kBluetoothDeviceClassMajorPeripheral) {
        IOReturn nr = [device remoteNameRequest:nil withPageTimeout:(BluetoothHCIPageTimeout)(0x2000)];
        name = device.name ?: @"";
        PairLog([NSString stringWithFormat:@"name request -> 0x%x '%@'", nr, name]);
    }
    if (!LooksLikeWiimoteName(name)) {
        if (name.length == 0) {
            // Let the inquiry report it again once the name resolves.
            [_inquiry clearFoundDevices];
        }
        return;
    }
    _deviceName = name;
    if (device.isPaired) {
        // Already bonded: pressing any button reconnects it, nothing to do.
        [self finish:"paired" message:[NSString stringWithFormat:@"%@ was already paired - press any button on it", name]];
        return;
    }

    [_inquiry stop];
    _pair = [IOBluetoothDevicePair pairWithDevice:device];
    _pair.delegate = self;

    // Ask IOBluetooth to always query the delegate for the PIN (private, but
    // without it macOS 12+ tries its own numeric PIN and the remote refuses).
    SEL userPinSel = NSSelectorFromString(@"setUserDefinedPincode:");
    if ([_pair respondsToSelector:userPinSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(_pair, userPinSel, YES);
    }

    IOReturn r = [_pair start];
    PairLog([NSString stringWithFormat:@"pair start -> 0x%x", r]);
    if (r != kIOReturnSuccess) {
        [self finish:"failed" message:[NSString stringWithFormat:@"Could not start pairing (%s)", mach_error_string(r)]];
        return;
    }
    [self report:"pairing" message:[NSString stringWithFormat:@"Pairing with %@...", name]];
}

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender device:(IOBluetoothDevice *)device {
    (void)sender;
    [self considerDevice:device];
}

- (void)deviceInquiryDeviceNameUpdated:(IOBluetoothDeviceInquiry *)sender
                                device:(IOBluetoothDevice *)device
                      devicesRemaining:(uint32_t)devicesRemaining {
    (void)sender; (void)devicesRemaining;
    [self considerDevice:device];
}

- (void)deviceInquiryStarted:(IOBluetoothDeviceInquiry *)sender {
    (void)sender;
    PairLog(@"inquiry running");
}

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)sender error:(IOReturn)error aborted:(BOOL)aborted {
    PairLog([NSString stringWithFormat:@"inquiry complete err=0x%x aborted=%d found=%lu", error, aborted, (unsigned long)sender.foundDevices.count]);
    // Inquiries last a few seconds; keep searching until found or timed out.
    if (_running && !_pair && !aborted) {
        [sender clearFoundDevices];
        [sender start];
    }
}

#pragma mark - Pairing

- (void)devicePairingPINCodeRequest:(id)sender {
    IOBluetoothDevicePair *pair = (IOBluetoothDevicePair *)sender;
    IOBluetoothDevice *device = [pair device];

    BluetoothDeviceAddress host;
    memset(&host, 0, sizeof(host));
    NSString *hostAddress = [[IOBluetoothHostController defaultController] addressAsString];
    IOBluetoothNSStringToDeviceAddress(hostAddress, &host);
    PairLog([NSString stringWithFormat:@"PIN request; host=%@", hostAddress]);

    // SYNC-button pairing: the PIN is the host address in reverse byte order.
    BluetoothPINCode pin;
    memset(&pin, 0, sizeof(pin));
    for (int i = 0; i < 6; i++) {
        pin.data[i] = host.data[5 - i];
    }

    // The public replyPINCode: turns the PIN into a string first, which
    // mangles the raw bytes on current macOS. Hand the 6 raw bytes straight
    // to the CoreBluetooth coordinator instead when it is available.
    Class coordinatorClass = NSClassFromString(@"IOBluetoothCoreBluetoothCoordinator");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    SEL pairSel = NSSelectorFromString(@"pairPeer:forType:withKey:");
    SEL peerSel = NSSelectorFromString(@"classicPeer");
    SEL typeSel = NSSelectorFromString(@"currentPairingType");
    if (coordinatorClass && [coordinatorClass respondsToSelector:sharedSel] &&
        [device respondsToSelector:peerSel] && [pair respondsToSelector:typeSel]) {
        id coordinator = ((id (*)(id, SEL))objc_msgSend)(coordinatorClass, sharedSel);
        if ([coordinator respondsToSelector:pairSel]) {
            id peer = ((id (*)(id, SEL))objc_msgSend)(device, peerSel);
            NSUInteger type = ((NSUInteger (*)(id, SEL))objc_msgSend)(pair, typeSel);
            uint64_t key = 0;
            memcpy(&key, pin.data, 6);
            ((void (*)(id, SEL, id, NSUInteger, id))objc_msgSend)(coordinator, pairSel, peer, type, @(key));
            PairLog([NSString stringWithFormat:@"PIN sent via coordinator (type %lu)", (unsigned long)type]);
            return;
        }
    }
    [pair replyPINCode:6 PINCode:&pin];
    PairLog(@"PIN sent via replyPINCode");
}

- (void)devicePairingStarted:(id)sender {
    (void)sender;
    PairLog(@"pairing started");
}

- (void)devicePairingConnecting:(id)sender {
    (void)sender;
    PairLog(@"pairing: connecting");
}

- (void)devicePairingUserConfirmationRequest:(id)sender numericValue:(BluetoothNumericValue)numericValue {
    PairLog([NSString stringWithFormat:@"unexpected numeric confirmation %u", (unsigned)numericValue]);
    [(IOBluetoothDevicePair *)sender replyUserConfirmation:YES];
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    (void)sender;
    PairLog([NSString stringWithFormat:@"pairing finished -> 0x%x", error]);
    if (error == kIOReturnSuccess) {
        [self finish:"paired" message:[NSString stringWithFormat:@"%@ paired. Press 1+2 or any button to connect.", _deviceName ?: @"Wii Remote"]];
    } else {
        [self finish:"failed" message:[NSString stringWithFormat:@"Pairing failed (%s). Press SYNC and retry.", mach_error_string(error)]];
    }
}

@end
