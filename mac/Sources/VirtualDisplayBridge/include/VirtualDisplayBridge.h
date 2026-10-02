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

/// Destroys the last created virtual display.
void VDBridgeDestroyDisplay(void);

/// Destroys a specific virtual display by its ID.
void VDBridgeDestroyDisplayByID(CGDirectDisplayID displayID);

/// Destroys all currently active virtual displays.
void VDBridgeDestroyAllDisplays(void);

/// Returns the current active virtual display ID, or 0 if none.
CGDirectDisplayID VDBridgeGetActiveDisplayID(void);

// MARK: - Touch Bar Bridge

/// Checks if private DFR Touch Bar symbols are available on this macOS system.
BOOL VDBridgeTouchBarIsAvailable(void);

/// Returns the native Touch Bar screen size in points.
CGSize VDBridgeTouchBarGetSize(void);

/// Starts capturing the macOS Touch Bar stream.
BOOL VDBridgeTouchBarStart(void (^handler)(IOSurfaceRef surface));

/// Stops capturing the Touch Bar stream.
void VDBridgeTouchBarStop(void);

/// Posts a touch event to the macOS Touch Bar.
/// eventType: 1 = down, 2 = move/drag, 3 = up
/// normX, normY: normalized coordinates (0.0 to 1.0)
void VDBridgeTouchBarPostEvent(uint8_t eventType, float normX, float normY);

/// Posts a system media key (sound up/down, mute, play/pause, brightness, etc.)
void VDBridgePostSystemMediaKey(int keyType);

/// Posts a keyboard virtual key press or release (Esc = 0x35, F1..F12, etc.)
void VDBridgePostVirtualKey(uint16_t keyCode, BOOL isDown);

/// Gets current main display brightness (0.0 to 1.0)
float VDBridgeGetBrightness(void);

/// Sets current main display brightness (0.0 to 1.0)
void VDBridgeSetBrightness(float brightness);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END

#endif /* VirtualDisplayBridge_h */
