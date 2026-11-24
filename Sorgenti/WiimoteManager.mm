#import "WiimoteManager.h"
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#include <algorithm>
#include <cmath>
#include <iostream>
#include <sstream>
#include <unistd.h>
#include <vector>

// ---------------------------------------------------------------------------
// Device identity
// ---------------------------------------------------------------------------
static const int kNintendoVendorID = 0x057E;
static const int kWiimoteProductID = 0x0306;      // RVL-CNT-01
static const int kWiimotePlusProductID = 0x0330;  // RVL-CNT-01-TR (MotionPlus inside)

// ID estensione (6 byte a 0xA400FA / 0xA600FA). MotionPlus: xx xx A6 20 0? 05 quando
// è inattivo (letto a 0xA600FA), xx xx A4 20 0? 05 quando è attivo. Vale sia per il
// MotionPlus integrato (Wii Remote Plus) sia per l'adattatore esterno.
static bool IsMotionPlusID(const uint8_t *b) {
    return b[3] == 0x20 && b[5] == 0x05 && (b[4] == 0x00 || b[4] == 0x04 || b[4] == 0x05 || b[4] == 0x07);
}
static bool IsActiveMotionPlusID(const uint8_t *b) { return IsMotionPlusID(b) && b[2] == 0xA4; }

// Calibrazione: campioni fermi da mediare e massima oscillazione ammessa (conteggi grezzi).
static const int kCalibrationSamples = 100;      // ~1 s
static const int kCalibrationSpread = 40;        // ~3 gradi/s
static const int kRestSpread = 12;               // ~0,9 gradi/s: appoggiato, non in mano

// ---------------------------------------------------------------------------
// Joy-Con 2 button words (must match JoyConDecoder.h / DriverKitClient.mm)
// ---------------------------------------------------------------------------
static const uint32_t L_DOWN = 0x000001, L_UP = 0x000002, L_RIGHT = 0x000004, L_LEFT = 0x000008;
static const uint32_t L_L = 0x000040, L_ZL = 0x000080, L_MINUS = 0x000100;
static const uint32_t R_Y = 0x000100, R_B = 0x000200, R_X = 0x000400, R_A = 0x000800;
static const uint32_t R_R = 0x004000, R_ZR = 0x008000, R_PLUS = 0x000002, R_HOME = 0x000010;

// ---------------------------------------------------------------------------
// Wii Remote core buttons (input report bytes 1 and 2)
// ---------------------------------------------------------------------------
static const uint8_t W1_LEFT = 0x01, W1_RIGHT = 0x02, W1_DOWN = 0x04, W1_UP = 0x08, W1_PLUS = 0x10;
static const uint8_t W2_TWO = 0x01, W2_ONE = 0x02, W2_B = 0x04, W2_A = 0x08, W2_MINUS = 0x10, W2_HOME = 0x80;

static const uint32_t L_L3 = 0x000800, L_CAPTURE = 0x002000, R_R3 = 0x000004;

// ---------------------------------------------------------------------------
// Remappable mapping: physical "sources" -> Switch "targets"
// ---------------------------------------------------------------------------
enum WiiSource : int {
    S_WII_UP, S_WII_DOWN, S_WII_LEFT, S_WII_RIGHT, S_WII_A, S_WII_B, S_WII_1, S_WII_2,
    S_WII_MINUS, S_WII_PLUS, S_WII_HOME,
    S_NUN_C, S_NUN_Z,
    S_CC_UP, S_CC_DOWN, S_CC_LEFT, S_CC_RIGHT, S_CC_A, S_CC_B, S_CC_X, S_CC_Y,
    S_CC_L, S_CC_R, S_CC_ZL, S_CC_ZR, S_CC_MINUS, S_CC_PLUS, S_CC_HOME,
    S_COUNT
};

static const char *kSourceNames[S_COUNT] = {
    "wii.up", "wii.down", "wii.left", "wii.right", "wii.a", "wii.b", "wii.1", "wii.2",
    "wii.minus", "wii.plus", "wii.home",
    "nun.c", "nun.z",
    "cc.up", "cc.down", "cc.left", "cc.right", "cc.a", "cc.b", "cc.x", "cc.y",
    "cc.l", "cc.r", "cc.zl", "cc.zr", "cc.minus", "cc.plus", "cc.home",
};

enum SwitchTarget : int {
    T_NONE, T_A, T_B, T_X, T_Y, T_L, T_R, T_ZL, T_ZR, T_PLUS, T_MINUS, T_HOME, T_CAPTURE,
    T_UP, T_DOWN, T_LEFT, T_RIGHT, T_L3, T_R3, T_COUNT
};

static const char *kTargetNames[T_COUNT] = {
    "none", "a", "b", "x", "y", "l", "r", "zl", "zr", "plus", "minus", "home", "capture",
    "up", "down", "left", "right", "l3", "r3",
};

static void ApplyTarget(int target, uint32_t &left, uint32_t &right) {
    switch (target) {
        case T_A: right |= R_A; break;
        case T_B: right |= R_B; break;
        case T_X: right |= R_X; break;
        case T_Y: right |= R_Y; break;
        case T_L: left |= L_L; break;
        case T_R: right |= R_R; break;
        case T_ZL: left |= L_ZL; break;
        case T_ZR: right |= R_ZR; break;
        case T_PLUS: right |= R_PLUS; break;
        case T_MINUS: left |= L_MINUS; break;
        case T_HOME: right |= R_HOME; break;
        case T_CAPTURE: left |= L_CAPTURE; break;
        case T_UP: left |= L_UP; break;
        case T_DOWN: left |= L_DOWN; break;
        case T_LEFT: left |= L_LEFT; break;
        case T_RIGHT: left |= L_RIGHT; break;
        case T_L3: left |= L_L3; break;
        case T_R3: right |= R_R3; break;
        default: break;
    }
}

// Preset layouts. "Upright" = one Joy-Con 2 (R) held vertically (motion
// games), "sideways" = one Joy-Con held horizontally (NES-style).
static int PresetTarget(int source, bool sideways) {
    switch (source) {
        case S_WII_UP:    return sideways ? T_LEFT : T_UP;
        case S_WII_DOWN:  return sideways ? T_RIGHT : T_DOWN;
        case S_WII_LEFT:  return sideways ? T_DOWN : T_LEFT;
        case S_WII_RIGHT: return sideways ? T_UP : T_RIGHT;
        case S_WII_A:     return sideways ? T_X : T_A;
        case S_WII_B:     return sideways ? T_R : T_ZR;
        case S_WII_1:     return sideways ? T_B : T_Y;
        case S_WII_2:     return sideways ? T_A : T_X;
        case S_WII_MINUS: return T_MINUS;
        case S_WII_PLUS:  return T_PLUS;
        case S_WII_HOME:  return T_HOME;
        case S_NUN_C:     return T_L;
        case S_NUN_Z:     return T_ZL;
        case S_CC_UP:     return T_UP;
        case S_CC_DOWN:   return T_DOWN;
        case S_CC_LEFT:   return T_LEFT;
        case S_CC_RIGHT:  return T_RIGHT;
        case S_CC_A:      return T_A;
        case S_CC_B:      return T_B;
        case S_CC_X:      return T_X;
        case S_CC_Y:      return T_Y;
        case S_CC_L:      return T_L;
        case S_CC_R:      return T_R;
        case S_CC_ZL:     return T_ZL;
        case S_CC_ZR:     return T_ZR;
        case S_CC_MINUS:  return T_MINUS;
        case S_CC_PLUS:   return T_PLUS;
        case S_CC_HOME:   return T_HOME;
        default:          return T_NONE;
    }
}

// Total input report lengths *including* the report ID byte.
static size_t ExpectedInputLength(uint8_t reportID) {
    switch (reportID) {
        case 0x20: return 7;
        case 0x21: return 22;
        case 0x22: return 5;
        case 0x30: return 3;
        case 0x31: return 6;
        case 0x32: return 11;
        case 0x33: return 18;
        case 0x34: return 22;
        case 0x35: return 22;
        default: return 0;
    }
}

static int16_t AxisToHID(float value) {
    value = std::clamp(value, -1.0f, 1.0f);
    return static_cast<int16_t>(value * 32767.0f);
}

static StickData MakeStick(float x, float y, float deadzone) {
    if (std::fabs(x) < deadzone && std::fabs(y) < deadzone) {
        return {0, 0, 0, 0};
    }
    // Same convention as DecodeJoystick: positive y means "up" on the
    // physical stick and is emitted as a negative HID value.
    return {AxisToHID(x), AxisToHID(-y), 0, 0};
}

static const char *ExtensionName(WiimoteExtension ext) {
    switch (ext) {
        case WiimoteExtension::Nunchuk: return "nunchuk";
        case WiimoteExtension::Classic: return "classic";
        case WiimoteExtension::MotionPlus: return "motionplus";
        case WiimoteExtension::Unknown: return "unknown";
        case WiimoteExtension::None: default: return "none";
    }
}

@interface WiimoteManager ()
- (void)deviceMatched:(IOHIDDeviceRef)device;
- (void)deviceRemoved:(IOHIDDeviceRef)device;
- (void)handleRawReport:(const uint8_t *)report length:(CFIndex)length reportID:(uint32_t)reportID;
@end

static void WiimoteMatchedCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)result; (void)sender;
    [(__bridge WiimoteManager *)context deviceMatched:device];
}

static void WiimoteRemovedCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)result; (void)sender;
    [(__bridge WiimoteManager *)context deviceRemoved:device];
}

static void WiimoteInputCallback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                 uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    (void)sender; (void)type;
    if (result != kIOReturnSuccess || !report || reportLength <= 0) {
        return;
    }
    [(__bridge WiimoteManager *)context handleRawReport:report length:reportLength reportID:reportID];
}

@implementation WiimoteManager {
    IOHIDManagerRef _manager;
    IOHIDDeviceRef _device;
    uint8_t _inputBuffer[64];
    dispatch_queue_t _writeQueue;
    WiimoteEventCallback _eventCallback;
    WiimoteStateCallback _stateCallback;
    WiimoteGamepadState _state;
    WiimoteExtension _extension;
    BOOL _extensionPresent;
    BOOL _rumble;
    int _battery;
    BOOL _haveNunchukCenter;
    int _nunchukCenterX, _nunchukCenterY;
    BOOL _haveClassicCenter;
    int _classicCenterLX, _classicCenterLY, _classicCenterRX, _classicCenterRY;
    uint32_t _lastReportedLeft, _lastReportedRight, _lastReportedSources;
    BOOL _loggedWriteError;

    // 0 = none, 1 = MotionPlus probe (0xA600FA), 2 = extension id (0xA400FA)
    int _pendingIDRead;
    BOOL _motionPlusProbed;
    BOOL _hasMotionPlus;
    BOOL _motionPlusActivating;
    BOOL _motionPlusActive;
    int _accZero[3];
    int _accOne[3];
    int _accRaw[3];
    BOOL _haveAccRaw;
    NSTimeInterval _lastMotionEmit;
    int _layoutMode;            // 0 = auto, 1 = upright (Joy-Con R), 2 = sideways
    int _overrides[S_COUNT];    // -1 = use preset, else SwitchTarget
    double _gyroBias[3];
    double _gyroBiasSum[3];
    int _gyroBiasSamples;
    int _gyroWindowMin[3], _gyroWindowMax[3];
    BOOL _invertPitch, _invertYaw, _invertRoll;
    NSString *_deviceKey;        // seriale (indirizzo Bluetooth) del telecomando, per lo zero salvato
    BOOL _biasFromMemory;        // zero del giroscopio ripreso dalla volta scorsa, non ancora rimisurato
    int _probeAttempts;          // letture di 0xA600FA fallite di fila
    int _activateAttempts;       // attivazioni MotionPlus senza risposta
    BOOL _extensionInitTried;    // init 0x55 già fatto per l'estensione attuale
    BOOL _calibrationRequested;  // ricalibrazione chiesta dall'utente: serve appoggiarlo piatto
    BOOL _motionPlusBuiltIn;     // primo byte dell'ID: 01 integrato, 00 adattatore
    uint8_t _playerLED;          // bit LED (0x10…0x80) del numero giocatore
    // Modalità veloce del MotionPlus (oltre ~440 gradi/s): scala e zero diversi da quella lenta.
    uint8_t _mpCal[32];
    int _mpCalParts;
    double _fastRatio[3];        // conteggi per grado/s lenti / veloci (da calibrazione di fabbrica)
    double _fastZero[3];         // zero in modalità veloce, imparato ai cambi di modalità
    int _fastZeroN[3];
    BOOL _histSlow[3], _histSlow2[3], _haveHistory;
    double _histRate[3], _histRate2[3];
    int _lastFastRaw[3];
    BOOL _exitPending[3];
    int _exitRaw[3];
    double _exitRate[3];
    // Aggiornamento lento dello zero solo quando è appoggiato (finestra di ~1 s).
    double _restSum[3];
    int _restSamples;
    int _restMin[3], _restMax[3];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _writeQueue = dispatch_queue_create("joycon2mac.wiimote.write", DISPATCH_QUEUE_SERIAL);
        _extension = WiimoteExtension::None;
        _battery = -1;
        _layoutMode = 0;
        for (int i = 0; i < S_COUNT; i++) _overrides[i] = -1;
        [self resetCalibration];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)resetCalibration {
    for (int i = 0; i < 3; i++) {
        _accZero[i] = 512;   // typical values; replaced by the EEPROM calibration
        _accOne[i] = 616;
        _gyroBias[i] = 8192;
        _gyroBiasSum[i] = 0;
    }
    _gyroBiasSamples = 0;
    _biasFromMemory = NO;
    _restSamples = 0;
    _haveAccRaw = NO;
    [self resetFastMode];
}

// Zero del giroscopio salvato per telecomando e tipo di MotionPlus (cambia da esemplare
// a esemplare): alla connessione successiva si parte già calibrati.
- (NSString *)gyroBiasKey {
    if (_deviceKey.length == 0) return nil;
    return [NSString stringWithFormat:@"wiiZero.%@.%@", _deviceKey, _motionPlusBuiltIn ? @"integrato" : @"esterno"];
}

- (void)saveGyroBias {
    NSString *key = [self gyroBiasKey];
    if (!key) return;
    [[NSUserDefaults standardUserDefaults] setObject:@[@(_gyroBias[0]), @(_gyroBias[1]), @(_gyroBias[2])] forKey:key];
}

- (void)loadGyroBias {
    NSString *key = [self gyroBiasKey];
    NSArray *saved = key ? [[NSUserDefaults standardUserDefaults] arrayForKey:key] : nil;
    if (saved.count != 3) return;
    for (int i = 0; i < 3; i++) {
        double v = [saved[i] doubleValue];
        if (v < 6000 || v > 10400) return;   // valore assurdo: meglio rimisurare
        _gyroBias[i] = v;
    }
    _biasFromMemory = YES;
    std::cout << "[Wiimote] MotionPlus zero restored from last session" << std::endl;
}

- (void)resetFastMode {
    for (int i = 0; i < 3; i++) {
        _fastRatio[i] = 2000.0 / 440.0;   // nominale, finché non arriva la calibrazione di fabbrica
        _fastZeroN[i] = 0;
        _exitPending[i] = NO;
    }
    _mpCalParts = 0;
    _haveHistory = NO;
}

/// Calibrazione di fabbrica: due blocchi da 16 byte (0x20 veloce, 0x30 lenta), ciascuno
/// con zero e "scala" (valore letto a N gradi/s) per imbardata, rollio, beccheggio, in
/// 16 bit big-endian (14 bit utili), e N/6 in un byte. Gli zeri derivano con la
/// temperatura (si usano quelli misurati); il rapporto tra le scale invece è stabile:
/// verificato entro l'1% contro i salti misurati ai cambi di modalità.
- (void)parseMotionPlusCalibration {
    auto u16 = [&](int o) { return (double)(((int)_mpCal[o] << 8) | _mpCal[o + 1]) / 4.0; };
    double fastDeg = _mpCal[12] * 6.0, slowDeg = _mpCal[16 + 12] * 6.0;
    if (fastDeg <= 0 || slowDeg <= 0) return;
    for (int i = 0; i < 3; i++) {
        double fast = std::fabs(u16(6 + i * 2) - u16(i * 2)) / fastDeg;              // conteggi per grado/s
        double slow = std::fabs(u16(16 + 6 + i * 2) - u16(16 + i * 2)) / slowDeg;
        double ratio = fast > 0 ? slow / fast : 0;
        if (ratio > 3.5 && ratio < 5.5) _fastRatio[i] = ratio;   // altrimenti resta il nominale
    }
    printf("[Wiimote] MotionPlus fast/slow ratio %.3f %.3f %.3f\n", _fastRatio[0], _fastRatio[1], _fastRatio[2]);
    fflush(stdout);
}

/// Zero della modalità veloce: all'inizio lo stesso scostamento in gradi/s della lenta.
- (double)fastZero:(int)i {
    return _fastZeroN[i] ? _fastZero[i] : 8192 + (_gyroBias[i] - 8192) / _fastRatio[i];
}

/// Un cambio di modalità: la velocità vera è continua, quindi il conteggio veloce deve
/// dare la velocità estrapolata dal lato lento. Media mobile, scarta i valori assurdi.
- (void)addFastZeroSample:(int)i raw:(int)raw rate:(double)expected scale:(double)fastScale {
    double implied = raw - expected / fastScale;
    if (_fastZeroN[i] > 5 && std::fabs(implied - _fastZero[i]) > 400) return;
    int n = std::min(_fastZeroN[i] + 1, 30);
    _fastZero[i] = _fastZeroN[i] ? _fastZero[i] + (implied - _fastZero[i]) / n : implied;
    _fastZeroN[i]++;
}

- (BOOL)usesSidewaysLayout {
    if (_extension == WiimoteExtension::Nunchuk || _extension == WiimoteExtension::Classic) return NO;
    if (_layoutMode == 1) return NO;
    if (_layoutMode == 2) return YES;
    return _extension != WiimoteExtension::MotionPlus;   // auto
}

- (void)setLayoutMode:(NSString *)mode overrides:(NSDictionary<NSString *, NSString *> *)overrides {
    _layoutMode = [mode isEqualToString:@"upright"] ? 1 : [mode isEqualToString:@"sideways"] ? 2 : 0;
    for (int i = 0; i < S_COUNT; i++) {
        _overrides[i] = -1;
        NSString *target = overrides[[NSString stringWithUTF8String:kSourceNames[i]]];
        if (![target isKindOfClass:[NSString class]]) continue;
        for (int t = 0; t < T_COUNT; t++) {
            if ([target isEqualToString:[NSString stringWithUTF8String:kTargetNames[t]]]) {
                _overrides[i] = t;
                break;
            }
        }
    }
    std::cout << "[Wiimote] Mapping updated (layout " << [mode UTF8String] << ")" << std::endl;
    [self emit:"status" detail:[self statusJSON]];
}

- (void)emitMotionIfDue {
    NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
    if (now - _lastMotionEmit < 0.12) return;   // ~8 Hz is enough for a readout
    _lastMotionEmit = now;
    char json[256];
    snprintf(json, sizeof(json),
             "{\"mp\":%s,\"calibrated\":%s,\"pitch\":%.1f,\"yaw\":%.1f,\"roll\":%.1f,\"ax\":%.2f,\"ay\":%.2f,\"az\":%.2f}",
             _state.motionPlusActive ? "true" : "false",
             _gyroBiasSamples >= kCalibrationSamples ? "true" : "false",
             _state.gyroPitch, _state.gyroYaw, _state.gyroRoll,
             _state.accelX, _state.accelY, _state.accelZ);
    [self emit:"motion" detail:std::string(json)];
}

- (void)recalibrate {
    for (int i = 0; i < 3; i++) { _gyroBiasSum[i] = 0; }
    _gyroBiasSamples = 0;
    _biasFromMemory = NO;      // si mostra di nuovo "appoggialo piatto" finché non è rimisurato
    _calibrationRequested = YES;
    _haveNunchukCenter = NO;
    _haveClassicCenter = NO;
    std::cout << "[Wiimote] Recalibrating - lay it face down on a flat surface" << std::endl;
    [self emit:"calibrating" detail:[self statusJSON]];
    if (!_motionPlusActive) {
        // Nothing to average without MotionPlus: sticks re-centre on the
        // next report, so report completion straight away.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self emit:"calibrated" detail:[self statusJSON]];
        });
    }
}

- (void)setInvertPitch:(BOOL)pitch yaw:(BOOL)yaw roll:(BOOL)roll {
    _invertPitch = pitch;
    _invertYaw = yaw;
    _invertRoll = roll;
}

- (void)setEventCallback:(WiimoteEventCallback)callback { _eventCallback = callback; }
- (void)setStateCallback:(WiimoteStateCallback)callback { _stateCallback = callback; }
- (WiimoteGamepadState)currentState { return _state; }

- (void)emit:(const char *)status detail:(const std::string &)json {
    if (_eventCallback) {
        _eventCallback(status, json);
    }
}

- (std::string)statusJSON {
    std::ostringstream out;
    out << "{\"connected\":" << (_device ? "true" : "false")
        << ",\"extension\":\"" << ExtensionName(_extension) << "\""
        << ",\"battery\":" << _battery
        << ",\"motionPlus\":\"" << (_motionPlusActive ? "active"
                                    : _hasMotionPlus ? "inactive"
                                    : _motionPlusProbed ? "absent" : "unknown") << "\""
        << ",\"mode\":\"" << (_extension == WiimoteExtension::Classic ? "classic"
                              : [self usesSidewaysLayout] ? "sideways" : "upright")
        << "\"}";
    return out.str();
}

#pragma mark - Lifecycle

- (void)start {
    if (_manager) {
        return;
    }
    _manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!_manager) {
        std::cout << "[Wiimote] IOHIDManagerCreate failed" << std::endl;
        return;
    }

    NSArray *matching = @[
        @{ @kIOHIDVendorIDKey: @(kNintendoVendorID), @kIOHIDProductIDKey: @(kWiimoteProductID) },
        @{ @kIOHIDVendorIDKey: @(kNintendoVendorID), @kIOHIDProductIDKey: @(kWiimotePlusProductID) },
    ];
    IOHIDManagerSetDeviceMatchingMultiple(_manager, (__bridge CFArrayRef)matching);
    IOHIDManagerRegisterDeviceMatchingCallback(_manager, WiimoteMatchedCallback, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(_manager, WiimoteRemovedCallback, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    // JoyConFinto: seize the remote so JoyCon2Mac's daemon doesn't also turn
    // it into a gamepad; fall back to shared access if that is refused.
    IOReturn openResult = IOHIDManagerOpen(_manager, kIOHIDOptionsTypeSeizeDevice);
    if (openResult != kIOReturnSuccess) {
        openResult = IOHIDManagerOpen(_manager, kIOHIDOptionsTypeNone);
    }
    if (openResult != kIOReturnSuccess) {
        std::cout << "[Wiimote] IOHIDManagerOpen failed: 0x" << std::hex << openResult << std::dec << std::endl;
    }
    std::cout << "[Wiimote] Waiting for a paired Wii Remote (pair it once with WiimotePair)" << std::endl;
    [self emit:"searching" detail:[self statusJSON]];
}

- (void)stop {
    if (_device) {
        [self deviceRemoved:_device];
    }
    if (_manager) {
        IOHIDManagerUnscheduleFromRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(_manager, kIOHIDOptionsTypeNone);
        CFRelease(_manager);
        _manager = nullptr;
    }
}

- (void)attachDevice:(IOHIDDeviceRef)device { [self deviceMatched:device]; }
- (void)detachDevice:(IOHIDDeviceRef)device { [self deviceRemoved:device]; }
- (BOOL)ownsDevice:(IOHIDDeviceRef)device { return _device && CFEqual(_device, device); }

- (void)setPlayerIndex:(int)index {
    _playerLED = (uint8_t)(0x10 << std::clamp(index, 0, 3));
    if (_device) [self sendReport:std::vector<uint8_t>{0x11, _playerLED} delayMicros:20000];
}

- (void)deviceMatched:(IOHIDDeviceRef)device {
    if (_device) {
        // One Wii Remote at a time keeps the merged gamepad unambiguous.
        std::cout << "[Wiimote] Additional Wii Remote ignored" << std::endl;
        return;
    }
    _device = (IOHIDDeviceRef)CFRetain(device);
    _extension = WiimoteExtension::None;
    _extensionPresent = NO;
    _haveNunchukCenter = NO;
    _haveClassicCenter = NO;
    _state = WiimoteGamepadState();
    _state.connected = true;
    _loggedWriteError = NO;
    _pendingIDRead = 0;
    _motionPlusProbed = NO;
    _hasMotionPlus = NO;
    _motionPlusActivating = NO;
    _motionPlusActive = NO;
    _probeAttempts = 0;
    _activateAttempts = 0;
    _extensionInitTried = NO;
    _calibrationRequested = NO;
    [self resetCalibration];
    NSString *serial = (__bridge NSString *)IOHIDDeviceGetProperty(_device, CFSTR(kIOHIDSerialNumberKey));
    NSNumber *location = (__bridge NSNumber *)IOHIDDeviceGetProperty(_device, CFSTR(kIOHIDLocationIDKey));
    _deviceKey = serial.length ? serial : (location ? [NSString stringWithFormat:@"loc%@", location] : nil);

    IOHIDDeviceRegisterInputReportCallback(_device, _inputBuffer, sizeof(_inputBuffer),
                                           WiimoteInputCallback, (__bridge void *)self);

    NSString *product = (__bridge NSString *)IOHIDDeviceGetProperty(_device, CFSTR(kIOHIDProductKey));
    std::cout << "[Wiimote] Connected: " << (product ? [product UTF8String] : "Wii Remote") << std::endl;

    // LED del giocatore (1…4); senza numero assegnato il quarto, come prima.
    [self sendReport:std::vector<uint8_t>{0x11, (uint8_t)(_playerLED ? _playerLED : 0x80)} delayMicros:20000];
    // Accelerometer calibration lives in EEPROM at 0x0016 (10 bytes).
    [self sendReport:std::vector<uint8_t>{0x17, 0x00, 0x00, 0x00, 0x16, 0x00, 0x0A} delayMicros:20000];
    // Ask for status: tells us whether an extension is plugged in and the
    // battery level. The reply (0x20) also triggers the reporting-mode setup.
    [self sendReport:std::vector<uint8_t>{0x15, 0x00} delayMicros:20000];

    [self emit:"connected" detail:[self statusJSON]];
    if (_stateCallback) _stateCallback(_state);
}

- (void)deviceRemoved:(IOHIDDeviceRef)device {
    if (!_device || device != _device) {
        return;
    }
    std::cout << "[Wiimote] Disconnected" << std::endl;
    IOHIDDeviceRegisterInputReportCallback(_device, _inputBuffer, sizeof(_inputBuffer), nullptr, nullptr);
    CFRelease(_device);
    _device = nullptr;
    _extension = WiimoteExtension::None;
    _extensionPresent = NO;
    _motionPlusActive = NO;
    _motionPlusActivating = NO;
    _state = WiimoteGamepadState();
    [self emit:"disconnected" detail:[self statusJSON]];
    if (_stateCallback) _stateCallback(_state);
}

#pragma mark - Output

- (void)sendReport:(std::vector<uint8_t>)bytes delayMicros:(useconds_t)delay {
    if (!_device || bytes.empty()) {
        return;
    }
    if (bytes.size() > 1) {
        // Bit 0 of the first payload byte is the rumble motor on every
        // output report; keep it in sync or each write would stop rumble.
        bytes[1] = (uint8_t)((bytes[1] & ~0x01) | (_rumble ? 0x01 : 0x00));
    }
    IOHIDDeviceRef device = (IOHIDDeviceRef)CFRetain(_device);
    __weak WiimoteManager *weakSelf = self;
    dispatch_async(_writeQueue, ^{
        // macOS expects the report ID as the first byte for numbered reports
        // (same convention hidapi uses, which is what Dolphin relies on).
        IOReturn r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, bytes[0],
                                          bytes.data(), (CFIndex)bytes.size());
        CFRelease(device);
        if (r != kIOReturnSuccess) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WiimoteManager *strongSelf = weakSelf;
                if (strongSelf && !strongSelf->_loggedWriteError) {
                    strongSelf->_loggedWriteError = YES;
                    std::cout << "[Wiimote] Output report failed: 0x" << std::hex << r << std::dec << std::endl;
                }
            });
        }
        // The Wii Remote drops writes that arrive back-to-back.
        usleep(delay);
    });
}

- (void)setReportingMode {
    // 0x35 = buttons + accel + 16 ext bytes, 0x31 = buttons + accel.
    // 0x04 = continuous: without it the remote only sends a report when a
    // button changes, so gyro/accel values froze between button presses.
    // Must be re-sent after every status report.
    uint8_t mode = _extensionPresent ? 0x35 : 0x31;
    [self sendReport:std::vector<uint8_t>{0x12, 0x04, mode} delayMicros:20000];
}

- (void)writeRegister:(uint32_t)address value:(uint8_t)value {
    std::vector<uint8_t> report(22, 0x00);
    report[0] = 0x16;
    report[1] = 0x04;  // control registers
    report[2] = (uint8_t)((address >> 16) & 0xFF);
    report[3] = (uint8_t)((address >> 8) & 0xFF);
    report[4] = (uint8_t)(address & 0xFF);
    report[5] = 0x01;  // size
    report[6] = value;
    [self sendReport:report delayMicros:50000];
}

- (void)initializeExtension {
    // "New" unencrypted init: 0x55 -> 0xA400F0, 0x00 -> 0xA400FB.
    [self writeRegister:0xA400F0 value:0x55];
    [self writeRegister:0xA400FB value:0x00];
    [self readExtensionID];
}

- (void)readExtensionID {
    // 6-byte extension identifier at 0xA400FA.
    _pendingIDRead = 2;
    [self sendReport:std::vector<uint8_t>{0x17, 0x04, 0xA4, 0x00, 0xFA, 0x00, 0x06} delayMicros:20000];
}

- (void)probeMotionPlus {
    // A Wii Remote Plus (or a MotionPlus dongle) answers at 0xA600FA while
    // inactive; older remotes return a read error.
    _motionPlusProbed = YES;
    _pendingIDRead = 1;
    [self sendReport:std::vector<uint8_t>{0x17, 0x04, 0xA6, 0x00, 0xFA, 0x00, 0x06} delayMicros:20000];
}

/// Rilegge 0xA600FA più tardi: dopo una lettura fallita, o di continuo (ogni 3 s)
/// finché non c'è un MotionPlus, così un adattatore esterno inserito dopo la
/// connessione viene trovato.
- (void)scheduleProbeAfter:(double)seconds {
    __weak WiimoteManager *weakSelf = self;
    IOHIDDeviceRef device = _device;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WiimoteManager *me = weakSelf;
        if (!me || !me->_device || me->_device != device) return;
        if (me->_hasMotionPlus || me->_extensionPresent || me->_motionPlusActivating || me->_pendingIDRead) return;
        [me probeMotionPlus];
    });
}

- (void)activateMotionPlus {
    // Standalone mode (0x04). Nunchuk pass-through is not used: with a
    // Nunchuk plugged in, the Nunchuk wins and MotionPlus stays off.
    std::cout << "[Wiimote] Activating MotionPlus" << std::endl;
    _motionPlusActivating = YES;
    _activateAttempts++;
    for (int i = 0; i < 3; i++) { _gyroBiasSum[i] = 0; _gyroBias[i] = 8192; }
    _gyroBiasSamples = 0;
    _biasFromMemory = NO;
    [self loadGyroBias];
    [self writeRegister:0xA600F0 value:0x55];
    [self writeRegister:0xA600FE value:0x04];

    // Se il telecomando perde una delle due scritture il MotionPlus non compare:
    // riprova fino a 3 volte.
    __weak WiimoteManager *weakSelf = self;
    IOHIDDeviceRef device = _device;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WiimoteManager *me = weakSelf;
        if (!me || me->_device != device || !me->_motionPlusActivating || me->_motionPlusActive) return;
        if (me->_activateAttempts < 3) {
            [me activateMotionPlus];
        } else {
            std::cout << "[Wiimote] MotionPlus did not switch on" << std::endl;
            me->_motionPlusActivating = NO;
        }
    });
}

- (void)setRumble:(BOOL)on {
    if (_rumble == on) return;
    _rumble = on;
    [self sendReport:std::vector<uint8_t>{0x10, 0x00} delayMicros:0];
}

#pragma mark - Input

- (void)handleRawReport:(const uint8_t *)raw length:(CFIndex)length reportID:(uint32_t)reportID {
    // Normalise so report[0] is always the report ID.
    std::vector<uint8_t> report;
    size_t expected = ExpectedInputLength((uint8_t)reportID);
    if (expected && (size_t)length == expected - 1) {
        report.push_back((uint8_t)reportID);
        report.insert(report.end(), raw, raw + length);
    } else if (raw[0] == (uint8_t)reportID) {
        report.assign(raw, raw + length);
    } else {
        report.push_back((uint8_t)reportID);
        report.insert(report.end(), raw, raw + length);
    }
    if (report.size() < 3) {
        return;
    }

    const uint8_t id = report[0];
    const uint8_t core1 = report[1] & 0x1F;
    const uint8_t core2 = report[2] & 0x9F;
    const uint8_t *ext = nullptr;

    switch (id) {
        case 0x20: {  // status
            if (report.size() < 7) return;
            BOOL present = (report[3] & 0x02) != 0;
            _battery = (int)std::lround(report[6] * 100.0 / 0xC8);
            _battery = std::clamp(_battery, 0, 100);
            if (present && !_extensionPresent) {
                _extensionPresent = YES;
                if (_motionPlusActivating || _motionPlusActive) {
                    // MotionPlus just switched on and now shows up as the
                    // extension. Do NOT write 0x55 to 0xA400F0: that would
                    // switch it straight back off.
                    _motionPlusActivating = NO;
                    _motionPlusActive = YES;
                    [self readExtensionID];
                } else {
                    // Prima si legge l'ID senza inizializzare: il MotionPlus può essere
                    // ancora attivo da una sessione precedente, e l'init 0x55 lo spegnerebbe.
                    std::cout << "[Wiimote] Extension plugged in, reading its id" << std::endl;
                    _extensionInitTried = NO;
                    [self readExtensionID];
                }
            } else if (!present && _extensionPresent) {
                _extensionPresent = NO;
                _extension = WiimoteExtension::None;
                _motionPlusActive = NO;
                std::cout << "[Wiimote] Extension removed" << std::endl;
                [self emit:"extension" detail:[self statusJSON]];
                // Nunchuk tolto da un Wii Remote Plus, o adattatore MotionPlus staccato:
                // si ricontrolla 0xA600FA e, se c'è, si riattiva.
                _hasMotionPlus = NO;
                _probeAttempts = 0;
                _activateAttempts = 0;
                [self probeMotionPlus];
            } else if (!present && !_extensionPresent && !_motionPlusProbed) {
                [self probeMotionPlus];
            }
            [self setReportingMode];
            [self emit:"status" detail:[self statusJSON]];
            break;
        }
        case 0x21: {  // memory read reply
            if (report.size() < 12) return;
            uint8_t error = report[3] & 0x0F;
            uint16_t address = (uint16_t)((report[4] << 8) | report[5]);
            if (address == 0x0016) {
                if (error == 0 && report.size() >= 16) {
                    const uint8_t *c = &report[6];
                    _accZero[0] = (c[0] << 2) | ((c[3] >> 4) & 0x03);
                    _accZero[1] = (c[1] << 2) | ((c[3] >> 2) & 0x03);
                    _accZero[2] = (c[2] << 2) | (c[3] & 0x03);
                    _accOne[0] = (c[4] << 2) | ((c[7] >> 4) & 0x03);
                    _accOne[1] = (c[5] << 2) | ((c[7] >> 2) & 0x03);
                    _accOne[2] = (c[6] << 2) | (c[7] & 0x03);
                    for (int i = 0; i < 3; i++) {
                        if (_accOne[i] - _accZero[i] < 40) { _accZero[i] = 512; _accOne[i] = 616; }
                    }
                }
                break;
            }
            if ((address == 0x0020 || address == 0x0030) && error == 0 && report.size() >= 22) {
                memcpy(&_mpCal[address - 0x20], &report[6], 16);
                _mpCalParts |= address == 0x0020 ? 1 : 2;
                if (_mpCalParts == 3) [self parseMotionPlusCalibration];
                break;
            }
            if (address == 0x00FA && _pendingIDRead == 1) {
                _pendingIDRead = 0;
                if (error == 0 && IsMotionPlusID(&report[6])) {
                    _hasMotionPlus = YES;
                    _motionPlusBuiltIn = report[6] == 0x01;
                    _probeAttempts = 0;
                    std::cout << "[Wiimote] MotionPlus found" << std::endl;
                    if (!_extensionPresent) {
                        _activateAttempts = 0;
                        [self activateMotionPlus];
                    }
                } else {
                    _hasMotionPlus = NO;
                    _probeAttempts++;
                    if (_probeAttempts == 3) std::cout << "[Wiimote] No MotionPlus on this remote (yet)" << std::endl;
                    // Subito dopo la connessione le letture possono fallire: riprova presto,
                    // poi ogni 3 s per un adattatore inserito più tardi.
                    [self scheduleProbeAfter:(_probeAttempts < 3 ? 0.4 : 3.0)];
                }
                [self emit:"status" detail:[self statusJSON]];
                break;
            }
            if (error == 0 && address == 0x00FA) {
                _pendingIDRead = 0;
                const uint8_t *idBytes = &report[6];
                if (IsActiveMotionPlusID(idBytes)) {
                    _extension = WiimoteExtension::MotionPlus;
                    _motionPlusBuiltIn = idBytes[0] == 0x01;
                    // Calibrazione di fabbrica (32 byte a 0xA40020): serve il rapporto di scala
                    // tra modalità veloce e lenta di ciascun asse.
                    [self sendReport:std::vector<uint8_t>{0x17, 0x04, 0xA4, 0x00, 0x20, 0x00, 0x20} delayMicros:20000];
                    _motionPlusActive = YES;
                    _motionPlusActivating = NO;
                    _hasMotionPlus = YES;
                } else if (IsMotionPlusID(idBytes)) {
                    // MotionPlus presente ma spento (es. dopo un init 0x55): riaccendilo.
                    _extension = WiimoteExtension::None;
                    _hasMotionPlus = YES;
                    _motionPlusActive = NO;
                    _activateAttempts = 0;
                    std::cout << "[Wiimote] MotionPlus is off, switching it on" << std::endl;
                    [self activateMotionPlus];
                    [self setReportingMode];
                    break;
                } else if (!_extensionInitTried && !_motionPlusActive) {
                    // Non è un MotionPlus attivo: inizializza l'estensione (Nunchuk,
                    // Classic...) e rileggi l'ID.
                    _extensionInitTried = YES;
                    std::cout << "[Wiimote] Initialising extension" << std::endl;
                    [self initializeExtension];
                    break;
                } else if (idBytes[4] == 0x00 && idBytes[5] == 0x00) {
                    _extension = WiimoteExtension::Nunchuk;
                } else if (idBytes[4] == 0x01 && idBytes[5] == 0x01) {
                    _extension = WiimoteExtension::Classic;
                } else {
                    _extension = WiimoteExtension::Unknown;
                }
                _haveNunchukCenter = NO;
                _haveClassicCenter = NO;
                char idHex[32];
                snprintf(idHex, sizeof(idHex), "%02X%02X%02X%02X%02X%02X",
                         idBytes[0], idBytes[1], idBytes[2], idBytes[3], idBytes[4], idBytes[5]);
                std::cout << "[Wiimote] Extension: " << ExtensionName(_extension)
                          << " (id " << idHex << ")" << std::endl;
                [self emit:"extension" detail:[self statusJSON]];
            }
            [self setReportingMode];
            break;
        }
        case 0x22:  // write acknowledgement
            break;
        case 0x32:
            if (report.size() >= 11) ext = &report[3];
            break;
        case 0x34:
            if (report.size() >= 22) ext = &report[3];
            break;
        case 0x35:
            if (report.size() >= 22) ext = &report[6];
            break;
        default:
            break;
    }

    if ((id == 0x31 || id == 0x33 || id == 0x35) && report.size() >= 6) {
        // 10-bit accel: 8 MSBs in bytes 3..5, LSBs hidden in the button bytes.
        _accRaw[0] = (report[3] << 2) | ((report[1] >> 5) & 0x03);
        _accRaw[1] = (report[4] << 2) | ((report[2] >> 4) & 0x02);
        _accRaw[2] = (report[5] << 2) | ((report[2] >> 5) & 0x02);
        _haveAccRaw = YES;
    }

    [self updateStateWithCore1:core1 core2:core2 extension:(_extensionPresent ? ext : nullptr)];
}

- (void)updateMotionWithExtension:(const uint8_t *)e {
    _state.hasAccel = _haveAccRaw;
    _state.batteryPercent = _battery;
    _state.timestampUs = (uint64_t)([[NSProcessInfo processInfo] systemUptime] * 1e6);

    // Wii Remote frame: +X towards the left side, +Y out of the IR end,
    // +Z out of the button face. Gravity reads +1g on Z when lying face up.
    float ax = 0, ay = 0, az = 0;
    if (_haveAccRaw) {
        ax = (float)(_accRaw[0] - _accZero[0]) / (float)(_accOne[0] - _accZero[0]);
        ay = (float)(_accRaw[1] - _accZero[1]) / (float)(_accOne[1] - _accZero[1]);
        az = (float)(_accRaw[2] - _accZero[2]) / (float)(_accOne[2] - _accZero[2]);
    }
    // DSU/DS4 frame (controller lying flat, front towards the screen):
    // +X right, +Y up, +Z towards the player.
    // Verificato con pose note (punta al soffitto / in giù): l'asse lungo del Wii
    // Remote va preso con questo segno, altrimenti avanti e indietro risultano
    // specchiati e nel gioco la punta si alza quando la abbassi.
    _state.accelX = -ax;
    _state.accelY = az;
    _state.accelZ = ay;

    _state.motionPlusActive = _motionPlusActive && _extension == WiimoteExtension::MotionPlus;
    _state.motionPlusBuiltIn = _motionPlusBuiltIn;
    if (!_state.motionPlusActive || !e || !(e[5] & 0x02)) {
        if (!_state.motionPlusActive) {
            _state.gyroPitch = _state.gyroYaw = _state.gyroRoll = 0;
            _state.calibration = 0;
        }
        return;
    }

    int raw[3];
    raw[0] = e[0] | ((e[3] & 0xFC) << 6);  // yaw   (around Z)
    raw[1] = e[1] | ((e[4] & 0xFC) << 6);  // roll  (around Y)
    raw[2] = e[2] | ((e[5] & 0xFC) << 6);  // pitch (around X)
    bool slow[3] = { (e[3] & 0x02) != 0, (e[4] & 0x02) != 0, (e[3] & 0x01) != 0 };

    // ~8192/595 counts per deg/s in slow mode, 2000/440 times fewer in fast.
    const double slowScale = 595.0 / 8192.0;
    const double fastScale = slowScale * 2000.0 / 440.0;

    // Zero del giroscopio. Si impara dalla media di ~1 s di campioni fermi:
    // - subito dopo l'attivazione, in qualsiasi posizione;
    // - quando l'utente chiede "Ricalibra": solo appoggiato piatto su un piano
    //   (a faccia in giù come sulla Wii; va bene anche a faccia in su).
    // Se si muove durante la misura, la finestra riparte.
    if (_gyroBiasSamples < kCalibrationSamples) {
        bool flat = std::fabs(_state.accelY) > 0.85 && std::fabs(_state.accelX) < 0.3 && std::fabs(_state.accelZ) < 0.3;
        bool ready = !_calibrationRequested || flat;
        if (_gyroBiasSamples == 0) {
            for (int i = 0; i < 3; i++) { _gyroWindowMin[i] = raw[i]; _gyroWindowMax[i] = raw[i]; _gyroBiasSum[i] = 0; }
        }
        bool moved = !ready;
        for (int i = 0; i < 3; i++) {
            _gyroWindowMin[i] = std::min(_gyroWindowMin[i], raw[i]);
            _gyroWindowMax[i] = std::max(_gyroWindowMax[i], raw[i]);
            if (_gyroWindowMax[i] - _gyroWindowMin[i] > kCalibrationSpread) moved = true;
        }
        if (moved) {
            _gyroBiasSamples = 0;
        } else {
            for (int i = 0; i < 3; i++) _gyroBiasSum[i] += raw[i];
            _gyroBiasSamples++;
        }
        // Con lo zero della volta scorsa si gioca subito; la misura nuova, appena il
        // telecomando sta fermo un secondo, lo sostituisce.
        _state.calibration = _biasFromMemory ? 0 : (_gyroBiasSamples > 0 ? 2 : 1);
        if (_gyroBiasSamples == kCalibrationSamples) {
            for (int i = 0; i < 3; i++) _gyroBias[i] = _gyroBiasSum[i] / kCalibrationSamples;
            _calibrationRequested = NO;
            _biasFromMemory = NO;
            _restSamples = 0;
            _state.calibration = 0;
            [self saveGyroBias];
            std::cout << "[Wiimote] MotionPlus calibrated" << std::endl;
            [self emit:"calibrated" detail:[self statusJSON]];
        }
    }
    bool biasKnown = _gyroBiasSamples >= kCalibrationSamples || _biasFromMemory;

    // Deriva termica: lo zero si corregge solo quando il telecomando è davvero
    // appoggiato (oscillazione < ~1 grado/s per ~1 s). Prima si correggeva a ogni
    // campione sotto 3 gradi/s, e così i movimenti lenti venivano "mangiati".
    if (biasKnown) {
        if (_restSamples == 0) {
            for (int i = 0; i < 3; i++) { _restMin[i] = raw[i]; _restMax[i] = raw[i]; _restSum[i] = 0; }
        }
        bool resting = true;
        for (int i = 0; i < 3; i++) {
            _restMin[i] = std::min(_restMin[i], raw[i]);
            _restMax[i] = std::max(_restMax[i], raw[i]);
            if (_restMax[i] - _restMin[i] > kRestSpread) resting = false;
            _restSum[i] += raw[i];
        }
        if (!resting) {
            _restSamples = 0;
        } else if (++_restSamples == kCalibrationSamples) {
            for (int i = 0; i < 3; i++) _gyroBias[i] += (_restSum[i] / kCalibrationSamples - _gyroBias[i]) * 0.5;
            _restSamples = 0;
            [self saveGyroBias];
        }
    }

    // Modalità lenta: zero calibrato. Modalità veloce: scala dal rapporto di fabbrica e
    // zero imparato ai cambi (prima ogni cambio dava un salto fino a ~100 gradi/s).
    double rate[3];
    for (int i = 0; i < 3; i++) {
        double fs = slowScale * _fastRatio[i];
        rate[i] = slow[i] ? (raw[i] - _gyroBias[i]) * slowScale : (raw[i] - [self fastZero:i]) * fs;
        if (_haveHistory && biasKnown) {
            if (_histSlow[i] && _histSlow2[i] && !slow[i]) {
                // lento -> veloce: velocità attesa estrapolata dagli ultimi due campioni lenti
                [self addFastZeroSample:i raw:raw[i] rate:2 * _histRate[i] - _histRate2[i] scale:fs];
                rate[i] = (raw[i] - [self fastZero:i]) * fs;
                _exitPending[i] = NO;
            } else if (!_histSlow[i] && slow[i]) {
                // veloce -> lento: serve anche il campione successivo per estrapolare all'indietro
                _exitPending[i] = YES; _exitRaw[i] = _lastFastRaw[i]; _exitRate[i] = rate[i];
            } else if (_exitPending[i]) {
                _exitPending[i] = NO;
                if (slow[i]) [self addFastZeroSample:i raw:_exitRaw[i] rate:2 * _exitRate[i] - rate[i] scale:fs];
            }
        }
        _histSlow2[i] = _histSlow[i]; _histSlow[i] = slow[i];
        _histRate2[i] = _histRate[i]; _histRate[i] = rate[i];
        if (!slow[i]) _lastFastRaw[i] = raw[i];
    }
    _haveHistory = YES;
    (void)fastScale;

    float yaw = (float)rate[0], roll = (float)rate[1], pitch = (float)rate[2];
    // Segni coerenti con l'accelerometro qui sopra (rotazione propria, non uno specchio).
    _state.gyroPitch = _invertPitch ? pitch : -pitch;
    _state.gyroYaw   = _invertYaw ? yaw : -yaw;
    _state.gyroRoll  = _invertRoll ? -roll : roll;
}

- (void)updateStateWithCore1:(uint8_t)c1 core2:(uint8_t)c2 extension:(const uint8_t *)e {
    uint32_t left = 0, right = 0;
    StickData leftStick = {0, 0, 0, 0};
    StickData rightStick = {0, 0, 0, 0};
    uint8_t triggerL = 0, triggerR = 0;

    // 1. Which physical buttons are down.
    uint32_t sources = 0;
    auto setSource = [&](int source, bool down) { if (down) sources |= (1u << source); };
    setSource(S_WII_UP, c1 & W1_UP);
    setSource(S_WII_DOWN, c1 & W1_DOWN);
    setSource(S_WII_LEFT, c1 & W1_LEFT);
    setSource(S_WII_RIGHT, c1 & W1_RIGHT);
    setSource(S_WII_PLUS, c1 & W1_PLUS);
    setSource(S_WII_A, c2 & W2_A);
    setSource(S_WII_B, c2 & W2_B);
    setSource(S_WII_1, c2 & W2_ONE);
    setSource(S_WII_2, c2 & W2_TWO);
    setSource(S_WII_MINUS, c2 & W2_MINUS);
    setSource(S_WII_HOME, c2 & W2_HOME);

    if (_extension == WiimoteExtension::Classic && e) {
        // Classic / Classic Pro: buttons are active-low.
        uint8_t p4 = (uint8_t)~e[4];
        uint8_t p5 = (uint8_t)~e[5];
        setSource(S_CC_RIGHT, p4 & 0x80);
        setSource(S_CC_DOWN, p4 & 0x40);
        setSource(S_CC_L, p4 & 0x20);
        setSource(S_CC_MINUS, p4 & 0x10);
        setSource(S_CC_HOME, p4 & 0x08);
        setSource(S_CC_PLUS, p4 & 0x04);
        setSource(S_CC_R, p4 & 0x02);
        setSource(S_CC_ZL, p5 & 0x80);
        setSource(S_CC_B, p5 & 0x40);
        setSource(S_CC_Y, p5 & 0x20);
        setSource(S_CC_A, p5 & 0x10);
        setSource(S_CC_X, p5 & 0x08);
        setSource(S_CC_ZR, p5 & 0x04);
        setSource(S_CC_LEFT, p5 & 0x02);
        setSource(S_CC_UP, p5 & 0x01);

        int lx = e[0] & 0x3F;
        int ly = e[1] & 0x3F;
        int rx = ((e[0] & 0xC0) >> 3) | ((e[1] & 0xC0) >> 5) | ((e[2] & 0x80) >> 7);
        int ry = e[2] & 0x1F;
        int lt = ((e[2] & 0x60) >> 2) | ((e[3] & 0xE0) >> 5);
        int rt = e[3] & 0x1F;
        if (!_haveClassicCenter) {
            _classicCenterLX = (lx > 20 && lx < 44) ? lx : 32;
            _classicCenterLY = (ly > 20 && ly < 44) ? ly : 32;
            _classicCenterRX = (rx > 10 && rx < 22) ? rx : 16;
            _classicCenterRY = (ry > 10 && ry < 22) ? ry : 16;
            _haveClassicCenter = YES;
        }
        leftStick = MakeStick((lx - _classicCenterLX) / 26.0f, (ly - _classicCenterLY) / 26.0f, 0.10f);
        rightStick = MakeStick((rx - _classicCenterRX) / 13.0f, (ry - _classicCenterRY) / 13.0f, 0.12f);
        triggerL = (uint8_t)std::min(255, lt * 255 / 31);
        triggerR = (uint8_t)std::min(255, rt * 255 / 31);
    } else if (_extension == WiimoteExtension::Nunchuk && e) {
        setSource(S_NUN_C, !(e[5] & 0x02));   // active low
        setSource(S_NUN_Z, !(e[5] & 0x01));
        int sx = e[0], sy = e[1];
        if (!_haveNunchukCenter) {
            _nunchukCenterX = (sx > 100 && sx < 156) ? sx : 128;
            _nunchukCenterY = (sy > 100 && sy < 156) ? sy : 128;
            _haveNunchukCenter = YES;
        }
        leftStick = MakeStick((sx - _nunchukCenterX) / 100.0f, (sy - _nunchukCenterY) / 100.0f, 0.10f);
    }

    // 2. Translate through the preset + user overrides into Switch buttons.
    bool sideways = [self usesSidewaysLayout];
    for (int source = 0; source < S_COUNT; source++) {
        if (!(sources & (1u << source))) continue;
        int target = _overrides[source] >= 0 ? _overrides[source] : PresetTarget(source, sideways);
        ApplyTarget(target, left, right);
    }

    _state.connected = true;
    _state.sources = sources;
    _state.leftButtons = left;
    _state.rightButtons = right;
    _state.leftStick = leftStick;
    _state.rightStick = rightStick;
    _state.triggerL = triggerL;
    _state.triggerR = triggerR;
    [self updateMotionWithExtension:e];
    [self emitMotionIfDue];

    if (_stateCallback) {
        _stateCallback(_state);
    }

    if (left != _lastReportedLeft || right != _lastReportedRight || sources != _lastReportedSources) {
        _lastReportedLeft = left;
        _lastReportedRight = right;
        _lastReportedSources = sources;
        std::ostringstream pressed;
        pressed << "{\"left\":" << left << ",\"right\":" << right << ",\"sources\":" << sources << "}";
        [self emit:"input" detail:pressed.str()];
    }
}

@end
