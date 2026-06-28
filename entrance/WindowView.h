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

// Path X (native macOS): NSView analogue of the iOS WindowView (a UIView).
// The Objective-C class name is kept exactly `WindowView` because
// virtual_rs_window.mm references it by that name (static_cast<WindowView*>,
// isKindOfClass:[WindowView class], setWindowDelegate:, createSurfaceNode, etc).
// UIKit -> AppKit, EAGL/CAEAGLLayer -> NSOpenGLContext/CALayer, CADisplayLink ->
// CVDisplayLink. Features with no macOS equivalent (safe-area, status bar,
// orientation, screen brightness) are stubbed no-op.

#ifndef FOUNDATION_ACE_ADAPTER_MACOS_ENTRANCE_WINDOW_VIEW_H
#define FOUNDATION_ACE_ADAPTER_MACOS_ENTRANCE_WINDOW_VIEW_H

#include <AppKit/AppKit.h>
#include <memory>

namespace OHOS::Rosen {
class Window;
}

@interface WindowView : NSView
// macOS has no interface-orientation concept; kept for source parity with iOS,
// always treated as a no-op placeholder.
@property (nonatomic, assign) NSInteger OrientationMask;
// iOS used UIViewController; the macOS analogue is NSViewController. Kept for
// parity so call sites that query the controller still compile.
@property (nonatomic, assign) NSViewController* viewController;
@property (nonatomic, assign) BOOL focusable;
@property (nonatomic, assign) BOOL isFocused;
@property (nonatomic, assign) BOOL fullScreen;
@property (nonatomic, assign) NSInteger zOrder;
@property (nonatomic, assign) float brightness;
// ArkUI instance id this view renders, set by StageViewController. Used by the
// NSAccessibility bridge to walk the matching engine accessibility tree.
@property (nonatomic, assign) int32_t instanceId;

- (NSViewController*)getViewController;

// Mark this view as a transparent sub-window host (Dialog/Menu/Popup), so its
// backing layer clears to alpha 0 and only the popup content is visible.
- (void)markAsTransparentSubWindow;

- (void)setWindowDelegate:(std::shared_ptr<OHOS::Rosen::Window>)window;
- (void)createSurfaceNode;
- (BOOL)requestFocus;
- (void)setTouchHotAreas:(CGRect[])rects size:(NSInteger)size;
- (BOOL)showOnView:(NSView*)rootView;
- (BOOL)hide;
- (void)notifySurfaceChangedWithWidth:(int32_t)width height:(int32_t)height density:(float)density;
- (void)notifySurfaceDestroyed;
- (void)notifyForeground;
- (void)notifyBackground;
- (void)notifyHandleWillTerminate;
- (void)notifyActiveChanged:(BOOL)isActive;
- (void)notifyWindowDestroyed;
- (void)notifySafeAreaChanged;
- (void)notifyTraitCollectionDidChange:(BOOL)isSplitScreen;
- (std::shared_ptr<OHOS::Rosen::Window>)getWindow;
- (void)notifyApplicationForeground:(BOOL)isForeground;

- (void)updateBrightness:(BOOL)isShow;
- (BOOL)processBackPressed;
- (void)keyboardWillChangeFrame:(NSNotification*)notification;
- (void)keyboardWillBeHidden:(NSNotification*)notification;
- (void)startBaseDisplayLink;
// Synthetic touch injection. iOS keyed this on UITouchPhase; macOS has no such
// enum, so we use NSInteger phase codes matching the iOS UITouchPhase ordering
// (0=Began, 1=Moved, 2=Stationary, 3=Ended, 4=Cancelled).
- (BOOL)dispatchSyntheticTouchWithPhase:(NSInteger)phase
                                 pixelX:(CGFloat)pixelX
                                 pixelY:(CGFloat)pixelY
                              pointerId:(int32_t)pointerId
                              timeStamp:(int64_t)timeStamp;
@end

#endif  // FOUNDATION_ACE_ADAPTER_MACOS_ENTRANCE_WINDOW_VIEW_H
