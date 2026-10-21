// The ScreenSaver framework's extension classes, which `com.apple.screensaver` app extensions
// subclass. They are exported by the framework but not declared in its public headers; these
// declarations follow Apple's own screen saver extensions (live screen saver notes §7 (d)).

#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>

NS_ASSUME_NONNULL_BEGIN

/// The extension's principal class (`NSExtensionPrincipalClass`).
@interface ScreenSaverExtension : NSObject
- (instancetype)init;
@end

/// The view controller the host asks for the saver's view (`ScreenSaverViewControllerClass`).
@interface ScreenSaverViewController : NSViewController
@property (nonatomic, weak, nullable) ScreenSaverView *representedView;
@property (nonatomic, getter=isAnimating) BOOL animating;
- (void)loadViewForFrame:(NSRect)frame isPreview:(BOOL)isPreview NS_SWIFT_NAME(loadView(forFrame:isPreview:));
@end

NS_ASSUME_NONNULL_END
