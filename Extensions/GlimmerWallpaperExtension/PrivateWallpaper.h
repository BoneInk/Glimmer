// Adapted from Phosphene, copyright (c) 2026 kageroumado. MIT; see ThirdParty/Phosphene-LICENSE.txt.
//
//  WallpaperExtension-Bridging-Header.h
//  WallpaperVideoExtension
//
//  ObjC protocol definitions matching WallpaperExtensionKit.
//  XPC type classes are loaded at runtime via dlopen.
//

#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <bsm/libbsm.h>

// MARK: - Private NSXPCConnection caller identity
//
// NSXPCConnection exposes the connecting peer's audit token as private API.
// Declaring it here lets Swift read the token to validate the caller's code
// signature before accepting a connection. Guarded with -respondsToSelector:
// at the call site so a future OS that drops the SPI degrades gracefully.

@interface NSXPCConnection (PhospheneCallerIdentity)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

// MARK: - Private CAContext API (for remote rendering)

@interface CAContext : NSObject
@property (readonly) unsigned int contextId;
@property (retain, nullable) CALayer *layer;
+ (id)remoteContext;
+ (id)remoteContextWithOptions:(id)options;
@end

// MARK: - Extension → Host protocol (what we can call on WallpaperAgent)

@protocol WallpaperExtensionProxyXPCProtocol <NSObject>
- (void)pingWithId:(id _Nullable)anId;
- (void)updateSettingsViewModels:(id _Nullable)models reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)requestReadOnlyAccessTo:(id _Nullable)url reply:(void (^ _Nonnull)(id _Nullable))reply;
- (void)invalidateSnapshotsWithReply:(void (^ _Nonnull)(NSError * _Nullable))reply;
@end

// MARK: - Host → Extension protocol (what WallpaperAgent calls on us)

@protocol WallpaperExtensionXPCProtocol <NSObject>

// Lifecycle
- (void)acquireWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)updateWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invalidateWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)snapshotWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;

// Settings
- (void)provideSettingsViewModelsWithContentTypes:(id _Nullable)types reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;

// Choices
- (void)addChoiceRequestWithChoiceRequest:(id _Nullable)request onBehalfOfProcess:(id _Nullable)process reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)removeChoiceRequestWithChoiceRequest:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)selectedChoicesDidChangeFor:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invokeContextMenuActionWithMenuItemID:(id _Nullable)menuItemID groupItemID:(id _Nullable)groupItemID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Downloads
// The reply carries an NSNumber-boxed Bool (`@?<v@?@"NSNumber"@"NSError">`). Declaring a bare BOOL
// makes NSXPC reject the call as an undecodable message and cancel the whole agent connection.
- (void)isChoiceDownloadedWith:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSNumber * _Nullable, NSError * _Nullable))reply;
- (id _Nullable)downloadWithChoiceID:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)pauseDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)cancelDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)resumeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)removeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Migration
- (void)migrateSelectedChoiceFor:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)migrateFrom:(id _Nullable)from to:(id _Nullable)to reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Shuffle
- (void)skipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)canSkipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(BOOL, NSError * _Nullable))reply;

// Debug & notifications
- (void)handleDebugRequestFor:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)handleNotificationWithNamed:(id _Nullable)name reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

@end

#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <WebKit/WebKit.h>
NS_ASSUME_NONNULL_BEGIN
BOOL GWSandboxIsActive(void);
BOOL GWUseRemoteVideoComposition(AVSampleBufferDisplayLayer *layer);
BOOL GWApplePeer(NSXPCConnection *connection);
id _Nullable GWDecodeAsClass(NSData *data, Class targetClass, NSString *sourceName);
BOOL GWRoundTripObject(id object);
BOOL GWSetWebDeviceScale(WKWebView *view, double scale);
void GWAfterWebPresentation(WKWebView *view, void (^reply)(BOOL));
void GWCloseWebPage(WKWebView *view);
NS_ASSUME_NONNULL_END
BOOL GWXPCObjectRoundTrip(id _Nonnull object, NSTimeInterval timeout);
