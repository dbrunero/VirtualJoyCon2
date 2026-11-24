// Ponte Swift ↔ WiimoteManager (copiato da JoyCon2Mac): espone lo stato del
// Wii Remote (Plus) con soli tipi C, così Swift può leggerlo senza C++.

#import <Foundation/Foundation.h>

typedef struct {
    bool connected;
    // Un bit per tasto fisico: 0 su, 1 giù, 2 sinistra, 3 destra, 4 A, 5 B,
    // 6 Uno, 7 Due, 8 Meno, 9 Più, 10 Home, 11 Nunchuk C, 12 Nunchuk Z.
    uint32_t buttons;
    // Stick del Nunchuk, -32767…32767 (positivo = destra / giù); 0 se assente.
    int16_t nunchukX, nunchukY;
    bool motionPlus;
    // Già ruotati nel riferimento DSU (telecomando disteso, punta verso lo
    // schermo: +X destra, +Y su, +Z verso il giocatore). g e gradi/s.
    float accelX, accelY, accelZ;
    float gyroPitch, gyroYaw, gyroRoll;
    int battery;
    // Calibrazione giroscopio: 0 = fatta, 1 = in attesa (appoggialo fermo e piatto), 2 = misura.
    int calibration;
    bool motionPlusBuiltIn;   // integrato (Wii Remote Plus) o adattatore esterno
} JFWiiState;

/// Fino a 4 Wii Remote insieme: un solo IOHIDManager (accesso esclusivo) assegna ogni
/// telecomando al primo posto libero 0…3 e accende il LED del giocatore.
@interface JFWiiHub : NSObject
@property (nonatomic, copy, nullable) void (^onState)(int slot, JFWiiState state);
- (void)start;
- (void)stop;
- (void)setRumble:(BOOL)on slot:(int)slot;
- (void)recalibrateSlot:(int)slot;
@end

/// Accoppiamento di un nuovo Wii Remote (PIN binario che macOS non sa inserire).
/// state: "searching" | "pairing" | "paired" | "failed" | "timeout" | "cancelled"
@interface JFWiiPairer : NSObject
@property (nonatomic, copy, nullable) void (^onUpdate)(NSString *state, NSString *message);
@property (nonatomic, readonly) BOOL isRunning;
- (void)startWithTimeout:(NSTimeInterval)timeout;
- (void)cancel;
@end

@interface JFWiiReader : NSObject
@property (nonatomic, copy, nullable) void (^onState)(JFWiiState state);
- (void)start;
- (void)stop;
- (void)setRumble:(BOOL)on;
- (void)recalibrate;
@end
