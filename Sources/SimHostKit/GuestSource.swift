// The helper that simhost builds and starts inside the simulator, as Objective-C source.
// It is kept in a Swift string, so a program that links SimHostKit needs no resource bundle.

let guestSource = #"""
// simhost-guest: runs inside the simulator (`simctl spawn`) and adds a virtual USB keyboard there.
//
// It reads one command per line from stdin and answers each with OK or ERROR:
//   key <usage> <down>          a keyboard key, by HID usage on page 7; down is 1 or 0
//   type <text>                 types printable ASCII on a US layout
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
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
static KeyboardEventFunc keyboardEvent;

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

int main(void) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/HID.framework/HID", RTLD_NOW);
        void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        keyboardEvent = (KeyboardEventFunc)dlsym(io, "IOHIDEventCreateKeyboardEvent");
        if (!keyboardEvent) { fprintf(stderr, "HID is not available\n"); return 1; }

        keyboard = service(1, 6, @{@"Transport": @"USB", @"Product": @"simhost keyboard", @"Manufacturer": @"simhost",
                                    @"Built-In": @NO, @"VendorID": @0x05ac, @"ProductID": @0x0250, @"CountryCode": @0});
        if (!keyboard) { fprintf(stderr, "the keyboard service did not start\n"); return 1; }
        usleep(300000); // backboardd enumerates new services in this time.
        puts("READY"); fflush(stdout);

        char *line = NULL; size_t capacity = 0; ssize_t length;
        while ((length = getline(&line, &capacity, stdin)) > 0) {
            @autoreleasepool {
                if (line[length - 1] == '\n') line[--length] = 0;
                unsigned a, b; char extra;
                BOOL ok = NO;
                if (sscanf(line, "key %u %u %c", &a, &b, &extra) == 2) {
                    ok = key(a, b != 0);
                } else if (strncmp(line, "type ", 5) == 0) {
                    ok = type(line + 5);
                }
                puts(ok ? "OK" : "ERROR"); fflush(stdout);
            }
        }
        if (keyboard) ((void (*)(id, SEL))objc_msgSend)(keyboard, sel_registerName("cancel"));
    }
    return 0;
}
"""#
