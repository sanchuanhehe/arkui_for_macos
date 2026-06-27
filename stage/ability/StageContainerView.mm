/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
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

#import "StageContainerView.h"
#import <set>
#include "StageApplication.h"
#include "base/log/log.h"

@implementation StageContainerView

- (instancetype)initWithFrame:(NSRect)frame {
    if (self = [super initWithFrame: frame]) {
        [self setupNotificationCenterObservers];
    }
    return self;
}

- (void)showWindow:(WindowView *)window {
    LOGI("%{public}s", "showWindow");
    // NSView subview ordering: front-most is last in subviews. Mirror the iOS
    // z-order insertion using addSubview:positioned:relativeTo:.
    NSView* aboveView = nil;
    for (NSView* view in self.subviews.reverseObjectEnumerator) {
        if ([view isKindOfClass:[WindowView class]] && window.zOrder < ((WindowView *)view).zOrder) {
            aboveView = view;
        } else {
            break;
        }
    }
    if (!aboveView) {
        [self addSubview:window];
    } else {
        [self addSubview:window positioned:NSWindowBelow relativeTo:aboveView];
    }

    if (window.focusable) {
        [self setActiveWindow:window];
    }
}

- (BOOL)requestFocus:(WindowView*)window {
    if (!window.focusable) {
        return NO;
    }
    BOOL res = NO;
    for (NSView *subview in [self.subviews reverseObjectEnumerator]) {
       if (subview == window) {
            res = YES;
           break;
       }
    }
    if (res) {
        // bringSubviewToFront -> remove + re-add at top on AppKit.
        [window removeFromSuperview];
        [self addSubview:window];
        self.activeWindow = window;
        return YES;
    }
    return NO;
}

- (void)setMainWindow:(WindowView *)mainWindow {
    _mainWindow = mainWindow;
    self.activeWindow = mainWindow;
    [self addSubview:mainWindow];
}

- (void)hiddenWindow:(WindowView *)window {
    [window removeFromSuperview];
    self.activeWindow = self.mainWindow;
}

- (void)setupNotificationCenterObservers {
    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    // UIApplication*Notification -> NSApplication*Notification on macOS.
    [center addObserver:self
               selector:@selector(applicationBecameActive:)
                   name:NSApplicationDidBecomeActiveNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(applicationWillResignActive:)
                   name:NSApplicationWillResignActiveNotification
                 object:nil];

    // macOS has no enter-background/foreground; hide/unhide are the closest analogues.
    [center addObserver:self
               selector:@selector(applicationDidEnterBackground:)
                   name:NSApplicationDidHideNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(applicationWillEnterForeground:)
                   name:NSApplicationWillUnhideNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleWillTerminate:)
                   name:NSApplicationWillTerminateNotification
                 object:nil];
}
#pragma mark - Application lifecycle notifications

- (void)applicationBecameActive:(NSNotification *)notification {
    [self notifyActiveChanged:YES];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self notifyActiveChanged:NO];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    if (self.notifyDelegate == [StageApplication getApplicationTopViewController]) {
        LOGI("{public}StageContainerView TopViewController applicationDidEnterBackground");
        [self notifyBackground];
    }

    if ([self.notifyDelegate respondsToSelector:@selector(notifyApplicationDidEnterBackground)]) {
        [self.notifyDelegate notifyApplicationDidEnterBackground];
    }
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    if (self.notifyDelegate == [StageApplication getApplicationTopViewController]) {
        LOGI("{public}StageContainerView TopViewController applicationWillEnterForeground");
        [self notifyForeground];
    }
    if ([self.notifyDelegate respondsToSelector:@selector(notifyApplicationWillEnterForeground)]) {
        [self.notifyDelegate notifyApplicationWillEnterForeground];
    }
}

- (void)handleWillTerminate:(NSNotification*)notification {
    if ([self.notifyDelegate respondsToSelector:@selector(notifyApplicationWillTerminateNotification)]) {
        [self.notifyDelegate notifyApplicationWillTerminateNotification];
    }

    for (NSView *subview in [self.subviews reverseObjectEnumerator]) {
       if ([subview isKindOfClass:[WindowView class]]) {
           [(WindowView*)subview notifyHandleWillTerminate];
       }
    }
}

- (void)notifyActiveChanged:(BOOL)isActive {
    self.activeWindow.isFocused = isActive;
   for (NSView *subview in [self.subviews reverseObjectEnumerator]) {
       if ([subview isKindOfClass:[WindowView class]]) {
           [(WindowView*)subview notifyActiveChanged:isActive];
       }
   }
}

- (void)notifyForeground {
    for (NSView *subview in [self.subviews reverseObjectEnumerator]) {
       if ([subview isKindOfClass:[WindowView class]]) {
           [(WindowView*)subview notifyForeground];
           [(WindowView*)subview notifyApplicationForeground:YES];
       }
    }
}
- (void)notifyBackground {
    for (NSView *subview in [self.subviews reverseObjectEnumerator]) {
       if ([subview isKindOfClass:[WindowView class]]) {
           [(WindowView*)subview notifyBackground];
           [(WindowView*)subview notifyApplicationForeground:NO];
       }
    }
}

- (void)setActiveWindow:(WindowView *)activeWindow {
    if (_activeWindow != activeWindow && activeWindow.focusable) {
        _activeWindow.isFocused = NO;
        _activeWindow = activeWindow;
        _activeWindow.isFocused = YES;
    }
}

- (NSView *)hitTest:(NSPoint)point {
    // macOS: AppKit ignores hidden / fully-transparent views automatically.
    if (self.isHidden || self.alphaValue <= 0.01) {
        return nil;
    }
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if ([self mouse:local inRect:self.bounds]) {
        for (NSView *subview in [self.subviews reverseObjectEnumerator]) {
            NSView *hitTestView = [subview hitTest:point];
            if (hitTestView) {
                if ([hitTestView isKindOfClass:[WindowView class]] && self.activeWindow != hitTestView) {
                    if (self.activeWindow != hitTestView && hitTestView != self.mainWindow) {
                        // bringSubviewToFront -> remove + re-add at top.
                        [hitTestView removeFromSuperview];
                        [self addSubview:hitTestView];
                    }
                    self.activeWindow = (WindowView *)hitTestView;
                }
                return hitTestView;
            }
        }

        return self;
    }
    return nil;
}

- (void)dealloc {
    LOGI("{public}StageContainerView dealloc");
    self.notifyDelegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
@end
