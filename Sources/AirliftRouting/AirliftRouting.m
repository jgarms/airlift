#import "include/AirliftRouting.h"
#import <objc/message.h>

NSObject *ALCreateDiscoverySession(NSInteger features, NSInteger mode) {
    Class cls = NSClassFromString(@"AVOutputDeviceDiscoverySession");
    if (!cls) return nil;
    id session = [cls alloc];
    SEL initSel = NSSelectorFromString(@"initWithDeviceFeatures:");
    if (![session respondsToSelector:initSel]) return nil;
    id (*initFn)(id, SEL, NSInteger) = (id (*)(id, SEL, NSInteger))objc_msgSend;
    session = initFn(session, initSel, features);
    @try {
        [session setValue:@(mode) forKey:@"discoveryMode"];
    } @catch (id exception) {
        return nil;
    }
    return session;
}

NSArray<NSObject *> *ALAvailableOutputDevices(NSObject *session) {
    @try {
        NSArray *devices = [session valueForKey:@"availableOutputDevices"];
        return devices ?: @[];
    } @catch (id exception) {
        return @[];
    }
}

id ALDeviceProperty(NSObject *device, NSString *key) {
    @try {
        return [device valueForKey:key];
    } @catch (id exception) {
        return nil;
    }
}

NSObject *ALCreateAudioContext(void) {
    Class cls = NSClassFromString(@"AVOutputContext");
    SEL sel = NSSelectorFromString(@"iTunesAudioContext");
    if (![cls respondsToSelector:sel]) return nil;
    id (*fn)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
    return fn(cls, sel);
}

NSObject *ALDefaultSharedAudioContext(void) {
    Class cls = NSClassFromString(@"AVOutputContext");
    SEL sel = NSSelectorFromString(@"defaultSharedOutputContext");
    if (![cls respondsToSelector:sel]) return nil;
    id (*fn)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
    return fn(cls, sel);
}

NSString *ALContextID(NSObject *context) {
    @try {
        NSString *identifier = [context valueForKey:@"ID"];
        if (identifier) return identifier;
    } @catch (id exception) {
    }
    @try {
        return [context valueForKey:@"contextID"];
    } @catch (id exception) {
        return nil;
    }
}

NSObject *ALContextForID(NSString *contextID) {
    Class cls = NSClassFromString(@"AVOutputContext");
    SEL sel = NSSelectorFromString(@"outputContextForID:");
    if (![cls respondsToSelector:sel]) return nil;
    id (*fn)(Class, SEL, id) = (id (*)(Class, SEL, id))objc_msgSend;
    return fn(cls, sel, contextID);
}

BOOL ALPickerSetOutputContextID(NSObject *pickerView, NSString *contextID) {
    SEL sel = NSSelectorFromString(@"setOutputContextID:");
    if (![pickerView respondsToSelector:sel]) return NO;
    void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    fn(pickerView, sel, contextID);
    return YES;
}

BOOL ALContextSetOutputDevices(NSObject *context, NSArray<NSObject *> *devices) {
    SEL sel = NSSelectorFromString(@"setOutputDevices:");
    if (![context respondsToSelector:sel]) return NO;
    void (*fn)(id, SEL, NSArray *) = (void (*)(id, SEL, NSArray *))objc_msgSend;
    fn(context, sel, devices);
    return YES;
}

BOOL ALContextAddOutputDevice(NSObject *context, NSObject *device,
                              void (^completion)(void)) {
    SEL sel = NSSelectorFromString(@"addOutputDevice:options:completionHandler:");
    if (![context respondsToSelector:sel]) return NO;
    void (*fn)(id, SEL, id, id, void (^)(void)) =
        (void (*)(id, SEL, id, id, void (^)(void)))objc_msgSend;
    fn(context, sel, device, nil, completion);
    return YES;
}

NSArray<NSObject *> *ALContextOutputDevices(NSObject *context) {
    @try {
        NSArray *devices = [context valueForKey:@"outputDevices"];
        if (devices.count > 0) return devices;
    } @catch (id exception) {
    }
    @try {
        id device = [context valueForKey:@"outputDevice"];
        if (device) return @[ device ];
    } @catch (id exception) {
    }
    return @[];
}

BOOL ALRendererSetOutputContext(AVSampleBufferAudioRenderer *renderer, NSObject *context) {
    SEL sel = NSSelectorFromString(@"setOutputContext:");
    if (![renderer respondsToSelector:sel]) return NO;
    void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    fn(renderer, sel, context);
    return YES;
}

BOOL ALDeviceSetVolume(NSObject *device, float volume) {
    SEL sel = NSSelectorFromString(@"setDeviceVolume:");
    if ([device respondsToSelector:sel]) {
        void (*fn)(id, SEL, float) = (void (*)(id, SEL, float))objc_msgSend;
        fn(device, sel, volume);
        return YES;
    }
    sel = NSSelectorFromString(@"setVolume:");
    if ([device respondsToSelector:sel]) {
        void (*fn)(id, SEL, float) = (void (*)(id, SEL, float))objc_msgSend;
        fn(device, sel, volume);
        return YES;
    }
    return NO;
}
