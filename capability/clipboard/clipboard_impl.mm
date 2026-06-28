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

// macOS clipboard backed by NSPasteboard. The class is declared by the
// platform-agnostic iOS header; this file provides the AppKit implementation
// that the macOS build links instead of the UIKit one. Text is fully supported;
// pixel-map / span-string / multi-record paths are no-ops for now (follow-up).

#import <AppKit/AppKit.h>

#include "adapter/ios/capability/clipboard/clipboard_impl.h"
#include "base/image/pixel_map.h"

namespace OHOS::Ace::Platform {

void ClipboardImpl::SetData(const std::string& data, CopyOptions /*copyOption*/, bool /*isDragData*/)
{
    NSString* text = [NSString stringWithUTF8String:data.c_str()];
    if (text == nil) {
        text = @"";
    }
    auto setOnPasteboard = [text]() {
        NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard setString:text forType:NSPasteboardTypeString];
    };
    if (taskExecutor_) {
        taskExecutor_->PostTask(setOnPasteboard, TaskExecutor::TaskType::PLATFORM, "ArkUI-XMacClipboardSetData");
    } else {
        setOnPasteboard();
    }
}

void ClipboardImpl::GetData(const std::function<void(const std::string&)>& callback, bool /*syncMode*/)
{
    if (!callback) {
        return;
    }
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    NSString* text = [pasteboard stringForType:NSPasteboardTypeString];
    std::string result = (text != nil && text.UTF8String != nullptr) ? std::string(text.UTF8String) : std::string();
    callback(result);
}

void ClipboardImpl::GetData(const std::function<void(const std::string&, bool)>& callback, bool /*syncMode*/)
{
    if (!callback) {
        return;
    }
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    NSString* text = [pasteboard stringForType:NSPasteboardTypeString];
    std::string result = (text != nil && text.UTF8String != nullptr) ? std::string(text.UTF8String) : std::string();
    // The bool is isFromAutoFill -- a normal clipboard paste is not auto-fill, so
    // pass false (true would route to ProcessAutoFillOnPaste and drop the text).
    callback(result, false);
}

void ClipboardImpl::HasData(const std::function<void(bool hasData, bool isAutoFill)>& callback)
{
    if (!callback) {
        return;
    }
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    NSString* text = [pasteboard stringForType:NSPasteboardTypeString];
    callback(text != nil && text.length > 0, false);
}

void ClipboardImpl::HasDataType(
    const std::function<void(bool hasData, bool isAutoFill)>& callback, const std::vector<std::string>& /*mimeTypes*/)
{
    HasData(callback);
}

void ClipboardImpl::Clear()
{
    auto clearPasteboard = []() { [[NSPasteboard generalPasteboard] clearContents]; };
    if (taskExecutor_) {
        taskExecutor_->PostTask(clearPasteboard, TaskExecutor::TaskType::PLATFORM, "ArkUI-XMacClipboardClear");
    } else {
        clearPasteboard();
    }
}

// ---------------------------------------------------------------------------
// Pixel-map / span-string / multi-record paths: not yet supported on macOS.
// ---------------------------------------------------------------------------
void ClipboardImpl::SetPixelMapData(const RefPtr<PixelMap>& /*pixmap*/, CopyOptions /*copyOption*/) {}
void ClipboardImpl::GetPixelMapData(
    const std::function<void(const RefPtr<PixelMap>&)>& callback, bool /*syncMode*/)
{
    if (callback) {
        callback(nullptr);
    }
}
void ClipboardImpl::RegisterCallbackSetClipboardPixmapData(CallbackSetClipboardPixmapData callback)
{
    callbackSetClipboardPixmapData_ = std::move(callback);
}
void ClipboardImpl::RegisterCallbackGetClipboardPixmapData(CallbackGetClipboardPixmapData callback)
{
    callbackGetClipboardPixmapData_ = std::move(callback);
}
void ClipboardImpl::AddPixelMapRecord(const RefPtr<PasteDataMix>& /*pasteData*/, const RefPtr<PixelMap>& /*pixmap*/) {}
void ClipboardImpl::AddImageRecord(const RefPtr<PasteDataMix>& /*pasteData*/, const std::string& /*uri*/) {}
void ClipboardImpl::AddTextRecord(const RefPtr<PasteDataMix>& /*pasteData*/, const std::string& /*selectedStr*/) {}
void ClipboardImpl::AddSpanStringRecord(const RefPtr<PasteDataMix>& /*pasteData*/, std::vector<uint8_t>& /*data*/) {}
void ClipboardImpl::AddMultiTypeRecord(
    const RefPtr<PasteDataMix>& /*pasteData*/, const RefPtr<MultiTypeRecordMix>& /*multiTypeRecord*/) {}
void ClipboardImpl::SetData(const RefPtr<PasteDataMix>& /*pasteData*/, CopyOptions /*copyOption*/) {}
void ClipboardImpl::GetData(const std::function<void(const std::string&, bool isLastRecord)>& textCallback,
    const std::function<void(const RefPtr<PixelMap>&, bool isLastRecord)>& /*pixelMapCallback*/,
    const std::function<void(const std::string&, bool isLastRecord)>& /*urlCallback*/, bool /*syncMode*/)
{
    // Fall back to plain text so a paste from a TextField still works.
    if (textCallback) {
        NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
        NSString* text = [pasteboard stringForType:NSPasteboardTypeString];
        std::string result =
            (text != nil && text.UTF8String != nullptr) ? std::string(text.UTF8String) : std::string();
        textCallback(result, true);
    }
}
void ClipboardImpl::GetSpanStringData(
    const std::function<void(std::vector<std::vector<uint8_t>>&, const std::string&, bool&)>& /*callback*/,
    bool /*syncMode*/)
{}
void ClipboardImpl::GetSpanStringData(
    const std::function<void(std::vector<std::vector<uint8_t>>&, const std::string&, bool&, bool&)>& /*callback*/,
    bool /*syncMode*/)
{}
RefPtr<PasteDataMix> ClipboardImpl::CreatePasteDataMix()
{
    return nullptr;
}

} // namespace OHOS::Ace::Platform
