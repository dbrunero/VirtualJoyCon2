#pragma once

// Built-in Wii Remote pairing.
//
// macOS cannot pair a Wii Remote on its own: the remote expects a binary PIN
// (when SYNC is pressed it is the host's Bluetooth address, byte-reversed),
// which the System Settings UI cannot type. This class runs a classic
// Bluetooth inquiry, starts pairing with the first "Nintendo RVL-CNT-01*"
// device it finds and answers the PIN request with that binary key.
//
// The technique is the one documented by Dolphin's WiimotePair utility; this
// is an independent implementation (no code copied).

#import <Foundation/Foundation.h>
#include <functional>
#include <string>

// state: "searching" | "pairing" | "paired" | "failed" | "timeout" | "cancelled"
using WiimotePairingCallback = std::function<void(const char *state, const std::string &message)>;

@interface WiimotePairer : NSObject

- (void)setCallback:(WiimotePairingCallback)callback;
- (void)startWithTimeout:(NSTimeInterval)timeout;
- (void)cancel;

@property (nonatomic, readonly) BOOL isRunning;

@end
