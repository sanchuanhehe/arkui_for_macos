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

// macOS system font enumeration via AppKit's NSFontManager / NSFont. The class is
// declared by the platform-agnostic iOS header; the macOS build links this AppKit
// implementation instead of the UIKit one, so font_platform_impl.cpp (which just
// calls SystemFontManager) is reused as-is.

#import <AppKit/AppKit.h>

#include "adapter/ios/capability/font/system_font_manager.h"

namespace OHOS::Ace::Platform {

std::unique_ptr<FontNameFamilyMap> SystemFontManager::fontNameFamilyMap_ = nullptr;

void SystemFontManager::GetSystemFontList(std::vector<std::string>& fontList)
{
    GetSystemFontNameFamilyMap();
    if (!fontNameFamilyMap_) {
        return;
    }
    for (auto iter = fontNameFamilyMap_->begin(); iter != fontNameFamilyMap_->end(); iter++) {
        fontList.push_back(iter->first);
    }
}

bool SystemFontManager::GetSystemFont(const std::string& fontName, FontInfo& fontInfo)
{
    return GetSystemFontDetailByName(fontName, fontInfo);
}

bool SystemFontManager::GetSystemFontDetailByName(const std::string& fontName, FontInfo& fontInfo)
{
    GetSystemFontNameFamilyMap();
    if (!fontNameFamilyMap_) {
        return false;
    }
    auto findIter = fontNameFamilyMap_->find(fontName);
    if (fontNameFamilyMap_->end() == findIter) {
        return false;
    }
    fontInfo.fullName = findIter->first;
    fontInfo.family = findIter->second;
    NSString* name = [NSString stringWithUTF8String:fontName.c_str()];
    NSFont* font = [NSFont fontWithName:name size:[NSFont systemFontSize]];
    if (font == nil) {
        return false;
    }
    NSFontDescriptor* descriptor = font.fontDescriptor;
    const char* psName = descriptor.postscriptName.UTF8String;
    fontInfo.postScriptName = psName != nullptr ? std::string(psName) : std::string();
    NSFontSymbolicTraits traits = descriptor.symbolicTraits;
    if (traits & NSFontDescriptorTraitItalic) {
        fontInfo.italic = true;
    }
    if (traits & NSFontDescriptorTraitMonoSpace) {
        fontInfo.monoSpace = true;
    }
    if (traits & NSFontDescriptorClassSymbolic) {
        fontInfo.symbolic = true;
    }
    return true;
}

void SystemFontManager::GetSystemFontNameFamilyMap()
{
    if (!fontNameFamilyMap_) {
        fontNameFamilyMap_ = std::make_unique<FontNameFamilyMap>();
    }
    if (!fontNameFamilyMap_->empty()) {
        return;
    }
    NSFontManager* fontManager = [NSFontManager sharedFontManager];
    NSArray<NSString*>* familyNames = [fontManager availableFontFamilies];
    for (NSString* familyName in familyNames) {
        std::string family = std::string(familyName.UTF8String);
        // availableMembersOfFontFamily returns rows of [postScriptName, styleName,
        // weight, traits]; element 0 is the concrete font name.
        NSArray<NSArray*>* members = [fontManager availableMembersOfFontFamily:familyName];
        for (NSArray* member in members) {
            if (member.count == 0 || ![member[0] isKindOfClass:[NSString class]]) {
                continue;
            }
            std::string name = std::string([(NSString*)member[0] UTF8String]);
            fontNameFamilyMap_->emplace(name, family);
        }
    }
}

} // namespace OHOS::Ace::Platform
