// The helper that simhost builds and starts inside the simulator, as Objective-C source.
// It is kept in a Swift string, so a program that links SimHostKit needs no resource bundle.

let guestSource = #"""
// simhost-guest: runs inside the simulator (`simctl spawn`) and adds virtual HID devices there:
// a USB keyboard, and on iPhone Duo the hinge and the hardware buttons.
// The hinge and button services follow serve-sim's Duo HID helper (Apache-2.0).
//
// It reads one command per line from stdin and answers each with OK or ERROR:
//   key <usage> <down>          a keyboard key, by HID usage on page 7; down is 1 or 0
//   type <text>                 types printable ASCII on a US layout
//   angle <degrees>             sets the hinge, 0 to 180
//   sweep <from> <to> <ms>      moves the hinge in steps of one frame
//   orientation <n>             1 portrait, 2 upside down, 3 landscape left, 4 landscape right
//   button <page> <usage> <down>  a Duo hardware button
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

@interface ServiceDelegate : NSObject
@property NSDictionary *properties;
@end
@implementation ServiceDelegate
- (id)propertyForKey:(NSString *)key forService:(id)service { return self.properties[key]; }
- (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service { return YES; }
- (id)copyEventMatching:(id)matching forService:(id)service { return nil; }
- (BOOL)setOutputEvent:(id)event forService:(id)service { return YES; }
- (void)notification:(uint32_t)type withProperty:(id)property forService:(id)service {}
@end

typedef CFTypeRef (*KeyboardEventFunc)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);
typedef CFTypeRef (*VendorEventFunc)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, const void *, CFIndex, uint32_t);
static KeyboardEventFunc keyboardEvent;
static VendorEventFunc vendorEvent;

static id service(uint32_t page, uint32_t usage, NSDictionary *extra) {
    Class cls = NSClassFromString(@"HIDVirtualEventService");
    if (!cls) return nil;
    id instance = [[cls alloc] init];
    ServiceDelegate *delegate = [ServiceDelegate new];
    NSMutableDictionary *properties = [@{
        @"PrimaryUsagePage": @(page), @"PrimaryUsage": @(usage),
        @"DeviceUsagePairs": @[@{@"DeviceUsagePage": @(page), @"DeviceUsage": @(usage)}],
        @"VendorID": @0, @"ProductID": @0, @"VersionNumber": @0, @"ReportInterval": @8000,
    } mutableCopy];
    [properties addEntriesFromDictionary:extra];
    delegate.properties = properties;
    objc_setAssociatedObject(instance, @selector(properties), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(instance, sel_registerName("setDelegate:"), delegate);
    ((void (*)(id, SEL, id))objc_msgSend)(instance, sel_registerName("setDispatchQueue:"), dispatch_queue_create("simhost.guest", DISPATCH_QUEUE_SERIAL));
    ((void (*)(id, SEL))objc_msgSend)(instance, sel_registerName("activate"));
    return ((uint64_t (*)(id, SEL))objc_msgSend)(instance, sel_registerName("serviceID")) ? instance : nil;
}

static BOOL dispatch(id service, CFTypeRef event) {
    if (!service || !event) { if (event) CFRelease(event); return NO; }
    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(service, sel_registerName("dispatchEvent:"), (__bridge id)event);
    CFRelease(event);
    return ok;
}

// MARK: Keyboard

static id keyboard;

static BOOL key(uint32_t usage, BOOL down) {
    return dispatch(keyboard, keyboardEvent(NULL, mach_absolute_time(), 7, usage, down, 0));
}

// The HID usage of a printable ASCII character on a US layout, and whether it needs shift.
static BOOL usageFor(char c, uint32_t *usage, BOOL *shift) {
    // Usages 0x04 to 0x38, in order, without and with shift. 0x32 is the non-US key: skipped.
    static const char plain[] = "abcdefghijklmnopqrstuvwxyz1234567890\n\x1b\b\t -=[]\\\x01;'`,./";
    static const char shifted[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()\x01\x01\x01\x01\x01_+{}|\x01:\"~<>?";
    for (int i = 0; i < (int)sizeof(plain) - 1; i++) {
        if (plain[i] == c) { *usage = 0x04 + i; *shift = NO; return YES; }
        if (shifted[i] == c) { *usage = 0x04 + i; *shift = YES; return YES; }
    }
    return NO;
}

static BOOL type(const char *text) {
    BOOL ok = YES;
    for (const char *c = text; *c; c++) {
        uint32_t usage; BOOL shift;
        if (*c == 0x01 || !usageFor(*c, &usage, &shift)) { ok = NO; continue; }
        if (shift) ok &= key(0xE1, YES);
        ok &= key(usage, YES);
        ok &= key(usage, NO);
        if (shift) ok &= key(0xE1, NO);
    }
    return ok;
}

// MARK: iPhone Duo

static id hinge, buttons;

static void header(NSMutableData *data, uint32_t count, uint8_t type) {
    uint8_t bytes[] = {count & 255, (count >> 8) & 255, (count >> 16) & 255, type};
    [data appendBytes:bytes length:4];
}
static void string(NSMutableData *data, const char *text, BOOL isKey, BOOL last) {
    size_t length = strlen(text) + (isKey ? 1 : 0);
    header(data, (uint32_t)length, (isKey ? 8 : 9) | (last ? 0x80 : 0));
    [data appendBytes:text length:length];
    while (data.length % 4) { uint8_t zero = 0; [data appendBytes:&zero length:1]; }
}
static NSMutableData *control(const char *source, const char *kind) {
    NSMutableData *data = [NSMutableData data];
    header(data, 0xd3, 0);
    header(data, 4, 0x81);
    string(data, "provider", YES, NO); string(data, "com.apple.Virtualization.VirtualMachines", NO, NO);
    string(data, "source", YES, NO); string(data, source, NO, NO);
    string(data, "type", YES, NO); string(data, kind, NO, NO);
    string(data, "value", YES, NO);
    return data;
}
static BOOL vendor(NSData *payload) {
    return dispatch(hinge, vendorEvent(NULL, mach_absolute_time(), 0xff61, 0x5b, 0, payload.bytes, payload.length, 0));
}
static BOOL angle(double degrees) {
    NSMutableData *data = control("hinge-slider-control", "range");
    header(data, 0x3f, 0x84);
    [data appendBytes:&degrees length:sizeof(degrees)];
    return vendor(data);
}
static BOOL orientation(unsigned value) {
    const char *names[] = {NULL, "portrait", "pud", "landscape-left", "landscape-right"};
    if (value < 1 || value > 4) return NO;
    NSMutableData *data = control("orientation-picker-control", "enum");
    string(data, names[value], NO, YES);
    return vendor(data);
}

int main(void) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW);
        void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        keyboardEvent = (KeyboardEventFunc)dlsym(io, "IOHIDEventCreateKeyboardEvent");
        vendorEvent = (VendorEventFunc)dlsym(io, "IOHIDEventCreateVendorDefinedEvent");
        if (!keyboardEvent || !vendorEvent) { fprintf(stderr, "HID is not available\n"); return 1; }

        keyboard = service(1, 6, @{@"Transport": @"USB", @"Product": @"simhost keyboard", @"Manufacturer": @"simhost",
                                    @"Built-In": @NO, @"VendorID": @0x05ac, @"ProductID": @0x0250, @"CountryCode": @0});
        if (getenv("SIMHOST_DUO")) {
            NSDictionary *duo = @{@"Transport": @"CoreDevice", @"Product": @"simhost Duo HID"};
            NSMutableDictionary *builtIn = [duo mutableCopy]; builtIn[@"Built-In"] = @YES;
            NSMutableDictionary *external = [duo mutableCopy]; external[@"Built-In"] = @NO;
            hinge = service(0xff61, 0x5b, external);
            buttons = service(0x0b, 1, builtIn);
        }
        if (!keyboard) { fprintf(stderr, "the keyboard service did not start\n"); return 1; }
        usleep(300000); // backboardd enumerates new services in this time.
        puts("READY"); fflush(stdout);

        char *line = NULL; size_t capacity = 0; ssize_t length;
        while ((length = getline(&line, &capacity, stdin)) > 0) {
            @autoreleasepool {
                if (line[length - 1] == '\n') line[--length] = 0;
                double from, to, ms; unsigned a, b, c; char extra;
                BOOL ok = NO;
                if (sscanf(line, "key %u %u %c", &a, &b, &extra) == 2) {
                    ok = key(a, b != 0);
                } else if (strncmp(line, "type ", 5) == 0) {
                    ok = type(line + 5);
                } else if (sscanf(line, "angle %lf %c", &to, &extra) == 1 && isfinite(to) && to >= 0 && to <= 180) {
                    ok = angle(to);
                } else if (sscanf(line, "sweep %lf %lf %lf %c", &from, &to, &ms, &extra) == 3 && isfinite(from) && isfinite(to) &&
                           from >= 0 && from <= 180 && to >= 0 && to <= 180 && ms >= 0 && ms <= 1500) {
                    int frames = MAX(1, (int)ceil(ms / 16.667));
                    ok = YES;
                    for (int i = 1; i <= frames && ok; i++) {
                        double eased = 1 - pow(1 - (double)i / frames, 3);
                        ok = angle(from + (to - from) * eased);
                        if (i < frames) usleep((useconds_t)(ms * 1000 / frames));
                    }
                } else if (sscanf(line, "orientation %u %c", &a, &extra) == 1) {
                    ok = orientation(a);
                } else if (sscanf(line, "button %u %u %u %c", &a, &b, &c, &extra) == 3 && a <= 0xffff && b <= 0xffff) {
                    ok = dispatch(buttons, keyboardEvent(NULL, mach_absolute_time(), a, b, c != 0, 0));
                }
                puts(ok ? "OK" : "ERROR"); fflush(stdout);
            }
        }
        for (id each in @[keyboard ?: NSNull.null, hinge ?: NSNull.null, buttons ?: NSNull.null]) {
            if (each != NSNull.null) ((void (*)(id, SEL))objc_msgSend)(each, sel_registerName("cancel"));
        }
    }
    return 0;
}
"""#
