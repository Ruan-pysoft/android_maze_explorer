package android_maze_explorer

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/android"
import glue "core:sys/android/native_app_glue"
import "core:time"

THREEDEE_GRAPHICS_SCALE :: 2

State :: struct {
	app_has_been_init: bool,
	should_quit: bool,
	last_frame_time_nanos: i64,
	last_draw_nanos: time.Duration,

	ctx: runtime.Context,

	last_touch_pos: [2]int,

	window_size: [2]int,
	window_size_changed: bool,

	canvas3d: Canvas3D,

	wood_block_texture: Image,
}

Image :: struct {
	data: []Color,
	w, h: int,
}

main :: proc() {
	context.logger = log.create_console_logger(ident="android-maze-explorer")

	state: State
	state.ctx = context

	raw_img, err := os.read_entire_file(
		"/android_asset/wood_block.bmp",
		context.allocator,
	)
	if err != nil {
		// TODO: display error somehow?
		log.panicf("Failed reading texture file: %v", err)
	}
	raw_pixels := transmute([]Color) runtime.Raw_Slice {
		raw_data(raw_img[len(raw_img)-257:len(raw_img)-1]),
		64,
	}
	for &pixel in raw_pixels {
		pixel = pixel.abgr
	}
	state.wood_block_texture = Image {
		data = raw_pixels,
		w = 8,
		h = 8,
	}
	ensure(len(state.wood_block_texture.data) == state.wood_block_texture.w*state.wood_block_texture.h)

	app := glue.app()
	app.userData = &state
	app.onAppCmd = on_app_cmd
	app.onInputEvent = auto_cast on_input_event

	for app.destroyRequested == 0 && !state.should_quit && !state.app_has_been_init {
		source: ^glue.android_poll_source
		if android.ALooper_pollOnce(
			-1,
			nil,
			nil,
			(^rawptr)(&source),
		) >= 0 && source != nil {
			source.process(app, source)
		}
	}
	for app.destroyRequested == 0 && !state.should_quit {
		for app.destroyRequested == 0 && !state.should_quit {
			source: ^glue.android_poll_source
			poll_res := android.ALooper_pollOnce(
				0,
				nil,
				nil,
				(^rawptr)(&source),
			)
			if poll_res >= 0 && source != nil {
				source.process(app, source)
			} else if poll_res < 0 do break
		}

		time_nsec := time.tick_now()._nsec
		dt_nsec := time_nsec - state.last_frame_time_nanos
		state.last_frame_time_nanos = time_nsec

		process(app, &state, dt_nsec)
	}
}

frame_cb :: proc"c"(frame_time_nanos: i64, data: rawptr) {
	app := cast(^glue.android_app) data
	state := cast(^State) app.userData
	context = state.ctx
	defer android.ALooper_wake(app.looper)
	defer android.AChoreographer_postFrameCallback64(
		android.AChoreographer_getInstance(),
		frame_cb,
		app,
	)
	frame_length_nanos := frame_time_nanos - state.last_frame_time_nanos
	state.last_frame_time_nanos = frame_time_nanos

	process(app, state, frame_length_nanos)
}

process :: proc(app: ^glue.android_app, state: ^State, dt_nsec: i64) {
	draw(app, state)
}

on_app_cmd :: proc(app: ^glue.android_app, cmd: i32) {
	state := (^State)(app.userData)
	switch cmd {
	case glue.APP_CMD_INIT_WINDOW, glue.APP_CMD_WINDOW_RESIZED, glue.APP_CMD_WINDOW_REDRAW_NEEDED:
		w, h := int(android.ANativeWindow_getWidth(app.window)), int(android.ANativeWindow_getHeight(app.window))
		log.debug("Window size changed to:", w, h)
		if state.window_size != {w, h} {
			state.window_size = {w, h}
			state.window_size_changed = true
		}
	case glue.APP_CMD_DESTROY:
		log.info("destroy command sent")
		state := (^State)(app.userData)
		state.should_quit = true
	}
	if cmd == glue.APP_CMD_INIT_WINDOW {
		state.app_has_been_init = true
	}
}

on_input_event :: proc(
	app: ^glue.android_app,
	event: ^android.AInputEvent,
) -> (handled: b32) {
	if android.AInputEvent_getType(event) != .MOTION || app.window == nil {
		return false
	}

	#partial switch android.AMotionEvent_getAction(event).action {
	case .DOWN, .MOVE:
		state := (^State)(app.userData)

		w, h := int(android.ANativeWindow_getWidth(app.window)), int(android.ANativeWindow_getHeight(app.window))
		state.last_touch_pos = {
			int(android.AMotionEvent_getX(event, 0)),
			int(android.AMotionEvent_getY(event, 0)),
		}
		state.last_touch_pos = {
			clamp(state.last_touch_pos.x, 0, w),
			clamp(state.last_touch_pos.y, 0, h),
		}
	}
	return true
}

transform :: proc(vertex: [3]f64, by: matrix[4, 4]f64) -> [3]f64 {
	return (by*[4]f64{vertex.x, vertex.y, vertex.z, 1}).xyz
}
project_to_screenspace :: proc(vertex: [3]f64, pers: matrix[4, 4]f64) -> [3]f64 {
	transformed := pers*[4]f64{vertex.x, vertex.y, vertex.z, 1}
	return transformed.xyz/transformed.w
}
draw_triangle_colored :: proc(canvas: ^Canvas3D, triangle: [3][3]f64, colors: [3]Color) -> [3][2]int {
	float_to_screen :: proc(w,h:int, posf:[2]f64) -> (posi: [2]int) {
		// TODO: 1 -> w or h, it should map to w-1 or h-1?
		return auto_cast((posf+1)/2 * [2]f64{f64(w),f64(h)})
	}
	triangle_screen_coords := [3][2]int {
		float_to_screen(canvas.width, canvas.height, triangle[0].xy),
		float_to_screen(canvas.width, canvas.height, triangle[1].xy),
		float_to_screen(canvas.width, canvas.height, triangle[2].xy),
	}
	triangle_depth := [3]f64 { triangle[0].z, triangle[1].z, triangle[2].z }

	x1 := triangle_screen_coords[0].x
	x2 := triangle_screen_coords[1].x
	x3 := triangle_screen_coords[2].x
	y1 := triangle_screen_coords[0].y
	y2 := triangle_screen_coords[1].y
	y3 := triangle_screen_coords[2].y

	edge1 := [2]int { x2-x1, y2-y1 }
	edge2 := [2]int { x3-x1, y3-y1 }
	D := edge1.x*edge2.y - edge2.x*edge1.y
	when ONLY_CC_TRIANGLES do if D <= 0 do return {}
	else do if D == 0 do return {}
	factor := D < 0 ? -1 : 1
	D *= factor

	xmin := min(x1, x2, x3)
	ymin := min(y1, y2, y3)
	xmax := max(x1, x2, x3)
	ymax := max(y1, y2, y3)

	xmin = clamp(xmin, 0, canvas.width-1)
	ymin = clamp(ymin, 0, canvas.height-1)
	xmax = clamp(xmax, 0, canvas.width-1)
	ymax = clamp(ymax, 0, canvas.height-1)

	for y in ymin..=ymax {
		l1 := ((xmin-x1)*edge2.y - (y-y1)*edge2.x)*factor
		l2 := (-(xmin-x1)*edge1.y + (y-y1)*edge1.x)*factor
		for x in xmin..=xmax {
			//l1 := ((x-x1)*edge2.y - (y-y1)*edge2.x)*factor
			//l2 := (-(x-x1)*edge1.y + (y-y1)*edge1.x)*factor
			defer {
				l1 += edge2.y*factor
				l2 -= edge1.y*factor
			}

			if l1 < 0 || l2 < 0 || D < l1+l2 do continue

			w0 := D-l1-l2
			w1 := l1
			w2 := l2

			depth := (
				triangle_depth[0]*f64(w0) +
				triangle_depth[1]*f64(w1) +
				triangle_depth[2]*f64(w2) \
			)/f64(D)
			if depth < -1 || 1 < depth do continue
			color := Color((
				([4]int)(colors[0])*w0 +
				([4]int)(colors[1])*w1 +
				([4]int)(colors[2])*w2 \
			)/D)

			if canvas_draw_depth_unsafe(canvas, x, y, depth) {
				canvas_draw_pixel_unsafe(canvas, x, y, color)
			}
		}
	}

	return triangle_screen_coords
}
draw_triangle_img :: proc(canvas: ^Canvas3D, triangle: [3][3]f64, tex: [3][2]int, img: Image, tints: [3]Color) -> [3][2]int {
	float_to_screen :: proc(w,h:int, posf:[2]f64) -> (posi: [2]int) {
		// TODO: 1 -> w or h, it should map to w-1 or h-1?
		return auto_cast((posf+1)/2 * [2]f64{f64(w),f64(h)})
	}
	triangle_screen_coords := [3][2]int {
		float_to_screen(canvas.width, canvas.height, triangle[0].xy),
		float_to_screen(canvas.width, canvas.height, triangle[1].xy),
		float_to_screen(canvas.width, canvas.height, triangle[2].xy),
	}
	triangle_depth := [3]f64 { triangle[0].z, triangle[1].z, triangle[2].z }

	x1 := triangle_screen_coords[0].x
	x2 := triangle_screen_coords[1].x
	x3 := triangle_screen_coords[2].x
	y1 := triangle_screen_coords[0].y
	y2 := triangle_screen_coords[1].y
	y3 := triangle_screen_coords[2].y

	edge1 := [2]int { x2-x1, y2-y1 }
	edge2 := [2]int { x3-x1, y3-y1 }
	D := edge1.x*edge2.y - edge2.x*edge1.y
	when ONLY_CC_TRIANGLES do if D <= 0 do return {}
	else do if D == 0 do return {}
	factor := D < 0 ? -1 : 1
	D *= factor

	xmin := min(x1, x2, x3)
	ymin := min(y1, y2, y3)
	xmax := max(x1, x2, x3)
	ymax := max(y1, y2, y3)

	xmin = clamp(xmin, 0, canvas.width-1)
	ymin = clamp(ymin, 0, canvas.height-1)
	xmax = clamp(xmax, 0, canvas.width-1)
	ymax = clamp(ymax, 0, canvas.height-1)

	for y in ymin..=ymax {
		l1 := ((xmin-x1)*edge2.y - (y-y1)*edge2.x)*factor
		l2 := (-(xmin-x1)*edge1.y + (y-y1)*edge1.x)*factor
		for x in xmin..=xmax {
			//l1 := ((x-x1)*edge2.y - (y-y1)*edge2.x)*factor
			//l2 := (-(x-x1)*edge1.y + (y-y1)*edge1.x)*factor
			defer {
				l1 += edge2.y*factor
				l2 -= edge1.y*factor
			}

			if l1 < 0 || l2 < 0 || D < l1+l2 do continue

			w0 := D-l1-l2
			w1 := l1
			w2 := l2

			depth := (
				triangle_depth[0]*f64(w0) +
				triangle_depth[1]*f64(w1) +
				triangle_depth[2]*f64(w2) \
			)/f64(D)
			if depth < -1 || 1 < depth do continue
			tex_coords := (
				tex[0]*w0 +
				tex[1]*w1 +
				tex[2]*w2 \
			)/D % [2]int { img.w, img.h }
			tint := Color((
				([4]int)(tints[0])*w0 +
				([4]int)(tints[1])*w1 +
				([4]int)(tints[2])*w2 \
			)/D)
			color := img.data[tex_coords.y*img.w + tex_coords.x]
			color = {
				u8(int(color.r)*int(tint.r)/255),
				u8(int(color.g)*int(tint.g)/255),
				u8(int(color.b)*int(tint.b)/255),
				color.a,
			}

			if canvas_draw_depth_unsafe(canvas, x, y, depth) {
				canvas_draw_pixel_unsafe(canvas, x, y, color)
			}
		}
	}

	return triangle_screen_coords
}

draw_fps :: proc(canvas: ^Canvas, fps: int) {
	at := Point { 128 + 5*8, 128 }
	if fps > 999999 {
		blit(canvas, letter_plus, at)
		return
	}
	fps := fps
	if fps == 0 {
		blit(canvas, letter_0, at)
	} else do for fps > 0 {
		digit := fps%10
		fps /= 10
		blit(canvas, number_letter_map[digit], at)
		at.x -= 8
	}
}

draw :: proc(app: ^glue.android_app, state: ^State) {
	if app.window == nil do return

	state := (^State)(app.userData)

	android.ANativeWindow_setBuffersGeometry(app.window, 0, 0, .R8G8B8A8_UNORM)
	buffer: android.ANativeWindow_Buffer
	if android.ANativeWindow_lock(app.window, &buffer, nil) != 0 {
		return
	}
	defer android.ANativeWindow_unlockAndPost(app.window)

	before_draw := time.tick_now()

	touch_color := Color {
		0xF0,
		u8(state.last_touch_pos.x*255/state.window_size.x),
		u8(state.last_touch_pos.y*255/state.window_size.y),
		0xFF,
	}

	canvas := Canvas {
		data = transmute([]Color) runtime.Raw_Slice { buffer.bits, int(buffer.width*buffer.height) },
		width = int(buffer.width),
		stride = int(buffer.stride),
		height = int(buffer.height),
	}
	canvas3d_resize(&state.canvas3d, int(buffer.width)/THREEDEE_GRAPHICS_SCALE, int(buffer.height)/THREEDEE_GRAPHICS_SCALE, preserve_content=false)
	//fmt.println("drawing:", state.canvas.width, state.canvas.height)
	bg := Color {150,150,150,255}
	//canvas_fill(&state.canvas, /*state.bg_color*/)
	canvas3d_reset(&state.canvas3d)

	time_s := f64(time.tick_now()._nsec / 1_000_000) / 1_000

	pos_ratio := ([2]f64)(state.last_touch_pos)/[2]f64{f64(canvas.width),f64(canvas.height)}
	theta_y := math.mod(time_s, math.TAU)//(-math.TAU/8)*(1-pos_ratio.x) + (math.TAU/8)*pos_ratio.x
	theta_x := math.mod(time_s*0.1, math.TAU)//(-math.TAU/8)*(1-pos_ratio.y) + (math.TAU/8)*pos_ratio.y
	bob := math.sin(time_s*1.75) * 0.4

	trans := linalg.matrix4_translate_f64({-0.5, 4, -3})
	bob_trans := linalg.matrix4_translate_f64({0,bob,0})
	rot_y := linalg.matrix4_rotate_f64(theta_y, {0,1,0})
	rot_x := linalg.matrix4_rotate_f64(theta_x, {1,0,0})
	view := linalg.matrix4_look_at_f64({0,0,-12}, {-0.5, 4, -3}, {0,1,0})
	proj := linalg.matrix4_perspective_f64(math.TAU/6, f64(state.canvas3d.width)/f64(state.canvas3d.height), 1, 1000)
	cube_trans := view*bob_trans*trans*rot_y*rot_x
	floor_trans := view*trans

	outlines: [dynamic; 25]struct{triag:Triangle2D,color:Color}

	for triag, i in cube {
		transformed := [3][3]f64 {
			transform(triag[0], cube_trans),
			transform(triag[1], cube_trans),
			transform(triag[2], cube_trans),
		}
		screenspace := [3][3]f64 {
			project_to_screenspace(transformed[0], proj),
			project_to_screenspace(transformed[1], proj),
			project_to_screenspace(transformed[2], proj),
		}

		r := u8(20 + 200*i/(len(cube)-1))
		g := u8(200 - 200*i/(len(cube)-1))
		color := Color {r, g, 150, 255}

		if i == 0 {
			/*coords := draw_triangle_colored(
				&state.canvas3d, screenspace,
				{touch_color,touch_color,touch_color},
			)*/
			coords := draw_triangle_img(
				&state.canvas3d, screenspace,
				{ { 15, 15 }, { 15, 0 }, { 0, 15 } },
				state.wood_block_texture,
				{touch_color,touch_color,touch_color},
			)
			oc := touch_color.rgb/4
			append(&outlines, {coords,{oc.r,oc.g,oc.b,255}})
		} else if i == 1 {
			coords := draw_triangle_img(
				&state.canvas3d, screenspace,
				{ { 0, 15 }, { 15, 0 }, { 0, 0 } },
				state.wood_block_texture,
				{touch_color,touch_color,touch_color},
			)
			oc := touch_color.rgb/4
			append(&outlines, {coords,{oc.r,oc.g,oc.b,255}})
		} else {
			touchy_color := Color {
				u8(int(color.r)*2/3 + int(touch_color.r)/3),
				u8(int(color.g)*2/3 + int(touch_color.g)/3),
				u8(int(color.b)*2/3 + int(touch_color.b)/3),
				255,
			}
			coords := draw_triangle_colored(
				&state.canvas3d, screenspace,
				{color,color,touchy_color},
			)
			oc := color.rgb/4
			append(&outlines, {coords,{oc.r,oc.g,oc.b,255}})
		}
	}
	for triag in floor {
		transformed := [3][3]f64 {
			transform(triag[0], floor_trans),
			transform(triag[1], floor_trans),
			transform(triag[2], floor_trans),
		}
		screenspace := [3][3]f64 {
			project_to_screenspace(transformed[0], proj),
			project_to_screenspace(transformed[1], proj),
			project_to_screenspace(transformed[2], proj),
		}

		coords := draw_triangle_colored(
			&state.canvas3d, screenspace,
			{{255,0,0,255},{0,255,0,255},{0,0,255,255}},
		)
		append(&outlines, {coords,{255,255,255,127}})
	}

	for y in 0..<state.canvas3d.height {
		for ysub in 0..<THREEDEE_GRAPHICS_SCALE {
			y_outer := y*THREEDEE_GRAPHICS_SCALE + ysub
			for x in 0..<state.canvas3d.width {
				color: Color
				#no_bounds_check {
				color = state.canvas3d.data[y*state.canvas3d.stride + x]
				}
				if color.a == 0 do for xsub in 0..<THREEDEE_GRAPHICS_SCALE {
					x_outer := x*THREEDEE_GRAPHICS_SCALE + xsub
					canvas_draw_pixel_unsafe(
						&canvas,
						x_outer, y_outer,
						bg,
					)
				} else do for xsub in 0..<THREEDEE_GRAPHICS_SCALE {
					x_outer := x*THREEDEE_GRAPHICS_SCALE + xsub
					canvas_draw_pixel_unsafe(
						&canvas,
						x_outer, y_outer,
						color,
					)
				}
			}
		}
	}

	for outline in outlines {
		draw_triangle_outline(&canvas, outline.triag*THREEDEE_GRAPHICS_SCALE, outline.color)
	}

	draw_rect(&canvas, {10,16,64,128}, {0,100,200,255})
	draw_rect_outline(&canvas, {64,128,256,512}, {0,0,0,255})
	draw_line(
		&canvas,
		{canvas.width/2, canvas.height/2},
		state.last_touch_pos,
		{0,0,0,255},
	)

	draw_triangle(&canvas, {
		{550,550},
		{750,500},
		{500,750},
	}, {255,255,255,127}, debug=true)

	if state.last_draw_nanos > 0 {
		fps := 1_000_000_000 / int(state.last_draw_nanos)
		draw_fps(&canvas, fps)
	}

	draw_time := time.tick_diff(before_draw, time.tick_now())
	state.last_draw_nanos = draw_time
}
