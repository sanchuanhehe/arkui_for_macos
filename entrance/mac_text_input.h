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

#ifndef FOUNDATION_ACE_ADAPTER_MACOS_ENTRANCE_MAC_TEXT_INPUT_H
#define FOUNDATION_ACE_ADAPTER_MACOS_ENTRANCE_MAC_TEXT_INPUT_H

#include <functional>
#include <string>

#include "base/memory/referenced.h"
#include "base/thread/task_executor.h"
#include "core/common/ime/text_input_action.h"
#include "core/common/ime/text_input_client.h"

namespace OHOS::Ace::Platform {

// Bridge between AppKit's NSTextInputClient (implemented on WindowView) and the
// focused ArkUI TextInputClient (a TextFieldPattern). The mac
// TextInputConnectionImpl activates/deactivates the bridge as fields gain/lose
// focus; WindowView routes committed IME text and edit commands through it.
//
// All public mutators are safe to call from the AppKit main thread; the actual
// client calls are marshalled onto the ArkUI UI task queue via the connection's
// TaskExecutor.
class MacTextInputBridge {
public:
    static MacTextInputBridge& GetInstance();

    void Activate(const WeakPtr<TextInputClient>& client, const RefPtr<TaskExecutor>& taskExecutor, int32_t clientId,
        TextInputAction action);
    // Only deactivates when clientId matches the active connection, so a stale
    // Close() from a previously-focused field cannot tear down the current one.
    void Deactivate(int32_t clientId);
    bool IsActive() const
    {
        return active_;
    }

    // Called from WindowView (AppKit main thread).
    void CommitText(const std::u16string& text);
    void DeleteBackward(int32_t count);
    void PerformAction();
    // Keep the shadow caret in sync when the field's caret moves via arrow keys /
    // Home / End (whose actual movement is driven by ArkUI's key handling). Without
    // this the next insertion would land at a stale offset.
    void SetCaret(int32_t caret);

    // Caret bounding box in ArkUI window pixels (top-left origin), pushed from the
    // focused TextField so NSTextInputClient firstRectForCharacterRange: can anchor
    // the IME candidate window at the caret instead of the window corner.
    void SetCaretWindowRect(double x, double y, double width, double height);
    bool GetCaretWindowRect(double& x, double& y, double& width, double& height) const;

    // Mirror of the field's current text/selection, kept in sync from
    // SetEditingState(); used to answer NSTextInputClient range queries and as the
    // base for the next full editing value pushed to the field.
    void SetMirror(const std::u16string& text, int32_t selStart, int32_t selEnd);
    const std::u16string& GetMirror() const
    {
        return text_;
    }
    int32_t GetSelStart() const
    {
        return caret_;
    }
    int32_t GetSelEnd() const
    {
        return caret_;
    }

private:
    // Push the full editing value (text + caret), matching how the iOS adapter
    // drives the CROSS_PLATFORM/IOS_PLATFORM TextInput so the caret tracks edits.
    void PushEditingValue(const std::u16string& appendText, bool isDelete);

    bool active_ = false;
    int32_t clientId_ = -1;
    TextInputAction action_ = TextInputAction::UNSPECIFIED;
    WeakPtr<TextInputClient> client_;
    RefPtr<TaskExecutor> taskExecutor_;
    // Authoritative editing state held on the platform side (UTF-16 code units,
    // matching ArkUI's TextSelection offsets). caret_ is a collapsed selection.
    std::u16string text_;
    int32_t caret_ = 0;

    // Caret rect in ArkUI window pixels (top-left origin); WindowView converts to
    // screen points for the IME candidate window.
    double caretWinX_ = 0.0;
    double caretWinY_ = 0.0;
    double caretWinWidth_ = 0.0;
    double caretWinHeight_ = 0.0;
    bool hasCaretWinRect_ = false;
};

} // namespace OHOS::Ace::Platform

#endif // FOUNDATION_ACE_ADAPTER_MACOS_ENTRANCE_MAC_TEXT_INPUT_H
