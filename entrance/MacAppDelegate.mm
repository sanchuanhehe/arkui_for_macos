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

// Phase 2 path X (M1): macOS app delegate. Mirrors templates/ios/app
// AppDelegate_stage.m: configure the bundle module, launch AbilityRuntime, then
// create an NSWindow whose contentViewController is the StageViewController (the
// NSViewController that builds WindowView + createSurfaceNode + DispatchOnCreate).

#import "MacAppDelegate.h"
#import "StageApplication.h"
#import "StageViewController.h"

#define BUNDLE_DIRECTORY @"arkui-x"
// M1 格-c2: a standard (non dynamic-render) HelloWorld stage app built with
// `ace build bundle` and copied to out/.../arkui-x/entry. A plain EntryAbility +
// @Entry page runs in the main runtime, avoiding the dynamic-render realm issues.
#define BUNDLE_NAME @"com.example.helloworld"
#define MODULE_NAME @"entry"
#define ABILITY_NAME @"EntryAbility"

@implementation MacAppDelegate

- (void)applicationWillFinishLaunching:(NSNotification*)notification
{
    // Suppress AppKit's launch-time document autoreopen / window state restoration. lldb showed
    // -[NSDocumentController _autoreopenDocumentsIgnoringExpendable:] -> _autosaveDirectoryURL...
    // -> URLForDirectory:NSDocumentDirectory at startup, which touches ~/Documents and pops a
    // "allow access to your Documents folder" TCC prompt. This ArkUI app is not document-based,
    // so the autoreopen is spurious; ignoring persisted state skips it. Must run BEFORE
    // didFinishLaunching (when AppKit performs the autoreopen).
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{ @"ApplePersistenceIgnoreState" : @YES }];
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication*)sender
{
    return NO;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
    // cwd is pinned to the bundle resources by a constructor(101) in main.mm (runs
    // before any AbilityRuntime / napi-module init, which a delegate method cannot),
    // so relative asset enumerations stay inside the bundle instead of recursing the
    // whole disk and tripping TCC prompts.

    // 1. Configure the .abc / module bundle and start AbilityRuntime.
    [StageApplication configModuleWithBundleDirectory:BUNDLE_DIRECTORY];
    [StageApplication launchApplication];

    // 2. Build the stage view controller for the sample ability.
    NSString* instanceName =
        [NSString stringWithFormat:@"%@:%@:%@", BUNDLE_NAME, MODULE_NAME, ABILITY_NAME];
    StageViewController* rootVC =
        [[StageViewController alloc] initWithInstanceName:instanceName];

    // 3. Host it in a regular titled NSWindow. Default to a landscape desktop size
    // (wider than tall) so the app looks like a native macOS window rather than a
    // portrait phone simulator.
    NSRect frame = NSMakeRect(0, 0, 1024, 768);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:style
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    [self.window setContentViewController:rootVC];
    [self.window setTitle:@"ArkUI-X (macOS)"];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [rootVC loadViewIfNeeded];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
    // NO: a sub-window (Dialog/Menu/Popup) lives in a child NSPanel that covers the
    // main window; as it is shown/hidden AppKit's "last window closed" accounting
    // can momentarily see no eligible window and would terminate the whole app.
    // Standard macOS desktop behaviour anyway — the app stays alive in the Dock when
    // its window is closed; Cmd-Q (applicationShouldTerminate) still quits.
    return NO;
}

@end
