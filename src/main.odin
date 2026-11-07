package android_test_app

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"

// headers:
// ~/Android/ndk/30.0.16248370/sources/android/native_app_glue/android_native_app_glue.h
// ~/Android/ndk/30.0.16248370/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/android/

Color :: [4]u8
Android_Color :: struct #packed {
	r: u8,
	g: u8,
	b: u8,
	a: u8,
}
/*Android_Color :: struct #packed { // `R8G8B8A8_UNORM`
	a: u8,
	b: u8,
	g: u8,
	r: u8,
}*/
droidify :: #force_inline proc(c: Color) -> Android_Color {
	//return transmute(Android_Color) c.abgr
	return transmute(Android_Color) c
}

Rectangle :: struct {
	x, y: int,
	width, height: int,
}

Canvas :: struct {
	width: int,
	height: int,
	stride: int,
	data: []Android_Color,
}

canvas_make :: proc(width, height, stride: int, allocator := context.allocator) -> Canvas {
	ensure(width <= stride)
	return { width, height, stride, make([]Android_Color, stride*height, allocator=allocator) }
}
canvas_resize :: proc(canvas: ^Canvas, width, height: int, allocator := context.allocator) {
	if width <= canvas.stride && height <= len(canvas.data)/canvas.stride {
		canvas.width = width
		canvas.height = height
	} else {
		old_width := canvas.width
		old_height := canvas.height
		old_stride := canvas.stride
		canvas.width = width
		canvas.height = height
		canvas.stride = max(canvas.width, canvas.stride)
		new_size := canvas.stride*max(canvas.height, old_height)
		new_data := make([]Android_Color, new_size, allocator=allocator)
		for y in 0..<min(old_height, height) {
			for x in 0..<min(old_width, width) {
				new_data[y*canvas.stride + x] = canvas.data[y*old_stride + x]
			}
		}
		delete(canvas.data)
		canvas.data = new_data
	}
}
canvas_put_pixel :: #force_inline proc(canvas: ^Canvas, x, y: int, color: Color) {
	canvas_put_pixel_raw(canvas, x, y, droidify(color))
}
canvas_put_pixel_raw :: proc(canvas: ^Canvas, x, y: int, color: Android_Color) {
	canvas.data[y*canvas.stride + x] = color
}
canvas_put_pixel_raw_unsafe :: proc(canvas: ^Canvas, x, y: int, color: Android_Color) #no_bounds_check {
	canvas.data[y*canvas.stride + x] = color
}
canvas_draw_pixel :: #force_inline proc(canvas: ^Canvas, x, y: int, color: Color) {
	canvas_draw_pixel_raw(canvas, x, y, droidify(color))
	
}
canvas_draw_pixel_raw :: proc(canvas: ^Canvas, x, y: int, color: Android_Color) {
	if color.a == 255 do canvas.data[y*canvas.stride + x] = color
	else {
		old_color := canvas.data[y*canvas.stride + x]
		new_color := Android_Color {
			r = (old_color.r*(255-color.a) + color.r*color.a)/255,
			g = (old_color.g*(255-color.a) + color.g*color.a)/255,
			b = (old_color.b*(255-color.a) + color.b*color.a)/255,
			a = old_color.a + (255-old_color.a)*color.a/255,
		}
		canvas.data[y*canvas.stride + x] = new_color
	}
}
canvas_draw_pixel_raw_unsafe :: proc(canvas: ^Canvas, x, y: int, color: Android_Color) #no_bounds_check {
	if color.a == 255 do canvas.data[y*canvas.stride + x] = color
	else {
		old_color := canvas.data[y*canvas.stride + x]
		new_color := Android_Color {
			r = (old_color.r*(255-color.a) + color.r*color.a)/255,
			g = (old_color.g*(255-color.a) + color.g*color.a)/255,
			b = (old_color.b*(255-color.a) + color.b*color.a)/255,
			a = old_color.a + (255-old_color.a)*color.a/255,
		}
		canvas.data[y*canvas.stride + x] = new_color
	}
}
canvas_rect_outline :: proc(canvas: ^Canvas, rectangle: Rectangle, color: Color) {
	// TODO: handle out of bounds?
	ensure(rectangle.width >= 0 && rectangle.height >= 0)
	if rectangle.x < 0 do return
	if rectangle.y < 0 do return
	if rectangle.x + rectangle.width > canvas.width do return
	if rectangle.y + rectangle.height > canvas.height do return

	ac := droidify(color)

	for x in rectangle.x..<rectangle.x+rectangle.width {
		#force_inline canvas_draw_pixel_raw(canvas, x, rectangle.y, ac)
		#force_inline canvas_draw_pixel_raw(canvas, x, rectangle.y+rectangle.height-1, ac)
	}
	for y in rectangle.y..<rectangle.y+rectangle.height {
		#force_inline canvas_draw_pixel_raw(canvas, rectangle.x, y, ac)
		#force_inline canvas_draw_pixel_raw(canvas, rectangle.x+rectangle.width-1, y, ac)
	}
}
canvas_rect_fill :: proc(canvas: ^Canvas, rectangle: Rectangle, color: Color) #no_bounds_check {
	// TODO: handle out of bounds?
	ensure(rectangle.width >= 0 && rectangle.height >= 0)
	if rectangle.x < 0 do return
	if rectangle.y < 0 do return
	if rectangle.x + rectangle.width > canvas.width do return
	if rectangle.y + rectangle.height > canvas.height do return

	ac := droidify(color)

	for y in rectangle.y..<rectangle.y+rectangle.height {
		for x in rectangle.x..<rectangle.x+rectangle.width {
			#force_inline canvas_draw_pixel_raw_unsafe(canvas, x, y, ac)
		}
	}
}
canvas_fill :: #force_inline proc(canvas: ^Canvas, color: Color) {
	canvas_rect_fill(canvas, {0, 0, canvas.width, canvas.height}, color)
}
canvas_draw_line :: proc(canvas: ^Canvas, x1, y1, x2, y2: int, color: Color) {
	// TODO: handle out of bounds?
	if x1 < 0 || x1 >= canvas.width do return
	if y1 < 0 || y1 >= canvas.height do return
	if x2 < 0 || x2 >= canvas.width do return
	if y2 < 0 || y2 >= canvas.height do return

	if x1 > x2 {
		canvas_draw_line(canvas, x2, y2, x1, y1, color)
		return
	}

	dx := x2 - x1
	dy := y2 - y1

	ac := droidify(color)

	if dx == dy {
		for i in 0..=dx {
			#force_inline canvas_draw_pixel_raw(canvas, x1+i, y1+i, ac)
		}
	} else if dx == -dy {
		for i in 0..=dx {
			#force_inline canvas_draw_pixel_raw(canvas, x1+i, y1-i, ac)
		}
	} else if dx == 0 {
		if dy > 0 {
			for y in y1..=y2 {
				#force_inline canvas_draw_pixel_raw(canvas, x1, y, ac)
			}
		} else {
			for y in y2..=y1 {
				#force_inline canvas_draw_pixel_raw(canvas, x1, y, ac)
			}
		}
	} else if dy == 0 {
		for i in 0..=dx {
			#force_inline canvas_draw_pixel_raw(canvas, x1+i, y1, ac)
		}
	} else if dx > abs(dy) {
		y_offset := dy > 0 ? 1 : -1
		dy = abs(dy)

		D := 2*dy - dx

		y := y1
		for x in x1..=x2 {
			#force_inline canvas_draw_pixel_raw(canvas, x, y, ac)
			if D > 0 {
				y += y_offset
				D += 2*(dy - dx)
			} else {
				D += 2*dy
			}
		}
	} else {
		pos_slope := dy > 0
		dy = abs(dy)

		D := 2*dx - dy

		if pos_slope {
			x := x1
			for y in y1..=y2 {
				#force_inline canvas_draw_pixel_raw(canvas, x, y, ac)
				if D > 0 {
					x += 1
					D += 2*(dx - dy)
				} else {
					D += 2*dx
				}
			}
		} else {
			x := x2
			for y in y2..=y1 {
				#force_inline canvas_draw_pixel_raw(canvas, x, y, ac)
				if D > 0 {
					x -= 1
					D += 2*(dx - dy)
				} else {
					D += 2*dx
				}
			}
		}
	}
}

State :: struct {
	bg_color: Color,
	canvas: Canvas,
	last_touch_pos: [2]int,
}

main :: proc() {
	context.logger = log.create_console_logger(ident="android-test-app")

	fmt.println("Hello from main, started with", os.args)
	log.info("Logging, does it work..?")

	state := State{bg_color = {0xF0, 0xC0, 0x42, 0xFF}, canvas = canvas_make(100, 100, 100)}
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
		w, h := int(android.ANativeWindow_getWidth(app.window)), int(android.ANativeWindow_getHeight(app.window))
		log.info("Window size:", w, h)
		state := (^State)(app.userData)
		canvas_resize(&state.canvas, w, h)
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
		height := android.ANativeWindow_getHeight(app.window)
		x := clamp(i32(android.AMotionEvent_getX(event, 0)), 0, width)
		y := clamp(i32(android.AMotionEvent_getY(event, 0)), 0, height)

		state := (^State)(app.userData)
		state.bg_color.g = u8(x*255/width)
		state.bg_color.b = u8(y*255/height)
		state.last_touch_pos = { int(x), int(y) }
		//fmt.println(state.last_touch_pos)
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

	canvas_resize(&state.canvas, int(buffer.width), int(buffer.height))
	//fmt.println("drawing:", state.canvas.width, state.canvas.height)
	canvas_fill(&state.canvas, state.bg_color)
	canvas_rect_fill(&state.canvas, {10,16,64,128}, {0,100,200,255})
	canvas_rect_outline(&state.canvas, {64,128,256,512}, {})
	canvas_draw_line(
		&state.canvas,
		state.canvas.width/2, state.canvas.height/2,
		state.last_touch_pos.x, state.last_touch_pos.y,
		{0,25,0,0},//{0,0,0,255},
	)

	pixels := ([^]Android_Color)(buffer.bits)
	for y in 0..<state.canvas.height {
		for x in 0..<state.canvas.width {
			pixels[y*int(buffer.stride) + x] = state.canvas.data[y*state.canvas.stride + x]
		}
	}
}
