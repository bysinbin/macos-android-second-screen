#import "VirtualDisplayBridge.h"
#import <Cocoa/Cocoa.h>
#import <unistd.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>

// Private CoreGraphics interfaces for Virtual Display
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, retain) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static NSMutableDictionary<NSNumber *, CGVirtualDisplay *> *sActiveDisplays = nil;
static CGDirectDisplayID sActiveDisplayID = 0;
static dispatch_queue_t sVirtualDisplayQueue = nil;

CGDirectDisplayID VDBridgeCreateDisplay(NSString *name, uint32_t width, uint32_t height, double refreshRate, BOOL hiDPI) {
    if (!sVirtualDisplayQueue) {
        sVirtualDisplayQueue = dispatch_queue_create("com.antigravity.virtualdisplay", DISPATCH_QUEUE_SERIAL);
    }
    if (!sActiveDisplays) {
        sActiveDisplays = [[NSMutableDictionary alloc] init];
    }

    Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");

    if (!descClass || !displayClass || !modeClass || !settingsClass) {
        NSLog(@"[VDBridge] Error: CGVirtualDisplay classes not found in CoreGraphics.");
        return 0;
    }

    CGVirtualDisplayDescriptor *desc = [[descClass alloc] init];
    desc.name = name ?: [NSString stringWithFormat:@"Android Display %lu", (unsigned long)(sActiveDisplays.count + 1)];
    desc.maxPixelsWide = 3840;
    desc.maxPixelsHigh = 3840;
    desc.sizeInMillimeters = CGSizeMake(160, 90);
    desc.serialNum = (unsigned int)(0x414E4400 + sActiveDisplays.count); // "AND0", "AND1"...
    desc.productID = 0x5343524E; // "SCRN"
    desc.vendorID = 0x05AC;     // Apple / Generic
    desc.queue = sVirtualDisplayQueue;

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:desc];
    if (!display) {
        NSLog(@"[VDBridge] Error: Failed to initialize CGVirtualDisplay.");
        return 0;
    }

    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.modes = @[mode];
    settings.hiDPI = hiDPI ? 1 : 0;

    BOOL success = [display applySettings:settings];
    if (!success) {
        NSLog(@"[VDBridge] Warning: applySettings returned NO.");
    }

    // Wait 300ms for CoreGraphics and WindowServer to register the display mode
    usleep(300000);

    // Position this new display to the right of the existing right-most display
    CGDisplayConfigRef configRef;
    if (CGBeginDisplayConfiguration(&configRef) == kCGErrorSuccess) {
        CGConfigureDisplayMirrorOfDisplay(configRef, display.displayID, kCGNullDirectDisplay);
        
        // Find max X among all active displays
        uint32_t maxDisplays = 16;
        CGDirectDisplayID activeIDs[16];
        uint32_t displayCount = 0;
        CGGetActiveDisplayList(maxDisplays, activeIDs, &displayCount);
        
        CGFloat maxX = 0;
        for (uint32_t i = 0; i < displayCount; i++) {
            if (activeIDs[i] == display.displayID) continue;
            CGRect b = CGDisplayBounds(activeIDs[i]);
            if (CGRectGetMaxX(b) > maxX) {
                maxX = CGRectGetMaxX(b);
            }
        }
        
        int32_t targetX = (int32_t)maxX;
        int32_t targetY = 0;
        CGConfigureDisplayOrigin(configRef, display.displayID, targetX, targetY);
        CGCompleteDisplayConfiguration(configRef, kCGConfigurePermanently);
        NSLog(@"[VDBridge] Configured display ID %u as Extended Desktop at (%d, %d)", display.displayID, targetX, targetY);
    }

    sActiveDisplays[@(display.displayID)] = display;
    sActiveDisplayID = display.displayID;
    NSLog(@"[VDBridge] Created virtual display ID %u (%ux%u @ %.1fHz). Total active: %lu", sActiveDisplayID, width, height, refreshRate, (unsigned long)sActiveDisplays.count);
    return sActiveDisplayID;
}

BOOL VDBridgeUpdateDisplayMode(uint32_t width, uint32_t height, double refreshRate, BOOL hiDPI) {
    if (!sActiveDisplays || sActiveDisplays.count == 0) {
        return NO;
    }
    CGVirtualDisplay *display = sActiveDisplays[@(sActiveDisplayID)] ?: sActiveDisplays.allValues.firstObject;
    if (!display) return NO;

    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!modeClass || !settingsClass) return NO;

    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.modes = @[mode];
    settings.hiDPI = hiDPI ? 1 : 0;

    return [display applySettings:settings];
}

void VDBridgeDestroyDisplayByID(CGDirectDisplayID displayID) {
    if (sActiveDisplays && sActiveDisplays[@(displayID)]) {
        NSLog(@"[VDBridge] Destroying virtual display ID %u", displayID);
        [sActiveDisplays removeObjectForKey:@(displayID)];
        if (sActiveDisplayID == displayID) {
            sActiveDisplayID = sActiveDisplays.allKeys.lastObject.unsignedIntValue;
        }
    }
}

void VDBridgeDestroyAllDisplays(void) {
    if (sActiveDisplays) {
        NSLog(@"[VDBridge] Destroying all %lu virtual displays", (unsigned long)sActiveDisplays.count);
        [sActiveDisplays removeAllObjects];
        sActiveDisplayID = 0;
    }
}

void VDBridgeDestroyDisplay(void) {
    if (sActiveDisplays && sActiveDisplays.count > 0) {
        if (sActiveDisplayID != 0) {
            VDBridgeDestroyDisplayByID(sActiveDisplayID);
        } else {
            VDBridgeDestroyAllDisplays();
        }
    }
}

CGDirectDisplayID VDBridgeGetActiveDisplayID(void) {
    return sActiveDisplayID;
}

// MARK: - Touch Bar Bridge

typedef void (*DFRSetStatusFunc)(int);
typedef int (*DFRGetStatusFunc)(void);
typedef void (*DFRPostEventFunc)(NSEventType, CGPoint);
typedef CGDisplayStreamRef (*SLSDFRDisplayStreamCreateFunc)(int, dispatch_queue_t, CGDisplayStreamFrameAvailableHandler);
typedef CGError (*CGDisplayStreamStartFunc)(CGDisplayStreamRef);
typedef CGError (*CGDisplayStreamStopFunc)(CGDisplayStreamRef);
typedef CGSize (*DFRGetScreenSizeFunc)(void);

static void *sDFRHandle = NULL;
static void *sSkyLightHandle = NULL;
static void *sCoreGraphicsHandle = NULL;

static DFRSetStatusFunc sDFRSetStatus = NULL;
static DFRGetStatusFunc sDFRGetStatus = NULL;
static DFRPostEventFunc sDFRPostEvent = NULL;
static DFRGetScreenSizeFunc sDFRGetScreenSize = NULL;
static SLSDFRDisplayStreamCreateFunc sSLSDFRDisplayStreamCreate = NULL;
static CGDisplayStreamStartFunc sCGDisplayStreamStart = NULL;
static CGDisplayStreamStopFunc sCGDisplayStreamStop = NULL;

static CGDisplayStreamRef sTouchBarStream = NULL;
static int sInitialDFRStatus = 0;
static uint32_t sLastTBSurfaceWidth = 2008;
static uint32_t sLastTBSurfaceHeight = 60;
static dispatch_queue_t sTouchBarQueue = NULL;

static void InitTouchBarSymbols(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sDFRHandle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
        sSkyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        sCoreGraphicsHandle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);

        if (sDFRHandle) {
            sDFRSetStatus = (DFRSetStatusFunc)dlsym(sDFRHandle, "DFRSetStatus");
            sDFRGetStatus = (DFRGetStatusFunc)dlsym(sDFRHandle, "DFRGetStatus");
            sDFRPostEvent = (DFRPostEventFunc)dlsym(sDFRHandle, "DFRFoundationPostEventWithMouseActivity");
            sDFRGetScreenSize = (DFRGetScreenSizeFunc)dlsym(sDFRHandle, "DFRGetScreenSize");
        }

        if (sSkyLightHandle) {
            sSLSDFRDisplayStreamCreate = (SLSDFRDisplayStreamCreateFunc)dlsym(sSkyLightHandle, "SLSDFRDisplayStreamCreate");
        }

        if (sCoreGraphicsHandle) {
            sCGDisplayStreamStart = (CGDisplayStreamStartFunc)dlsym(sCoreGraphicsHandle, "CGDisplayStreamStart");
            sCGDisplayStreamStop = (CGDisplayStreamStopFunc)dlsym(sCoreGraphicsHandle, "CGDisplayStreamStop");
        }
    });
}

BOOL VDBridgeTouchBarIsAvailable(void) {
    InitTouchBarSymbols();
    return (sDFRSetStatus != NULL && sSLSDFRDisplayStreamCreate != NULL && sCGDisplayStreamStart != NULL);
}

CGSize VDBridgeTouchBarGetSize(void) {
    InitTouchBarSymbols();
    if (sDFRGetScreenSize) {
        return sDFRGetScreenSize();
    }
    return CGSizeMake(1004.0, 30.0);
}

BOOL VDBridgeTouchBarStart(void (^handler)(IOSurfaceRef surface)) {
    InitTouchBarSymbols();
    if (!VDBridgeTouchBarIsAvailable()) {
        NSLog(@"[TouchBarBridge] Error: Required private symbols not available.");
        return NO;
    }

    if (sTouchBarStream != NULL) {
        VDBridgeTouchBarStop();
    }

    if (!sTouchBarQueue) {
        sTouchBarQueue = dispatch_queue_create("com.antigravity.touchbar", DISPATCH_QUEUE_SERIAL);
    }

    if (sDFRGetStatus) {
        sInitialDFRStatus = sDFRGetStatus();
    }

    if (sDFRSetStatus) {
        sDFRSetStatus(2); // Enable DFR display mode
    }

    sTouchBarStream = sSLSDFRDisplayStreamCreate(0, sTouchBarQueue, ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {
        if (status == kCGDisplayStreamFrameStatusFrameComplete && frameSurface != NULL) {
            sLastTBSurfaceWidth = (uint32_t)IOSurfaceGetWidth(frameSurface);
            sLastTBSurfaceHeight = (uint32_t)IOSurfaceGetHeight(frameSurface);
            if (handler) {
                handler(frameSurface);
            }
        }
    });

    if (!sTouchBarStream) {
        NSLog(@"[TouchBarBridge] Failed to create DFR display stream.");
        return NO;
    }

    CGError err = sCGDisplayStreamStart(sTouchBarStream);
    if (err != kCGErrorSuccess) {
        NSLog(@"[TouchBarBridge] CGDisplayStreamStart error: %d", err);
        return NO;
    }

    NSLog(@"[TouchBarBridge] Touch Bar capture stream started successfully.");
    return YES;
}

void VDBridgeTouchBarStop(void) {
    if (sTouchBarStream) {
        if (sCGDisplayStreamStop) {
            sCGDisplayStreamStop(sTouchBarStream);
        }
        CFRelease(sTouchBarStream);
        sTouchBarStream = NULL;
    }

    if (sDFRSetStatus && sInitialDFRStatus != 0) {
        sDFRSetStatus(sInitialDFRStatus);
    }
    NSLog(@"[TouchBarBridge] Touch Bar capture stopped.");
}

void VDBridgeTouchBarPostEvent(uint8_t eventType, float normX, float normY) {
    if (!sDFRPostEvent) return;

    // Convert normalized (0..1) coordinate to DFR points
    float dfrWidth = (sLastTBSurfaceWidth > 0) ? ((float)sLastTBSurfaceWidth / 2.0f) : 1004.0f;
    float dfrHeight = (sLastTBSurfaceHeight > 0) ? ((float)sLastTBSurfaceHeight / 2.0f) : 30.0f;

    float x = fmaxf(0.0f, fminf(1.0f, normX)) * dfrWidth;
    // AppKit coordinates: origin (0,0) is bottom-left, invert Y
    float y = (1.0f - fmaxf(0.0f, fminf(1.0f, normY))) * dfrHeight;

    NSEventType type = NSEventTypeLeftMouseDown;
    if (eventType == 1) {
        type = NSEventTypeLeftMouseDown;
    } else if (eventType == 2) {
        type = NSEventTypeLeftMouseDragged;
    } else if (eventType == 3) {
        type = NSEventTypeLeftMouseUp;
    }

    sDFRPostEvent(type, CGPointMake(x, y));
}

void VDBridgePostSystemMediaKey(int keyType) {
    NSEvent *eventDown = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                            location:NSZeroPoint
                                       modifierFlags:0xa00
                                           timestamp:0
                                        windowNumber:0
                                             context:nil
                                             subtype:8
                                               data1:(keyType << 16) | (0xa << 8)
                                               data2:-1];
    NSEvent *eventUp = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                          location:NSZeroPoint
                                     modifierFlags:0xb00
                                         timestamp:0
                                      windowNumber:0
                                           context:nil
                                           subtype:8
                                             data1:(keyType << 16) | (0xb << 8)
                                             data2:-1];
    CGEventPost(kCGHIDEventTap, [eventDown CGEvent]);
    CGEventPost(kCGHIDEventTap, [eventUp CGEvent]);
}

void VDBridgePostVirtualKey(uint16_t keyCode, BOOL isDown) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef ev = CGEventCreateKeyboardEvent(src, (CGKeyCode)keyCode, (Boolean)isDown);
    CGEventPost(kCGHIDEventTap, ev);
    if (ev) CFRelease(ev);
    if (src) CFRelease(src);
}

// MARK: - Display Brightness

static int (*sDisplayServicesGetBrightness)(uint32_t, float *) = NULL;
static int (*sDisplayServicesSetBrightness)(uint32_t, float) = NULL;
static dispatch_once_t sInitDisplayServicesToken;

static void sInitDisplayServices(void) {
    dispatch_once(&sInitDisplayServicesToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
        if (handle) {
            sDisplayServicesGetBrightness = dlsym(handle, "DisplayServicesGetBrightness");
            sDisplayServicesSetBrightness = dlsym(handle, "DisplayServicesSetBrightness");
        }
    });
}

float VDBridgeGetBrightness(void) {
    sInitDisplayServices();
    if (sDisplayServicesGetBrightness) {
        float b = 0.5f;
        CGDirectDisplayID mainDisplay = CGMainDisplayID();
        if (sDisplayServicesGetBrightness(mainDisplay, &b) == 0) {
            return b;
        }
    }
    return 0.5f;
}

void VDBridgeSetBrightness(float brightness) {
    sInitDisplayServices();
    if (sDisplayServicesSetBrightness) {
        CGDirectDisplayID mainDisplay = CGMainDisplayID();
        float clamped = fmaxf(0.0f, fminf(1.0f, brightness));
        sDisplayServicesSetBrightness(mainDisplay, clamped);
    }
}



