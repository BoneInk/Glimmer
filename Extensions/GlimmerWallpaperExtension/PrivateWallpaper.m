#import "PrivateWallpaper.h"
#import <objc/message.h>
extern int sandbox_check(pid_t pid, const char *operation, int type, ...);
BOOL GWSandboxIsActive(void) { return sandbox_check(getpid(), NULL, 0) > 0; }

BOOL GWSetWebDeviceScale(WKWebView *view, double scale) {
    SEL selector = NSSelectorFromString(@"_setOverrideDeviceScaleFactor:");
    if (![view respondsToSelector:selector]) return NO;
    ((void (*)(id, SEL, double))objc_msgSend)(view, selector, scale);
    return YES;
}

void GWAfterWebPresentation(WKWebView *view, void (^reply)(BOOL)) {
    SEL selector = NSSelectorFromString(@"_doAfterNextPresentationUpdate:");
    if (![view respondsToSelector:selector]) { reply(NO); return; }
    ((void (*)(id, SEL, id))objc_msgSend)(view, selector, ^{ reply(YES); });
}

void GWCloseWebPage(WKWebView *view) {
    SEL selector = NSSelectorFromString(@"_close");
    if ([view respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(view, selector);
}

// Isolate private-selector calls and Objective-C archive exceptions from Swift.
BOOL GWUseRemoteVideoComposition(AVSampleBufferDisplayLayer *layer) {
    SEL selector = NSSelectorFromString(@"_setDisallowsVideoLayerDisplayCompositing:");
    if (![layer respondsToSelector:selector]) return NO;
    @try {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, selector, YES);
        return YES;
    } @catch (NSException *exception) { NSLog(@"GW private runtime exception: %@", exception); return NO; }
}

BOOL GWApplePeer(NSXPCConnection *connection) {
    if (connection.effectiveUserIdentifier != getuid() && connection.effectiveUserIdentifier != 0) return NO;
    if (![connection respondsToSelector:@selector(auditToken)]) return NO;
    audit_token_t token = connection.auditToken;
    NSData *data = [NSData dataWithBytes:&token length:sizeof(token)];
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)@{(__bridge NSString *)kSecGuestAttributeAudit:data}, 0, &code);
    if (status != errSecSuccess || !code) return NO;
    SecRequirementRef requirement = NULL;
    status = SecRequirementCreateWithString(CFSTR("anchor apple"), 0, &requirement);
    BOOL accepted = status == errSecSuccess && requirement && SecCodeCheckValidity(code, 0, requirement) == errSecSuccess;
    if (requirement) CFRelease(requirement);
    CFRelease(code);
    return accepted;
}

id GWDecodeAsClass(NSData *data, Class targetClass, NSString *sourceName) {
    @try {
        NSError *error = nil;
        NSKeyedUnarchiver *decoder = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
        if (!decoder || error) return nil;
        decoder.requiresSecureCoding = NO; // trusted in-process archive only
        decoder.decodingFailurePolicy = NSDecodingFailurePolicySetErrorAndReturn;
        [decoder setClass:targetClass forClassName:sourceName];
        id value = [decoder decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        [decoder finishDecoding];
        if (decoder.error) NSLog(@"GW settings unarchive error: %@", decoder.error);
        return decoder.error ? nil : value;
    } @catch (NSException *exception) { NSLog(@"GW runtime archive exception: %@", exception); return nil; }
}

BOOL GWRoundTripObject(id object) {
    @try {
        NSError *error = nil;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:YES error:&error];
        if (!data || error) return NO;
        id result = [NSKeyedUnarchiver unarchivedObjectOfClass:[object class] fromData:data error:&error];
        if (error) NSLog(@"GW secure roundtrip %@ error: %@", [object class], error);
        return result != nil && error == nil;
    } @catch (NSException *exception) { NSLog(@"GW private runtime exception: %@", exception); return NO; }
}

// Explicit diagnostic only: anonymous in-process endpoints still use NSXPCCoder,
// unlike NSKeyedArchiver, so this verifies real IOSurface XPC transport without
// registering a service or touching WallpaperAgent/the wallpaper selection.
@protocol GWLocalTransport
- (void)echo:(id)object reply:(void (^)(id))reply;
@end
@interface GWLocalTransportHost : NSObject <GWLocalTransport, NSXPCListenerDelegate>
@property (strong) NSXPCInterface *interface;
@end
@implementation GWLocalTransportHost
- (void)echo:(id)object reply:(void (^)(id))reply { reply(object); }
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.exportedInterface = self.interface;
    connection.exportedObject = self;
    [connection resume];
    return YES;
}
@end
BOOL GWXPCObjectRoundTrip(id object, NSTimeInterval timeout) {
    @try {
        NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(GWLocalTransport)];
        NSSet *classes = [NSSet setWithObjects:[object class], [NSString class], [NSNumber class], [NSArray class], [NSDictionary class], [NSData class], [NSURL class], nil];
        [interface setClasses:classes forSelector:@selector(echo:reply:) argumentIndex:0 ofReply:NO];
        [interface setClasses:classes forSelector:@selector(echo:reply:) argumentIndex:0 ofReply:YES];
        GWLocalTransportHost *host = [GWLocalTransportHost new];
        host.interface = interface;
        NSXPCListener *listener = [NSXPCListener anonymousListener];
        listener.delegate = host;
        [listener resume];
        NSXPCConnection *client = [[NSXPCConnection alloc] initWithListenerEndpoint:listener.endpoint];
        client.remoteObjectInterface = interface;
        [client resume];
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block BOOL success = NO;
        id<GWLocalTransport> proxy = [client remoteObjectProxyWithErrorHandler:^(NSError *error) {
            NSLog(@"GW isolated XPC transport error: %@", error);
            dispatch_semaphore_signal(semaphore);
        }];
        [proxy echo:object reply:^(id reply) { success = [reply isKindOfClass:[object class]]; dispatch_semaphore_signal(semaphore); }];
        long wait = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
        [client invalidate];
        [listener invalidate];
        return wait == 0 && success;
    } @catch (NSException *exception) { NSLog(@"GW isolated XPC exception: %@", exception); return NO; }
}
