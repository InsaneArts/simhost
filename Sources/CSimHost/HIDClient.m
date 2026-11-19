#import "CSimHost.h"
#import <dlfcn.h>
#import <objc/message.h>

// SimulatorKit's message builders. Each returns a malloc'd message that the client frees after sending.
// The touch builder takes points from 0 to 1 when `size` is 1x1, as Simulator.app passes it.
typedef void *_Nullable (*MouseBuilder)(const CGPoint *first, const CGPoint *_Nullable second,
                                        uint32_t target, int32_t eventType, CGSize size, uint32_t edge);
typedef void *_Nullable (*ButtonBuilder)(int32_t source, int32_t direction, int32_t target);
typedef void *_Nullable (*UsageBuilder)(uint32_t target, uint32_t page, uint32_t usage, uint32_t direction);

static MouseBuilder mouseBuilder;
static ButtonBuilder buttonBuilder;
static UsageBuilder usageBuilder;

// The message types and directions SimulatorKit takes.
enum { MouseDown = 1, MouseUp = 2, DirectionDown = 1, DirectionUp = 2 };

@implementation SHHIDClient {
    id _client;
    SEL _send;
}

+ (void)initialize {
    if (self != [SHHIDClient class]) return;
    mouseBuilder = (MouseBuilder)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
    buttonBuilder = (ButtonBuilder)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForButton");
    usageBuilder = (UsageBuilder)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForHIDArbitrary");
}

- (nullable instancetype)initWithDevice:(id)device error:(NSError **)error {
    self = [super init];
    Class cls = NSClassFromString(@"_TtC12SimulatorKit24SimDeviceLegacyHIDClient");
    if (!cls || !mouseBuilder) {
        if (error) *error = [NSError errorWithDomain:@"simhost" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"SimulatorKit's HID client is not available"}];
        return nil;
    }
    id client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([cls alloc], sel_registerName("initWithDevice:error:"), device, error);
    if (!client) return nil;
    _client = client;
    _send = sel_registerName("sendWithMessage:freeWhenDone:completionQueue:completion:");
    return self;
}

- (BOOL)sendMessage:(void *)message {
    if (!message) return NO;
    ((void (*)(id, SEL, void *, BOOL, id, id))objc_msgSend)(_client, _send, message, YES, nil, nil);
    return YES;
}

- (BOOL)touchDown:(BOOL)down first:(CGPoint)first second:(const CGPoint *)second target:(SHTouchTarget)target edge:(SHEdge)edge {
    return [self sendMessage:mouseBuilder(&first, second, target, down ? MouseDown : MouseUp, CGSizeMake(1, 1), edge)];
}

- (BOOL)buttonSource:(int32_t)source down:(BOOL)down {
    if (!buttonBuilder) return NO;
    return [self sendMessage:buttonBuilder(source, down ? DirectionDown : DirectionUp, 0x33)];
}

- (BOOL)usagePage:(uint32_t)page usage:(uint32_t)usage down:(BOOL)down target:(uint32_t)target {
    if (!usageBuilder) return NO;
    return [self sendMessage:usageBuilder(target, page, usage, down ? DirectionDown : DirectionUp)];
}

@end
