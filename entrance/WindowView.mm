/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Path X (native macOS) WindowView. See WindowView.h for the porting overview.
//
// Rendering pipeline note:
//   On iOS, +layerClass returned CAEAGLLayer and the GL renderbuffer was bound
//   straight to the layer's drawable. macOS desktop GL has no such API; the
//   render_context (foundation/appframework/graphic_2d/macos/render_context.mm)
//   renders into an offscreen FBO (framebuffer_ + colorbuffer_) via an
//   NSOpenGLContext. This WindowView's backing layer therefore must *present*
//   that offscreen FBO. We use a CAOpenGLLayer subclass (WindowGLLayer) whose
//   -drawInCGLContext: blits the render_context FBO color attachment into the
//   layer's drawable each vsync. CreateSurfaceNode(self.layer) hands the layer
//   to Window/render_context exactly as iOS handed it the CAEAGLLayer.

#include "WindowView.h"

#include <atomic>
#include <map>
#include <memory>
#include <vector>

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>

// Phase 0 path X (M1 格-c1): share the layer's CGL context with render_context's
// resource context (share group root) so the offscreen FBO it renders can be
// blitted to the layer drawable.
#include "render_context/new_render_context/render_context_gl.h"
#import <QuartzCore/QuartzCore.h>

#include "hilog.h"
#include "base/utils/time_util.h"
#include "virtual_rs_window.h"
#include "adapter/macos/entrance/mac_accessibility_bridge.h"
#include "ace_pointer_data_packet.h"
#include "core/event/key_event.h"
#include "configuration.h"
#include "adapter/macos/entrance/mac_text_input.h"

namespace {
// Match the iOS UITouchPhase ordering so synthetic-touch callers stay source
// compatible across platforms.
constexpr NSInteger TOUCH_PHASE_BEGAN = 0;
constexpr NSInteger TOUCH_PHASE_MOVED = 1;
constexpr NSInteger TOUCH_PHASE_STATIONARY = 2;
constexpr NSInteger TOUCH_PHASE_ENDED = 3;
constexpr NSInteger TOUCH_PHASE_CANCELLED = 4;

// NSString is UTF-16 internally; unichar == char16_t, so this is a direct copy.
std::u16string NSStringToU16(NSString* s)
{
    if (s == nil || s.length == 0) {
        return std::u16string();
    }
    std::u16string out(static_cast<size_t>(s.length), u'\0');
    [s getCharacters:reinterpret_cast<unichar*>(out.data()) range:NSMakeRange(0, s.length)];
    return out;
}
} // namespace

#pragma mark - WindowGLLayer (FBO -> CALayer presentation)

// CAOpenGLLayer subclass that presents the render_context's offscreen FBO.
// It owns nothing GL-side beyond the blit; the offscreen FBO id is published to
// it by render_context (Phase 2 wiring). For the rendering milestone this draws
// the cleared / blitted output; the precise FBO id handshake is a small TODO
// noted inline below.
@interface WindowGLLayer : CAOpenGLLayer
// FBO whose GL_COLOR_ATTACHMENT0 should be blitted to the layer drawable.
// Set by the render_context once it has created the offscreen framebuffer.
@property (nonatomic, assign) GLuint sourceFramebuffer;
// The owning RenderContextGL instance's color renderbuffer, pushed here by
// RSSurfaceGPU::FlushFrame after each render. Per-layer (not the global
// "last MakeCurrent wins" RenderContextGL::GetCurrentColorbuffer), so a second
// window (sub-window) blits ITS own content instead of the main window's.
// Settable via KVC by the graphic_2d layer (key "sourceColorbuffer").
@property (nonatomic, assign) GLuint sourceColorbuffer;
// Transparent background: a sub-window layer clears to alpha 0 so only the
// popup/menu content shows; the main window stays opaque white.
@property (nonatomic, assign) BOOL transparentBackground;
@end

@implementation WindowGLLayer
{
    // Phase 0 path X (M1 格-c1): a self-contained test FBO created in the shared
    // context, filled with a pattern, to prove the cross-context FBO -> blit ->
    // screen path independent of the (not-yet-running) RS pipeline.
    GLuint _testFbo;
    GLuint _testTex;
    GLint _testW;
    GLint _testH;
    // M1 格-c2: a local FBO (this context's namespace) used to wrap render_context's shared
    // color renderbuffer for the blit, since the FBO id itself is not shareable across contexts.
    GLuint _blitFbo;
}

- (instancetype)init
{
    if (self = [super init]) {
        self.asynchronous = NO;
        self.needsDisplayOnBoundsChange = YES;
        self.opaque = NO;
        _sourceFramebuffer = 0;
        _testFbo = 0;
        _testTex = 0;
        _testW = 0;
        _testH = 0;
    }
    return self;
}

// M1 格-c2: the layer's CGL context must use the SAME GL profile (Core 3.2) as
// render_context's NSOpenGLContext, otherwise CGLCreateContext(.., shareCgl, ..) fails with
// a pixel-format mismatch (err 10009) and falls back to an UNSHARED context -> render_context's
// colorbuffer is invisible here and the window stays blank. Force a Core 3.2 pixel format.
- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask
{
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
        kCGLPFADoubleBuffer,
        kCGLPFAAccelerated,
        (CGLPixelFormatAttribute)0,
    };
    CGLPixelFormatObj pf = nullptr;
    GLint npix = 0;
    CGLChoosePixelFormat(attrs, &pf, &npix);
    if (pf != nullptr) {
        return pf;
    }
    return [super copyCGLPixelFormatForDisplayMask:mask];
}

// Phase 0 path X (M1 格-c1): make the layer's CGL context part of render_context's
// share group, so an FBO rendered in render_context's NSOpenGLContext (which also
// shares with the resource context) is readable here for the blit.
- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pixelFormat
{
    CGLContextObj shareCgl = nullptr;
    void* resCtx = OHOS::Rosen::RenderContextGL::GetResourceContext();
    if (resCtx != nullptr) {
        NSOpenGLContext* nsShare = static_cast<NSOpenGLContext*>(resCtx);
        shareCgl = [nsShare CGLContextObj];
    }
    CGLContextObj ctx = nullptr;
    CGLError cerr = (shareCgl != nullptr) ? CGLCreateContext(pixelFormat, shareCgl, &ctx) : kCGLBadContext;
    if (shareCgl != nullptr && cerr == kCGLNoError) {
        return ctx;
    }
    // Fall back to the default (unshared) context if the share group is not ready.
    return [super copyCGLContextForPixelFormat:pixelFormat];
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)glContext
                pixelFormat:(CGLPixelFormatObj)pixelFormat
               forLayerTime:(CFTimeInterval)timeInterval
                displayTime:(const CVTimeStamp*)timeStamp
{
    return YES;
}

// Phase 0 path X (M1 格-c1): lazily build/refresh a test FBO with a recognizable
// pattern (cyan field + magenta diagonal band) in the current (shared) context.
// Returns the FBO id, or 0 on failure.
- (GLuint)ensureTestFramebufferWidth:(GLint)w height:(GLint)h
{
    if (w <= 0 || h <= 0) {
        return 0;
    }
    if (_testFbo == 0) {
        glGenFramebuffers(1, &_testFbo);
        glGenTextures(1, &_testTex);
    }
    if (w != _testW || h != _testH) {
        glBindTexture(GL_TEXTURE_2D, _testTex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glBindFramebuffer(GL_FRAMEBUFFER, _testFbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _testTex, 0);
        _testW = w;
        _testH = h;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, _testFbo);
    glViewport(0, 0, w, h);
    // Background: cyan.
    glClearColor(0.0f, 0.8f, 0.9f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    // A magenta diagonal band via scissor stripes (no shaders needed).
    glEnable(GL_SCISSOR_TEST);
    glClearColor(1.0f, 0.0f, 1.0f, 1.0f);
    const GLint band = h / 8 > 1 ? h / 8 : 1;
    for (GLint y = 0; y < h; y += band * 2) {
        glScissor(0, y, w, band);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    glDisable(GL_SCISSOR_TEST);
    return _testFbo;
}

- (void)drawInCGLContext:(CGLContextObj)glContext
             pixelFormat:(CGLPixelFormatObj)pixelFormat
            forLayerTime:(CFTimeInterval)timeInterval
             displayTime:(const CVTimeStamp*)timeStamp
{
    CGLSetCurrentContext(glContext);

    const CGSize size = self.bounds.size;
    const CGFloat scale = self.contentsScale > 0 ? self.contentsScale : 1.0;
    const GLint dstW = static_cast<GLint>(size.width * scale);
    const GLint dstH = static_cast<GLint>(size.height * scale);

    // The CAOpenGLLayer-provided context has the layer drawable bound as the
    // default framebuffer. Capture that binding FIRST, before any FBO work below
    // rebinds it (e.g. building the test FBO), so we blit into the real drawable.
    GLint drawFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFbo);

    // M1 格-c2: RS renders the page into render_context's offscreen FBO (framebuffer_ +
    // colorbuffer_). The FBO id is NOT shareable across GL contexts, but the renderbuffer color
    // attachment IS (same share group). So we wrap render_context's shared colorbuffer in OUR
    // OWN FBO (_blitFbo, valid in this context) and blit from that. (Using framebuffer_ directly
    // read as an empty/white surface, which was the cause of the blank window.)
    // Prefer THIS layer's own colorbuffer (pushed per-render by RSSurfaceGPU) over
    // the global last-MakeCurrent-wins one, so the main window and a sub-window each
    // blit their own content instead of colliding on the shared global.
    GLuint colorRb = self.sourceColorbuffer;
    if (colorRb == 0) {
        colorRb = OHOS::Rosen::RenderContextGL::GetCurrentColorbuffer();
    }

    if (colorRb != 0 && dstW > 0 && dstH > 0) {
        if (_blitFbo == 0) {
            glGenFramebuffers(1, &_blitFbo);
        }
        glBindFramebuffer(GL_READ_FRAMEBUFFER, _blitFbo);
        glFramebufferRenderbuffer(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorRb);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, static_cast<GLuint>(drawFbo));
        // RS already renders the page right-side up into the offscreen color buffer, and
        // CAOpenGLLayer's drawable shares the same top-left origin, so blit straight through
        // (no Y flip) — flipping here turned the whole page upside down.
        glBlitFramebuffer(0, 0, dstW, dstH, 0, 0, dstW, dstH,
                          GL_COLOR_BUFFER_BIT, GL_NEAREST);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(drawFbo));
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, static_cast<GLuint>(drawFbo));
    } else {
        glBindFramebuffer(GL_FRAMEBUFFER, static_cast<GLuint>(drawFbo));
        // Sub-window: clear transparent so only the popup/menu content is visible
        // over the main window; main window stays opaque white.
        if (self.transparentBackground) {
            glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
        } else {
            glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
        }
        glClear(GL_COLOR_BUFFER_BIT);
    }

    // CAOpenGLLayer flushes the drawable for us after this returns.
    [super drawInCGLContext:glContext
                pixelFormat:pixelFormat
               forLayerTime:timeInterval
                displayTime:timeStamp];
}

@end

#pragma mark - WindowView

// M2 IME: conform to NSTextInputClient so the macOS input method (incl. CJK
// composition) can drive the focused ArkUI TextInput via MacTextInputBridge.
@interface WindowView () <NSTextInputClient>
@end

@implementation WindowView
{
    std::weak_ptr<OHOS::Rosen::Window> _windowDelegate;
    int32_t _width;
    int32_t _height;
    float _density;
    BOOL _needNotifySurfaceChangedWithWidth;
    BOOL _needCreateSurfaceNode;
    BOOL _needNotifyForground;
    BOOL _needNotifyFocus;
    int32_t _deviceId;
    // M2 scroll: synthetic finger-pan session driven by scrollWheel: (trackpad / mouse wheel).
    BOOL _scrollTouchActive;
    CGFloat _scrollTouchX;
    CGFloat _scrollTouchY;
    int32_t _pointerId;
    // M2 IME: in-progress composition (marked text) shown by the input method
    // before the user commits. Committed text arrives via insertText:.
    NSMutableString* _markedText;
    std::vector<CGRect> hotAreas_;
    float _oldBrightness;

    // CVDisplayLink replaces iOS CADisplayLink. It fires on a private, high
    // priority thread, so every callback marshals to the main queue before
    // touching RS / UIContent / the window delegate.
    CVDisplayLinkRef _displayLink;

    // Set for sub-window views (Dialog/Menu/Popup) so their backing WindowGLLayer
    // clears to transparent instead of opaque white — only the popup content shows.
    BOOL _transparentSubWindow;

    // Set for an app-created (@ohos.window) sub-window that the user can drag to
    // move. Popup/Menu/Dialog sub-windows leave this NO so their drags still reach
    // the engine (and they dismiss on outside click instead of moving).
    BOOL _movableSubWindow;
}

#pragma mark - Backing layer (replaces +layerClass / CAEAGLLayer)

- (BOOL)wantsLayer
{
    return YES;
}

- (BOOL)wantsUpdateLayer
{
    return YES;
}

// macOS hosts a custom backing layer instead of overriding +layerClass.
- (CALayer*)makeBackingLayer
{
    WindowGLLayer* layer = [[WindowGLLayer alloc] init];
    CGFloat scale = [self currentBackingScale];
    layer.contentsScale = scale;
    layer.transparentBackground = _transparentSubWindow;
    return layer;
}

// Called by virtual_rs_window's CreateSubWindow so this view renders a transparent
// background (sub-window host); the backing layer may not exist yet, so remember
// the flag and also apply it if the layer is already up.
- (void)markAsTransparentSubWindow
{
    _transparentSubWindow = YES;
    if ([self.layer isKindOfClass:[WindowGLLayer class]]) {
        ((WindowGLLayer*)self.layer).transparentBackground = YES;
    }
}

- (void)setMovableSubWindow:(BOOL)movable
{
    _movableSubWindow = movable;
}

// ArkUI expects a top-left origin coordinate system; AppKit defaults to
// bottom-left, so flip.
- (BOOL)isFlipped
{
    return YES;
}

- (CGFloat)currentBackingScale
{
    CGFloat scale = self.window.backingScaleFactor;
    if (scale <= 0.0) {
        scale = [NSScreen mainScreen].backingScaleFactor;
    }
    if (scale <= 0.0) {
        scale = 1.0;
    }
    return scale;
}

#pragma mark - Lifecycle

- (instancetype)init
{
    if (self = [super initWithFrame:NSZeroRect]) {
        LOGI("windowView init");
        _width = 0;
        _height = 0;
        _needNotifySurfaceChangedWithWidth = NO;
        _needCreateSurfaceNode = NO;
        _focusable = YES;
        _isFocused = NO;
        self.wantsLayer = YES;
        // macOS: layer-backed view does not honor backgroundColor like UIView;
        // clear is the layer default. (no-op for parity with iOS clearColor)
        _deviceId = 0;
        _pointerId = 0;
        _oldBrightness = -1;
        _brightness = 1.0f; // macOS: no per-screen brightness API; placeholder.
        _displayLink = NULL;
        [self setupNotificationCenterObservers];
    }
    return self;
}

- (void)dealloc
{
    LOGI("WindowView dealloc");
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
    [super dealloc];
}

// AppKit calls this when geometry changes; this is the analogue of iOS
// -layoutSubviews. We recompute the pixel-size surface and notify RS.
- (void)layout
{
    [super layout];
    CGFloat scale = [self currentBackingScale];
    HILOG_INFO("layout : bounds.width/height=%{public}u/%{public}u",
        static_cast<int32_t>(self.bounds.size.width),
        static_cast<int32_t>(self.bounds.size.height));
    int32_t width = static_cast<int32_t>(self.bounds.size.width * scale);
    int32_t height = static_cast<int32_t>(self.bounds.size.height * scale);
    if (self.layer != nil) {
        self.layer.contentsScale = scale;
    }
    [self notifySurfaceChangedWithWidth:width height:height density:scale];
}

// Track backing-scale changes (e.g. moving between Retina and non-Retina
// displays). iOS handled this implicitly via UIScreen.scale.
- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    CGFloat scale = [self currentBackingScale];
    if (self.layer != nil) {
        self.layer.contentsScale = scale;
    }
    [self setNeedsLayout:YES];
}

// M3 dark mode: AppKit calls this on the initial appearance and whenever the system toggles
// light/dark. Map NSAppearance -> ArkUI's "ohos.system.colorMode" config so theme colors and
// resources (systemres base vs dark) switch, then ArkUI re-applies the theme and repaints.
- (void)viewDidChangeEffectiveAppearance
{
    [super viewDidChangeEffectiveAppearance];
    auto window = _windowDelegate.lock();
    if (window == nullptr) {
        return;
    }
    NSAppearanceName matched = [self.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    const bool isDark = [matched isEqualToString:NSAppearanceNameDarkAqua];
    auto config = std::make_shared<OHOS::AbilityRuntime::Platform::Configuration>();
    config->AddItem(OHOS::AbilityRuntime::Platform::ConfigurationInner::SYSTEM_COLORMODE,
        isDark ? OHOS::AbilityRuntime::Platform::ConfigurationInner::COLOR_MODE_DARK
               : OHOS::AbilityRuntime::Platform::ConfigurationInner::COLOR_MODE_LIGHT);
    window->UpdateConfiguration(config);
}

- (void)setFullScreen:(BOOL)fullScreen
{
    _fullScreen = fullScreen;
    if (fullScreen) {
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    } else {
        self.autoresizingMask = NSViewNotSizable;
    }
}

#pragma mark - Window show/hide/focus

- (BOOL)requestFocus
{
    if (self.focusable) {
        // macOS: AppKit first responder model. Make this view first responder
        // in its window so it receives key events.
        if (self.window != nil) {
            [self.window makeFirstResponder:self];
        }
        return YES;
    }
    return NO;
}

- (void)setTouchHotAreas:(CGRect[])rect size:(NSInteger)size
{
    hotAreas_.clear();
    for (int i = 0; i < size; ++i) {
        hotAreas_.push_back(*(rect + i));
    }
}

- (BOOL)showOnView:(NSView*)rootView
{
    if (rootView != nil) {
        if (self.fullScreen) {
            self.frame = rootView.bounds;
        }
        [rootView addSubview:self];
        return YES;
    }
    return NO;
}

- (BOOL)hide
{
    if (self.superview != nil) {
        [self removeFromSuperview];
        return YES;
    }
    return NO;
}

- (BOOL)acceptsFirstResponder
{
    return self.focusable;
}

- (void)setIsFocused:(BOOL)isFocused
{
    if (self.focusable && _isFocused != isFocused) {
        _isFocused = isFocused;
        [self notifyFocusChanged:isFocused];
    }
}

#pragma mark - Window delegate bridge (called from virtual_rs_window.mm)

- (void)setWindowDelegate:(std::shared_ptr<OHOS::Rosen::Window>)window
{
    _windowDelegate = window;
    if (_needCreateSurfaceNode) {
        _needCreateSurfaceNode = NO;
        [self createSurfaceNode];
    }
    if (_needNotifySurfaceChangedWithWidth) {
        _needNotifySurfaceChangedWithWidth = NO;
        [self notifySurfaceChangedWithWidth:_width height:_height density:_density];
    }
    if (_needNotifyForground) {
        _needNotifyForground = NO;
        [self notifyForeground];
    }
    if (_needNotifyFocus) {
        _needNotifyFocus = NO;
        [self notifyFocusChanged:_isFocused];
    }
}

- (std::shared_ptr<OHOS::Rosen::Window>)getWindow
{
    return _windowDelegate.lock();
}

- (void)createSurfaceNode
{
    if (_windowDelegate.lock() != nullptr) {
        // Hands the backing CALayer (WindowGLLayer) to Window/render_context,
        // exactly as iOS handed it the CAEAGLLayer.
        _windowDelegate.lock()->CreateSurfaceNode(self.layer);
    } else {
        _needCreateSurfaceNode = YES;
    }
}

- (void)notifySurfaceChangedWithWidth:(int32_t)width height:(int32_t)height density:(float)density
{
    _width = width;
    _height = height;
    _density = density;
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->NotifySurfaceChanged(width, height, density);
    } else {
        _needNotifySurfaceChangedWithWidth = YES;
    }
}

- (void)notifySurfaceDestroyed
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->NotifySurfaceDestroyed();
    }
}

- (void)notifyWindowDestroyed
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->Destroy();
    }
    if (_displayLink) {
        LOGI("WindowView notifyWindowDestroyed in");
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
}

- (void)notifySafeAreaChanged
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->NotifySafeAreaChanged();
    }
}

- (void)notifyForeground
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->Foreground();
    } else {
        _needNotifyForground = YES;
    }
}

- (void)notifyBackground
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->Background();
    }
}

- (void)notifyActiveChanged:(BOOL)isActive
{
    [self updateBrightness:isActive];
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->WindowActiveChanged(isActive);
    }
}

- (void)notifyFocusChanged:(BOOL)focus
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->WindowFocusChanged(focus);
    } else {
        _needNotifyFocus = YES;
    }
}

- (void)notifyApplicationForeground:(BOOL)isForeground
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->NotifyApplicationForeground(isForeground);
    }
}

- (void)notifyTraitCollectionDidChange:(BOOL)isSplitScreen
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->NotifyTraitCollectionDidChange(isSplitScreen);
    }
}

- (void)notifyHandleWillTerminate
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->NotifyWillTeminate();
    }
}

- (BOOL)processBackPressed
{
    if (_windowDelegate.lock() != nullptr) {
        return _windowDelegate.lock()->ProcessBackPressed();
    }
    return false;
}

- (void)touchOutside
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->NotifyTouchOutside();
    }
}

#pragma mark - Brightness (macOS: no per-screen brightness API)

- (void)setBrightness:(float)brightness
{
    _oldBrightness = _brightness;
    _brightness = brightness;
}

- (float)getBrightness
{
    return _brightness;
}

- (void)updateBrightness:(BOOL)isShow
{
    // macOS: no public per-screen brightness control. Store-only no-op.
}

#pragma mark - Keyboard (soft keyboard) notifications (macOS: no-op)

- (void)setupNotificationCenterObservers
{
    // macOS has no UIKeyboardWillChangeFrame / WillHide notifications (no system
    // soft keyboard). Left intentionally empty; keyboardWillChangeFrame: and
    // keyboardWillBeHidden: remain callable for source parity.
    // macOS: no-op
}

- (void)keyboardWillChangeFrame:(NSNotification*)notification
{
    // macOS: no system soft keyboard; report zero inset.
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->NotifyKeyboardHeightChanged(0);
    }
}

- (void)keyboardWillBeHidden:(NSNotification*)notification
{
    if (_windowDelegate.lock() != nullptr) {
        _windowDelegate.lock()->NotifyKeyboardHeightChanged(0);
    }
}

#pragma mark - View controller lookup

- (NSViewController*)getViewController
{
    NSResponder* responder = self;
    while ((responder = [responder nextResponder])) {
        if ([responder isKindOfClass:[NSViewController class]]) {
            return (NSViewController*)responder;
        }
    }
    return nil;
}

#pragma mark - Mouse events (replaces touchesBegan/Moved/Ended/Cancelled)

// M2 event dispatch. Mirror the iOS dispatchTouches path: build an
// AcePointerDataPacket from the NSEvent location and call window->ProcessPointerEvent(...).
// macOS reports a single mouse pointer (pointer/device id 0). NSView's default
// coordinate system is top-left origin because WindowView overrides isFlipped (YES).
- (void)dispatchMouseEvent:(NSEvent*)event
                    action:(OHOS::Ace::Platform::AcePointerData::PointerAction)action
{
    auto window = _windowDelegate.lock();
    if (window == nullptr) {
        return;
    }
    const CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 1.0;
    const NSPoint inView = [self convertPoint:event.locationInWindow fromView:nil];
    const CGFloat xPx = inView.x * scale;
    // WindowView overrides isFlipped (YES), so convertPoint already yields a top-left-origin
    // point. Use inView.y directly -- subtracting from height here double-flipped it (taps landed
    // mirrored vertically and drag-scroll went the wrong way).
    const CGFloat yPx = inView.y * scale;

    OHOS::Ace::Platform::AcePointerData pd;
    pd.Clear();
    pd.pointer_id = 0;
    pd.device_id = 0;
    pd.time_stamp = OHOS::Ace::GetMicroTickCount();
    pd.finger_count = 1;
    pd.pointer_action = action;
    // Report as a finger touch: macOS emulates a single touch pointer, and ArkUI's scrollable
    // containers (List/Scroll) recognize pan-to-scroll from Touch, not Mouse, drags.
    pd.tool_type = OHOS::Ace::Platform::AcePointerData::ToolType::Touch;
    pd.display_x = xPx;
    pd.display_y = yPx;
    pd.window_x = xPx;
    pd.window_y = yPx;
    pd.pressure = (action == OHOS::Ace::Platform::AcePointerData::PointerAction::kUped) ? 0.0 : 1.0;
    pd.actionPoint = true;

    OHOS::Ace::Platform::AcePointerDataPacket packet(1);
    packet.SetPointerData(0, pd);
    window->ProcessPointerEvent(packet.data());
}

- (void)mouseDown:(NSEvent*)event
{
    // Movable sub-window (app-created via @ohos.window): let AppKit drag the whole
    // window instead of dispatching a touch into ArkUI. performWindowDragWithEvent:
    // handles the move, screen-edge clamping and mouse-up for us. Popups (flag NO)
    // fall through to the normal engine touch path.
    if (_movableSubWindow && self.window != nil) {
        [self.window performWindowDragWithEvent:event];
        return;
    }
    [self dispatchMouseEvent:event action:OHOS::Ace::Platform::AcePointerData::PointerAction::kDowned];
}

- (void)mouseDragged:(NSEvent*)event
{
    [self dispatchMouseEvent:event action:OHOS::Ace::Platform::AcePointerData::PointerAction::kMoved];
}

- (void)mouseUp:(NSEvent*)event
{
    [self dispatchMouseEvent:event action:OHOS::Ace::Platform::AcePointerData::PointerAction::kUped];
}

- (void)rightMouseDown:(NSEvent*)event
{
    // Secondary button: routed as a primary pointer for now (context menu handling is M6/M3 work).
    [self dispatchMouseEvent:event action:OHOS::Ace::Platform::AcePointerData::PointerAction::kDowned];
}

- (void)rightMouseDragged:(NSEvent*)event
{
    [self dispatchMouseEvent:event action:OHOS::Ace::Platform::AcePointerData::PointerAction::kMoved];
}

- (void)rightMouseUp:(NSEvent*)event
{
    [self dispatchMouseEvent:event action:OHOS::Ace::Platform::AcePointerData::PointerAction::kUped];
}

#pragma mark - Scroll wheel (trackpad / mouse wheel -> synthetic finger pan)

// Dispatch one synthetic Touch pointer at explicit physical-pixel coordinates.
- (void)dispatchTouchAtPixelX:(CGFloat)xPx pixelY:(CGFloat)yPx
                       action:(OHOS::Ace::Platform::AcePointerData::PointerAction)action
{
    auto window = _windowDelegate.lock();
    if (window == nullptr) {
        return;
    }
    OHOS::Ace::Platform::AcePointerData pd;
    pd.Clear();
    pd.pointer_id = 0;
    pd.device_id = 0;
    pd.time_stamp = OHOS::Ace::GetMicroTickCount();
    pd.finger_count = 1;
    pd.pointer_action = action;
    pd.tool_type = OHOS::Ace::Platform::AcePointerData::ToolType::Touch;
    pd.display_x = xPx;
    pd.display_y = yPx;
    pd.window_x = xPx;
    pd.window_y = yPx;
    pd.pressure = (action == OHOS::Ace::Platform::AcePointerData::PointerAction::kUped) ? 0.0 : 1.0;
    pd.actionPoint = true;
    OHOS::Ace::Platform::AcePointerDataPacket packet(1);
    packet.SetPointerData(0, pd);
    window->ProcessPointerEvent(packet.data());
}

// ArkUI scrollables recognize pan-to-scroll from a Touch drag, not a scroll axis (the axis path
// is unwired on mac). Translate scrollWheel: into a continuous synthetic finger pan: press on the
// gesture's first event, drag by the accumulated scroll delta, release when it ends (incl. momentum).
- (void)scrollWheel:(NSEvent*)event
{
    using PointerAction = OHOS::Ace::Platform::AcePointerData::PointerAction;
    const CGFloat scale = self.window.backingScaleFactor > 0 ? self.window.backingScaleFactor : 1.0;
    const NSPoint inView = [self convertPoint:event.locationInWindow fromView:nil];
    const CGFloat xPx = inView.x * scale;
    const CGFloat yPx = inView.y * scale; // view isFlipped -> already top-left origin

    CGFloat deltaY = event.scrollingDeltaY;
    if (deltaY == 0.0 && event.deltaY != 0.0) {
        deltaY = event.deltaY * 10.0; // legacy line-based mouse wheel
    }
    // Finger pan that matches macOS scrolling: scrollingDeltaY already honours the user's "natural
    // scrolling" setting (it is the content delta). A Touch drag moves content with the finger, so
    // the finger delta equals the content delta -> map straight through.
    const CGFloat dyPx = deltaY * scale;

    const NSEventPhase phase = event.phase;
    const NSEventPhase momentum = event.momentumPhase;

    if (phase == NSEventPhaseNone && momentum == NSEventPhaseNone) {
        // Legacy mouse wheel: discrete one-shot micro-pan.
        if (deltaY == 0.0) {
            return;
        }
        [self dispatchTouchAtPixelX:xPx pixelY:yPx action:PointerAction::kDowned];
        [self dispatchTouchAtPixelX:xPx pixelY:yPx + dyPx action:PointerAction::kMoved];
        [self dispatchTouchAtPixelX:xPx pixelY:yPx + dyPx action:PointerAction::kUped];
        return;
    }

    if (phase == NSEventPhaseBegan) {
        _scrollTouchActive = YES;
        _scrollTouchX = xPx;
        _scrollTouchY = yPx;
        [self dispatchTouchAtPixelX:_scrollTouchX pixelY:_scrollTouchY action:PointerAction::kDowned];
        return;
    }
    if (_scrollTouchActive && (phase == NSEventPhaseChanged || momentum == NSEventPhaseChanged)) {
        _scrollTouchY += dyPx;
        [self dispatchTouchAtPixelX:_scrollTouchX pixelY:_scrollTouchY action:PointerAction::kMoved];
        return;
    }
    const BOOL phaseEndedNoMomentum = (phase == NSEventPhaseEnded || phase == NSEventPhaseCancelled) &&
                                      momentum == NSEventPhaseNone;
    if (_scrollTouchActive && (phaseEndedNoMomentum || momentum == NSEventPhaseEnded ||
                               momentum == NSEventPhaseCancelled)) {
        [self dispatchTouchAtPixelX:_scrollTouchX pixelY:_scrollTouchY action:PointerAction::kUped];
        _scrollTouchActive = NO;
    }
}

#pragma mark - Key events (replaces pressesBegan/Ended)

namespace {
// Window::ProcessKeyEvent feeds keyCode through KeyCodeToAceKeyCode(), which is keyed on
// USB-HID usage codes (the iOS path passes UIKeyboardHIDUsage). macOS NSEvent.keyCode is a
// kVK_* virtual keycode, a different namespace -- translate it to the HID usage code here.
int32_t MacVirtualKeyToHidUsage(unsigned short vk)
{
    switch (vk) {
        // Letters (kVK_ANSI_A..Z -> HID 4..29)
        case 0x00: return 4;  case 0x0B: return 5;  case 0x08: return 6;  case 0x02: return 7;
        case 0x0E: return 8;  case 0x03: return 9;  case 0x05: return 10; case 0x04: return 11;
        case 0x22: return 12; case 0x26: return 13; case 0x28: return 14; case 0x25: return 15;
        case 0x2E: return 16; case 0x2D: return 17; case 0x1F: return 18; case 0x23: return 19;
        case 0x0C: return 20; case 0x0F: return 21; case 0x01: return 22; case 0x11: return 23;
        case 0x20: return 24; case 0x09: return 25; case 0x0D: return 26; case 0x07: return 27;
        case 0x10: return 28; case 0x06: return 29;
        // Digits 1..0 (kVK_ANSI_1..0 -> HID 30..39)
        case 0x12: return 30; case 0x13: return 31; case 0x14: return 32; case 0x15: return 33;
        case 0x17: return 34; case 0x16: return 35; case 0x1A: return 36; case 0x1C: return 37;
        case 0x19: return 38; case 0x1D: return 39;
        // Control / punctuation
        case 0x24: return 40; // Return
        case 0x35: return 41; // Escape
        case 0x33: return 42; // Delete (backspace)
        case 0x30: return 43; // Tab
        case 0x31: return 44; // Space
        case 0x1B: return 45; // Minus
        case 0x18: return 46; // Equal
        case 0x21: return 47; // LeftBracket
        case 0x1E: return 48; // RightBracket
        case 0x2A: return 49; // Backslash
        case 0x29: return 51; // Semicolon
        case 0x27: return 52; // Quote
        case 0x32: return 53; // Grave
        case 0x2B: return 54; // Comma
        case 0x2F: return 55; // Period
        case 0x2C: return 56; // Slash
        // Navigation
        case 0x7B: return 80; // Left
        case 0x7C: return 79; // Right
        case 0x7D: return 81; // Down
        case 0x7E: return 82; // Up
        case 0x75: return 76; // ForwardDelete
        case 0x73: return 74; // Home
        case 0x77: return 77; // End
        case 0x74: return 75; // PageUp
        case 0x79: return 78; // PageDown
        default:   return 0;
    }
}

// Modifier bitmask expected by ProcessKeyEvent (matches the iOS GetModifierKeys: ctrl/shift/alt/meta).
int32_t MacModifierBits(NSEventModifierFlags flags)
{
    int32_t bits = 0;
    // Bits match CtrlKeysBit: CTRL=1, SHIFT=2, ALT=4, META=8. macOS Command maps to
    // META, which is what the platform editing shortcuts (KeyComb(KEY_V, KEY_META)
    // etc., guarded by MAC_PLATFORM in text_input_client) expect.
    if (flags & NSEventModifierFlagControl) { bits |= 1; }
    if (flags & NSEventModifierFlagShift)   { bits |= 2; }
    if (flags & NSEventModifierFlagOption)  { bits |= 4; }
    if (flags & NSEventModifierFlagCommand) { bits |= 8; }
    return bits;
}
} // namespace

- (void)dispatchKeyEvent:(NSEvent*)event action:(OHOS::Ace::KeyAction)action
{
    auto window = _windowDelegate.lock();
    if (window == nullptr) {
        return;
    }
    const int32_t hidUsage = MacVirtualKeyToHidUsage(event.keyCode);
    if (hidUsage == 0) {
        return;
    }
    const int64_t ts = OHOS::Ace::GetMicroTickCount();
    const int32_t repeatTime = (action == OHOS::Ace::KeyAction::DOWN && event.isARepeat) ? 1 : 0;
    window->ProcessKeyEvent(hidUsage, static_cast<int32_t>(action), repeatTime, ts, ts,
        MacModifierBits(event.modifierFlags));
}

- (void)keyDown:(NSEvent*)event
{
    // When a text field is focused, hand the key to the input method so it can
    // build composition / committed text (insertText:) and emit edit commands
    // (doCommandBySelector:). Otherwise dispatch the raw key for shortcuts/nav.
    // Command/Control shortcuts (Cmd+C/V/X/A/Z ...) must reach ArkUI's key handling
    // as raw key events, not the input method -- otherwise interpretKeyEvents would
    // turn e.g. Cmd+V into the literal text "v". Route any Command/Control-modified
    // key down the raw path.
    const BOOL hasShortcutModifier =
        (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
    if (!hasShortcutModifier && OHOS::Ace::Platform::MacTextInputBridge::GetInstance().IsActive()) {
        // Still forward non-text keys (arrows, enter, etc.) to ArkUI for caret
        // movement / submit, but let the IME consume printable + composing input.
        [self interpretKeyEvents:@[ event ]];
        return;
    }
    [self dispatchKeyEvent:event action:OHOS::Ace::KeyAction::DOWN];
}

- (void)keyUp:(NSEvent*)event
{
    [self dispatchKeyEvent:event action:OHOS::Ace::KeyAction::UP];
}

#pragma mark - NSTextInputClient (M2 IME)

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    NSString* text = [string isKindOfClass:[NSAttributedString class]] ? [string string] : string;
    // Committing text ends any active composition.
    [_markedText setString:@""];
    OHOS::Ace::Platform::MacTextInputBridge::GetInstance().CommitText(NSStringToU16(text));
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange
{
    NSString* text = [string isKindOfClass:[NSAttributedString class]] ? [string string] : string;
    if (_markedText == nil) {
        _markedText = [[NSMutableString alloc] init];
    }
    [_markedText setString:(text ?: @"")];
    // Composition is shown by the IME's own candidate window; the in-progress
    // string is not pushed to the field until committed via insertText:.
}

- (void)unmarkText
{
    [_markedText setString:@""];
    OHOS::Ace::Platform::MacTextInputBridge::GetInstance().PerformAction();
}

- (NSRange)selectedRange
{
    auto& bridge = OHOS::Ace::Platform::MacTextInputBridge::GetInstance();
    NSInteger start = bridge.GetSelStart();
    NSInteger len = bridge.GetSelEnd() - bridge.GetSelStart();
    if (start < 0) {
        return NSMakeRange(NSNotFound, 0);
    }
    return NSMakeRange(static_cast<NSUInteger>(start), static_cast<NSUInteger>(len < 0 ? 0 : len));
}

- (NSRange)markedRange
{
    if (_markedText.length > 0) {
        return NSMakeRange(0, _markedText.length);
    }
    return NSMakeRange(NSNotFound, 0);
}

- (BOOL)hasMarkedText
{
    return _markedText.length > 0;
}

- (nullable NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range
                                                        actualRange:(nullable NSRangePointer)actualRange
{
    return nil;
}

- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText
{
    return @[];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(nullable NSRangePointer)actualRange
{
    // Anchor the IME candidate window at the caret. ArkUI pushes the caret rect in
    // window pixels (top-left origin) via MacTextInputBridge; convert to view points
    // (the view is flipped, so it shares ArkUI's top-left origin), then to screen.
    double cx = 0, cy = 0, cw = 0, ch = 0;
    if (OHOS::Ace::Platform::MacTextInputBridge::GetInstance().GetCaretWindowRect(cx, cy, cw, ch)) {
        CGFloat scale = [self currentBackingScale];
        if (scale <= 0.0) {
            scale = 1.0;
        }
        // Candidate window sits just below the caret; give it the caret's height.
        NSRect viewRect = NSMakeRect(cx / scale, cy / scale, (cw > 0 ? cw : 1) / scale, (ch > 0 ? ch : 16) / scale);
        NSRect winRect = [self convertRect:viewRect toView:nil];
        return [self.window convertRectToScreen:winRect];
    }
    // Fallback: view origin, so composition is still usable before the first push.
    NSRect viewRect = NSMakeRect(0, 0, 1, 16);
    NSRect winRect = [self convertRect:viewRect toView:nil];
    return [self.window convertRectToScreen:winRect];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
    return NSNotFound;
}

- (void)doCommandBySelector:(SEL)selector
{
    auto& bridge = OHOS::Ace::Platform::MacTextInputBridge::GetInstance();
    if (selector == @selector(deleteBackward:)) {
        bridge.DeleteBackward(1);
        return;
    }
    if (selector == @selector(insertNewline:)) {
        bridge.PerformAction();
        return;
    }
    // Caret navigation: ArkUI's key handling moves the visible caret, but the
    // shadow caret in MacTextInputBridge must move in lockstep so the next inserted
    // character lands at the right offset. Mirror the same logical move here, then
    // forward the raw key so the field actually repositions its caret.
    const int32_t caret = bridge.GetSelStart();
    const int32_t len = static_cast<int32_t>(bridge.GetMirror().length());
    if (selector == @selector(moveLeft:) || selector == @selector(moveLeftAndModifySelection:) ||
        selector == @selector(moveBackward:)) {
        bridge.SetCaret(caret - 1);
    } else if (selector == @selector(moveRight:) || selector == @selector(moveRightAndModifySelection:) ||
        selector == @selector(moveForward:)) {
        bridge.SetCaret(caret + 1);
    } else if (selector == @selector(moveToBeginningOfLine:) || selector == @selector(moveToLeftEndOfLine:) ||
        selector == @selector(moveToBeginningOfDocument:)) {
        bridge.SetCaret(0);
    } else if (selector == @selector(moveToEndOfLine:) || selector == @selector(moveToRightEndOfLine:) ||
        selector == @selector(moveToEndOfDocument:)) {
        bridge.SetCaret(len);
    }
    NSEvent* current = [NSApp currentEvent];
    if (current != nil && current.type == NSEventTypeKeyDown) {
        [self dispatchKeyEvent:current action:OHOS::Ace::KeyAction::DOWN];
    }
}

#pragma mark - Synthetic touch injection

- (BOOL)dispatchSyntheticTouchWithPhase:(NSInteger)phase
                                 pixelX:(CGFloat)pixelX
                                 pixelY:(CGFloat)pixelY
                              pointerId:(int32_t)pointerId
                              timeStamp:(int64_t)timeStamp
{
    // TODO M2: event dispatch. Build an AcePointerData from pixelX/pixelY (already
    // in physical pixels), map `phase` (TOUCH_PHASE_*) to AcePointerData::
    // PointerAction, and call window->ProcessSyntheticPointerEvent(...). Wiring
    // mirrors the iOS dispatchSyntheticTouchWithPhase:.
    (void)phase;
    (void)pixelX;
    (void)pixelY;
    (void)pointerId;
    (void)timeStamp;
    return NO;
}

#pragma mark - Display link (CADisplayLink -> CVDisplayLink)

// CVDisplayLink output callback. Fires on a private thread; we marshal to the
// main queue before touching the GL layer / RS so all RS / UIContent work stays
// on the main thread, matching iOS CADisplayLink semantics.
static CVReturn WindowViewDisplayLinkCallback(CVDisplayLinkRef displayLink,
                                              const CVTimeStamp* now,
                                              const CVTimeStamp* outputTime,
                                              CVOptionFlags flagsIn,
                                              CVOptionFlags* flagsOut,
                                              void* context)
{
    WindowView* view = (__bridge WindowView*)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view onDisplayLinkTick];
    });
    return kCVReturnSuccess;
}

- (void)startBaseDisplayLink
{
    if (_displayLink != NULL) {
        return;
    }
    CVReturn ret = CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
    if (ret != kCVReturnSuccess || _displayLink == NULL) {
        LOGI("startBaseDisplayLink: CVDisplayLink create failed");
        return;
    }
    CVDisplayLinkSetOutputCallback(_displayLink, &WindowViewDisplayLinkCallback, (__bridge void*)self);
    CVDisplayLinkStart(_displayLink);
}

// Main-thread tick. iOS onDisplayLinkTouch: was an empty hook used only to keep
// the link warm; the macOS analogue triggers a layer redraw so the FBO->layer
// blit runs each vsync.
- (void)onDisplayLinkTick
{
    if (self.layer != nil) {
        [self.layer setNeedsDisplay];
    }
}

#pragma mark - Hit testing / hot areas

- (NSView*)hitTest:(NSPoint)point
{
    // macOS: respect hot areas if configured, else default behavior.
    if (!hotAreas_.empty()) {
        NSPoint local = [self convertPoint:point fromView:self.superview];
        BOOL inHotArea = NO;
        for (auto it = hotAreas_.begin(); it != hotAreas_.end(); ++it) {
            if (!CGRectIsEmpty(*it) && CGRectContainsPoint(*it, NSPointToCGPoint(local))) {
                inHotArea = YES;
                break;
            }
        }
        if (!inHotArea) {
            [self touchOutside];
            return nil;
        }
    }
    return [super hitTest:point];
}

#pragma mark - Safe area / orientation (macOS: no-op)

// iOS overrode -safeAreaInsetsDidChange. macOS desktop windows have no safe-area
// insets, status bar, or interface orientation; nothing to forward here.
// macOS: no-op

#pragma mark - NSAccessibility (expose the ArkUI tree to VoiceOver / Inspector)

// Map an ArkUI component tag to the closest AppKit accessibility role, so
// VoiceOver announces e.g. a Button as a button and Text as static text.
static NSAccessibilityRole AceTagToNSRole(const std::string& tag)
{
    if (tag == "Text" || tag == "Span" || tag == "RichText") {
        return NSAccessibilityStaticTextRole;
    }
    if (tag == "Button") {
        return NSAccessibilityButtonRole;
    }
    if (tag == "TextInput" || tag == "TextArea" || tag == "Search") {
        return NSAccessibilityTextFieldRole;
    }
    if (tag == "Image") {
        return NSAccessibilityImageRole;
    }
    if (tag == "Toggle" || tag == "Checkbox") {
        return NSAccessibilityCheckBoxRole;
    }
    if (tag == "Slider") {
        return NSAccessibilitySliderRole;
    }
    return NSAccessibilityGroupRole;
}

// WindowView is an accessibility container, not a leaf element.
- (BOOL)isAccessibilityElement
{
    return NO;
}

- (NSString*)accessibilityRole
{
    return NSAccessibilityGroupRole;
}

// Snapshot the engine accessibility tree and mirror it as a tree of
// NSAccessibilityElements rooted under this view. AppKit queries this on demand,
// so each call reflects the current UI. Geometry: the engine reports rects in
// window coordinates, top-left origin, physical px; this view is isFlipped (YES)
// so dividing by the backing scale yields top-left view points, which convert to
// the screen rect AppKit expects.
- (NSArray*)accessibilityChildren
{
    if (self.instanceId < 0) {
        return @[];
    }
    std::vector<OHOS::Ace::Platform::MacA11yNode> nodes =
        OHOS::Ace::Platform::BuildMacA11yTree(self.instanceId);
    if (nodes.empty()) {
        return @[];
    }
    const CGFloat scale = [self currentBackingScale] > 0 ? [self currentBackingScale] : 1.0;

    NSMutableDictionary<NSNumber*, NSAccessibilityElement*>* byId = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber*, NSMutableArray*>* kids = [NSMutableDictionary dictionary];
    NSMutableArray<NSAccessibilityElement*>* roots = [NSMutableArray array];

    for (const auto& n : nodes) {
        NSRect viewRect = NSMakeRect(n.x / scale, n.y / scale, n.w / scale, n.h / scale);
        NSRect winRect = [self convertRect:viewRect toView:nil];
        NSRect screenRect = self.window ? [self.window convertRectToScreen:winRect] : winRect;
        NSString* label = [NSString stringWithUTF8String:n.label.c_str()];
        NSAccessibilityElement* el =
            [NSAccessibilityElement accessibilityElementWithRole:AceTagToNSRole(n.role)
                                                           frame:screenRect
                                                           label:(label.length ? label : nil)
                                                          parent:nil];
        if (n.checkable) {
            [el setAccessibilityValue:@(n.checked ? 1 : 0)];
        }
        byId[@(n.id)] = el;
        kids[@(n.id)] = [NSMutableArray array];
    }
    for (const auto& n : nodes) {
        NSAccessibilityElement* el = byId[@(n.id)];
        NSAccessibilityElement* parent = (n.parentId >= 0) ? byId[@(n.parentId)] : nil;
        if (parent) {
            [el setAccessibilityParent:parent];
            [kids[@(n.parentId)] addObject:el];
        } else {
            [el setAccessibilityParent:self];
            [roots addObject:el];
        }
    }
    for (NSNumber* key in byId) {
        [byId[key] setAccessibilityChildren:kids[key]];
    }
    return roots;
}

@end
