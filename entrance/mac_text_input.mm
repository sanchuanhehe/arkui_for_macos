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

#include "adapter/macos/entrance/mac_text_input.h"

// The connection class is declared by the (platform-agnostic) iOS header; the
// macOS build links this real implementation instead of the inert stub that
// used to live in mac_link_stubs.cpp.
#include "adapter/ios/capability/editing/text_input_connection_impl.h"
#include "adapter/ios/capability/editing/text_input_client_handler.h"

#include <algorithm>

#include "base/log/log.h"
#include "core/common/ime/text_editing_value.h"

#import <Foundation/Foundation.h>

namespace OHOS::Ace::Platform {

namespace {
// NSString is UTF-16 internally; unichar == char16_t, so this round-trips losslessly.
std::string U16ToU8(const std::u16string& s)
{
    if (s.empty()) {
        return std::string();
    }
    NSString* ns = [NSString stringWithCharacters:reinterpret_cast<const unichar*>(s.data()) length:s.length()];
    const char* u8 = ns.UTF8String;
    return u8 ? std::string(u8) : std::string();
}
} // namespace

MacTextInputBridge& MacTextInputBridge::GetInstance()
{
    static MacTextInputBridge instance;
    return instance;
}

void MacTextInputBridge::Activate(const WeakPtr<TextInputClient>& client, const RefPtr<TaskExecutor>& taskExecutor,
    int32_t clientId, TextInputAction action)
{
    client_ = client;
    taskExecutor_ = taskExecutor;
    clientId_ = clientId;
    action_ = action;
    active_ = true;
    text_.clear();
    caret_ = 0;
}

void MacTextInputBridge::Deactivate(int32_t clientId)
{
    if (clientId != clientId_) {
        return;
    }
    active_ = false;
    client_ = nullptr;
    taskExecutor_ = nullptr;
    clientId_ = -1;
    text_.clear();
    caret_ = 0;
}

void MacTextInputBridge::CommitText(const std::u16string& text)
{
    if (text.empty()) {
        return;
    }
    if (caret_ < 0 || caret_ > static_cast<int32_t>(text_.length())) {
        caret_ = static_cast<int32_t>(text_.length());
    }
    text_.insert(static_cast<size_t>(caret_), text);
    caret_ += static_cast<int32_t>(text.length());
    PushEditingValue(text, false);
}

void MacTextInputBridge::DeleteBackward(int32_t count)
{
    if (count <= 0 || caret_ <= 0) {
        return;
    }
    int32_t n = std::min(count, caret_);
    text_.erase(static_cast<size_t>(caret_ - n), static_cast<size_t>(n));
    caret_ -= n;
    PushEditingValue(std::u16string(), true);
}

void MacTextInputBridge::PerformAction()
{
    if (!active_ || !taskExecutor_) {
        return;
    }
    auto action = action_;
    auto weak = client_;
    taskExecutor_->PostTask(
        [weak, action]() {
            auto client = weak.Upgrade();
            if (client) {
                client->PerformAction(action, false);
            }
        },
        TaskExecutor::TaskType::UI, "ArkUI-XMacPerformAction");
}

void MacTextInputBridge::SetMirror(const std::u16string& text, int32_t selStart, int32_t selEnd)
{
    text_ = text;
    caret_ = selEnd;
    if (caret_ < 0 || caret_ > static_cast<int32_t>(text_.length())) {
        caret_ = static_cast<int32_t>(text_.length());
    }
}

void MacTextInputBridge::SetCaret(int32_t caret)
{
    int32_t len = static_cast<int32_t>(text_.length());
    caret_ = std::clamp(caret, 0, len);
}

void MacTextInputBridge::PushEditingValue(const std::u16string& appendText, bool isDelete)
{
    if (!active_ || !taskExecutor_) {
        return;
    }
    // Mirror the iOS adapter (text_input_connection_impl.mm): hand the focused
    // TextInput the full editing value. HandleEditingEventCrossPlatform stores it
    // as editingValue_ (so the caret follows selection) and replays appendText via
    // InsertValue. We push directly to the focused client (the one whose Show()
    // activated this bridge) rather than through TextInputClientHandler, whose
    // clientId gate can reject us: on macOS two Attach paths (TextInputPlugin and
    // InputMethodManager) race to set the "current" connection, so the handler's
    // currentConnection_ may not be the one we hold.
    auto value = std::make_shared<TextEditingValue>();
    value->text = U16ToU8(text_);
    value->appendText = U16ToU8(appendText);
    value->UpdateSelection(caret_, caret_);
    value->isDelete = isDelete;
    value->unmarkText = false;
    value->discardedMarkedText = false;
    value->stopBackPress = false;
    auto weak = client_;
    taskExecutor_->PostTask(
        [weak, value]() {
            auto client = weak.Upgrade();
            if (client) {
                client->UpdateEditingValue(value, true);
            }
        },
        TaskExecutor::TaskType::UI, "ArkUI-XMacPushEditingValue");
}

// ---------------------------------------------------------------------------
// Real macOS TextInputConnectionImpl. Drives MacTextInputBridge instead of the
// iOS UIKit text input manager.
// ---------------------------------------------------------------------------
TextInputConnectionImpl::TextInputConnectionImpl(
    const WeakPtr<TextInputClient>& client, const RefPtr<TaskExecutor>& taskExecutor)
    : TextInputConnection(client, taskExecutor)
{}

TextInputConnectionImpl::TextInputConnectionImpl(const WeakPtr<TextInputClient>& client,
    const RefPtr<TaskExecutor>& taskExecutor, const TextInputConfiguration& config)
    : TextInputConnection(client, taskExecutor), config_(config)
{}

bool TextInputConnectionImpl::Attached()
{
    return TextInputClientHandler::GetInstance().ConnectionIsCurrent(this);
}

void TextInputConnectionImpl::Show(bool /*isFocusViewChanged*/, int32_t /*instanceId*/)
{
    MacTextInputBridge::GetInstance().Activate(client_, taskExecutor_, GetClientId(), config_.action);
}

void TextInputConnectionImpl::SetEditingState(
    const TextEditingValue& value, int32_t /*instanceId*/, bool /*needFireChangeEvent*/)
{
    // value.text is UTF-8; convert via the wide helper instead of a byte copy so
    // multi-byte CJK mirrors correctly for NSTextInputClient range queries.
    auto wide = value.GetWideText();
    std::u16string text(wide.begin(), wide.end());
    MacTextInputBridge::GetInstance().SetMirror(text, value.selection.GetStart(), value.selection.GetEnd());
}

void MacTextInputBridge::SetCaretWindowRect(double x, double y, double width, double height)
{
    caretWinX_ = x;
    caretWinY_ = y;
    caretWinWidth_ = width;
    caretWinHeight_ = height;
    hasCaretWinRect_ = true;
}

bool MacTextInputBridge::GetCaretWindowRect(double& x, double& y, double& width, double& height) const
{
    if (!hasCaretWinRect_) {
        return false;
    }
    x = caretWinX_;
    y = caretWinY_;
    width = caretWinWidth_;
    height = caretWinHeight_;
    return true;
}

void TextInputConnectionImpl::Close(int32_t /*instanceId*/)
{
    MacTextInputBridge::GetInstance().Deactivate(GetClientId());
}

void TextInputConnectionImpl::FinishComposing(int32_t /*instanceId*/)
{
    // Marked (composing) text is owned by WindowView; it is committed on the next
    // insertText: or dropped when the field loses focus via Close().
}

} // namespace OHOS::Ace::Platform
