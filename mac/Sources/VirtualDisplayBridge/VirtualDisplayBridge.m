#import "VirtualDisplayBridge.h"
#import <unistd.h>

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

static CGVirtualDisplay *sActiveDisplay = nil;
static CGDirectDisplayID sActiveDisplayID = 0;
static dispatch_queue_t sVirtualDisplayQueue = nil;

CGDirectDisplayID VDBridgeCreateDisplay(NSString *name, uint32_t width, uint32_t height, double refreshRate, BOOL hiDPI) {
    if (sActiveDisplay != nil) {
        VDBridgeDestroyDisplay();
    }

    if (!sVirtualDisplayQueue) {
        sVirtualDisplayQueue = dispatch_queue_create("com.antigravity.virtualdisplay", DISPATCH_QUEUE_SERIAL);
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
    desc.name = name ?: @"Android Virtual Display";
    desc.maxPixelsWide = 3840;
    desc.maxPixelsHigh = 3840;
    desc.sizeInMillimeters = CGSizeMake(160, 90);
    desc.serialNum = 0x414E4452; // "ANDR"
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

    // Explicitly configure as EXTENDED DESKTOP (disable mirror, position to right of primary display)
    CGDisplayConfigRef configRef;
    if (CGBeginDisplayConfiguration(&configRef) == kCGErrorSuccess) {
        CGConfigureDisplayMirrorOfDisplay(configRef, display.displayID, kCGNullDirectDisplay);
        CGRect mainBounds = CGDisplayBounds(CGMainDisplayID());
        int32_t targetX = (int32_t)(mainBounds.origin.x + mainBounds.size.width);
        int32_t targetY = (int32_t)(mainBounds.origin.y);
        CGConfigureDisplayOrigin(configRef, display.displayID, targetX, targetY);
        CGCompleteDisplayConfiguration(configRef, kCGConfigurePermanently);
        NSLog(@"[VDBridge] Configured display ID %u as Extended Desktop at (%d, %d)", display.displayID, targetX, targetY);
    }

    sActiveDisplay = display;
    sActiveDisplayID = display.displayID;
    NSLog(@"[VDBridge] Created virtual display ID %u (%ux%u @ %.1fHz)", sActiveDisplayID, width, height, refreshRate);
    return sActiveDisplayID;
}

BOOL VDBridgeUpdateDisplayMode(uint32_t width, uint32_t height, double refreshRate, BOOL hiDPI) {
    if (!sActiveDisplay) {
        return NO;
    }
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!modeClass || !settingsClass) return NO;

    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.modes = @[mode];
    settings.hiDPI = hiDPI ? 1 : 0;

    return [sActiveDisplay applySettings:settings];
}

void VDBridgeDestroyDisplay(void) {
    if (sActiveDisplay) {
        NSLog(@"[VDBridge] Destroying virtual display ID %u", sActiveDisplayID);
        sActiveDisplay = nil;
        sActiveDisplayID = 0;
    }
}

CGDirectDisplayID VDBridgeGetActiveDisplayID(void) {
    return sActiveDisplayID;
}
