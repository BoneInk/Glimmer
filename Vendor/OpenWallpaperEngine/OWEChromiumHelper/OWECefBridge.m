// The only code that talks to CEF. It uses CEF's C API from the headers vendored for the pinned
// version (Vendor/cef) and resolves every function with dlsym from the framework the app
// installed, so nothing links CEF at build time and the app itself never loads it.
//
// Threads: CEF's UI thread is the helper's main thread (external message pump), so every
// browser call and most handlers run there. Resource handlers run on CEF's IO thread; the
// renderer handlers run in the renderer subprocess.

#import "OWECefBridge.h"

#import <AppKit/AppKit.h>
#import <crt_externs.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stddef.h>
#import <string.h>
#import <unistd.h>

#include "include/cef_api_hash.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_callback_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_render_handler_capi.h"
#include "include/capi/cef_render_process_handler_capi.h"
#include "include/capi/cef_request_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/cef_resource_handler_capi.h"
#include "include/capi/cef_resource_request_handler_capi.h"
#include "include/capi/cef_response_capi.h"
#include "include/capi/cef_scheme_capi.h"
#include "include/capi/cef_v8_capi.h"
#include "include/capi/cef_values_capi.h"
#include "include/internal/cef_string.h"

static NSString *const kFrameworkName = @"Chromium Embedded Framework.framework";
static NSString *const kFrameworkBinary = @"Chromium Embedded Framework";
static const char *kFrameworkDirSwitch = "--framework-dir-path=";
static const char *kFrameworkDirEnvironment = "OWE_CEF_FRAMEWORK_DIR";
/// CEF's helper, copied into the engine bundle's Frameworks folder with its (Renderer), (GPU) and
/// (Plugin) variants, the names Chromium derives from this one.
static NSString *const kHelperName = @"OWE Chromium Helper";

// MARK: - The main bundle CEF sees

// Chromium gives each sandboxed subprocess read access to the browser's main bundle
// (`(allow file-read* (subpath (param bundle-path)))`), computed from +[NSBundle mainBundle].
// CEF's main_bundle_path setting doesn't change that parameter, and this process's own bundle is
// the XPC service, so the framework and helpers in the engine bundle would be unreadable once a
// subprocess enters the sandbox. This process exists only to host CEF, so from just before
// cef_initialize its main bundle is the engine bundle (OWE Chromium.app).
static NSBundle *engineMainBundle;
@implementation NSBundle (OWEEngineMainBundle)
+ (NSBundle *)owe_mainBundle { return engineMainBundle ?: [self owe_mainBundle]; }
@end
static void use_engine_main_bundle(NSString *path) {
    engineMainBundle = [NSBundle bundleWithPath:path];
    method_exchangeImplementations(class_getClassMethod(NSBundle.class, @selector(mainBundle)),
                                   class_getClassMethod(NSBundle.class, @selector(owe_mainBundle)));
}

/// The scheme local wallpapers load from; the app answers every request for it.
static const char *kWallpaperScheme = "owe-wallpaper";
static const char *kWallpaperSchemePrefix = "owe-wallpaper://";
/// A remote embed page (YouTube, Vimeo) is served by the app at this https origin, as WebKit's
/// `loadHTMLString(_:baseURL:)` does, because the players refuse other origins.
static const char *kEmbedPageURL = "https://localhost/";
/// The process message a renderer sends for `__owePost(name, body)`.
static const char *kPostMessageName = "owe-post";
/// The browser's start script travels to the renderer in the browser's extra info under this key.
static const char *kStartScriptKey = "owe-start-script";
/// The function the start script calls to reach the app; WebKit's equivalent is
/// `window.webkit.messageHandlers`.
static const char *kHostPostFunction = "__oweHostPost";

// MARK: - The NSApplication CEF requires

/// CEF's macOS message loop requires NSApp to implement CefAppProtocol (cef_application_mac.h).
/// The protocol header is C++, so the two methods are implemented by name.
@interface OWECefApplication : NSApplication {
    BOOL _handlingSendEvent;
}
@end

@implementation OWECefApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent { _handlingSendEvent = handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
    BOOL previous = _handlingSendEvent;
    _handlingSendEvent = YES;
    [super sendEvent:event];
    _handlingSendEvent = previous;
}
@end

void owe_cef_prepare_application(void) {
    [OWECefApplication sharedApplication];
    // No Dock icon, no menu bar: the helper has no UI.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
}

// MARK: - Loading the framework

typedef const char *(*api_hash_fn)(int, int);
typedef int (*execute_process_fn)(const cef_main_args_t *, cef_app_t *, void *);
typedef int (*initialize_fn)(const cef_main_args_t *, const cef_settings_t *, cef_app_t *, void *);
typedef void (*void_fn)(void);
typedef cef_browser_t *(*create_browser_sync_fn)(const cef_window_info_t *, cef_client_t *, const cef_string_t *,
                                                 const cef_browser_settings_t *, cef_dictionary_value_t *,
                                                 cef_request_context_t *);
typedef int (*utf8_to_utf16_fn)(const char *, size_t, cef_string_utf16_t *);
typedef int (*utf16_to_utf8_fn)(const char16_t *, size_t, cef_string_utf8_t *);
typedef void (*utf16_clear_fn)(cef_string_utf16_t *);
typedef void (*utf8_clear_fn)(cef_string_utf8_t *);
typedef void (*userfree_free_fn)(cef_string_userfree_utf16_t);
typedef cef_process_message_t *(*process_message_create_fn)(const cef_string_t *);
typedef cef_v8_context_t *(*v8_current_context_fn)(void);
typedef cef_v8_value_t *(*v8_create_function_fn)(const cef_string_t *, cef_v8_handler_t *);
typedef cef_dictionary_value_t *(*dictionary_create_fn)(void);
typedef void *(*sandbox_initialize_fn)(int, char **);
typedef void (*sandbox_destroy_fn)(void *);

static struct {
    api_hash_fn api_hash;
    execute_process_fn execute_process;
    initialize_fn initialize;
    void_fn do_message_loop_work;
    void_fn shutdown;
    create_browser_sync_fn create_browser_sync;
    utf8_to_utf16_fn utf8_to_utf16;
    utf16_to_utf8_fn utf16_to_utf8;
    utf16_clear_fn utf16_clear;
    utf8_clear_fn utf8_clear;
    userfree_free_fn userfree_free;
    process_message_create_fn process_message_create;
    v8_current_context_fn v8_current_context;
    v8_create_function_fn v8_create_function;
    dictionary_create_fn dictionary_create;
} cef;

static void set_error(char *error, size_t size, NSString *message) {
    if (error && size > 0) strlcpy(error, message.UTF8String, size);
}

/// Loads the framework binary under `frameworkDir` and resolves the functions used here, then
/// configures the API version the vendored headers describe and checks the library agrees.
static BOOL load_cef(NSString *frameworkDir, char *error, size_t errorSize) {
    NSString *binary = [[frameworkDir stringByAppendingPathComponent:kFrameworkName]
        stringByAppendingPathComponent:kFrameworkBinary];
    void *handle = dlopen(binary.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
    if (!handle) {
        const char *reason = dlerror();
        set_error(error, errorSize, [NSString stringWithFormat:@"Can't load %@: %s", binary, reason ? reason : "unknown"]);
        return NO;
    }
#define OWE_RESOLVE(field, symbol)                                                                   \
    cef.field = (__typeof__(cef.field))dlsym(handle, symbol);                                        \
    if (!cef.field) {                                                                                \
        set_error(error, errorSize, [NSString stringWithFormat:@"The framework has no %s", symbol]); \
        return NO;                                                                                   \
    }
    OWE_RESOLVE(api_hash, "cef_api_hash")
    OWE_RESOLVE(execute_process, "cef_execute_process")
    OWE_RESOLVE(initialize, "cef_initialize")
    OWE_RESOLVE(do_message_loop_work, "cef_do_message_loop_work")
    OWE_RESOLVE(shutdown, "cef_shutdown")
    OWE_RESOLVE(create_browser_sync, "cef_browser_host_create_browser_sync")
    OWE_RESOLVE(utf8_to_utf16, "cef_string_utf8_to_utf16")
    OWE_RESOLVE(utf16_to_utf8, "cef_string_utf16_to_utf8")
    OWE_RESOLVE(utf16_clear, "cef_string_utf16_clear")
    OWE_RESOLVE(utf8_clear, "cef_string_utf8_clear")
    OWE_RESOLVE(userfree_free, "cef_string_userfree_utf16_free")
    OWE_RESOLVE(process_message_create, "cef_process_message_create")
    OWE_RESOLVE(v8_current_context, "cef_v8_context_get_current_context")
    OWE_RESOLVE(v8_create_function, "cef_v8_value_create_function")
    OWE_RESOLVE(dictionary_create, "cef_dictionary_value_create")
#undef OWE_RESOLVE
    // Must be the first call into libcef: it fixes the struct layouts both sides use.
    const char *hash = cef.api_hash(CEF_API_VERSION, 0);
    if (!hash || strcmp(hash, CEF_API_HASH_PLATFORM) != 0) {
        set_error(error, errorSize,
                  [NSString stringWithFormat:@"The framework's API (%s) doesn't match the helper's (%s)",
                                             hash ? hash : "none", CEF_API_HASH_PLATFORM]);
        return NO;
    }
    return YES;
}

static void set_string(cef_string_t *target, const char *utf8) {
    if (utf8) cef.utf8_to_utf16(utf8, strlen(utf8), target);
}

/// A CEF string as an NSString (nil for none).
static NSString *string_from(const cef_string_t *value) {
    if (!value || !value->str) return nil;
    cef_string_utf8_t utf8 = {0};
    cef.utf16_to_utf8(value->str, value->length, &utf8);
    NSString *result = utf8.str ? [[NSString alloc] initWithBytes:utf8.str length:utf8.length
                                                         encoding:NSUTF8StringEncoding] : @"";
    cef.utf8_clear(&utf8);
    return result;
}

/// Converts and frees a string CEF handed over.
static NSString *take_string(cef_string_userfree_t value) {
    if (!value) return nil;
    NSString *result = string_from(value);
    cef.userfree_free(value);
    return result;
}

static void release_ref(cef_base_ref_counted_t *base) {
    if (base) base->release(base);
}
#define OWE_RELEASE(object) release_ref((object) ? &(object)->base : NULL)

// MARK: - Reference counting of long-lived handlers

// The app, the renderer handler and each browser's handlers live until the browser closes (or for
// the whole process), so their counting is a no-op; each browser's block is freed in
// `on_before_close`, CEF's last call for it.
static void CEF_CALLBACK static_add_ref(cef_base_ref_counted_t *self) { (void)self; }
static int CEF_CALLBACK static_release(cef_base_ref_counted_t *self) { (void)self; return 0; }
static int CEF_CALLBACK static_has_one_ref(cef_base_ref_counted_t *self) { (void)self; return 0; }
static int CEF_CALLBACK static_has_at_least_one_ref(cef_base_ref_counted_t *self) { (void)self; return 1; }

static void init_base(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = static_add_ref;
    base->release = static_release;
    base->has_one_ref = static_has_one_ref;
    base->has_at_least_one_ref = static_has_at_least_one_ref;
}

// MARK: - The app: scheme registration (every process) and the renderer's handler

static cef_app_t app;
static cef_render_process_handler_t renderProcessHandler;
static cef_v8_handler_t hostPostHandler;
/// Renderer only: each browser's start script, by CEF browser identifier.
static NSMutableDictionary<NSNumber *, NSString *> *startScripts;

static void CEF_CALLBACK app_on_register_custom_schemes(cef_app_t *self, cef_scheme_registrar_t *registrar) {
    (void)self;
    cef_string_t name = {0};
    set_string(&name, kWallpaperScheme);
    // Standard (host and path, relative URLs), secure (a secure context, as WebKit treats a custom
    // scheme), and open to CORS and fetch, so a page reads its own files as it does under WebKit.
    registrar->add_custom_scheme(registrar, &name,
                                 CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
                                     CEF_SCHEME_OPTION_CORS_ENABLED | CEF_SCHEME_OPTION_FETCH_ENABLED);
    cef.utf16_clear(&name);
}

/// The DevTools port the browser process listens on (127.0.0.1 only), or 0 for none.
static int remoteDebuggingPort = 0;

static void append_switch(cef_command_line_t *command_line, const char *switchName, const char *switchValue) {
    cef_string_t name = {0}, value = {0};
    set_string(&name, switchName);
    set_string(&value, switchValue);
    command_line->append_switch_with_value(command_line, &name, &value);
    cef.utf16_clear(&name);
    cef.utf16_clear(&value);
}

/// The browser process's switches: media plays without a user gesture, as WebKit is configured
/// for wallpapers (`mediaTypesRequiringUserActionForPlayback = []`); nobody can click a wallpaper
/// to start its sound. With DevTools on, the frontend that CEF serves on the port itself may open
/// its WebSocket (Chromium refuses any other origin).
static void CEF_CALLBACK app_on_before_command_line_processing(cef_app_t *self, const cef_string_t *process_type,
                                                               cef_command_line_t *command_line) {
    (void)self;
    if (process_type && process_type->length == 0 && command_line) {
        append_switch(command_line, "autoplay-policy", "no-user-gesture-required");
        if (remoteDebuggingPort > 0) {
            append_switch(command_line, "remote-debugging-address", "127.0.0.1");
            char origins[96];
            snprintf(origins, sizeof origins, "http://127.0.0.1:%d,http://localhost:%d",
                     remoteDebuggingPort, remoteDebuggingPort);
            append_switch(command_line, "remote-allow-origins", origins);
        }
    }
    OWE_RELEASE(command_line);
}

static cef_render_process_handler_t *CEF_CALLBACK app_get_render_process_handler(cef_app_t *self) {
    (void)self;
    return &renderProcessHandler;
}

static void CEF_CALLBACK render_on_browser_created(cef_render_process_handler_t *self, cef_browser_t *browser,
                                                   cef_dictionary_value_t *extra_info) {
    (void)self;
    if (extra_info) {
        cef_string_t key = {0};
        set_string(&key, kStartScriptKey);
        NSString *script = take_string(extra_info->get_string(extra_info, &key));
        cef.utf16_clear(&key);
        if (script.length) startScripts[@(browser->get_identifier(browser))] = script;
        OWE_RELEASE(extra_info);
    }
    OWE_RELEASE(browser);
}

static void CEF_CALLBACK render_on_browser_destroyed(cef_render_process_handler_t *self, cef_browser_t *browser) {
    (void)self;
    [startScripts removeObjectForKey:@(browser->get_identifier(browser))];
    OWE_RELEASE(browser);
}

/// `__oweHostPost(name, body)`: hands a message to the browser process for the app.
static int CEF_CALLBACK host_post_execute(cef_v8_handler_t *self, const cef_string_t *name, cef_v8_value_t *object,
                                          size_t argumentsCount, cef_v8_value_t *const *arguments,
                                          cef_v8_value_t **retval, cef_string_t *exception) {
    (void)self; (void)name; (void)object; (void)retval; (void)exception;
    if (argumentsCount < 2 || !arguments[0]->is_string(arguments[0]) || !arguments[1]->is_string(arguments[1])) {
        return 1;
    }
    cef_string_userfree_t messageName = arguments[0]->get_string_value(arguments[0]);
    cef_string_userfree_t body = arguments[1]->get_string_value(arguments[1]);
    cef_string_t processMessageName = {0};
    set_string(&processMessageName, kPostMessageName);
    cef_process_message_t *message = cef.process_message_create(&processMessageName);
    cef.utf16_clear(&processMessageName);
    cef_list_value_t *list = message->get_argument_list(message);
    list->set_string(list, 0, messageName);
    list->set_string(list, 1, body);
    OWE_RELEASE(list);
    if (messageName) cef.userfree_free(messageName);
    if (body) cef.userfree_free(body);
    cef_v8_context_t *context = cef.v8_current_context();
    cef_frame_t *frame = context ? context->get_frame(context) : NULL;
    if (frame) {
        frame->send_process_message(frame, PID_BROWSER, message);
    } else {
        OWE_RELEASE(message);
    }
    OWE_RELEASE(frame);
    OWE_RELEASE(context);
    return 1;
}

/// Runs before any of the document's own scripts: binds `__oweHostPost`, then the browser's start
/// script (the WE bridge, the same scripts WebKit injects at document start).
static void CEF_CALLBACK render_on_context_created(cef_render_process_handler_t *self, cef_browser_t *browser,
                                                   cef_frame_t *frame, cef_v8_context_t *context) {
    (void)self;
    NSString *script = startScripts[@(browser->get_identifier(browser))];
    if (frame->is_main(frame) && script) {
        cef_v8_value_t *global = context->get_global(context);
        cef_string_t functionName = {0};
        set_string(&functionName, kHostPostFunction);
        cef_v8_value_t *function = cef.v8_create_function(&functionName, &hostPostHandler);
        global->set_value_bykey(global, &functionName, function,
                                V8_PROPERTY_ATTRIBUTE_READONLY | V8_PROPERTY_ATTRIBUTE_DONTENUM |
                                    V8_PROPERTY_ATTRIBUTE_DONTDELETE);
        cef.utf16_clear(&functionName);
        OWE_RELEASE(global);
        cef_string_t code = {0}, url = {0};
        set_string(&code, script.UTF8String);
        set_string(&url, "owe-bridge.js");
        cef_v8_value_t *result = NULL;
        cef_v8_exception_t *exception = NULL;
        context->eval(context, &code, &url, 1, &result, &exception);
        cef.utf16_clear(&code);
        cef.utf16_clear(&url);
        OWE_RELEASE(result);
        OWE_RELEASE(exception);
    }
    OWE_RELEASE(browser);
    OWE_RELEASE(frame);
    OWE_RELEASE(context);
}

static void init_app(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        startScripts = [NSMutableDictionary dictionary];
        memset(&app, 0, sizeof app);
        init_base(&app.base, sizeof app);
        app.on_register_custom_schemes = app_on_register_custom_schemes;
        app.on_before_command_line_processing = app_on_before_command_line_processing;
        app.get_render_process_handler = app_get_render_process_handler;
        memset(&renderProcessHandler, 0, sizeof renderProcessHandler);
        init_base(&renderProcessHandler.base, sizeof renderProcessHandler);
        renderProcessHandler.on_browser_created = render_on_browser_created;
        renderProcessHandler.on_browser_destroyed = render_on_browser_destroyed;
        renderProcessHandler.on_context_created = render_on_context_created;
        memset(&hostPostHandler, 0, sizeof hostPostHandler);
        init_base(&hostPostHandler.base, sizeof hostPostHandler);
        hostPostHandler.execute = host_post_execute;
    });
}

// MARK: - Subprocesses

/// A subprocess failure goes to stderr and the unified log: an XPC service's stderr goes nowhere.
static void report(const char *message) {
    fprintf(stderr, "owe-chromium-helper: %s\n", message);
    os_log_error(OS_LOG_DEFAULT, "owe-chromium-helper: %{public}s", message);
}

int owe_cef_is_subprocess(int argc, char *const *argv) {
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--type=", 7) == 0) return 1;
    }
    return 0;
}

static NSString *subprocess_framework_dir(int argc, char **argv) {
    // CEF's layout: <engine>.app/Contents/Frameworks/<helper>.app beside the framework.
    NSString *frameworks = NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent;
    if ([NSFileManager.defaultManager fileExistsAtPath:[frameworks stringByAppendingPathComponent:kFrameworkName]]) {
        return frameworks;
    }
    size_t prefix = strlen(kFrameworkDirSwitch);
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], kFrameworkDirSwitch, prefix) == 0) {
            // The switch names the .framework itself; the folder above holds it.
            NSString *path = [NSString stringWithUTF8String:argv[i] + prefix];
            return [path.lastPathComponent isEqualToString:kFrameworkName] ? path.stringByDeletingLastPathComponent : path;
        }
    }
    const char *environment = getenv(kFrameworkDirEnvironment);
    return environment ? [NSString stringWithUTF8String:environment] : nil;
}

/// A subprocess runs unsandboxed only when the browser was started without the sandbox (Debug
/// builds only, `owe_cef_start`); CEF then passes --no-sandbox on.
static BOOL sandbox_disabled(int argc, char **argv) {
#if DEBUG
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--no-sandbox") == 0) return YES;
    }
#else
    (void)argc; (void)argv;
#endif
    return NO;
}

int owe_cef_run_subprocess(int argc, char **argv) {
    @autoreleasepool {
        NSString *frameworkDir = subprocess_framework_dir(argc, argv);
        if (!frameworkDir) {
            report("no framework folder for this subprocess");
            return 1;
        }
        // The sandbox is entered before the framework loads, as CefScopedSandboxContext does.
        void *sandboxContext = NULL;
        sandbox_destroy_fn sandboxDestroy = NULL;
        if (!sandbox_disabled(argc, argv)) {
            NSString *library = [[frameworkDir stringByAppendingPathComponent:kFrameworkName]
                stringByAppendingPathComponent:@"Libraries/libcef_sandbox.dylib"];
            void *sandbox = dlopen(library.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
            sandbox_initialize_fn initialize = sandbox ? (sandbox_initialize_fn)dlsym(sandbox, "cef_sandbox_initialize") : NULL;
            sandboxDestroy = sandbox ? (sandbox_destroy_fn)dlsym(sandbox, "cef_sandbox_destroy") : NULL;
            sandboxContext = initialize ? initialize(argc, argv) : NULL;
            if (!sandboxContext) {
                report("can't enter CEF's sandbox");
                return 1;
            }
        }
        char error[2048] = {0};
        if (!load_cef(frameworkDir, error, sizeof error)) {
            report(error);
            return 1;
        }
        // Every process registers the scheme; renderers also run the start scripts.
        init_app();
        cef_main_args_t args = {.argc = argc, .argv = argv};
        int code = cef.execute_process(&args, &app, NULL);
        if (sandboxContext && sandboxDestroy) sandboxDestroy(sandboxContext);
        return code;
    }
}

// MARK: - Resource requests (IO thread)

struct owe_cef_resource_request {
    cef_resource_handler_t handler; // first: CEF's pointer is the request's
    atomic_int refs;
    int browserId;
    pthread_mutex_t lock;
    cef_callback_t *openCallback; // released after it is continued
    int responded;
    int canceled;
    int status;
    CFDictionaryRef headers; // NSString → NSString, retained; NULL until answered
    void *data;
    size_t dataLength;
    size_t dataPosition;
    int fd;
    uint64_t fileOffset;
    uint64_t fileRemaining;
    uint64_t length;
};

static owe_cef_resource_request *request_from(cef_base_ref_counted_t *base) {
    return (owe_cef_resource_request *)base;
}

static void CEF_CALLBACK request_add_ref(cef_base_ref_counted_t *self) {
    atomic_fetch_add(&request_from(self)->refs, 1);
}

static int CEF_CALLBACK request_release(cef_base_ref_counted_t *self) {
    owe_cef_resource_request *request = request_from(self);
    if (atomic_fetch_sub(&request->refs, 1) != 1) return 0;
    if (request->openCallback) OWE_RELEASE(request->openCallback);
    if (request->fd >= 0) close(request->fd);
    free(request->data);
    if (request->headers) CFRelease(request->headers);
    pthread_mutex_destroy(&request->lock);
    free(request);
    return 1;
}

static int CEF_CALLBACK request_has_one_ref(cef_base_ref_counted_t *self) {
    return atomic_load(&request_from(self)->refs) == 1;
}

static int CEF_CALLBACK request_has_at_least_one_ref(cef_base_ref_counted_t *self) {
    return atomic_load(&request_from(self)->refs) >= 1;
}

/// What the browsers report to (set once by `owe_cef_initialize`, read on any thread after).
static owe_cef_callbacks callbacks;

static int CEF_CALLBACK resource_open(cef_resource_handler_t *self, cef_request_t *cefRequest, int *handle_request,
                                      cef_callback_t *callback) {
    owe_cef_resource_request *request = (owe_cef_resource_request *)self;
    NSString *url = take_string(cefRequest->get_url(cefRequest));
    cef_string_t rangeName = {0};
    set_string(&rangeName, "Range");
    NSString *range = take_string(cefRequest->get_header_by_name(cefRequest, &rangeName));
    cef.utf16_clear(&rangeName);
    OWE_RELEASE(cefRequest);
    // Answered asynchronously: the app replies over XPC and `owe_cef_resource_respond` continues.
    *handle_request = 0;
    pthread_mutex_lock(&request->lock);
    request->openCallback = callback;
    pthread_mutex_unlock(&request->lock);
    if (!callbacks.resource) {
        owe_cef_resource_respond(request, 404, "", NULL, 0, -1, 0, 0);
        return 1;
    }
    // The pending answer holds a reference until it arrives.
    request->handler.base.add_ref(&request->handler.base);
    callbacks.resource(callbacks.context, request->browserId, url.UTF8String ?: "",
                       range.length ? range.UTF8String : NULL, request);
    return 1;
}

void owe_cef_resource_respond(owe_cef_resource_request *request, int status, const char *headers,
                              const void *data, size_t data_length, int fd, uint64_t offset, uint64_t length) {
    NSMutableDictionary<NSString *, NSString *> *parsed = [NSMutableDictionary dictionary];
    for (NSString *line in [[NSString stringWithUTF8String:headers ?: ""] componentsSeparatedByString:@"\n"]) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (name.length) parsed[name] = value;
    }
    pthread_mutex_lock(&request->lock);
    if (request->responded) {
        pthread_mutex_unlock(&request->lock);
        if (fd >= 0) close(fd);
        return;
    }
    request->responded = 1;
    request->status = status;
    request->headers = (CFDictionaryRef)CFBridgingRetain([parsed copy]);
    if (fd >= 0) {
        request->fd = fd;
        request->fileOffset = offset;
        request->fileRemaining = length;
        request->length = length;
    } else if (data && data_length > 0) {
        request->data = malloc(data_length);
        if (request->data) {
            memcpy(request->data, data, data_length);
            request->dataLength = data_length;
        }
        request->length = request->dataLength;
    }
    cef_callback_t *callback = request->openCallback;
    request->openCallback = NULL;
    int canceled = request->canceled;
    pthread_mutex_unlock(&request->lock);
    if (callback) {
        if (!canceled) callback->cont(callback);
        OWE_RELEASE(callback);
    }
    // The reference `resource_open` took for this answer.
    request->handler.base.release(&request->handler.base);
}

static void CEF_CALLBACK resource_get_response_headers(cef_resource_handler_t *self, cef_response_t *response,
                                                       int64_t *response_length, cef_string_t *redirectUrl) {
    (void)redirectUrl;
    owe_cef_resource_request *request = (owe_cef_resource_request *)self;
    pthread_mutex_lock(&request->lock);
    response->set_status(response, request->status);
    NSDictionary<NSString *, NSString *> *headers = (__bridge NSDictionary *)request->headers;
    for (NSString *name in headers) {
        NSString *value = headers[name];
        cef_string_t cefName = {0}, cefValue = {0};
        set_string(&cefName, name.UTF8String);
        set_string(&cefValue, value.UTF8String);
        if ([name caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) {
            // CEF takes the MIME type separately; parameters (charset) stay in the header.
            NSString *mime = [[value componentsSeparatedByString:@";"].firstObject
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            cef_string_t cefMime = {0};
            set_string(&cefMime, mime.UTF8String);
            response->set_mime_type(response, &cefMime);
            cef.utf16_clear(&cefMime);
        }
        response->set_header_by_name(response, &cefName, &cefValue, 1);
        cef.utf16_clear(&cefName);
        cef.utf16_clear(&cefValue);
    }
    *response_length = (int64_t)request->length;
    pthread_mutex_unlock(&request->lock);
    OWE_RELEASE(response);
}

static int CEF_CALLBACK resource_skip(cef_resource_handler_t *self, int64_t bytes_to_skip, int64_t *bytes_skipped,
                                      cef_resource_skip_callback_t *callback) {
    OWE_RELEASE(callback);
    owe_cef_resource_request *request = (owe_cef_resource_request *)self;
    pthread_mutex_lock(&request->lock);
    uint64_t skip = bytes_to_skip > 0 ? (uint64_t)bytes_to_skip : 0;
    if (request->fd >= 0) {
        skip = MIN(skip, request->fileRemaining);
        request->fileOffset += skip;
        request->fileRemaining -= skip;
    } else {
        skip = MIN(skip, (uint64_t)(request->dataLength - request->dataPosition));
        request->dataPosition += skip;
    }
    pthread_mutex_unlock(&request->lock);
    *bytes_skipped = (int64_t)skip;
    return 1;
}

static int CEF_CALLBACK resource_read(cef_resource_handler_t *self, void *data_out, int bytes_to_read, int *bytes_read,
                                      cef_resource_read_callback_t *callback) {
    OWE_RELEASE(callback);
    owe_cef_resource_request *request = (owe_cef_resource_request *)self;
    *bytes_read = 0;
    pthread_mutex_lock(&request->lock);
    int result = 0;
    if (!request->canceled && bytes_to_read > 0) {
        if (request->fd >= 0 && request->fileRemaining > 0) {
            size_t wanted = (size_t)MIN((uint64_t)bytes_to_read, request->fileRemaining);
            ssize_t got = pread(request->fd, data_out, wanted, (off_t)request->fileOffset);
            if (got > 0) {
                request->fileOffset += (uint64_t)got;
                request->fileRemaining -= (uint64_t)got;
                *bytes_read = (int)got;
                result = 1;
            }
        } else if (request->data && request->dataPosition < request->dataLength) {
            size_t wanted = MIN((size_t)bytes_to_read, request->dataLength - request->dataPosition);
            memcpy(data_out, (const char *)request->data + request->dataPosition, wanted);
            request->dataPosition += wanted;
            *bytes_read = (int)wanted;
            result = 1;
        }
    }
    pthread_mutex_unlock(&request->lock);
    return result; // 0 with nothing read: the response is complete
}

static void CEF_CALLBACK resource_cancel(cef_resource_handler_t *self) {
    owe_cef_resource_request *request = (owe_cef_resource_request *)self;
    pthread_mutex_lock(&request->lock);
    request->canceled = 1;
    pthread_mutex_unlock(&request->lock);
}

static cef_resource_handler_t *make_resource_handler(int browserId) {
    owe_cef_resource_request *request = calloc(1, sizeof *request);
    if (!request) return NULL;
    request->handler.base.size = sizeof request->handler;
    request->handler.base.add_ref = request_add_ref;
    request->handler.base.release = request_release;
    request->handler.base.has_one_ref = request_has_one_ref;
    request->handler.base.has_at_least_one_ref = request_has_at_least_one_ref;
    request->handler.open = resource_open;
    request->handler.get_response_headers = resource_get_response_headers;
    request->handler.skip = resource_skip;
    request->handler.read = resource_read;
    request->handler.cancel = resource_cancel;
    atomic_init(&request->refs, 1); // CEF's
    request->browserId = browserId;
    request->fd = -1;
    pthread_mutex_init(&request->lock, NULL);
    return &request->handler;
}

// MARK: - Browsers (main thread)

/// One browser and its handlers; CEF's `self` pointers lead back here (`OWE_BROWSER`).
typedef struct {
    cef_client_t client;
    cef_render_handler_t render;
    cef_life_span_handler_t lifeSpan;
    cef_load_handler_t load;
    cef_request_handler_t request;
    cef_resource_request_handler_t resourceRequest;
    int id;
    int width;  // points
    int height; // points
    double scale;
    int closing;
    cef_browser_t *browser;
} owe_browser;

#define OWE_BROWSER(pointer, member) ((owe_browser *)((char *)(pointer) - offsetof(owe_browser, member)))

/// Open browsers by the app's number.
static NSMutableDictionary<NSNumber *, NSValue *> *browsers;
static NSTimer *pump;
static int initializeStatus = -1; // -1 not tried, 0 running, 1 failed
static NSString *initializeError;

static owe_browser *browser_for(int browserId) {
    owe_browser *browser = [browsers[@(browserId)] pointerValue];
    return browser && !browser->closing && browser->browser ? browser : NULL;
}

/// Calls `body` with the browser's host, if the browser is open.
static void with_host(int browserId, void (^body)(owe_browser *, cef_browser_host_t *)) {
    owe_browser *browser = browser_for(browserId);
    if (!browser) return;
    cef_browser_host_t *host = browser->browser->get_host(browser->browser);
    if (!host) return;
    body(browser, host);
    OWE_RELEASE(host);
}

static cef_render_handler_t *CEF_CALLBACK client_get_render_handler(cef_client_t *self) {
    return &OWE_BROWSER(self, client)->render;
}

static cef_life_span_handler_t *CEF_CALLBACK client_get_life_span_handler(cef_client_t *self) {
    return &OWE_BROWSER(self, client)->lifeSpan;
}

static cef_load_handler_t *CEF_CALLBACK client_get_load_handler(cef_client_t *self) {
    return &OWE_BROWSER(self, client)->load;
}

static cef_request_handler_t *CEF_CALLBACK client_get_request_handler(cef_client_t *self) {
    return &OWE_BROWSER(self, client)->request;
}

static int CEF_CALLBACK client_on_process_message_received(cef_client_t *self, cef_browser_t *cefBrowser,
                                                           cef_frame_t *frame, cef_process_id_t source,
                                                           cef_process_message_t *message) {
    owe_browser *browser = OWE_BROWSER(self, client);
    int handled = 0;
    NSString *name = take_string(message->get_name(message));
    if (source == PID_RENDERER && [name isEqualToString:@(kPostMessageName)]) {
        handled = 1;
        cef_list_value_t *list = message->get_argument_list(message);
        if (list && list->get_size(list) >= 2 && !browser->closing && callbacks.message) {
            NSString *postName = take_string(list->get_string(list, 0)) ?: @"";
            NSString *body = take_string(list->get_string(list, 1)) ?: @"null";
            callbacks.message(callbacks.context, browser->id, postName.UTF8String, body.UTF8String);
        }
        OWE_RELEASE(list);
    }
    OWE_RELEASE(message);
    OWE_RELEASE(frame);
    OWE_RELEASE(cefBrowser);
    return handled;
}

static void CEF_CALLBACK render_get_view_rect(cef_render_handler_t *self, cef_browser_t *cefBrowser, cef_rect_t *rect) {
    owe_browser *browser = OWE_BROWSER(self, render);
    rect->x = 0;
    rect->y = 0;
    rect->width = MAX(1, browser->width);
    rect->height = MAX(1, browser->height);
    OWE_RELEASE(cefBrowser);
}

static int CEF_CALLBACK render_get_screen_info(cef_render_handler_t *self, cef_browser_t *cefBrowser,
                                               cef_screen_info_t *info) {
    owe_browser *browser = OWE_BROWSER(self, render);
    info->device_scale_factor = (float)(browser->scale > 0 ? browser->scale : 1);
    info->depth = 24;
    info->depth_per_component = 8;
    info->rect = (cef_rect_t){0, 0, MAX(1, browser->width), MAX(1, browser->height)};
    info->available_rect = info->rect;
    OWE_RELEASE(cefBrowser);
    return 1;
}

static void CEF_CALLBACK render_on_paint(cef_render_handler_t *self, cef_browser_t *cefBrowser,
                                         cef_paint_element_type_t type, size_t dirtyRectsCount,
                                         cef_rect_t const *dirtyRects, const void *buffer, int width, int height) {
    // Only called when shared textures are unavailable; frames are shared textures only, so the
    // page shows nothing. Said once per helper process.
    (void)self; (void)type; (void)dirtyRectsCount; (void)dirtyRects; (void)buffer; (void)width; (void)height;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        report("software paint frames (no shared textures) are dropped; the page draws nothing");
    });
    OWE_RELEASE(cefBrowser);
}

static void CEF_CALLBACK render_on_accelerated_paint(cef_render_handler_t *self, cef_browser_t *cefBrowser,
                                                     cef_paint_element_type_t type, size_t dirtyRectsCount,
                                                     cef_rect_t const *dirtyRects,
                                                     const cef_accelerated_paint_info_t *info) {
    (void)dirtyRectsCount; (void)dirtyRects;
    owe_browser *browser = OWE_BROWSER(self, render);
    if (type == PET_VIEW && info && info->shared_texture_io_surface && !browser->closing && callbacks.frame) {
        callbacks.frame(callbacks.context, browser->id, (IOSurfaceRef)info->shared_texture_io_surface);
    }
    OWE_RELEASE(cefBrowser);
}

static int CEF_CALLBACK life_span_on_before_popup(cef_life_span_handler_t *self, cef_browser_t *cefBrowser,
                                                  cef_frame_t *frame, int popup_id, const cef_string_t *target_url,
                                                  const cef_string_t *target_frame_name,
                                                  cef_window_open_disposition_t target_disposition, int user_gesture,
                                                  const cef_popup_features_t *popupFeatures,
                                                  cef_window_info_t *windowInfo, cef_client_t **client,
                                                  cef_browser_settings_t *settings, cef_dictionary_value_t **extra_info,
                                                  int *no_javascript_access) {
    // A wallpaper has no window to open another in; WebKit's page gets no popup either.
    (void)self; (void)popup_id; (void)target_url; (void)target_frame_name; (void)target_disposition;
    (void)user_gesture; (void)popupFeatures; (void)windowInfo; (void)client; (void)settings; (void)extra_info;
    (void)no_javascript_access;
    OWE_RELEASE(frame);
    OWE_RELEASE(cefBrowser);
    return 1;
}

static void CEF_CALLBACK life_span_on_before_close(cef_life_span_handler_t *self, cef_browser_t *cefBrowser) {
    owe_browser *browser = OWE_BROWSER(self, lifeSpan);
    [browsers removeObjectForKey:@(browser->id)];
    OWE_RELEASE(browser->browser);
    OWE_RELEASE(cefBrowser);
    // CEF's last call for this browser: its handlers are no longer used.
    free(browser);
}

static void CEF_CALLBACK load_on_load_end(cef_load_handler_t *self, cef_browser_t *cefBrowser, cef_frame_t *frame,
                                          int httpStatusCode) {
    owe_browser *browser = OWE_BROWSER(self, load);
    if (frame->is_main(frame) && !browser->closing && callbacks.load_end) {
        callbacks.load_end(callbacks.context, browser->id, httpStatusCode);
    }
    OWE_RELEASE(frame);
    OWE_RELEASE(cefBrowser);
}

static void CEF_CALLBACK load_on_load_error(cef_load_handler_t *self, cef_browser_t *cefBrowser, cef_frame_t *frame,
                                            cef_errorcode_t errorCode, const cef_string_t *errorText,
                                            const cef_string_t *failedUrl) {
    (void)errorText; (void)failedUrl;
    owe_browser *browser = OWE_BROWSER(self, load);
    // ERR_ABORTED (-3) is a navigation replaced by another, not a failure.
    if (frame->is_main(frame) && errorCode != -3 && !browser->closing && callbacks.load_end) {
        callbacks.load_end(callbacks.context, browser->id, (int)errorCode);
    }
    OWE_RELEASE(frame);
    OWE_RELEASE(cefBrowser);
}

static cef_resource_request_handler_t *CEF_CALLBACK request_get_resource_request_handler(
    cef_request_handler_t *self, cef_browser_t *cefBrowser, cef_frame_t *frame, cef_request_t *request,
    int is_navigation, int is_download, const cef_string_t *request_initiator, int *disable_default_handling) {
    (void)is_download; (void)request_initiator; (void)disable_default_handling;
    owe_browser *browser = OWE_BROWSER(self, request);
    NSString *url = take_string(request->get_url(request));
    BOOL ours = [url hasPrefix:@(kWallpaperSchemePrefix)]
        || (is_navigation && frame && frame->is_main(frame) && [url isEqualToString:@(kEmbedPageURL)]);
    OWE_RELEASE(request);
    OWE_RELEASE(frame);
    OWE_RELEASE(cefBrowser);
    return ours ? &browser->resourceRequest : NULL;
}

static void CEF_CALLBACK request_on_render_process_terminated(cef_request_handler_t *self, cef_browser_t *cefBrowser,
                                                              cef_termination_status_t status, int error_code,
                                                              const cef_string_t *error_string) {
    owe_browser *browser = OWE_BROWSER(self, request);
    NSString *reason = [NSString stringWithFormat:@"status %d, code %d: %@", (int)status, error_code,
                                                  string_from(error_string) ?: @""];
    if (!browser->closing && callbacks.terminated) callbacks.terminated(callbacks.context, browser->id, reason.UTF8String);
    OWE_RELEASE(cefBrowser);
}

static cef_resource_handler_t *CEF_CALLBACK resource_request_get_resource_handler(
    cef_resource_request_handler_t *self, cef_browser_t *cefBrowser, cef_frame_t *frame, cef_request_t *request) {
    owe_browser *browser = OWE_BROWSER(self, resourceRequest);
    OWE_RELEASE(request);
    OWE_RELEASE(frame);
    OWE_RELEASE(cefBrowser);
    return make_resource_handler(browser->id);
}

static owe_browser *make_browser(int browserId, int width, int height, double scale) {
    owe_browser *browser = calloc(1, sizeof *browser);
    if (!browser) return NULL;
    browser->id = browserId;
    browser->width = width;
    browser->height = height;
    browser->scale = scale;
    init_base(&browser->client.base, sizeof browser->client);
    browser->client.get_render_handler = client_get_render_handler;
    browser->client.get_life_span_handler = client_get_life_span_handler;
    browser->client.get_load_handler = client_get_load_handler;
    browser->client.get_request_handler = client_get_request_handler;
    browser->client.on_process_message_received = client_on_process_message_received;
    init_base(&browser->render.base, sizeof browser->render);
    browser->render.get_view_rect = render_get_view_rect;
    browser->render.get_screen_info = render_get_screen_info;
    browser->render.on_paint = render_on_paint;
    browser->render.on_accelerated_paint = render_on_accelerated_paint;
    init_base(&browser->lifeSpan.base, sizeof browser->lifeSpan);
    browser->lifeSpan.on_before_popup = life_span_on_before_popup;
    browser->lifeSpan.on_before_close = life_span_on_before_close;
    init_base(&browser->load.base, sizeof browser->load);
    browser->load.on_load_end = load_on_load_end;
    browser->load.on_load_error = load_on_load_error;
    init_base(&browser->request.base, sizeof browser->request);
    browser->request.get_resource_request_handler = request_get_resource_request_handler;
    browser->request.on_render_process_terminated = request_on_render_process_terminated;
    init_base(&browser->resourceRequest.base, sizeof browser->resourceRequest);
    browser->resourceRequest.get_resource_handler = resource_request_get_resource_handler;
    return browser;
}

int owe_cef_initialize(const char *engine_bundle, const char *cache_dir, int no_sandbox,
                       int remote_debugging_port, const owe_cef_callbacks *newCallbacks,
                       char *error, size_t error_size) {
    @autoreleasepool {
        if (initializeStatus == 0) return 0;
        if (initializeStatus == 1) {
            set_error(error, error_size, initializeError ?: @"CEF didn't initialize");
            return 1;
        }
        initializeStatus = 1;
        // Everything CEF runs from lives in one bundle, so its sandbox (which allows the main
        // bundle) covers the framework, its resources and the helpers.
        NSString *bundle = [NSString stringWithUTF8String:engine_bundle];
        NSString *frameworks = [bundle stringByAppendingPathComponent:@"Contents/Frameworks"];
        NSString *helper = [frameworks stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.app/Contents/MacOS/%@", kHelperName, kHelperName]];
        if (![NSFileManager.defaultManager isExecutableFileAtPath:helper]) {
            initializeError = [NSString stringWithFormat:@"The engine has no helper at %@", helper];
            set_error(error, error_size, initializeError);
            return 1;
        }
        if (!load_cef(frameworks, error, error_size)) {
            initializeError = [NSString stringWithUTF8String:error];
            return 1;
        }
        use_engine_main_bundle(bundle);
        // Subprocesses find the framework through this when CEF doesn't pass the switch on.
        setenv(kFrameworkDirEnvironment, frameworks.fileSystemRepresentation, 1);
        if (newCallbacks) callbacks = *newCallbacks;
        browsers = [NSMutableDictionary dictionary];
        init_app();

        cef_main_args_t args = {.argc = *_NSGetArgc(), .argv = *_NSGetArgv()};
        cef_settings_t settings;
        memset(&settings, 0, sizeof settings);
        settings.size = sizeof settings;
#if DEBUG
        settings.no_sandbox = no_sandbox != 0;
#else
        (void)no_sandbox;
#endif
        settings.windowless_rendering_enabled = 1;
        settings.external_message_pump = 1;
        settings.command_line_args_disabled = 1;
        settings.persist_session_cookies = 0;
        settings.log_severity = LOGSEVERITY_WARNING;
        remoteDebuggingPort = remote_debugging_port >= 1024 && remote_debugging_port <= 65535 ? remote_debugging_port : 0;
        settings.remote_debugging_port = remoteDebuggingPort;
        NSString *frameworkPath = [frameworks stringByAppendingPathComponent:kFrameworkName];
        set_string(&settings.framework_dir_path, frameworkPath.fileSystemRepresentation);
        set_string(&settings.main_bundle_path, bundle.fileSystemRepresentation);
        set_string(&settings.browser_subprocess_path, helper.fileSystemRepresentation);
        set_string(&settings.root_cache_path, cache_dir);
        // CEF's own log (fatal checks included): an XPC service's stderr goes nowhere.
        NSString *logFile = [[NSString stringWithUTF8String:cache_dir] stringByAppendingPathComponent:@"cef.log"];
        set_string(&settings.log_file, logFile.fileSystemRepresentation);
        int initialized = cef.initialize(&args, &settings, &app, NULL);
        cef.utf16_clear(&settings.framework_dir_path);
        cef.utf16_clear(&settings.browser_subprocess_path);
        cef.utf16_clear(&settings.main_bundle_path);
        cef.utf16_clear(&settings.root_cache_path);
        cef.utf16_clear(&settings.log_file);
        if (!initialized) {
            initializeError = @"CEF didn't initialize";
            set_error(error, error_size, initializeError);
            return 1;
        }
        // External pump: CEF's work runs on this thread's run loop, often enough for 120 Hz pages.
        pump = [NSTimer scheduledTimerWithTimeInterval:1.0 / 240 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            cef.do_message_loop_work();
        }];
        [NSRunLoop.mainRunLoop addTimer:pump forMode:NSRunLoopCommonModes];
        initializeStatus = 0;
        return 0;
    }
}

int owe_cef_create_browser(int browser_id, const char *url, int width, int height, double scale, int frame_rate,
                           const char *start_script, char *error, size_t error_size) {
    @autoreleasepool {
        if (initializeStatus != 0) {
            set_error(error, error_size, @"CEF isn't running");
            return 1;
        }
        if (browsers[@(browser_id)]) {
            set_error(error, error_size, [NSString stringWithFormat:@"Browser %d already exists", browser_id]);
            return 1;
        }
        owe_browser *browser = make_browser(browser_id, width, height, scale);
        if (!browser) {
            set_error(error, error_size, @"Out of memory");
            return 1;
        }
        cef_window_info_t windowInfo;
        memset(&windowInfo, 0, sizeof windowInfo);
        windowInfo.size = sizeof windowInfo;
        windowInfo.windowless_rendering_enabled = 1;
        windowInfo.shared_texture_enabled = 1;
        cef_browser_settings_t browserSettings;
        memset(&browserSettings, 0, sizeof browserSettings);
        browserSettings.size = sizeof browserSettings;
        browserSettings.windowless_frame_rate = MAX(1, MIN(frame_rate, 240));
        cef_dictionary_value_t *extraInfo = NULL;
        if (start_script && *start_script) {
            extraInfo = cef.dictionary_create();
            cef_string_t key = {0}, value = {0};
            set_string(&key, kStartScriptKey);
            set_string(&value, start_script);
            extraInfo->set_string(extraInfo, &key, &value);
            cef.utf16_clear(&key);
            cef.utf16_clear(&value);
        }
        cef_string_t address = {0};
        set_string(&address, url);
        // Recorded first: requests for the page may arrive before the call returns.
        browsers[@(browser_id)] = [NSValue valueWithPointer:browser];
        browser->browser = cef.create_browser_sync(&windowInfo, &browser->client, &address, &browserSettings,
                                                   extraInfo, NULL);
        cef.utf16_clear(&address);
        if (!browser->browser) {
            [browsers removeObjectForKey:@(browser_id)];
            free(browser);
            set_error(error, error_size, @"CEF didn't create the browser");
            return 1;
        }
        return 0;
    }
}

/// Set while `owe_cef_run` keeps the main run loop going; cleared by `owe_cef_stop`.
static atomic_int running;

void owe_cef_run(void) {
    // CEF's message pump observes the main run loop's entries and exits and pops one record per
    // exit. CEF starts from a callout inside a run-loop pass whose entry it never saw, so letting
    // that pass end trips its check (EXC_BREAKPOINT). Running nested passes from here keeps the
    // outer one open; every pass CEF sees from now on has both its entry and its exit.
    int expected = 0;
    if (initializeStatus != 0 || !atomic_compare_exchange_strong(&running, &expected, 1)) return;
    while (atomic_load(&running)) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
    }
}

void owe_cef_close_browser(int browser_id) {
    with_host(browser_id, ^(owe_browser *browser, cef_browser_host_t *host) {
        browser->closing = 1;
        host->close_browser(host, 1);
    });
}

void owe_cef_resize_browser(int browser_id, int width, int height, double scale) {
    with_host(browser_id, ^(owe_browser *browser, cef_browser_host_t *host) {
        BOOL scaleChanged = browser->scale != scale;
        browser->width = width;
        browser->height = height;
        browser->scale = scale;
        if (scaleChanged) host->notify_screen_info_changed(host);
        host->was_resized(host);
    });
}

void owe_cef_set_hidden(int browser_id, int hidden) {
    with_host(browser_id, ^(owe_browser *browser, cef_browser_host_t *host) {
        (void)browser;
        host->was_hidden(host, hidden);
    });
}

void owe_cef_set_frame_rate(int browser_id, int frame_rate) {
    with_host(browser_id, ^(owe_browser *browser, cef_browser_host_t *host) {
        (void)browser;
        host->set_windowless_frame_rate(host, MAX(1, MIN(frame_rate, 240)));
    });
}

void owe_cef_set_audio_muted(int browser_id, int muted) {
    with_host(browser_id, ^(owe_browser *browser, cef_browser_host_t *host) {
        (void)browser;
        host->set_audio_muted(host, muted);
    });
}

void owe_cef_execute_javascript(int browser_id, const char *script) {
    owe_browser *browser = browser_for(browser_id);
    if (!browser || !script) return;
    cef_frame_t *frame = browser->browser->get_main_frame(browser->browser);
    if (!frame) return;
    cef_string_t code = {0}, url = {0};
    set_string(&code, script);
    set_string(&url, "owe-bridge.js");
    frame->execute_java_script(frame, &code, &url, 1);
    cef.utf16_clear(&code);
    cef.utf16_clear(&url);
    OWE_RELEASE(frame);
}

void owe_cef_send_mouse(int browser_id, int kind, double x, double y, int button, int click_count,
                        double delta_x, double delta_y, uint32_t modifiers) {
    with_host(browser_id, ^(owe_browser *browser, cef_browser_host_t *host) {
        (void)browser;
        cef_mouse_event_t event = {.x = (int)lround(x), .y = (int)lround(y), .modifiers = modifiers};
        cef_mouse_button_type_t type = button == 2 ? MBT_RIGHT : button == 1 ? MBT_MIDDLE : MBT_LEFT;
        switch (kind) {
        case 0: host->send_mouse_move_event(host, &event, 0); break;
        case 1: host->send_mouse_click_event(host, &event, type, 0, MAX(1, click_count)); break;
        case 2: host->send_mouse_click_event(host, &event, type, 1, MAX(1, click_count)); break;
        case 3: host->send_mouse_wheel_event(host, &event, (int)lround(delta_x), (int)lround(delta_y)); break;
        case 4: host->send_mouse_move_event(host, &event, 1); break;
        default: break;
        }
    });
}

// MARK: - Phase 1: one browser, frames to a plain callback

static owe_cef_frame_callback phase1Callback;
static void *phase1Context;

static void phase1_frame(void *context, int browser_id, IOSurfaceRef surface) {
    (void)context; (void)browser_id;
    if (phase1Callback) phase1Callback(phase1Context, surface);
}

int owe_cef_start(const char *engine_bundle, const char *cache_dir, const char *url, int width, int height,
                  int frame_rate, int no_sandbox, owe_cef_frame_callback callback, void *context, char *error, size_t error_size) {
    if (initializeStatus != -1) {
        set_error(error, error_size, @"The helper already started CEF");
        return 1;
    }
    phase1Callback = callback;
    phase1Context = context;
    owe_cef_callbacks phase1 = {.frame = phase1_frame};
    if (owe_cef_initialize(engine_bundle, cache_dir, no_sandbox, 0, &phase1, error, error_size) != 0) return 1;
    // Pixels as points at scale 1: the size asked for is the size painted.
    return owe_cef_create_browser(0, url, width, height, 1, frame_rate, NULL, error, error_size);
}

void owe_cef_stop(void) {
    phase1Callback = NULL;
    for (NSNumber *browserId in browsers.allKeys) owe_cef_close_browser(browserId.intValue);
    atomic_store(&running, 0);
}
