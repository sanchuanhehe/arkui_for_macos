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
#include <unistd.h>

// Pin cwd to the bundle resources as the VERY FIRST thing the process does, before
// any framework / AbilityRuntime / napi-module init. A GUI .app launched via
// LaunchServices starts with cwd = "/", and asset enumerations whose root resolves
// relative to cwd then recurse the whole disk (crossing ~/Desktop, ~/Downloads,
// ~/Pictures, mounted /Volumes, other apps' ~/Library), tripping a cascade of TCC
// folder/network-volume permission prompts. This MUST be a constructor, not code in
// main(): the executable links many static napi modules (each a __attribute__
// ((constructor))) and its real entry point is not this file's main() (the bundled
// AbilityRuntime provides one), so a chdir in main() never runs. constructor(101)
// runs at dlopen time, before the default-priority module constructors.
__attribute__((constructor(101))) static void ArkUIPinCwdToBundle(void)
{
    @autoreleasepool {
        NSString* resourceRoot = [NSBundle mainBundle].resourcePath ?: [NSBundle mainBundle].bundlePath;
        if (resourceRoot.length > 0) {
            chdir(resourceRoot.fileSystemRepresentation);
        }
    }
}

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
