#import "NativeWebLayerReceiver.h"
#import <objc/message.h>
CALayer *GWProbeLayerHost(unsigned int contextID) {
    CALayer *layer = [NSClassFromString(@"CALayerHost") new];
    SEL setter = NSSelectorFromString(@"setContextId:");
    if (![layer respondsToSelector:setter]) return nil;
    ((void (*)(id, SEL, unsigned int))objc_msgSend)(layer, setter, contextID);
    return layer;
}
