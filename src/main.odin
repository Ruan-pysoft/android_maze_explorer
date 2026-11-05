package android_test_app

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"

// headers:
// ~/Android/ndk/30.0.16248370/sources/android/native_app_glue/android_native_app_glue.h
// ~/Android/ndk/30.0.16248370/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/android/

Color :: [4]u8
Android_Color :: struct #packed { // `R8G8B8A8_UNORM`
	a: u8,
	b: u8,
	g: u8,
	r: u8,
}
droidify :: #force_inline proc(c: Color) -> Android_Color {
	return transmute(Android_Color) c.abgr
}

State :: struct {
	color: Color,
}

main :: proc() {
	context.logger = log.create_console_logger(ident="android-test-app")

	fmt.println("Hello from main, started with", os.args)

	state := State{color = {0xF0, 0xC0, 0x42, 0xFF}}

	app := glue.app()
	app.userData = &state
	app.onAppCmd = on_app_cmd
	app.onInputEvent = on_input_event

	for app.destroyRequested == 0 {
		source: ^glue.android_poll_source
		if android.ALooper_pollOnce(-1, nil, nil, (^rawptr)(&source)) >= 0 && source != nil {
			source.process(app, source)
		}
	}
	log.info("finishing up...")
}

on_app_cmd :: proc(app: ^glue.android_app, cmd: i32) {
	switch cmd {
	case glue.APP_CMD_INIT_WINDOW, glue.APP_CMD_WINDOW_RESIZED, glue.APP_CMD_WINDOW_REDRAW_NEEDED:
		draw(app)
	case glue.APP_CMD_DESTROY:
		log.info("destroy command sent?")
	}
}

on_input_event :: proc(app: ^glue.android_app, event: ^android.AInputEvent) -> i32 {
	if android.AInputEvent_getType(event) != .MOTION || app.window == nil {
		return 0
	}

	#partial switch android.AMotionEvent_getAction(event).action {
	case .DOWN, .MOVE:
		width := android.ANativeWindow_getWidth(app.window)
		height := android.ANativeWindow_getWidth(app.window)
		x := clamp(i32(android.AMotionEvent_getX(event, 0)), 0, width)
		y := clamp(i32(android.AMotionEvent_getY(event, 0)), 0, height)

		state := (^State)(app.userData)
		state.color.g = u8(x*255/width)
		state.color.b = u8(y*255/height)
		draw(app)
	}
	return 1
}

draw :: proc(app: ^glue.android_app) {
	if app.window == nil do return

	state := (^State)(app.userData)

	android.ANativeWindow_setBuffersGeometry(app.window, 0, 0, .R8G8B8A8_UNORM)
	buffer: android.ANativeWindow_Buffer
	if android.ANativeWindow_lock(app.window, &buffer, nil) != 0 {
		return
	}
	defer android.ANativeWindow_unlockAndPost(app.window)

	acolor := droidify(state.color)
	pixels := ([^]Android_Color)(buffer.bits)
	for y in 0..<buffer.height {
		row := pixels[y*buffer.stride:][:buffer.width]
		for &pixel in row {
			pixel = acolor
		}
	}
}
