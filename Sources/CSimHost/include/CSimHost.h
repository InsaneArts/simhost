#ifndef CSIMHOST_H
#define CSIMHOST_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Where a finger lands on a simulator. The values are SimulatorKit's display targets.
typedef NS_ENUM(uint32_t, SHTouchTarget) {
    /// The one screen of an ordinary iPhone or iPad.
    SHTouchTargetMain = 0x32,
    /// iPhone Duo's cover screen.
    SHTouchTargetDuoCover = 0x40000001,
    /// iPhone Duo's inner screen.
    SHTouchTargetDuoInner = 0x40000003,
};

/// A system edge for a touch that starts a system gesture.
typedef NS_ENUM(uint32_t, SHEdge) {
    SHEdgeNone = 0,
    SHEdgeLeft = 1,
    SHEdgeTop = 2,
    SHEdgeBottom = 3,
    SHEdgeRight = 4,
};

/// Sends HID input to one simulator through SimulatorKit's Indigo messages.
/// Every method sends at once, on the calling thread, and returns NO when SimulatorKit refused.
@interface SHHIDClient : NSObject

/// `device` is CoreSimulator's SimDevice. SimulatorKit must already be loaded.
- (nullable instancetype)initWithDevice:(id)device error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

/// One finger, or two when `second` is given. Points go from 0 to 1, origin top left.
/// `down` is YES while the fingers touch: for the first contact and for every move.
- (BOOL)touchDown:(BOOL)down
            first:(CGPoint)first
           second:(nullable const CGPoint *)second
           target:(SHTouchTarget)target
             edge:(SHEdge)edge;

/// A button by SimulatorKit's event source, such as 0 for home and 1 for lock.
- (BOOL)buttonSource:(int32_t)source down:(BOOL)down;

/// Any HID usage, such as the volume buttons (page 0x0C).
- (BOOL)usagePage:(uint32_t)page usage:(uint32_t)usage down:(BOOL)down target:(uint32_t)target;

@end

NS_ASSUME_NONNULL_END

#endif
