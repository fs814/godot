/**************************************************************************/
/*  libgodot_macos.mm                                                     */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "os_macos.h"

#include "core/extension/godot_instance.h"
#include "core/extension/libgodot.h"
#include "main/main.h"

#include <cstring> // strcmp (fs patch: --embedded detection)

static OS_MacOS *os = nullptr;

static GodotInstance *instance = nullptr;

GDExtensionObjectPtr libgodot_create_godot_instance(int p_argc, char *p_argv[], GDExtensionInitializationFunction p_init_func) {
	ERR_FAIL_COND_V_MSG(instance != nullptr, nullptr, "Only one Godot Instance may be created.");

	uint32_t remaining_args = p_argc - 1;

	// fs patch: allow embedding into a host app (e.g. Emacs) that displays the
	// engine's CAContext via CALayerHost.  When "--embedded" is passed, use
	// OS_MacOS_Embedded -- its ctor registers the "embedded" display driver, and
	// it does NOT create/own an NSApplication -- instead of OS_MacOS_NSApp, which
	// calls [NSApp run] (never returns) and is unusable when the host owns NSApp.
	// The embedded display server is TOOLS_ENABLED-only.
	bool is_embedded = false;
	for (int i = 1; i < p_argc; i++) {
		if (p_argv[i] && strcmp("--embedded", p_argv[i]) == 0) {
			is_embedded = true;
			break;
		}
	}

#ifdef TOOLS_ENABLED
	if (is_embedded) {
		os = new OS_MacOS_Embedded(p_argv[0], remaining_args, remaining_args > 0 ? &p_argv[1] : nullptr);
	} else
#endif
	{
		os = new OS_MacOS_NSApp(p_argv[0], remaining_args, remaining_args > 0 ? &p_argv[1] : nullptr);
	}

	@autoreleasepool {
		Error err = Main::setup(p_argv[0], remaining_args, remaining_args > 0 ? &p_argv[1] : nullptr, false);
		if (err != OK) {
			return nullptr;
		}

		instance = memnew(GodotInstance);
		if (!instance->initialize(p_init_func)) {
			memdelete(instance);
			instance = nullptr;
			return nullptr;
		}

		return (GDExtensionObjectPtr)instance;
	}
}

void libgodot_destroy_godot_instance(GDExtensionObjectPtr p_godot_instance) {
	GodotInstance *godot_instance = (GodotInstance *)p_godot_instance;
	if (instance == godot_instance) {
		godot_instance->stop();
		memdelete(godot_instance);
		// Note: When Godot Engine supports reinitialization, clear the instance pointer here.
		//instance = nullptr;
		Main::cleanup();
	}
}

// fs patch: thin C exports so an in-process host (Emacs xwidget shim) can drive
// the instance and fetch the embedded CAContext id WITHOUT going through the
// GDExtension method-bind ABI (which requires exact per-version method hashes).
// These operate on the single static `instance` created above.
#include "servers/display/display_server.h"
#include "display_server_macos_embedded.h" // fs patch: _window_set_size
#include "core/input/input.h"              // fs patch: input injection
#include "core/input/input_event.h"        // fs patch: input injection
#include "key_mapping_macos.h"             // fs patch: macOS virtual keycode -> Key
#import <AppKit/AppKit.h>                  // fs patch: NSEventModifierFlag* for modifiers

extern "C" __attribute__((visibility("default"))) bool libgodot_instance_start(void) {
	return instance ? instance->start() : false;
}

extern "C" __attribute__((visibility("default"))) bool libgodot_instance_iteration(void) {
	// Returns true when the engine requests exit.
	return instance ? instance->iteration() : true;
}

extern "C" __attribute__((visibility("default"))) bool libgodot_instance_is_started(void) {
	return instance ? instance->is_started() : false;
}

// The CAContext id of the embedded display server's main window (0 if absent).
extern "C" __attribute__((visibility("default"))) uint32_t libgodot_get_context_id(void) {
	DisplayServer *ds = DisplayServer::get_singleton();
	if (!ds) {
		return 0;
	}
	return (uint32_t)ds->window_get_native_handle(DisplayServerEnums::WINDOW_HANDLE, DisplayServerEnums::MAIN_WINDOW_ID);
}

// The embedded display server's CAMetalLayer.  In-process hosts can mount this
// layer directly instead of using CALayerHost/CAContext remoting.
extern "C" __attribute__((visibility("default"))) void *libgodot_get_window_view(void) {
	DisplayServer *ds = DisplayServer::get_singleton();
	if (!ds) {
		return nullptr;
	}
	return (void *)(uintptr_t)ds->window_get_native_handle(DisplayServerEnums::WINDOW_VIEW, DisplayServerEnums::MAIN_WINDOW_ID);
}

// Resize the embedded main window (pixels).  The public window_set_size on the
// embedded DS is a no-op ("Embedded window can't be resized" -- the editor host
// normally drives sizing via set_state); call the real internal _window_set_size.
extern "C" __attribute__((visibility("default"))) void libgodot_window_set_size(int p_w, int p_h) {
	DisplayServer *ds = DisplayServer::get_singleton();
	if (ds && ds->get_name() == "embedded") {
		static_cast<DisplayServerMacOSEmbedded *>(ds)->_window_set_size(Size2i(p_w, p_h), DisplayServerEnums::MAIN_WINDOW_ID);
	}
}

// fs patch: input injection.  For an in-process embedding there is no editor
// debugger connection forwarding input (see platform/macos/embedded_debugger.mm
// EmbeddedDebugger::_msg_event), so the host (Emacs) must feed events directly.
// These build real Godot InputEvents and hand them to Input::parse_input_event
// (thread-safe: _THREAD_SAFE_METHOD_; buffered events flush on the game thread
// via DisplayServerMacOSEmbedded::process_events).  Coordinates arrive in view
// POINTS and are scaled to render pixels here (matching embedded_debugger.mm),
// so the host does not need to pre-scale.  Modifier bits: 1=shift 2=ctrl 4=alt
// 8=cmd.  Mouse button: 1=left 2=right 3=middle (Godot MouseButton enum).

static float _libgodot_render_scale() {
	DisplayServer *ds = DisplayServer::get_singleton();
	if (ds && ds->get_name() == "embedded") {
		return static_cast<DisplayServerMacOSEmbedded *>(ds)->screen_get_max_scale();
	}
	return 1.0f;
}

static void _libgodot_apply_mods(const Ref<InputEventWithModifiers> &p_ev, int p_mods) {
	p_ev->set_shift_pressed((p_mods & 1) != 0);
	p_ev->set_ctrl_pressed((p_mods & 2) != 0);
	p_ev->set_alt_pressed((p_mods & 4) != 0);
	p_ev->set_meta_pressed((p_mods & 8) != 0);
}

extern "C" __attribute__((visibility("default"))) void libgodot_input_mouse_button(float p_x, float p_y, int p_button, bool p_pressed, int p_button_mask, int p_mods, bool p_double_click) {
	Input *input = Input::get_singleton();
	if (!input) {
		return;
	}
	const float scale = _libgodot_render_scale();
	Ref<InputEventMouseButton> mb;
	mb.instantiate();
	mb->set_window_id(DisplayServerEnums::MAIN_WINDOW_ID);
	_libgodot_apply_mods(mb, p_mods);
	Vector2 pos = Vector2(p_x, p_y) * scale;
	mb->set_position(pos);
	mb->set_global_position(pos);
	mb->set_button_index((MouseButton)p_button);
	mb->set_button_mask((BitField<MouseButtonMask>)p_button_mask);
	mb->set_pressed(p_pressed);
	mb->set_double_click(p_double_click);
	input->set_mouse_position(pos);
	input->parse_input_event(mb);
}

extern "C" __attribute__((visibility("default"))) void libgodot_input_mouse_motion(float p_x, float p_y, float p_rel_x, float p_rel_y, int p_button_mask, int p_mods) {
	Input *input = Input::get_singleton();
	if (!input) {
		return;
	}
	const float scale = _libgodot_render_scale();
	Ref<InputEventMouseMotion> mm;
	mm.instantiate();
	mm->set_window_id(DisplayServerEnums::MAIN_WINDOW_ID);
	_libgodot_apply_mods(mm, p_mods);
	Vector2 pos = Vector2(p_x, p_y) * scale;
	mm->set_position(pos);
	mm->set_global_position(pos);
	mm->set_relative(Vector2(p_rel_x, p_rel_y) * scale);
	mm->set_button_mask((BitField<MouseButtonMask>)p_button_mask);
	input->set_mouse_position(pos);
	input->parse_input_event(mm);
}

extern "C" __attribute__((visibility("default"))) void libgodot_input_mouse_wheel(float p_x, float p_y, float p_delta, int p_mods) {
	Input *input = Input::get_singleton();
	if (!input || p_delta == 0.0f) {
		return;
	}
	const float scale = _libgodot_render_scale();
	Vector2 pos = Vector2(p_x, p_y) * scale;
	// WHEEL_UP for positive delta, WHEEL_DOWN for negative.  A wheel event is a
	// press immediately followed by a release (matching the platform behavior).
	MouseButton btn = p_delta > 0.0f ? MouseButton::WHEEL_UP : MouseButton::WHEEL_DOWN;
	for (int press = 1; press >= 0; press--) {
		Ref<InputEventMouseButton> mb;
		mb.instantiate();
		mb->set_window_id(DisplayServerEnums::MAIN_WINDOW_ID);
		_libgodot_apply_mods(mb, p_mods);
		mb->set_position(pos);
		mb->set_global_position(pos);
		mb->set_button_index(btn);
		mb->set_factor(ABS(p_delta));
		mb->set_pressed(press == 1);
		input->parse_input_event(mb);
	}
}

extern "C" __attribute__((visibility("default"))) void libgodot_input_key(int p_macos_keycode, bool p_pressed, int p_mods, uint32_t p_unicode) {
	Input *input = Input::get_singleton();
	if (!input) {
		return;
	}
	unsigned int macos_state = 0;
	if (p_mods & 1) { macos_state |= NSEventModifierFlagShift; }
	if (p_mods & 2) { macos_state |= NSEventModifierFlagControl; }
	if (p_mods & 4) { macos_state |= NSEventModifierFlagOption; }
	if (p_mods & 8) { macos_state |= NSEventModifierFlagCommand; }

	Ref<InputEventKey> k;
	k.instantiate();
	k->set_window_id(DisplayServerEnums::MAIN_WINDOW_ID);
	_libgodot_apply_mods(k, p_mods);
	k->set_pressed(p_pressed);
	k->set_keycode(KeyMappingMacOS::remap_key((unsigned int)p_macos_keycode, macos_state, false));
	k->set_physical_keycode(KeyMappingMacOS::translate_key((unsigned int)p_macos_keycode));
	k->set_key_label(KeyMappingMacOS::remap_key((unsigned int)p_macos_keycode, macos_state, true));
	k->set_unicode((char32_t)p_unicode);
	k->set_location(KeyMappingMacOS::translate_location((unsigned int)p_macos_keycode));
	input->parse_input_event(k);
}
