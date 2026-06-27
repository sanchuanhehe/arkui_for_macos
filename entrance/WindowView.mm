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

namespace {
// Match the iOS UITouchPhase ordering so synthetic-touch callers stay source
// compatible across platforms.
constexpr NSInteger TOUCH_PHASE_BEGAN = 0;
constexpr NSInteger TOUCH_PHASE_MOVED = 1;
constexpr NSInteger TOUCH_PHASE_STATIONARY = 2;
constexpr NSInteger TOUCH_PHASE_ENDED = 3;
constexpr NSInteger TOUCH_PHASE_CANCELLED = 4;
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
    GLuint colorRb = OHOS::Rosen::RenderContextGL::GetCurrentColorbuffer();

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
        glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
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
    int32_t _pointerId;
    std::vector<CGRect> hotAreas_;
    float _oldBrightness;

    // CVDisplayLink replaces iOS CADisplayLink. It fires on a private, high
    // priority thread, so every callback marshals to the main queue before
    // touching RS / UIContent / the window delegate.
    CVDisplayLinkRef _displayLink;
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
    return layer;
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

// TODO M2: event dispatch. Mirror the iOS dispatchTouches path -- build an
// AcePointerDataPacket from the NSEvent location (convertPoint:fromView:nil,
// scaled by backingScaleFactor) and call window->ProcessPointerEvent(...).
// macOS reports a single mouse pointer (pointer/device id 0).

- (void)mouseDown:(NSEvent*)event
{
    // TODO M2: event dispatch (UITouchPhaseBegan analogue)
}

- (void)mouseDragged:(NSEvent*)event
{
    // TODO M2: event dispatch (UITouchPhaseMoved analogue)
}

- (void)mouseUp:(NSEvent*)event
{
    // TODO M2: event dispatch (UITouchPhaseEnded analogue)
}

- (void)rightMouseDown:(NSEvent*)event
{
    // TODO M2: event dispatch (secondary button)
}

- (void)rightMouseDragged:(NSEvent*)event
{
    // TODO M2: event dispatch (secondary button drag)
}

- (void)rightMouseUp:(NSEvent*)event
{
    // TODO M2: event dispatch (secondary button up)
}

#pragma mark - Key events (replaces pressesBegan/Ended)

- (void)keyDown:(NSEvent*)event
{
    // TODO M2: event dispatch. Map NSEvent.keyCode + modifierFlags to
    // window->ProcessKeyEvent(keyCode, KeyAction::DOWN, ...). macOS auto-repeat
    // is available via event.isARepeat, so the iOS dispatch-source repeat timer
    // is not needed.
}

- (void)keyUp:(NSEvent*)event
{
    // TODO M2: event dispatch -> window->ProcessKeyEvent(..., KeyAction::UP, ...)
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

@end
