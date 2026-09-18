#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Thin C wrappers over the private AVFCore routing classes
// (AVOutputDeviceDiscoverySession, AVOutputDevice, AVOutputContext).
// Everything is resolved at runtime via NSClassFromString/objc_msgSend so we
// never reference private symbols at link time.

/// Starts an AVOutputDeviceDiscoverySession. features: 1=audio, 2=video, 3=both.
/// mode: 0=none, 1=presence, 2=detailed (detailed is required to get devices).
NSObject *_Nullable ALCreateDiscoverySession(NSInteger features, NSInteger mode);

/// Devices currently visible to the discovery session (AVOutputDevice *).
NSArray<NSObject *> *ALAvailableOutputDevices(NSObject *session);

/// KVC property read that swallows exceptions; nil when absent.
id _Nullable ALDeviceProperty(NSObject *device, NSString *key);

/// The audio-type AVOutputContext (+iTunesAudioContext).
NSObject *_Nullable ALCreateAudioContext(void);

/// +[AVOutputContext defaultSharedOutputContext] (audio type).
NSObject *_Nullable ALDefaultSharedAudioContext(void);

/// -[AVOutputContext ID] (falls back to contextID).
NSString *_Nullable ALContextID(NSObject *context);

/// +[AVOutputContext outputContextForID:] — rehydrates a context by ID.
NSObject *_Nullable ALContextForID(NSString *contextID);

/// -[AVRoutePickerView setOutputContextID:] — attaches the system AirPlay
/// picker (which runs in the entitled AirPlayUIAgent) to our context.
BOOL ALPickerSetOutputContextID(NSObject *pickerView, NSString *contextID);

/// -[AVOutputContext setOutputDevices:]. Returns NO if the selector is missing.
BOOL ALContextSetOutputDevices(NSObject *context, NSArray<NSObject *> *devices);

/// -[AVOutputContext addOutputDevice:options:completionHandler:].
BOOL ALContextAddOutputDevice(NSObject *context, NSObject *device,
                              void (^_Nullable completion)(void));

/// -[AVOutputContext outputDevices] (falls back to outputDevice, wrapped in an array).
NSArray<NSObject *> *ALContextOutputDevices(NSObject *context);

/// -[AVSampleBufferAudioRenderer setOutputContext:]. Returns NO if missing.
BOOL ALRendererSetOutputContext(AVSampleBufferAudioRenderer *renderer, NSObject *context);

/// -[AVOutputDevice setDeviceVolume:] / volume read, when supported.
BOOL ALDeviceSetVolume(NSObject *device, float volume);

NS_ASSUME_NONNULL_END
