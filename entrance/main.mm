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

// Phase 2 path X: native macOS app entry (M1). Standalone executable, no Xcode
// project / .app bundle: we build a plain Mach-O, create NSApplication
// programmatically, set a regular activation policy so a window can appear, and
// hand off to MacAppDelegate.

#import <AppKit/AppKit.h>
#import "MacAppDelegate.h"

int main(int argc, const char* argv[])
{
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        // Regular policy: show in Dock and allow a key window (no .app bundle).
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        MacAppDelegate* delegate = [[MacAppDelegate alloc] init];
        [app setDelegate:delegate];

        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
