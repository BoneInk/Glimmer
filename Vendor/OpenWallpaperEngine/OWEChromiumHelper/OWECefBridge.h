#ifndef OWE_CEF_BRIDGE_H
#define OWE_CEF_BRIDGE_H

#include <IOSurface/IOSurfaceRef.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Called on the main thread for every frame CEF paints into a shared texture. The surface is
/// CEF's and goes back to its pool when this returns, so it must be copied before returning.
typedef void (*owe_cef_frame_callback)(void *context, IOSurfaceRef surface);

/// One `owe-wallpaper://` request waiting for the app's answer (`owe_cef_resource_respond`).
typedef struct owe_cef_resource_request owe_cef_resource_request;

/// What the browsers report, all on the main thread except `resource` (CEF's IO thread).
typedef struct {
    void *context;
    /// A frame of browser `browser_id`; the surface must be copied before returning.
    void (*frame)(void *context, int browser_id, IOSurfaceRef surface);
    /// The page called `__owePost(name, body)`.
    void (*message)(void *context, int browser_id, const char *name, const char *body);
    /// The main frame finished loading: an HTTP status, or a negative CEF error code.
    void (*load_end)(void *context, int browser_id, int status);
    /// The page's renderer process ended.
    void (*terminated)(void *context, int browser_id, const char *reason);
    /// A request to answer with `owe_cef_resource_respond` (exactly once, from any thread).
    /// `range` is the request's Range header, or NULL.
    void (*resource)(void *context, int browser_id, const char *url, const char *range,
                     owe_cef_resource_request *request);
} owe_cef_callbacks;

/// Whether `argv` belongs to a CEF subprocess (renderer, GPU, utility): it has a `--type=` switch.
int owe_cef_is_subprocess(int argc, char *const *argv);

/// Runs a CEF subprocess: enters CEF's sandbox (unless it is turned off), loads the framework and
/// returns the exit code of `cef_execute_process`. The framework folder comes from the
/// helper's place in the engine bundle, else the `--framework-dir-path=` switch, else `OWE_CEF_FRAMEWORK_DIR`.
/// Renderer processes run the start script of each browser and relay its `__owePost` messages.
int owe_cef_run_subprocess(int argc, char **argv);

/// Creates the NSApplication subclass CEF requires. Call before anything touches `NSApp`.
void owe_cef_prepare_application(void);

/// Loads the framework from the engine bundle `engine_bundle` (`OWE Chromium.app`, CEF's macOS
/// app layout: framework and helpers in `Contents/Frameworks`) and starts CEF with its profile in
/// `cache_dir`, the `owe-wallpaper` scheme registered and its message loop pumped on the main run
/// loop. `no_sandbox` turns CEF's sandbox off in Debug builds and is ignored otherwise.
/// `remote_debugging_port` (1024…65535, else none) opens Chromium's DevTools on 127.0.0.1 at that
/// port, for the frontend CEF serves there and Chrome's chrome://inspect. Main thread
/// only. Returns 0 on success (also when CEF already runs), else writes a message into `error`
/// and returns nonzero. On success the caller runs `owe_cef_run` next, from the same callout.
int owe_cef_initialize(const char *engine_bundle, const char *cache_dir, int no_sandbox,
                       int remote_debugging_port, const owe_cef_callbacks *callbacks,
                       char *error, size_t error_size);

/// Runs the main run loop from inside the call that started CEF, until `owe_cef_stop`. Call right
/// after the first successful `owe_cef_initialize` (or `owe_cef_start`), from the same main-thread
/// callout; later work reaches the main thread as run-loop blocks, not main-queue blocks.
void owe_cef_run(void);

/// Opens a windowless browser numbered `browser_id` of `width`×`height` points at `scale` pixels
/// per point. `start_script` runs in each new main-frame document before the page's scripts.
int owe_cef_create_browser(int browser_id, const char *url, int width, int height, double scale, int frame_rate,
                           const char *start_script, char *error, size_t error_size);
void owe_cef_close_browser(int browser_id);
void owe_cef_resize_browser(int browser_id, int width, int height, double scale);
void owe_cef_set_hidden(int browser_id, int hidden);
void owe_cef_set_frame_rate(int browser_id, int frame_rate);
void owe_cef_set_audio_muted(int browser_id, int muted);
void owe_cef_execute_javascript(int browser_id, const char *script);

/// `kind`: 0 move, 1 down, 2 up, 3 wheel, 4 leave. `button`: 0 left, 1 middle, 2 right. Points
/// from the view's top-left corner.
void owe_cef_send_mouse(int browser_id, int kind, double x, double y, int button, int click_count,
                        double delta_x, double delta_y, uint32_t modifiers);

/// Answers `request`: `headers` is "Name: value" lines joined by '\n'. The body is either `data`
/// (copied) or `length` bytes of `fd` from `offset` (the descriptor is taken over and closed).
/// Pass fd -1 for a data body.
void owe_cef_resource_respond(owe_cef_resource_request *request, int status, const char *headers,
                              const void *data, size_t data_length, int fd, uint64_t offset, uint64_t length);

/// Phase 1: initializes CEF from `engine_bundle` and opens one browser (number 0) of
/// `width`×`height` pixels whose frames go to `callback`. Main thread only, once per process.
int owe_cef_start(const char *engine_bundle, const char *cache_dir, const char *url, int width, int height,
                  int frame_rate, int no_sandbox, owe_cef_frame_callback callback, void *context, char *error, size_t error_size);

/// Closes every browser and ends `owe_cef_run`. The process is expected to exit next.
void owe_cef_stop(void);

#ifdef __cplusplus
}
#endif

#endif
