#ifndef VirtualDisplayBridge_h
#define VirtualDisplayBridge_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Creates a new virtual display with the given dimensions and refresh rate.
/// Returns the CGDirectDisplayID of the created virtual display, or 0 on failure.
CGDirectDisplayID VDBridgeCreateDisplay(NSString *name, uint32_t width, uint32_t height, double refreshRate, BOOL hiDPI);

/// Updates the resolution/mode of the active virtual display.
BOOL VDBridgeUpdateDisplayMode(uint32_t width, uint32_t height, double refreshRate, BOOL hiDPI);

/// Destroys the currently active virtual display.
void VDBridgeDestroyDisplay(void);

/// Returns the current active virtual display ID, or 0 if none.
CGDirectDisplayID VDBridgeGetActiveDisplayID(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif /* VirtualDisplayBridge_h */
