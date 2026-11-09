package android_test_app

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"

// headers:
// ~/Android/ndk/30.0.16248370/sources/android/native_app_glue/android_native_app_glue.h
// ~/Android/ndk/30.0.16248370/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/android/

Color :: [4]u8

Rectangle :: struct {
	x, y: int,
	width, height: int,
}

Canvas :: struct {
	width: int,
	height: int,
	stride: int,
	data: []Color,
}

canvas_make :: proc(width, height, stride: int, allocator := context.allocator) -> Canvas {
	ensure(width <= stride)
	return { width, height, stride, make([]Color, stride*height, allocator=allocator) }
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
		new_data := make([]Color, new_size, allocator=allocator)
		for y in 0..<min(old_height, height) {
			for x in 0..<min(old_width, width) {
				new_data[y*canvas.stride + x] = canvas.data[y*old_stride + x]
			}
		}
		delete(canvas.data)
		canvas.data = new_data
	}
}
canvas_put_pixel :: proc(canvas: ^Canvas, x, y: int, color: Color) {
	canvas.data[y*canvas.stride + x] = color
}
canvas_put_pixel_unsafe :: proc(canvas: ^Canvas, x, y: int, color: Color) #no_bounds_check {
	canvas.data[y*canvas.stride + x] = color
}
color_blend :: #force_inline proc(bg_color, fg_color: Color) -> Color {
	bgi := cast([4]int)bg_color
	fgi := cast([4]int)fg_color
	return {
		u8((bgi.r*(255-fgi.a) + fgi.r*fgi.a)/255),
		u8((bgi.g*(255-fgi.a) + fgi.g*fgi.a)/255),
		u8((bgi.b*(255-fgi.a) + fgi.b*fgi.a)/255),
		bg_color.a + u8((255-bgi.a)*fgi.a/255),
	}
}
canvas_draw_pixel :: proc(canvas: ^Canvas, x, y: int, color: Color) {
	if color.a == 255 do canvas.data[y*canvas.stride + x] = color
	else if color.a == 0 do return
	else {
		canvas.data[y*canvas.stride + x] = color_blend(
			canvas.data[y*canvas.stride + x],
			color,
		)
	}
}
canvas_draw_pixel_unsafe :: proc(canvas: ^Canvas, x, y: int, color: Color) #no_bounds_check {
	if color.a == 255 do canvas.data[y*canvas.stride + x] = color
	else if color.a == 0 do return
	else {
		canvas.data[y*canvas.stride + x] = color_blend(
			canvas.data[y*canvas.stride + x],
			color,
		)
	}
}
canvas_rect_outline :: proc(canvas: ^Canvas, rectangle: Rectangle, color: Color) {
	// TODO: handle out of bounds?
	ensure(rectangle.width >= 0 && rectangle.height >= 0)
	if rectangle.x < 0 do return
	if rectangle.y < 0 do return
	if rectangle.x + rectangle.width > canvas.width do return
	if rectangle.y + rectangle.height > canvas.height do return

	for x in rectangle.x..<rectangle.x+rectangle.width {
		#force_inline canvas_draw_pixel(canvas, x, rectangle.y, color)
		#force_inline canvas_draw_pixel(canvas, x, rectangle.y+rectangle.height-1, color)
	}
	for y in rectangle.y..<rectangle.y+rectangle.height {
		#force_inline canvas_draw_pixel(canvas, rectangle.x, y, color)
		#force_inline canvas_draw_pixel(canvas, rectangle.x+rectangle.width-1, y, color)
	}
}
canvas_rect_fill :: proc(canvas: ^Canvas, rectangle: Rectangle, color: Color) #no_bounds_check {
	// TODO: handle out of bounds?
	ensure(rectangle.width >= 0 && rectangle.height >= 0)
	if rectangle.x < 0 do return
	if rectangle.y < 0 do return
	if rectangle.x + rectangle.width > canvas.width do return
	if rectangle.y + rectangle.height > canvas.height do return

	for y in rectangle.y..<rectangle.y+rectangle.height {
		for x in rectangle.x..<rectangle.x+rectangle.width {
			#force_inline canvas_draw_pixel_unsafe(canvas, x, y, color)
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

	if dx == dy {
		for i in 0..=dx {
			#force_inline canvas_draw_pixel(canvas, x1+i, y1+i, color)
		}
	} else if dx == -dy {
		for i in 0..=dx {
			#force_inline canvas_draw_pixel(canvas, x1+i, y1-i, color)
		}
	} else if dx == 0 {
		if dy > 0 {
			for y in y1..=y2 {
				#force_inline canvas_draw_pixel(canvas, x1, y, color)
			}
		} else {
			for y in y2..=y1 {
				#force_inline canvas_draw_pixel(canvas, x1, y, color)
			}
		}
	} else if dy == 0 {
		for i in 0..=dx {
			#force_inline canvas_draw_pixel(canvas, x1+i, y1, color)
		}
	} else if dx > abs(dy) {
		y_offset := dy > 0 ? 1 : -1
		dy = abs(dy)

		D := 2*dy - dx

		y := y1
		for x in x1..=x2 {
			#force_inline canvas_draw_pixel(canvas, x, y, color)
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
				#force_inline canvas_draw_pixel(canvas, x, y, color)
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
				#force_inline canvas_draw_pixel(canvas, x, y, color)
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

floor := [?][3][3]f64 {
	{
		{-2.0, 2.0, 2.0 },
		{ 2.0, 2.0, 2.0 },
		{ 2.0, 2.0,-2.0 },
	},
	{
		{-2.0, 2.0, 2.0 },
		{ 2.0, 2.0,-2.0 },
		{-2.0, 2.0,-2.0 },
	},
}

cube := [?][3][3]f64 {
	{ // front face
		{ 1.0, 1.0,-1.0 },
		{ 1.0,-1.0,-1.0 },
		{-1.0, 1.0,-1.0 },
	},
	{
		{-1.0, 1.0,-1.0 },
		{ 1.0,-1.0,-1.0 },
		{-1.0,-1.0,-1.0 },
	},
	{ // back face
		{ 1.0, 1.0, 1.0 },
		{-1.0, 1.0, 1.0 },
		{ 1.0,-1.0, 1.0 },
	},
	{
		{-1.0, 1.0, 1.0 },
		{-1.0,-1.0, 1.0 },
		{ 1.0,-1.0, 1.0 },
	},
	{ // right face
		{ 1.0, 1.0,-1.0 },
		{ 1.0, 1.0, 1.0 },
		{ 1.0,-1.0,-1.0 },
	},
	{
		{ 1.0,-1.0,-1.0 },
		{ 1.0, 1.0, 1.0 },
		{ 1.0,-1.0, 1.0 },
	},
	{ // left face
		{-1.0, 1.0,-1.0 },
		{-1.0,-1.0,-1.0 },
		{-1.0, 1.0, 1.0 },
	},
	{
		{-1.0,-1.0,-1.0 },
		{-1.0,-1.0, 1.0 },
		{-1.0, 1.0, 1.0 },
	},
	{ // top face
		{-1.0,-1.0,-1.0 },
		{ 1.0,-1.0,-1.0 },
		{ 1.0,-1.0, 1.0 },
	},
	{
		{-1.0,-1.0,-1.0 },
		{ 1.0,-1.0, 1.0 },
		{-1.0,-1.0, 1.0 },
	},
	{ // bottom face
		{-1.0, 1.0,-1.0 },
		{ 1.0, 1.0, 1.0 },
		{ 1.0, 1.0,-1.0 },
	},
	{
		{-1.0, 1.0,-1.0 },
		{-1.0, 1.0, 1.0 },
		{ 1.0, 1.0, 1.0 },
	},
}

canvas_outline_triangle :: proc(canvas: ^Canvas, triangle: [3][2]int, color: Color) {
	// TODO: only render counterclockwise triangles?
	canvas_draw_line(canvas, triangle[0].x, triangle[0].y, triangle[1].x, triangle[1].y, color)
	canvas_draw_line(canvas, triangle[1].x, triangle[1].y, triangle[2].x, triangle[2].y, color)
	canvas_draw_line(canvas, triangle[2].x, triangle[2].y, triangle[0].x, triangle[0].y, color)
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

	float_to_screen :: proc(w,h:int, xf,yf: f64) -> (xi,yi: int) {
		// TODO: 1 -> w or h, it should map to w-1 or h-1?
		return int((xf+1)/2*f64(w)), int((yf+1)/2*f64(h))
	}

	canvas_resize(&state.canvas, int(buffer.width), int(buffer.height))
	//fmt.println("drawing:", state.canvas.width, state.canvas.height)
	canvas_fill(&state.canvas, {150,150,150,255}/*state.bg_color*/)

	pos_ratio := ([2]f64)(state.last_touch_pos)/[2]f64{f64(state.canvas.width),f64(state.canvas.height)}
	theta_y := (-math.TAU/8)*(1-pos_ratio.x) + (math.TAU/8)*pos_ratio.x
	theta_x := (-math.TAU/8)*(1-pos_ratio.y) + (math.TAU/8)*pos_ratio.y

	trans := linalg.matrix4_translate_f64({-0.5, 4, -3})
	rot_y := linalg.matrix4_rotate_f64(theta_y, {0,1,0})
	rot_x := linalg.matrix4_rotate_f64(theta_x, {1,0,0})
	view := linalg.matrix4_look_at_f64({0,0,-16}, {-0.5, 4, -3}, {0,1,0})
	proj := linalg.matrix4_perspective_f64(math.TAU/6, f64(state.canvas.width)/f64(state.canvas.height), 1, 1000)
	final_mat := proj*view*trans*rot_x*rot_y

	for triag, i in cube {
		triag_4d := [3][4]f64 {
			{ triag[0].x, triag[0].y, triag[0].z, 1 },
			{ triag[1].x, triag[1].y, triag[1].z, 1 },
			{ triag[2].x, triag[2].y, triag[2].z, 1 },
		}
		projected := [3][4]f64 {
			final_mat*triag_4d[0],
			final_mat*triag_4d[1],
			final_mat*triag_4d[2],
		}
		transformed := [3][3]f64 {
			projected[0].xyz/projected[0].w,
			projected[1].xyz/projected[1].w,
			projected[2].xyz/projected[2].w,
		}
		w, h := state.canvas.width, state.canvas.height
		x0, y0 := float_to_screen(w, h, transformed[0].x, transformed[0].y)
		x1, y1 := float_to_screen(w, h, transformed[1].x, transformed[1].y)
		x2, y2 := float_to_screen(w, h, transformed[2].x, transformed[2].y)
		screen := [3][2]int {{x0,y0},{x1,y1},{x2,y2}}
		r := u8(20 + 200*i/(len(cube)-1))
		g := u8(200 - 200*i/(len(cube)-1))
		if i < 2 do canvas_outline_triangle(&state.canvas, screen, state.bg_color)
		else do canvas_outline_triangle(&state.canvas, screen, {r, g, 150, 255})
	}
	for triag in floor {
		triag_4d := [3][4]f64 {
			{ triag[0].x, triag[0].y, triag[0].z, 1 },
			{ triag[1].x, triag[1].y, triag[1].z, 1 },
			{ triag[2].x, triag[2].y, triag[2].z, 1 },
		}
		projected := [3][4]f64 {
			final_mat*triag_4d[0],
			final_mat*triag_4d[1],
			final_mat*triag_4d[2],
		}
		transformed := [3][3]f64 {
			projected[0].xyz/projected[0].w,
			projected[1].xyz/projected[1].w,
			projected[2].xyz/projected[2].w,
		}
		w, h := state.canvas.width, state.canvas.height
		x0, y0 := float_to_screen(w, h, transformed[0].x, transformed[0].y)
		x1, y1 := float_to_screen(w, h, transformed[1].x, transformed[1].y)
		x2, y2 := float_to_screen(w, h, transformed[2].x, transformed[2].y)
		screen := [3][2]int {{x0,y0},{x1,y1},{x2,y2}}
		canvas_outline_triangle(&state.canvas, screen, {255,255,255,255})
	}

	canvas_rect_fill(&state.canvas, {10,16,64,128}, {0,100,200,255})
	canvas_rect_outline(&state.canvas, {64,128,256,512}, {0,0,0,255})
	canvas_draw_line(
		&state.canvas,
		state.canvas.width/2, state.canvas.height/2,
		state.last_touch_pos.x, state.last_touch_pos.y,
		{0,0,0,255},
	)

	pixels := ([^]Color)(buffer.bits)
	for y in 0..<state.canvas.height {
		for x in 0..<state.canvas.width {
			pixels[y*int(buffer.stride) + x] = state.canvas.data[y*state.canvas.stride + x]
		}
	}
}
