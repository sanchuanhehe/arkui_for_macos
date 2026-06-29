/*
 * Copyright (c) 2023-2026 Huawei Device Co., Ltd.
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

#import "AceSurfaceView.h"

#import <QuartzCore/QuartzCore.h>

// AceSurfaceCaptureHelper: iOS UIGraphics-based surface snapshot; not needed for the Video
// display carrier on macOS (surfaceCapture returns FAIL). Omitted to avoid porting the UIKit
// bitmap-capture path.
#import "AceSurfaceHolder.h"
#import "WindowView.h"
#import "StageViewController.h"
#include "base/log/log.h"

@interface AceSurfaceView (){
    BOOL _viewAdded;
    BOOL _isLock;
    CGRect _currentFrame;
    NSInteger _initialOrientation;
}
@property (nonatomic, assign) int64_t incId;
@property (nonatomic, assign) int32_t instanceId;
@property (nonatomic, copy) IAceOnResourceEvent callback;
@property (nonatomic, strong) NSMutableDictionary<NSString*, IAceOnCallSyncResourceMethod>* callMethodMap;
@property (nonatomic, weak) NSViewController* target;
@property (nonatomic, weak) id<IAceSurface> surfaceDelegate;
@end

@implementation AceSurfaceView

#define SUCCESS @"success"
#define FAIL @"false"

#define PARAM_EQUALS @"#HWJS-=-#"
#define PARAM_BEGIN @"#HWJS-?-#"
#define METHOD @"method"
#define EVENT @"event"
#define SURFACE_FLAG @"surface@"

#define SURFACE_LEFT_KEY @"surfaceLeft"
#define SURFACE_TOP_KEY @"surfaceTop"
#define SURFACE_WIDTH_KEY @"surfaceWidth"
#define SURFACE_HEIGHT_KEY @"surfaceHeight"
#define SURFACE_SET_BOUNDS @"setSurfaceBounds"
#define IS_LOCK @"isLock"

+ (Class)layerClass {
    return [CALayer class];
}

- (instancetype)initWithId:(int64_t)incId callback:(IAceOnResourceEvent)callback
    param:(NSDictionary*)initParam superTarget:(id)target abilityInstanceId:(int32_t)abilityInstanceId
    delegate:(id<IAceSurface>)delegate
{
    if (self = [super init]) {
        LOGI("AceSurfaceView: init instanceId: %{public}lld  incId: %{public}lld", abilityInstanceId,incId);
        self.incId = incId;
        self.instanceId = abilityInstanceId;
        self.callback = callback;
        self.callMethodMap = [[NSMutableDictionary alloc] init];
        self.target = target;
        self.surfaceDelegate = delegate;
        self.autoresizesSubviews = YES;

        // macOS: an NSView has NO backing layer until wantsLayer is set (unlike UIView which is
        // always layer-backed). AceSurfaceHolder/AceVideo look the view up by its backing CALayer
        // (whose .delegate is this view), so self.layer MUST be non-nil before layerCreate — a nil
        // layer is silently dropped by AceSurfaceHolder addLayer:, breaking getLayerWithId. Opt into
        // layer-backing here so self.layer exists and the AVPlayerLayer overlay can attach.
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;

        [self layerCreate];
        [self initEventCallback];
    }
    return self;
}

- (void)initEventCallback
{
    __weak AceSurfaceView* weakSelf = self;
    IAceOnCallSyncResourceMethod callSetSurfaceSize = ^NSString*(NSDictionary* param) {
        if (weakSelf) {
            return [weakSelf setSurfaceBounds:param];
        } else {
            LOGE("AceSurfaceView: setSurfaceBounds fail");
            return FAIL;
        }
    };
    [self.callMethodMap setObject:[callSetSurfaceSize copy]
                           forKey:[self method_hashFormat:@"setSurfaceBounds"]];

    IAceOnCallSyncResourceMethod callAttachNativeWindow = ^NSString*(NSDictionary* param) {
        if (weakSelf) {
            return [weakSelf setAttachNativeWindow:param];
        } else {
            LOGE("AceSurfaceView: callAttachNativeWindow fail");
            return FAIL;
        }
    };
    [self.callMethodMap setObject:[callAttachNativeWindow copy]
                           forKey:[self method_hashFormat:@"attachNativeWindow"]];

    IAceOnCallSyncResourceMethod callSetSurfaceRotation = ^NSString*(NSDictionary* param) {
        if (weakSelf) {
            return [weakSelf setSurfaceRotation:param];
        } else {
            LOGE("AceSurfaceView: callSetSurfaceRotation fail");
            return FAIL;
        }
    };
    [self.callMethodMap setObject:[callSetSurfaceRotation copy]
                           forKey:[self method_hashFormat:@"setSurfaceRotation"]];

    IAceOnCallSyncResourceMethod callsetSurfaceRect = ^NSString*(NSDictionary* param) {
        if (weakSelf) {
            return [weakSelf setSurfaceRect:param];
        } else {
            LOGE("AceSurfaceView: callsetSurfaceRect fail");
            return FAIL;
        }
    };
    [self.callMethodMap setObject:[callsetSurfaceRect copy]
                           forKey:[self method_hashFormat:@"setSurfaceRect"]];

    IAceOnCallSyncResourceMethod callSurfaceCapture = ^NSString*(NSDictionary* param) {
        if (weakSelf) {
            return [weakSelf surfaceCapture:param];
        } else {
            LOGE("AceSurfaceView: callSurfaceCapture fail");
            return FAIL;
        }
    };
    [self.callMethodMap setObject:[callSurfaceCapture copy]
                           forKey:[self method_hashFormat:@"surfaceCapture"]];
}

- (NSString*)surfaceCapture:(NSDictionary*)params
{
    // Surface snapshot not supported on macOS (iOS UIGraphics path omitted).
    return FAIL;
}

- (void)callSurfaceChange:(CGRect)surfaceRect
{
    if (!self.layer || CGRectEqualToRect(_currentFrame, surfaceRect)) {
        return;
    }
    CGFloat scale = [NSScreen mainScreen].backingScaleFactor;
    CGFloat x = surfaceRect.origin.x / scale;
    CGFloat w = surfaceRect.size.width / scale;
    CGFloat h = surfaceRect.size.height / scale;
    // ArkUI supplies a top-left-origin rect (matching the flipped GL WindowView), but this view's
    // parent (StageContainerView) is a plain NSView with bottom-left origin. Setting origin.y = top
    // directly would mirror the overlay vertically and leave the GL-drawn controls poking out below
    // the video. Convert the top-left Y to bottom-left so the AVPlayerLayer overlay aligns exactly
    // with the GL-rendered Video component. self.superview is still nil on the first call
    // (bringSubviewToFront runs afterwards), so use the target view-controller's root view height.
    CGFloat topY = surfaceRect.origin.y / scale;
    NSView* parentView = self.superview ?: [(NSViewController*)self.target view];
    CGFloat parentHeight = parentView ? parentView.bounds.size.height : (topY + h);
    CGFloat bottomY = parentHeight - topY - h;
    CGRect newRect = CGRectMake(x, bottomY, w, h);
    self.frame = newRect;
    BOOL sizeChanged = !CGSizeEqualToSize(_currentFrame.size, surfaceRect.size);
    _currentFrame = surfaceRect;
    if (!sizeChanged) {
        return;
    }
    NSString *param = [NSString stringWithFormat:@"surfaceWidth=%f&surfaceHeight=%f",
        surfaceRect.size.width, surfaceRect.size.height];
    [self fireCallback:@"onChanged" params:param];
}

- (void)layerCreate
{
    [AceSurfaceHolder addLayer:self.layer withId:self.incId inceId:self.instanceId];
    [self bringSubviewToFront];
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    // Keep the hosted content sublayer (e.g. the Video carrier's AVPlayerLayer) filling the
    // view. CALayer sublayers do not autoresize with an NSView's backing layer, so resize them
    // here. Disable the implicit animation so resizes track the layout without lag.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer* sublayer in self.layer.sublayers) {
        sublayer.frame = self.layer.bounds;
    }
    [CATransaction commit];
}

- (NSDictionary<NSString*, IAceOnCallSyncResourceMethod>*)getCallMethod
{
    return [self.callMethodMap copy];
}

- (NSString*)setSurfaceBounds:(NSDictionary*)params
{
    if (!params[SURFACE_WIDTH_KEY] || !params[SURFACE_HEIGHT_KEY]) {
        return FAIL;
    }
    @try {
        CGFloat surface_x = [params[SURFACE_LEFT_KEY] floatValue];
        CGFloat surface_y = [params[SURFACE_TOP_KEY] floatValue];
        CGFloat surface_width = [params[SURFACE_WIDTH_KEY] floatValue];
        CGFloat surface_height = [params[SURFACE_HEIGHT_KEY] floatValue];
        CGRect surfaceRect = CGRectMake(surface_x, surface_y, surface_width, surface_height);

        if (_viewAdded) {
            [self callSurfaceChange:surfaceRect];
            [self layoutSubtreeIfNeeded];
        } else {
            _viewAdded = YES;
            NSViewController* superViewController = (NSViewController*)self.target;
            self.frame = superViewController.view.bounds;
            self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [self callSurfaceChange:surfaceRect];
            [self bringSubviewToFront];
        }
    } @catch (NSException* exception) {
        LOGE("AceSurfaceView NumberFormatException, setSurfaceSize failed");
        return FAIL;
    }
    return SUCCESS;
}

- (NSString*)setAttachNativeWindow:(NSDictionary*)params
{
    if (!self.surfaceDelegate) {
        LOGE("AceSurfaceView IAceSurface is null");
        return FAIL;
    }
    if (![self.surfaceDelegate respondsToSelector:@selector(attachNaitveSurface:)]) {
        LOGE("AceSurfaceView IAceSurface attachNaitveSurface null");
        return FAIL;
    }
    uintptr_t nativeWindow = [self.surfaceDelegate attachNaitveSurface:self.layer];
    if (nativeWindow == 0) {
        LOGE("AceSurfaceView Surface nativeWindow: null");
        return FAIL;
    }
    NSDictionary * param = @{@"nativeWindow": [NSString stringWithFormat:@"%ld",(long)nativeWindow]};
    return [self convertMapToString:param];
}

- (NSString*)setSurfaceRotation:(NSDictionary*)params
{
    // macOS desktop has no device orientation; surface-rotation lock is a no-op.
    if (!params[IS_LOCK]) {
        return FAIL;
    }
    _isLock = [params[IS_LOCK] boolValue];
    return SUCCESS;
}

- (NSString*)setSurfaceRect:(NSDictionary*)params
{
    if (!params[SURFACE_WIDTH_KEY] || !params[SURFACE_HEIGHT_KEY]) {
        return FAIL;
    }
    @try {
        NSScreen *screen = [NSScreen mainScreen];
        CGFloat scale = screen.backingScaleFactor;
        CGFloat x = [params[SURFACE_LEFT_KEY] floatValue];
        CGFloat y = [params[SURFACE_TOP_KEY] floatValue];
        CGFloat width = [params[SURFACE_WIDTH_KEY] floatValue];
        CGFloat height = [params[SURFACE_HEIGHT_KEY] floatValue];
        CGRect surfaceRect = CGRectMake(x / scale, y / scale, width / scale, height / scale);
        CALayer *sublayer = [self.layer.sublayers firstObject];
        if (sublayer) {
            sublayer.frame = surfaceRect;
        }
    } @catch (NSException* exception) {
        LOGE("AceSurfaceView NumberFormatException, setSurfaceSize failed");
        return FAIL;
    }
    return SUCCESS;
}

- (NSView *)findWindowViewInView:(NSView *)view {
    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:[WindowView class]]) {
            return subview;
        } 
    }
    return nil;
}

- (void)orientationDidChange {
    // macOS desktop has no device-orientation rotation; the iOS rotation-transform logic
    // (initial vs current UIInterfaceOrientation) does not apply.
}

#pragma mark - fireCallback

- (void)fireCallback:(NSString *)method params:(NSString *)params
{
    NSString *method_hash = [NSString stringWithFormat:@"%@%lld%@%@%@%@", 
        SURFACE_FLAG, self.incId, EVENT, PARAM_EQUALS, method, PARAM_BEGIN];
    if (self.callback) {
        self.callback(method_hash, params);
    }
}

- (NSString *)method_hashFormat:(NSString *)method
{
    return [NSString stringWithFormat:@"%@%lld%@%@%@%@", SURFACE_FLAG, self.incId, METHOD, PARAM_EQUALS, method, PARAM_BEGIN];
}

- (long)getResId
{
    return self.incId;
}

- (void)bringSubviewToFront
{
    if (self.target){
        StageViewController* superViewController = (StageViewController*)self.target;
        if (!superViewController){
            return;
        }
        NSView *windowView = [superViewController getWindowView];
        if (!windowView){
            return;
        }
        // macOS: the GL WindowView is opaque, so the surface (e.g. AVPlayerLayer host) must
        // overlay ABOVE it (iOS inserts below a transparent UIView). NSView uses
        // addSubview:positioned:relativeTo:.
        self.translatesAutoresizingMaskIntoConstraints = YES;
        [windowView.superview addSubview:self positioned:NSWindowAbove relativeTo:windowView];
    }
}

- (NSString *)convertMapToString:(NSDictionary *)data
{
    NSArray *pairs = [data.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *string = [[NSMutableString alloc] init];
    for (NSString *key in pairs) {
        id value = data[key];
        [string appendFormat:@"%@=%@;", key, value];
    }
    [string deleteCharactersInRange:NSMakeRange(string.length - 1, 1)];
    return string;
}

- (void)releaseObject
{
    @try {
        LOGI("AceSurfaceView releaseObject");
        if (_viewAdded) {
            _viewAdded = false;
        }
        if (self.layer) {
            [AceSurfaceHolder removeLayerWithId:self.incId inceId:self.instanceId];
        }

        if (self.callMethodMap) {
            for (id key in self.callMethodMap) {
                IAceOnCallSyncResourceMethod block = [self.callMethodMap objectForKey:key];
                block = nil;
            }
            [self.callMethodMap removeAllObjects];
            self.callMethodMap = nil;
        }
        self.callback = nil;
        
    } @catch (NSException* exception) {
        LOGE("AceSurfaceView releaseObject failed");
    }
}

- (void)dealloc
{
    LOGI("AceSurfaceView dealloc instanceId: %{public}lld", self.instanceId);
}

@end
